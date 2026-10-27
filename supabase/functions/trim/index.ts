// Keeps Engine inside the free plan's storage. A daily cron job calls this; once post photos push file storage past
// 800 MB it deletes the oldest posts that have photos (photos first, then the posts) until storage is under 700 MB,
// and if the database passes 400 MB it drops the oldest text-only posts. Progress photos are never touched.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

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
  // Same shared secret as the push function, so only the cron job can run it.
  const { data: cfg } = await db.rpc("engine_push_config");
  if (!cfg?.secret || req.headers.get("x-engine-push") !== cfg.secret) return new Response("forbidden", { status: 403 });

  const { data: plan, error } = await db.rpc("engine_trim_plan");
  if (error) return new Response(error.message, { status: 500 });
  let posts = 0, photos = 0;
  // In batches, so one failure leaves the rest for tomorrow and a post is only deleted once its photos are gone.
  for (let i = 0; i < (plan ?? []).length; i += 50) {
    const batch = plan.slice(i, i + 50) as { post_id: string; paths: string[] }[];
    const paths = batch.flatMap((p) => p.paths);
    const { error: rmErr } = await db.storage.from("social").remove(paths);
    if (rmErr) { console.error("remove failed", rmErr.message); break; }
    photos += paths.length;
    const { error: delErr } = await db.from("posts").delete().in("id", batch.map((p) => p.post_id));
    if (delErr) { console.error("delete failed", delErr.message); break; }
    posts += batch.length;
  }
  const { data: textPosts } = await db.rpc("engine_trim_text");
  return new Response(JSON.stringify({ posts, photos, textPosts: textPosts ?? 0 }), { headers: { "Content-Type": "application/json" } });
});
