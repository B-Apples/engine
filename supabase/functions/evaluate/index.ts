// Runs Engine's post-workout evaluation with Claude. The app sends the prompt it builds from the session; this function
// checks the caller is signed in and within their daily allowance, and streams Claude's answer back. The Anthropic API
// key stays in the project's secrets.
import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

// The app says which feature is asking: coach chat thinks harder than a post-workout evaluation, which should come back
// quickly. Claude Opus 5.5 always thinks; effort sets how much.
const SETUP: Record<string, { model: string; effort: "low" | "medium" | "high" }> = {
  chat: { model: "claude-opus-5-5", effort: "high" },
  eval: { model: "claude-opus-5-5", effort: "medium" },
};
const MAX_PROMPT_CHARS = 400_000;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function publishableKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}");
    if (keys.default) return keys.default;
  } catch { /* fall back to the legacy key */ }
  return Deno.env.get("SUPABASE_ANON_KEY") ?? "";
}
function serviceKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (keys.default) return keys.default;
  } catch { /* fall back to the legacy key */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}
const asUser = (token: string) =>
  createClient(Deno.env.get("SUPABASE_URL")!, publishableKey(), { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${token}` } } });

// Daily allowance (migration 006): each account gets a set number of requests per rolling 24 hours; the owner has no limit.
// A request Claude never answered is given back.
async function takeRequest(token: string): Promise<{ ok: boolean; used?: number; limit?: number | null; freeAt?: string | null }> {
  const { data, error } = await asUser(token).rpc("engine_ai_take");
  if (error) throw error;
  return data;
}
async function refund(userId: string) {
  try {
    await createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } }).rpc("engine_ai_refund", { p_user: userId });
  } catch { /* the request stays counted */ }
}

// Coach style from the account's Settings (meta/settings.coachStyle). It applies to every request through this
// function: post-workout evaluations and coach chat. The checkin function carries the same wording.
const STYLE: Record<string, string> = {
  blunt: "The athlete chose a short and blunt coaching style. This overrides any length in the request: write about half as many words as it asks for, at most 2 bullet points per section, no praise or softening. Just the numbers and what to do next.",
  detailed: "The athlete chose a detailed and encouraging coaching style. You may write up to about half again as many words as the request asks for. Explain the reasoning behind each point, and give specific credit for what went well before what to fix.",
};
async function coachStyle(token: string): Promise<string> {
  try {
    const { data } = await asUser(token).from("docs").select("data").eq("col", "meta").eq("id", "settings").maybeSingle();
    return String(data?.data?.coachStyle ?? "balanced");
  } catch {
    return "balanced";
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { error: "Use POST.", code: "invalid_argument" });

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, publishableKey(), { auth: { persistSession: false } });
  const { data, error: authError } = await sb.auth.getUser(token);
  const user = data?.user;
  if (authError || !user) return json(401, { error: "Sign in again to get evaluations.", code: "session_expired" });

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json(503, { error: "Add your Anthropic API key in Supabase first.", code: "not_configured" });

  let prompt = "", kind = "eval";
  try {
    const b = await req.json();
    prompt = String(b?.prompt ?? "");
    if (b?.kind === "chat") kind = "chat";
  } catch { /* handled below */ }
  if (!prompt || prompt.length > MAX_PROMPT_CHARS) {
    return json(400, { error: "The evaluation request was empty or too large.", code: "invalid_argument" });
  }

  let quota;
  try {
    quota = await takeRequest(token);
  } catch {
    return json(503, { error: "Engine couldn't check your daily Claude allowance. Try again in a minute.", code: "upstream_error" });
  }
  if (!quota.ok) {
    return json(429, { error: `You've used all ${quota.limit} Claude requests for today.`, code: "limit_reached", limit: quota.limit, freeAt: quota.freeAt ?? null });
  }

  const system = STYLE[await coachStyle(token)];
  const client = new Anthropic({ apiKey });
  const encoder = new TextEncoder();
  // Newline-delimited JSON: {t} text deltas, {reset} when a fallback model restarts the answer, then {done} or {error}.
  const body = new ReadableStream({
    async start(controller) {
      const send = (event: Record<string, unknown>) => controller.enqueue(encoder.encode(JSON.stringify(event) + "\n"));
      let answered = false;
      try {
        const stream = client.beta.messages.stream({
          model: SETUP[kind].model,
          max_tokens: 16000,
          output_config: { effort: SETUP[kind].effort },
          betas: ["server-side-fallback-2026-07-01"],
          fallbacks: "default",
          ...(system ? { system } : {}),
          messages: [{ role: "user", content: prompt }],
        });
        for await (const event of stream) {
          if (event.type === "content_block_start" && event.content_block.type === "fallback") send({ reset: true });
          else if (event.type === "content_block_delta" && event.delta.type === "text_delta") { answered = true; send({ t: event.delta.text }); }
        }
        const message = await stream.finalMessage();
        if (message.stop_reason === "refusal") {
          send({ error: "Claude declined to evaluate this session.", code: "refused" });
        } else {
          let text = "";
          for (const block of message.content) {
            if (block.type === "fallback") text = "";
            else if (block.type === "text") text += block.text;
          }
          send({ done: true, text, stop: message.stop_reason });
        }
      } catch (e) {
        if (!answered) await refund(user.id);
        if (e instanceof Anthropic.AuthenticationError) {
          send({ error: "The Anthropic API key in Supabase isn't valid.", code: "not_configured" });
        } else if (e instanceof Anthropic.RateLimitError) {
          send({ error: "Claude is busy right now.", code: "rate_limited" });
        } else if (e instanceof Anthropic.APIError) {
          send({ error: `Claude API error ${e.status ?? ""}: ${String(e.message).slice(0, 300)}`, code: "upstream_error" });
        } else {
          send({ error: String((e as Error)?.message ?? e).slice(0, 300), code: "upstream_error" });
        }
      } finally {
        controller.close();
      }
    },
  });
  return new Response(body, { headers: { ...cors, "Content-Type": "application/x-ndjson", "Cache-Control": "no-store" } });
});
