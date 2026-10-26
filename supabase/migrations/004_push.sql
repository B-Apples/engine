-- Push notifications: workout reminders and rest-timer alerts.
-- push_subs holds each device's push subscription; push_jobs holds what to send and when. A cron job checks every
-- 5 seconds and calls the "push" Edge Function only when something is due. The VAPID private key and the shared
-- secret live in Vault (added separately, never in this file) and only the service role can read them.
create table public.push_subs (
  endpoint text primary key check (endpoint like 'https://%' and length(endpoint) < 1000),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  p256dh text not null check (length(p256dh) < 200),
  auth text not null check (length(auth) < 100),
  updated_at timestamptz not null default now()
);
create index push_subs_user on public.push_subs (user_id);
alter table public.push_subs enable row level security;
create policy "own devices" on public.push_subs for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create table public.push_jobs (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in ('remind', 'rest')),
  endpoint text,            -- send only to this device; null sends to every device on the account
  send_at timestamptz not null,
  title text not null check (length(title) <= 120),
  body text not null default '' check (length(body) <= 300),
  tag text check (length(tag) <= 60)
);
create index push_jobs_due on public.push_jobs (send_at);
create index push_jobs_user on public.push_jobs (user_id, kind);
alter table public.push_jobs enable row level security;
create policy "own jobs" on public.push_jobs for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- At most 40 pending jobs per account (two weeks of reminders plus a rest alert, with room to spare).
create or replace function public.engine_push_cap()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.push_jobs where user_id = new.user_id) >= 40 then
    raise exception 'Too many scheduled notifications';
  end if;
  return new;
end;
$$;
revoke execute on function public.engine_push_cap() from public, anon, authenticated;
create trigger engine_push_cap before insert on public.push_jobs for each row execute function public.engine_push_cap();

-- The app replaces its rest alert in one call when it goes to the background, and removes it when it comes back.
create or replace function public.engine_rest_alert(p_endpoint text, p_send_at timestamptz, p_title text, p_body text)
returns void language sql security invoker set search_path = '' as $$
  delete from public.push_jobs where user_id = (select auth.uid()) and kind = 'rest' and endpoint = p_endpoint;
  insert into public.push_jobs (kind, endpoint, send_at, title, body, tag) values ('rest', p_endpoint, p_send_at, p_title, p_body, 'rest');
$$;
create or replace function public.engine_rest_cancel(p_endpoint text)
returns void language sql security invoker set search_path = '' as $$
  delete from public.push_jobs where user_id = (select auth.uid()) and kind = 'rest' and endpoint = p_endpoint;
$$;
revoke execute on function public.engine_rest_alert(text, timestamptz, text, text), public.engine_rest_cancel(text) from public, anon;
grant execute on function public.engine_rest_alert(text, timestamptz, text, text), public.engine_rest_cancel(text) to authenticated;

-- Used only by the push function (service role): take everything due, drop anything more than 10 minutes late.
create or replace function public.engine_push_claim()
returns table (kind text, title text, body text, tag text, endpoint text, p256dh text, auth text)
language sql security definer set search_path = '' as $$
  with due as (delete from public.push_jobs where send_at <= now() returning *)
  select d.kind, d.title, d.body, d.tag, s.endpoint, s.p256dh, s.auth
  from due d join public.push_subs s on s.user_id = d.user_id and (d.endpoint is null or s.endpoint = d.endpoint)
  where d.send_at > now() - interval '10 minutes';
$$;
create or replace function public.engine_push_config()
returns json language sql security definer set search_path = '' as $$
  select json_build_object(
    'vapid_public', (select decrypted_secret from vault.decrypted_secrets where name = 'engine_vapid_public'),
    'vapid_private', (select decrypted_secret from vault.decrypted_secrets where name = 'engine_vapid_private'),
    'subject', (select decrypted_secret from vault.decrypted_secrets where name = 'engine_vapid_subject'),
    'secret', (select decrypted_secret from vault.decrypted_secrets where name = 'engine_push_secret'));
$$;
revoke execute on function public.engine_push_claim(), public.engine_push_config() from public, anon, authenticated;
grant execute on function public.engine_push_claim(), public.engine_push_config() to service_role;

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
select cron.schedule('engine-push', '5 seconds', $cron$
  select net.http_post(
    url := 'https://niuslslcmzacodgaklwl.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-engine-push', (select decrypted_secret from vault.decrypted_secrets where name = 'engine_push_secret')),
    body := '{}'::jsonb)
  where exists (select 1 from public.push_jobs where send_at <= now());
$cron$);
