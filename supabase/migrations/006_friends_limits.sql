-- Friends and a daily Claude allowance.
-- 1. Invite list (the same as 003, which never ran on the live project): only invited emails can make an account.
-- 2. Claude allowance: each account gets a set number of Claude requests (evaluations and coach chat) per rolling
--    24 hours, so invited friends can't run up the owner's API bill. The owner's account has no limit.
-- 3. Friends: an account can opt in to share a small summary (its PRs and/or this week's totals) with the other
--    accounts. Nothing is shared until the person turns it on, and turning it off deletes the shared copy.

-- ---------- 1. invite list ----------
create table if not exists public.engine_invites (
  email text primary key check (email = lower(email)),
  note text,
  created_at timestamptz not null default now()
);
-- Row-level security with no policies: only the dashboard and service role can read or edit the list.
alter table public.engine_invites enable row level security;

create or replace function public.engine_invite_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.engine_invites where email = lower(new.email)) then
    raise exception 'This email is not on the invite list';
  end if;
  new.email_confirmed_at := coalesce(new.email_confirmed_at, now());
  return new;
end;
$$;
revoke execute on function public.engine_invite_only() from public, anon, authenticated;

drop trigger if exists engine_single_account on auth.users;
drop function if exists public.engine_single_account();
-- The one-off copy of the owner's theme from the old app must not reach new accounts.
drop trigger if exists engine_seed_settings on auth.users;
drop function if exists public.engine_seed_settings();

drop trigger if exists engine_invite_only on auth.users;
create trigger engine_invite_only
  before insert on auth.users
  for each row execute function public.engine_invite_only();

-- ---------- 2. Claude allowance ----------
-- One row per Claude request in the last day or so. Only the functions below touch it.
create table if not exists public.ai_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  at timestamptz not null default now()
);
create index if not exists ai_requests_user_at on public.ai_requests (user_id, at desc);
alter table public.ai_requests enable row level security;

-- Per-account allowance. No row: the default (10). A row with daily = null: no limit.
create table if not exists public.ai_limits (
  user_id uuid primary key references auth.users (id) on delete cascade,
  daily int check (daily is null or daily between 0 and 1000),
  note text
);
alter table public.ai_limits enable row level security;

-- The owner's account has no limit.
insert into public.ai_limits (user_id, daily, note)
select id, null, 'owner' from auth.users where email = 'bradenkellough@proton.me'
on conflict (user_id) do update set daily = null, note = 'owner';

-- How many requests the caller has used in the last 24 hours, their allowance, and when the oldest one frees up.
create or replace function public.engine_ai_usage()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  has_row boolean;
  lim int;
  used int;
  oldest timestamptz;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select true, l.daily into has_row, lim from public.ai_limits l where l.user_id = me;
  if not coalesce(has_row, false) then lim := 10; end if;
  select count(*), min(r.at) into used, oldest from public.ai_requests r where r.user_id = me and r.at > now() - interval '24 hours';
  return jsonb_build_object('used', used, 'limit', lim, 'freeAt', case when lim is not null and used >= lim then oldest + interval '24 hours' end);
end;
$$;

-- Takes one request from the caller's allowance. Called by the evaluate function before it asks Claude.
create or replace function public.engine_ai_take()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  u jsonb;
begin
  if me is null then raise exception 'Not signed in'; end if;
  -- One at a time per account, so two quick taps can't both squeeze past the limit.
  perform pg_advisory_xact_lock(hashtext('engine_ai:' || me::text));
  u := public.engine_ai_usage();
  if u->>'limit' is not null and (u->>'used')::int >= (u->>'limit')::int then
    return u || jsonb_build_object('ok', false);
  end if;
  insert into public.ai_requests (user_id) values (me);
  delete from public.ai_requests where user_id = me and at < now() - interval '2 days';
  return jsonb_build_object('ok', true, 'used', (u->>'used')::int + 1, 'limit', u->'limit');
end;
$$;

-- Gives a request back when Claude never answered (an outage or a bad key). Service role only, so an account
-- can't hand itself requests back.
create or replace function public.engine_ai_refund(p_user uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.ai_requests where id = (
    select id from public.ai_requests where user_id = p_user and at > now() - interval '10 minutes' order by at desc limit 1);
$$;

revoke execute on function public.engine_ai_usage(), public.engine_ai_take(), public.engine_ai_refund(uuid) from public, anon, authenticated;
grant execute on function public.engine_ai_usage(), public.engine_ai_take() to authenticated;
grant execute on function public.engine_ai_refund(uuid) to service_role;

-- ---------- 3. friends ----------
-- One row per account that chose to share. data holds only what that person ticked: {prs: [...]} and/or {week: {...}}.
create table if not exists public.friend_shares (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 30),
  data jsonb not null default '{}' check (pg_column_size(data) < 20000),
  updated_at timestamptz not null default now()
);
alter table public.friend_shares enable row level security;
-- Every Engine account is someone on the invite list, so signed-in accounts can see what others chose to share.
drop policy if exists "Friends read shares" on public.friend_shares;
create policy "Friends read shares" on public.friend_shares for select to authenticated using (true);
drop policy if exists "Share own" on public.friend_shares;
create policy "Share own" on public.friend_shares for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists "Update own share" on public.friend_shares;
create policy "Update own share" on public.friend_shares for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "Stop sharing" on public.friend_shares;
create policy "Stop sharing" on public.friend_shares for delete to authenticated using (user_id = (select auth.uid()));
revoke all on public.friend_shares from anon;
grant select, insert, update, delete on public.friend_shares to authenticated;
