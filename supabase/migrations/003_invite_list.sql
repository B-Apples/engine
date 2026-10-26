-- Engine is shared with friends: an account can be created only for an email on the invite list.
-- New accounts are confirmed on creation, so signing up doesn't depend on an email link.
create table public.engine_invites (
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

create trigger engine_invite_only
  before insert on auth.users
  for each row execute function public.engine_invite_only();
