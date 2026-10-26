-- Weekly check-in: at each account's chosen day and time (in its time zone), the "checkin" Edge Function asks Claude
-- to review the week, saves the note as meta/coach and queues a "your check-in is ready" notification.
alter table public.push_jobs drop constraint push_jobs_kind_check;
alter table public.push_jobs add constraint push_jobs_kind_check check (kind in ('remind', 'rest', 'checkin'));

-- One row per account and week; attempts are capped so a failing call can't run up the API bill.
create table public.checkin_runs (
  user_id uuid not null references auth.users (id) on delete cascade,
  week_of date not null,
  tries int not null default 0,
  last_try timestamptz,
  done_at timestamptz,
  primary key (user_id, week_of)
);
-- Row-level security with no policies: only the service role reads or writes it.
alter table public.checkin_runs enable row level security;

-- Accounts whose check-in time has passed this week (up to 12 hours late, to ride out an outage), that trained in the last 14 days, and
-- haven't had this week's check-in. The zone is the one picked in Settings, else the phone's; accounts that haven't
-- opened a version of Engine that saves a zone are skipped.
create or replace function public.engine_checkins_due()
returns table (user_id uuid, tz text, week_of date)
language sql stable security definer set search_path = '' as $$
  with s as (
    select d.user_id,
      coalesce(nullif(d.data->>'tz', ''), nullif(d.data->>'tzPhone', '')) as tz,
      case when d.data->>'checkinDay' ~ '^[0-6]$' then (d.data->>'checkinDay')::int else 0 end as dow,
      case when d.data->>'checkinTime' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then (d.data->>'checkinTime')::time else time '19:00' end as at
    from public.docs d
    where d.col = 'meta' and d.id = 'settings' and coalesce(d.data->>'checkin', 'true') <> 'false'
  ), z as materialized (
    -- Materialized so the zone check runs before any "at time zone", which errors on an unknown zone.
    select s.*, (now() at time zone s.tz) as local_now
    from s where s.tz in (select name from pg_catalog.pg_timezone_names)
  ), w as (
    select z.*, (z.local_now::date - ((extract(dow from z.local_now)::int - z.dow + 7) % 7)) as due_date from z
  )
  select w.user_id, w.tz, w.due_date
  from w
  where w.local_now >= w.due_date + w.at
    and w.local_now < w.due_date + w.at + interval '12 hours'
    and exists (select 1 from public.docs x where x.user_id = w.user_id and x.col = 'workouts'
                and x.data->>'date' >= (w.local_now::date - 14)::text and coalesce(x.data->>'sample', 'false') <> 'true')
    and not exists (select 1 from public.checkin_runs r where r.user_id = w.user_id and r.week_of = w.due_date
                    and (r.done_at is not null or r.tries >= 3 or r.last_try > now() - interval '20 minutes'));
$$;

-- Takes one attempt for an account and week; false if it's done, out of tries, or another run is on it.
create or replace function public.engine_checkin_claim(p_user uuid, p_week date)
returns boolean language plpgsql security definer set search_path = '' as $$
declare ok boolean;
begin
  insert into public.checkin_runs as r (user_id, week_of, tries, last_try) values (p_user, p_week, 1, now())
  on conflict (user_id, week_of) do update set tries = r.tries + 1, last_try = now()
    where r.done_at is null and r.tries < 3 and (r.last_try is null or r.last_try < now() - interval '20 minutes')
  returning true into ok;
  return coalesce(ok, false);
end;
$$;

revoke execute on function public.engine_checkins_due(), public.engine_checkin_claim(uuid, date) from public, anon, authenticated;
grant execute on function public.engine_checkins_due(), public.engine_checkin_claim(uuid, date) to service_role;

-- Looks every minute and calls the function only when an account is due. It shares the push service's secret.
select cron.schedule('engine-checkin', '* * * * *', $cron$
  select net.http_post(
    url := 'https://niuslslcmzacodgaklwl.supabase.co/functions/v1/checkin',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-engine-push', (select decrypted_secret from vault.decrypted_secrets where name = 'engine_push_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 5000)
  where exists (select 1 from public.engine_checkins_due());
$cron$);

-- Remove the placeholder device used to test the push service when it went live.
delete from public.push_subs where endpoint like 'https://httpbin.org/%';
