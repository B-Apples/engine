// Writes each account's weekly check-in with Claude at the day and time picked in Settings, in the account's time zone.
// A database cron job calls this every minute while an account is due. The function answers right away and writes the
// check-in in the background: it saves the note as meta/coach (the app shows it on Today) and queues a notification.
// Each account gets at most 3 tries a week, so a failing call can't run up the API bill.
import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void };

const MODEL = "claude-opus-5-5";
const PER_CALL = 3;
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

type Doc = Record<string, any>;
type Job = { user_id: string; tz: string; week_of: string };

function serviceKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (keys.default) return keys.default;
  } catch { /* fall back to the legacy key */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

// Dates are YYYY-MM-DD strings in the athlete's zone; noon UTC keeps the arithmetic clear of DST.
const at = (d: string) => Date.parse(d + "T12:00:00Z");
const addDays = (d: string, n: number) => new Date(at(d) + n * 86400000).toISOString().slice(0, 10);
const diffDays = (a: string, b: string) => Math.round((at(a) - at(b)) / 86400000);
const weekday = (d: string) => new Date(at(d)).getUTCDay();
const localDate = (tz: string) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
const blockWeek = (b: Doc, d: string) => { const n = diffDays(d, b.startDate); return n < 0 ? 0 : Math.floor(n / 7) + 1; };

async function docs(db: SupabaseClient, uid: string, col: string, f?: (q: any) => any) {
  let q = db.from("docs").select("id,data").eq("user_id", uid).eq("col", col);
  if (f) q = f(q);
  const { data, error } = await q;
  if (error) throw new Error(`load ${col}: ${error.message}`);
  return (data ?? []).map((r: Doc) => ({ ...r.data, id: r.id })).filter((d: Doc) => !d.sample);
}

// The planned sessions on each date in a range, from the active block, with whether each one got done.
function planned(b: Doc | null, from: string, days: number, workouts: Doc[]) {
  if (!b?.startDate) return [];
  const out = [];
  for (let i = 0; i < days; i++) {
    const d = addDays(from, i), wk = blockWeek(b, d);
    if (wk < 1 || wk > b.weeks) continue;
    for (const day of (b.days ?? []).filter((x: Doc) => x.weekday === weekday(d))) {
      const done = workouts.find((w) => w.blockId === b.id && w.week === wk && w.dayKey === day.key);
      out.push({ date: d, key: day.key, weekday: DAYS[weekday(d)], session: day.title, type: day.type, blockWeek: wk, deload: !!b.deloadWeek && wk === b.deloadWeek, done: done ? done.date : false });
    }
  }
  return out;
}

const slim = (w: Doc) => {
  const { id, evaluation, evalPending, updatedAt, sample, templateId, startedAt, hr, ...rest } = w;
  return hr ? { ...rest, hr: { avg: hr.avg, max: hr.max, zoneSeconds: hr.zones } } : rest;
};

async function buildPrompt(db: SupabaseClient, job: Job) {
  const uid = job.user_id, end = job.week_of, start = addDays(end, -6);
  const [meta, blocks, workouts, body] = await Promise.all([
    docs(db, uid, "meta", (q) => q.in("id", ["profile", "settings", "coach", "plan"])),
    docs(db, uid, "blocks"),
    docs(db, uid, "workouts", (q) => q.gte("data->>date", addDays(end, -27)).lte("data->>date", end)),
    docs(db, uid, "body", (q) => q.gte("id", addDays(end, -55)).lte("id", end)),
  ]);
  const m = Object.fromEntries(meta.map((d: Doc) => [d.id, d]));
  const p = m.profile ?? {}, coach = m.coach;
  // The targets the app will show on each upcoming session card, which it saves as meta/plan.
  const ahead = new Map<string, Doc>((m.plan?.days ?? []).map((x: Doc) => [x.date + "|" + x.key, x]));
  workouts.sort((a: Doc, b: Doc) => a.date.localeCompare(b.date) || (a.startedAt ?? 0) - (b.startedAt ?? 0));
  body.sort((a: Doc, b: Doc) => a.id.localeCompare(b.id));
  const b = blocks.sort((x: Doc, y: Doc) => (y.startDate ?? "").localeCompare(x.startDate ?? "")).find((x: Doc) => x.active) ?? null;
  const bw = [...body].reverse().find((e: Doc) => e.weightLb)?.weightLb ?? null;
  const ctx = {
    athlete: { goal: p.goal || "General strength and conditioning", units: "pounds, kilometres, pool metres, inches for body measurements", age: p.age ?? null, trainingYears: p.trainingYears ?? null, previousBests: p.prevBests ?? null, bodyWeightLb: bw },
    checkIn: { date: end, weekday: DAYS[weekday(end)], covers: { from: start, to: end } },
    block: b ? {
      name: b.name, focus: b.focus, weeks: b.weeks, deloadWeek: b.deloadWeek ?? null, startDate: b.startDate, weekNow: blockWeek(b, end), endsAfter: addDays(b.startDate, b.weeks * 7 - 1),
      days: (b.days ?? []).map((d: Doc) => ({ weekday: DAYS[d.weekday], title: d.title, type: d.type, items: d.items, cardio: d.cardio, stretches: d.stretches })),
    } : null,
    plannedThisWeek: planned(b, start, 7, workouts).map(({ key, ...x }) => x),
    plannedNext7Days: planned(b, addDays(end, 1), 7, workouts).map(({ key, done, ...x }) => {
      const a = ahead.get(x.date + "|" + key);
      return a ? { ...x, targets: a.targets, cardio: a.cardio } : x;
    }),
    workoutsThisWeek: workouts.filter((w: Doc) => w.date >= start).map(slim),
    workoutsPrevious3Weeks: workouts.filter((w: Doc) => w.date < start).map(slim),
    bodyLast8Weeks: body.map((e: Doc) => ({ date: e.id, weightLb: e.weightLb ?? null, bodyFat: e.bodyFat ?? null, measurementsIn: e.meas ?? null, ...(e.cm ? { customMetrics: customMetrics(m.settings, e.cm) } : {}) })),
    lastCheckIn: coach?.kind === "checkin" && coach.weekOf && coach.weekOf < end ? { weekOf: coach.weekOf, note: coach.note } : null,
  };
  const prompt = `You are an experienced strength and conditioning coach writing an athlete's weekly check-in. It covers the 7 days ending ${DAYS[weekday(end)]} ${end} and sets up the next 7 days. The athlete reads it on their phone.

Write 150 to 250 words in plain, direct language, using Canadian spelling. Use exactly these sections, each a bold heading on its own line followed by 2 to 4 short bullet points:
**This week**
**What's working**
**Watch**
**Next week**
In This week, say how many planned sessions got done and name any that were missed. In Next week, give specific targets for the main lifts and cardio. Where plannedNext7Days has targets or cardio, those are the numbers the app will show the athlete, so quote them; otherwise use double progression within the planned rep range and RPE. Ease off if next week is a deload. If the block ends before next week, say so and suggest a focus for the next block. If lastCheckIn is present, say in one bullet whether last week's targets were met. Exercises that share a "group" value were done back to back as a superset or circuit. Mention fatigue only when RPE or performance shows it. Do not invent data that is not present. No preamble and no sign-off.

DATA (JSON):
${JSON.stringify(ctx)}`;
  return { prompt, settings: m.settings ?? {}, trained: ctx.workoutsThisWeek.length };
}

// The athlete's own metrics (grip strength, vertical jump...) are stored by id; name them for Claude.
function customMetrics(settings: Doc | undefined, cm: Record<string, number>) {
  const defs = new Map<string, Doc>((settings?.metrics ?? []).map((d: Doc) => [d.id, d]));
  return Object.entries(cm).filter(([id]) => defs.has(id) && !defs.get(id)!.removed).map(([id, v]) => ({ name: defs.get(id)!.name, unit: defs.get(id)!.unit || null, value: v, higherIsBetter: defs.get(id)!.higher !== false }));
}
// Coach style from Settings; the same wording is in the evaluate function, which also runs coach chat.
const STYLE: Record<string, string> = {
  blunt: "The athlete chose a short and blunt coaching style. This overrides any length in the request: write about half as many words as it asks for, at most 2 bullet points per section, no praise or softening. Just the numbers and what to do next.",
  detailed: "The athlete chose a detailed and encouraging coaching style. You may write up to about half again as many words as the request asks for. Explain the reasoning behind each point, and give specific credit for what went well before what to fix.",
};

async function ask(client: Anthropic, prompt: string, style?: string) {
  const system = STYLE[style ?? ""];
  const stream = client.beta.messages.stream({
    ...(system ? { system } : {}),
    model: MODEL,
    max_tokens: 16000,
    output_config: { effort: "medium" },
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    messages: [{ role: "user", content: prompt }],
  });
  const message = await stream.finalMessage();
  if (message.stop_reason === "refusal") throw new Error("Claude declined to write the check-in");
  let text = "";
  for (const block of message.content) {
    if (block.type === "fallback") text = "";
    else if (block.type === "text") text += block.text;
  }
  if (!text.trim()) throw new Error(`empty check-in (stop: ${message.stop_reason})`);
  return text.trim();
}

async function run(db: SupabaseClient, client: Anthropic, job: Job, record: boolean) {
  try {
    const { prompt, settings } = await buildPrompt(db, job);
    const note = await ask(client, prompt, settings.coachStyle);
    const { error } = await db.from("docs").upsert({ user_id: job.user_id, col: "meta", id: "coach", data: { note, updatedAt: Date.now(), weekOf: job.week_of, kind: "checkin" }, updated_at: new Date().toISOString() });
    if (error) throw new Error(`save: ${error.message}`);
    if (record) await db.from("checkin_runs").update({ done_at: new Date().toISOString() }).eq("user_id", job.user_id).eq("week_of", job.week_of);
    if (settings.checkinPush === true) {
      const { error: pushErr } = await db.from("push_jobs").insert({ user_id: job.user_id, kind: "checkin", endpoint: null, send_at: new Date().toISOString(), title: "Your weekly check-in is ready", body: "Claude reviewed your week and set next week's targets.", tag: "checkin" });
      if (pushErr) console.error("checkin push", pushErr.message);
    }
    console.log("checkin done", job.week_of);
  } catch (e) {
    if (e instanceof Anthropic.APIError) console.error("checkin claude error", e.status ?? "", String(e.message).slice(0, 300));
    else console.error("checkin failed", String((e as Error)?.message ?? e).slice(0, 300));
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Use POST", { status: 405 });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey(), { auth: { persistSession: false } });
  const { data: cfg, error: cfgErr } = await db.rpc("engine_push_config");
  if (cfgErr || !cfg?.secret) return new Response("not configured", { status: 503 });
  if (req.headers.get("x-engine-push") !== cfg.secret) return new Response("forbidden", { status: 403 });
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return new Response("no Anthropic key", { status: 503 });
  const client = new Anthropic({ apiKey, timeout: 120_000, maxRetries: 1 });

  // {"user": "<uuid>"} writes that account's check-in now, for testing. It isn't recorded, so the scheduled one still runs.
  let only = "";
  try { only = String((await req.json())?.user ?? ""); } catch { /* scheduled call */ }
  let jobs: Job[] = [];
  if (only) {
    const { data } = await db.from("docs").select("data").eq("user_id", only).eq("col", "meta").eq("id", "settings").maybeSingle();
    let tz = data?.data?.tz || data?.data?.tzPhone || "UTC";
    try { localDate(tz); } catch { tz = "UTC"; }
    jobs = [{ user_id: only, tz, week_of: localDate(tz) }];
  } else {
    const { data, error } = await db.rpc("engine_checkins_due");
    if (error) return new Response(error.message, { status: 500 });
    for (const j of (data ?? []) as Job[]) {
      if (jobs.length >= PER_CALL) break;
      const { data: ok } = await db.rpc("engine_checkin_claim", { p_user: j.user_id, p_week: j.week_of });
      if (ok) jobs.push(j);
    }
  }
  EdgeRuntime.waitUntil(Promise.all(jobs.map((j) => run(db, client, j, !only))));
  return new Response(JSON.stringify({ started: jobs.length }), { headers: { "Content-Type": "application/json" } });
});
