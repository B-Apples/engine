// Sends Engine's due notifications (workout reminders and rest alerts). A database cron job calls this every few
// seconds while anything is due; the jobs and the VAPID key come from the database, so the function needs no secrets.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { send, type Vapid } from "./webpush.ts";

function serviceKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (keys.default) return keys.default;
  } catch { /* fall back to the legacy key */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Use POST", { status: 405 });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });
  const { data: cfg, error: cfgErr } = await db.rpc("engine_push_config");
  if (cfgErr || !cfg?.vapid_private) return new Response("not configured", { status: 503 });
  if (req.headers.get("x-engine-push") !== cfg.secret) return new Response("forbidden", { status: 403 });
  const vapid: Vapid = { publicKey: cfg.vapid_public, privateJwk: JSON.parse(cfg.vapid_private), subject: cfg.subject };

  const { data: due, error } = await db.rpc("engine_push_claim");
  if (error) return new Response(error.message, { status: 500 });
  const gone: string[] = [];
  let sent = 0;
  await Promise.all((due ?? []).map(async (j: Record<string, string>) => {
    try {
      const status = await send({ endpoint: j.endpoint, p256dh: j.p256dh, auth: j.auth }, { title: j.title, body: j.body, tag: j.tag, kind: j.kind }, vapid, j.kind === "rest" ? 60 : 3600);
      if (status === 404 || status === 410) gone.push(j.endpoint); else if (status < 300) sent++;
      else console.error("push failed", status, new URL(j.endpoint).host);
    } catch (e) { console.error("push error", String(e)); }
  }));
  if (gone.length) await db.from("push_subs").delete().in("endpoint", gone);
  return new Response(JSON.stringify({ due: due?.length ?? 0, sent, gone: gone.length }), { headers: { "Content-Type": "application/json" } });
});
