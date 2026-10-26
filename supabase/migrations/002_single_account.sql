-- Engine is a one-person app: the first account is the only one allowed, and it is confirmed on creation
-- so signing up doesn't depend on an email link.
create or replace function public.engine_single_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from auth.users) then
    raise exception 'Engine already has an account';
  end if;
  new.email_confirmed_at := coalesce(new.email_confirmed_at, now());
  return new;
end;
$$;

revoke execute on function public.engine_single_account() from public, anon, authenticated;

create trigger engine_single_account
  before insert on auth.users
  for each row execute function public.engine_single_account();
