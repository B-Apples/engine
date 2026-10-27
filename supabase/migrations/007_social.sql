-- Social: usernames, friends by request, posts (with photos), props and comments, groups, per-stat privacy, and
-- notifications in the app and on the phone. Replaces friend_shares from 006, which shared with every account.
--
-- Who sees what:
--   profiles        username, name and bio: every Engine account (all of them are invited people), so you can be found.
--   profile_stats   one row per stat a person chose to show, marked 'everyone' or 'friends'. 'Only me' means no row.
--                   'friends' covers accepted friends and people in a group with you.
--   posts           your friends, or the members of the group it was posted to.
--   props/comments  whoever can see the post.
-- Friend requests and groups change only through the functions below, which check the rules.

-- ---------- profiles ----------
create table public.profiles (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  name text not null check (length(btrim(name)) between 1 and 30),
  bio text not null default '' check (length(bio) <= 160),
  -- Phone notifications by kind (request, accepted, prop, comment, group); a missing key means on.
  notify jsonb not null default '{}' check (jsonb_typeof(notify) = 'object' and pg_column_size(notify) < 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "Profiles are visible to every account" on public.profiles for select to authenticated using (true);
create policy "Make own profile" on public.profiles for insert to authenticated with check (user_id = (select auth.uid()));
create policy "Change own profile" on public.profiles for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Delete own profile" on public.profiles for delete to authenticated using (user_id = (select auth.uid()));
revoke all on public.profiles from anon;
grant select, insert, delete on public.profiles to authenticated;
grant update (username, name, bio, notify, updated_at) on public.profiles to authenticated;

-- ---------- friends ----------
-- a asked b. One row per pair, either direction.
create table public.friendships (
  a uuid not null references public.profiles (user_id) on delete cascade,
  b uuid not null references public.profiles (user_id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  primary key (a, b),
  check (a <> b)
);
create unique index friendships_pair on public.friendships (least(a, b), greatest(a, b));
create index friendships_b on public.friendships (b);
alter table public.friendships enable row level security;
create policy "See own friendships" on public.friendships for select to authenticated
  using ((select auth.uid()) in (a, b));
revoke all on public.friendships from anon;
grant select on public.friendships to authenticated;

-- ---------- groups ----------
create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 40),
  about text not null default '' check (length(about) <= 200),
  owner uuid not null references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now()
);
create table public.group_members (
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  added_by uuid,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index group_members_user on public.group_members (user_id);
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
revoke all on public.groups, public.group_members from anon;
grant select on public.groups, public.group_members to authenticated;

-- ---------- helpers used by the policies (they read friendships and groups directly) ----------
create or replace function public.engine_is_friend(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.friendships f where f.status = 'accepted'
    and ((f.a = (select auth.uid()) and f.b = p_user) or (f.b = (select auth.uid()) and f.a = p_user)));
$$;
create or replace function public.engine_in_group(p_group uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.group_members m where m.group_id = p_group and m.user_id = (select auth.uid()));
$$;
-- You, a friend, or someone in a group with you: who 'friends' visibility reaches.
create or replace function public.engine_peer(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user = (select auth.uid()) or public.engine_is_friend(p_user) or exists (
    select 1 from public.group_members m join public.group_members o on o.group_id = m.group_id
    where m.user_id = (select auth.uid()) and o.user_id = p_user);
$$;
-- The same for a storage folder name, which might not be a user id at all.
create or replace function public.engine_peer_folder(p_folder text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  if p_folder is null or p_folder !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return public.engine_peer(p_folder::uuid);
end;
$$;
revoke execute on function public.engine_is_friend(uuid), public.engine_in_group(uuid), public.engine_peer(uuid), public.engine_peer_folder(text) from public, anon;
grant execute on function public.engine_is_friend(uuid), public.engine_in_group(uuid), public.engine_peer(uuid), public.engine_peer_folder(text) to authenticated;

create policy "See own groups" on public.groups for select to authenticated using (public.engine_in_group(id));
create policy "See groupmates" on public.group_members for select to authenticated using (public.engine_in_group(group_id));

-- ---------- stats people chose to show ----------
-- prs: best lifts and recent PRs; week: weekly totals; history: recent sessions; streak: weekly streak and badges;
-- program: current block; body: weight and body fat; meas: measurements; live: "training now"; level: gym level.
create table public.profile_stats (
  user_id uuid not null default auth.uid() references public.profiles (user_id) on delete cascade,
  section text not null check (section in ('prs', 'week', 'history', 'streak', 'program', 'body', 'meas', 'live', 'level')),
  vis text not null check (vis in ('everyone', 'friends')),
  data jsonb not null check (pg_column_size(data) < 40000),
  updated_at timestamptz not null default now(),
  primary key (user_id, section)
);
alter table public.profile_stats enable row level security;
create policy "See stats shared with you" on public.profile_stats for select to authenticated
  using (vis = 'everyone' or public.engine_peer(user_id));
create policy "Share own stats" on public.profile_stats for insert to authenticated with check (user_id = (select auth.uid()));
create policy "Update own stats" on public.profile_stats for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Hide own stats" on public.profile_stats for delete to authenticated using (user_id = (select auth.uid()));
revoke all on public.profile_stats from anon;
grant select, insert, update, delete on public.profile_stats to authenticated;

-- ---------- posts, props, comments ----------
-- kind: text, workout, pr, milestone (badges and streaks), block (a shared training block). data holds the attachment.
-- client_id lets a post written offline be sent again without doubling up.
create table public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles (user_id) on delete cascade,
  client_id text check (length(client_id) <= 60),
  kind text not null check (kind in ('text', 'workout', 'pr', 'milestone', 'block')),
  body text not null default '' check (length(body) <= 2000),
  data jsonb not null default '{}' check (jsonb_typeof(data) = 'object' and pg_column_size(data) < 60000),
  photos text[] not null default '{}' check (cardinality(photos) <= 4),
  group_id uuid references public.groups (id) on delete cascade,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  unique (user_id, client_id)
);
create index posts_created on public.posts (created_at desc);
create index posts_user on public.posts (user_id, created_at desc);
create index posts_group on public.posts (group_id, created_at desc) where group_id is not null;
alter table public.posts enable row level security;
create policy "See friends' and groups' posts" on public.posts for select to authenticated
  using (user_id = (select auth.uid())
    or (group_id is null and public.engine_is_friend(user_id))
    or (group_id is not null and public.engine_in_group(group_id)));
create policy "Post as yourself" on public.posts for insert to authenticated
  with check (user_id = (select auth.uid()) and (group_id is null or public.engine_in_group(group_id)));
create policy "Edit own posts" on public.posts for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Delete own posts" on public.posts for delete to authenticated using (user_id = (select auth.uid()));
revoke all on public.posts from anon;
grant select, insert, delete on public.posts to authenticated;
grant update (body, edited_at) on public.posts to authenticated;

create table public.post_props (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create index post_props_user on public.post_props (user_id);
alter table public.post_props enable row level security;
create policy "See props on posts you can see" on public.post_props for select to authenticated
  using (exists (select 1 from public.posts p where p.id = post_id));
create policy "Give props" on public.post_props for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (select 1 from public.posts p where p.id = post_id));
create policy "Take back props" on public.post_props for delete to authenticated using (user_id = (select auth.uid()));
revoke all on public.post_props from anon;
grant select, insert, delete on public.post_props to authenticated;

create table public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (user_id) on delete cascade,
  body text not null check (length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index post_comments_post on public.post_comments (post_id, created_at);
create index post_comments_user on public.post_comments (user_id, created_at desc);
alter table public.post_comments enable row level security;
create policy "See comments on posts you can see" on public.post_comments for select to authenticated
  using (exists (select 1 from public.posts p where p.id = post_id));
create policy "Comment as yourself" on public.post_comments for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (select 1 from public.posts p where p.id = post_id));
-- Your own comments, or any comment on your own post.
create policy "Delete comments" on public.post_comments for delete to authenticated
  using (user_id = (select auth.uid()) or exists (select 1 from public.posts p where p.id = post_id and p.user_id = (select auth.uid())));
revoke all on public.post_comments from anon;
grant select, insert, delete on public.post_comments to authenticated;

-- Photos point into the caller's own folder of the "social" bucket, and an account can't flood the feed.
create or replace function public.engine_post_check()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from unnest(new.photos) p where p not like new.user_id::text || '/%' or p like '%..%') then
    raise exception 'Photos must be your own uploads';
  end if;
  if tg_op = 'INSERT' and (select count(*) from public.posts where user_id = new.user_id and created_at > now() - interval '1 day') >= 60 then
    raise exception 'Too many posts today';
  end if;
  return new;
end;
$$;
revoke execute on function public.engine_post_check() from public, anon, authenticated;
create trigger engine_post_check before insert or update on public.posts for each row execute function public.engine_post_check();

create or replace function public.engine_comment_cap()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.post_comments where user_id = new.user_id and created_at > now() - interval '1 day') >= 300 then
    raise exception 'Too many comments today';
  end if;
  return new;
end;
$$;
revoke execute on function public.engine_comment_cap() from public, anon, authenticated;
create trigger engine_comment_cap before insert on public.post_comments for each row execute function public.engine_comment_cap();

-- ---------- notifications ----------
create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  actor uuid references public.profiles (user_id) on delete cascade,
  kind text not null check (kind in ('request', 'accepted', 'prop', 'comment', 'group')),
  post_id uuid references public.posts (id) on delete cascade,
  group_id uuid references public.groups (id) on delete cascade,
  body text not null default '' check (length(body) <= 200),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index notifications_user on public.notifications (user_id, created_at desc);
alter table public.notifications enable row level security;
create policy "See own notifications" on public.notifications for select to authenticated using (user_id = (select auth.uid()));
create policy "Mark own notifications" on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Clear own notifications" on public.notifications for delete to authenticated using (user_id = (select auth.uid()));
revoke all on public.notifications from anon;
grant select, delete on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

-- Phone notifications go through push_jobs (migration 004), sent within seconds by the push function.
alter table public.push_jobs drop constraint push_jobs_kind_check;
alter table public.push_jobs add constraint push_jobs_kind_check check (kind in ('remind', 'rest', 'checkin', 'social'));

-- Records one notification and, if the person allows that kind and has a phone set up, queues a push.
create or replace function public.engine_notify(p_user uuid, p_actor uuid, p_kind text, p_post uuid, p_group uuid, p_body text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  who text;
  title text;
  allow boolean;
begin
  if p_user is null or p_user = p_actor then return; end if;
  -- Props taken back and given again don't notify twice.
  if p_kind = 'prop' and exists (select 1 from public.notifications n where n.user_id = p_user and n.actor = p_actor
      and n.kind = 'prop' and n.post_id = p_post and n.created_at > now() - interval '1 day') then return; end if;
  insert into public.notifications (user_id, actor, kind, post_id, group_id, body)
  values (p_user, p_actor, p_kind, p_post, p_group, left(coalesce(p_body, ''), 200));
  delete from public.notifications where user_id = p_user and created_at < now() - interval '60 days';

  select coalesce((p.notify ->> p_kind)::boolean, true) into allow from public.profiles p where p.user_id = p_user;
  if not coalesce(allow, false) or not exists (select 1 from public.push_subs s where s.user_id = p_user) then return; end if;
  -- Stay under the 40-job cap from migration 004 (a full queue skips the phone buzz, never the notification).
  if (select count(*) from public.push_jobs j where j.user_id = p_user) >= 30 then return; end if;
  select name into who from public.profiles where user_id = p_actor;
  title := case p_kind
    when 'request' then who || ' sent you a friend request'
    when 'accepted' then who || ' accepted your friend request'
    when 'prop' then who || ' gave you props'
    when 'comment' then who || ' commented'
    else who || ' added you to a group' end;
  insert into public.push_jobs (user_id, kind, send_at, title, body, tag)
  values (p_user, 'social', now(), left(title, 120), left(coalesce(p_body, ''), 300), left('social-' || p_kind || '-' || coalesce(p_post::text, p_actor::text), 60));
end;
$$;
revoke execute on function public.engine_notify(uuid, uuid, text, uuid, uuid, text) from public, anon, authenticated;

create or replace function public.engine_on_prop()
returns trigger language plpgsql security definer set search_path = '' as $$
declare p record;
begin
  select user_id, kind, body, data into p from public.posts where id = new.post_id;
  perform public.engine_notify(p.user_id, new.user_id, 'prop', new.post_id, null,
    coalesce(nullif(p.data ->> 'title', ''), nullif(p.body, ''), 'your post'));
  return new;
end;
$$;
create or replace function public.engine_on_comment()
returns trigger language plpgsql security definer set search_path = '' as $$
declare owner uuid;
begin
  select user_id into owner from public.posts where id = new.post_id;
  perform public.engine_notify(owner, new.user_id, 'comment', new.post_id, null, new.body);
  return new;
end;
$$;
revoke execute on function public.engine_on_prop(), public.engine_on_comment() from public, anon, authenticated;
create trigger engine_on_prop after insert on public.post_props for each row execute function public.engine_on_prop();
create trigger engine_on_comment after insert on public.post_comments for each row execute function public.engine_on_comment();

-- ---------- friend requests ----------
-- Returns 'sent', 'accepted' (they had already asked you), 'pending' (already asked), 'friends', or 'not_found'.
create or replace function public.engine_friend_request(p_username text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  them uuid;
  f record;
begin
  if me is null or not exists (select 1 from public.profiles where user_id = me) then raise exception 'Pick a username first'; end if;
  select user_id into them from public.profiles where username = lower(btrim(p_username));
  if them is null then return 'not_found'; end if;
  if them = me then raise exception 'That''s you'; end if;
  select * into f from public.friendships where (a = me and b = them) or (a = them and b = me);
  if found then
    if f.status = 'accepted' then return 'friends'; end if;
    if f.a = me then return 'pending'; end if;
    update public.friendships set status = 'accepted', accepted_at = now() where a = them and b = me;
    perform public.engine_notify(them, me, 'accepted', null, null, '');
    return 'accepted';
  end if;
  if (select count(*) from public.friendships where a = me and status = 'pending') >= 50 then raise exception 'Too many requests waiting'; end if;
  insert into public.friendships (a, b) values (me, them);
  perform public.engine_notify(them, me, 'request', null, null, '');
  return 'sent';
end;
$$;
create or replace function public.engine_friend_accept(p_from uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  update public.friendships set status = 'accepted', accepted_at = now() where a = p_from and b = me and status = 'pending';
  if not found then return false; end if;
  perform public.engine_notify(p_from, me, 'accepted', null, null, '');
  return true;
end;
$$;
-- Declines, cancels or unfriends, whichever applies.
create or replace function public.engine_friend_remove(p_other uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.friendships where (a = (select auth.uid()) and b = p_other) or (a = p_other and b = (select auth.uid()));
  delete from public.notifications where kind = 'request' and ((user_id = p_other and actor = (select auth.uid())) or (user_id = (select auth.uid()) and actor = p_other));
$$;
-- Everyone you're connected with: [{user_id, username, name, bio, status: friends | incoming | outgoing, since}].
create or replace function public.engine_friends()
returns jsonb language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', p.user_id, 'username', p.username, 'name', p.name, 'bio', p.bio,
    'status', case when f.status = 'accepted' then 'friends' when f.a = (select auth.uid()) then 'outgoing' else 'incoming' end,
    'since', coalesce(f.accepted_at, f.created_at)) order by p.name), '[]'::jsonb)
  from public.friendships f
  join public.profiles p on p.user_id = case when f.a = (select auth.uid()) then f.b else f.a end
  where (select auth.uid()) in (f.a, f.b);
$$;

-- ---------- groups ----------
create or replace function public.engine_group_create(p_name text, p_about text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  gid uuid;
begin
  if me is null or not exists (select 1 from public.profiles where user_id = me) then raise exception 'Pick a username first'; end if;
  if (select count(*) from public.groups where owner = me) >= 20 then raise exception 'You already run 20 groups'; end if;
  insert into public.groups (name, about, owner) values (btrim(p_name), coalesce(btrim(p_about), ''), me) returning id into gid;
  insert into public.group_members (group_id, user_id, added_by) values (gid, me, me);
  return gid;
end;
$$;
create or replace function public.engine_group_update(p_group uuid, p_name text, p_about text)
returns void language sql security definer set search_path = '' as $$
  update public.groups set name = btrim(p_name), about = coalesce(btrim(p_about), '') where id = p_group and owner = (select auth.uid());
$$;
-- Any member can add one of their own friends.
create or replace function public.engine_group_add(p_group uuid, p_user uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  gname text;
begin
  if not public.engine_in_group(p_group) then raise exception 'Not in this group'; end if;
  if not public.engine_is_friend(p_user) then raise exception 'You can only add your friends'; end if;
  if (select count(*) from public.group_members where group_id = p_group) >= 50 then raise exception 'Groups hold up to 50 people'; end if;
  insert into public.group_members (group_id, user_id, added_by) values (p_group, p_user, me) on conflict do nothing;
  if not found then return false; end if;
  select name into gname from public.groups where id = p_group;
  perform public.engine_notify(p_user, me, 'group', null, p_group, gname);
  return true;
end;
$$;
-- Leaving (p_user is you) or, for the owner, removing someone. When the owner leaves, the longest-standing member
-- takes over; the last one out deletes the group.
create or replace function public.engine_group_remove(p_group uuid, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  own uuid;
  heir uuid;
begin
  select owner into own from public.groups where id = p_group;
  if own is null then return; end if;
  if p_user <> me and own <> me then raise exception 'Only the group''s owner can remove people'; end if;
  delete from public.group_members where group_id = p_group and user_id = p_user;
  if p_user = own then
    select user_id into heir from public.group_members where group_id = p_group order by joined_at limit 1;
    if heir is null then delete from public.groups where id = p_group;
    else update public.groups set owner = heir where id = p_group; end if;
  end if;
end;
$$;
create or replace function public.engine_group_delete(p_group uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.groups where id = p_group and owner = (select auth.uid());
$$;
-- Your groups with their members: [{id, name, about, owner, members: [{user_id, username, name}]}].
create or replace function public.engine_groups()
returns jsonb language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'about', g.about, 'owner', g.owner, 'created_at', g.created_at,
    'members', (select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'username', p.username, 'name', p.name) order by m.joined_at)
      from public.group_members m join public.profiles p on p.user_id = m.user_id where m.group_id = g.id)) order by g.name), '[]'::jsonb)
  from public.groups g;
$$;

-- ---------- reading the feed ----------
-- Newest first, 20 at a time (older pages with p_before). p_group: one group's posts; p_user: one person's posts;
-- p_post: just that post (opened from a notification).
-- Runs as the caller, so the policies above decide what comes back.
create or replace function public.engine_feed(p_before timestamptz default null, p_group uuid default null, p_user uuid default null, p_limit int default 20, p_post uuid default null)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) from (
    select p.id, p.user_id, p.kind, p.body, p.data, p.photos, p.group_id, p.created_at, p.edited_at,
      pr.username, pr.name, g.name as group_name,
      (select count(*) from public.post_props k where k.post_id = p.id) as props,
      exists (select 1 from public.post_props k where k.post_id = p.id and k.user_id = (select auth.uid())) as propped,
      (select coalesce(jsonb_agg(q.name), '[]'::jsonb) from (select pf.name from public.post_props k join public.profiles pf on pf.user_id = k.user_id
        where k.post_id = p.id order by k.created_at desc limit 3) q) as prop_names,
      (select count(*) from public.post_comments c where c.post_id = p.id) as comments
    from public.posts p
    join public.profiles pr on pr.user_id = p.user_id
    left join public.groups g on g.id = p.group_id
    where (p_before is null or p.created_at < p_before)
      and (p_group is null or p.group_id = p_group)
      and (p_user is null or p.user_id = p_user)
      and (p_post is null or p.id = p_post)
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 50)
  ) x;
$$;
create or replace function public.engine_comments(p_post uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'user_id', c.user_id, 'username', p.username, 'name', p.name,
    'body', c.body, 'created_at', c.created_at) order by c.created_at), '[]'::jsonb)
  from public.post_comments c join public.profiles p on p.user_id = c.user_id where c.post_id = p_post;
$$;
create or replace function public.engine_notifications()
returns jsonb language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'actor', n.actor, 'username', p.username, 'name', p.name,
    'post_id', n.post_id, 'group_id', n.group_id, 'body', n.body, 'created_at', n.created_at, 'read', n.read_at is not null)
    order by n.created_at desc), '[]'::jsonb)
  from (select * from public.notifications where user_id = (select auth.uid()) order by created_at desc limit 60) n
  left join public.profiles p on p.user_id = n.actor;
$$;

revoke execute on function public.engine_friend_request(text), public.engine_friend_accept(uuid), public.engine_friend_remove(uuid), public.engine_friends(),
  public.engine_group_create(text, text), public.engine_group_update(uuid, text, text), public.engine_group_add(uuid, uuid), public.engine_group_remove(uuid, uuid),
  public.engine_group_delete(uuid), public.engine_groups(), public.engine_feed(timestamptz, uuid, uuid, int, uuid), public.engine_comments(uuid), public.engine_notifications()
  from public, anon;
grant execute on function public.engine_friend_request(text), public.engine_friend_accept(uuid), public.engine_friend_remove(uuid), public.engine_friends(),
  public.engine_group_create(text, text), public.engine_group_update(uuid, text, text), public.engine_group_add(uuid, uuid), public.engine_group_remove(uuid, uuid),
  public.engine_group_delete(uuid), public.engine_groups(), public.engine_feed(timestamptz, uuid, uuid, int, uuid), public.engine_comments(uuid), public.engine_notifications()
  to authenticated;

-- ---------- post photos: private bucket "social", <user id>/<file>.jpg ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('social', 'social', false, 5242880, array['image/jpeg', 'image/webp'])
on conflict (id) do nothing;
create policy "Post photos: add own" on storage.objects for insert to authenticated
  with check (bucket_id = 'social' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Post photos: friends and groups see them" on storage.objects for select to authenticated
  using (bucket_id = 'social' and public.engine_peer_folder((storage.foldername(name))[1]));
create policy "Post photos: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'social' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------- when storage fills up, the oldest posts go ----------
-- The free plan has 1 GB of file storage and 500 MB of database. Once files pass 800 MB, the "trim" function
-- (run daily by cron) deletes the oldest posts that have photos, and their photos, until files are back under 700 MB.
-- Progress photos are never touched. Posts without photos are tiny; if the database passes 400 MB the oldest of those go too.
create or replace function public.engine_trim_plan()
returns table (post_id uuid, paths text[])
language sql stable security definer set search_path = '' as $$
  with total as (select coalesce(sum((o.metadata ->> 'size')::bigint), 0) as bytes from storage.objects o),
  sized as (
    select p.id, p.photos, p.created_at,
      (select coalesce(sum((o.metadata ->> 'size')::bigint), 0) from storage.objects o where o.bucket_id = 'social' and o.name = any (p.photos)) as bytes
    from public.posts p where cardinality(p.photos) > 0
  ), run as (
    select s.*, sum(s.bytes) over (order by s.created_at, s.id) as freed from sized s
  )
  select r.id, r.photos from run r, total t
  where t.bytes > 800 * 1024 * 1024 and t.bytes - (r.freed - r.bytes) > 700 * 1024 * 1024
  order by r.created_at;
$$;
create or replace function public.engine_trim_text()
returns int language plpgsql security definer set search_path = '' as $$
declare n int := 0;
begin
  if pg_database_size(current_database()) > 400 * 1024 * 1024 then
    delete from public.posts where id in (select id from public.posts where cardinality(photos) = 0 order by created_at limit 500);
    get diagnostics n = row_count;
  end if;
  return n;
end;
$$;
revoke execute on function public.engine_trim_plan(), public.engine_trim_text() from public, anon, authenticated;
grant execute on function public.engine_trim_plan(), public.engine_trim_text() to service_role;

select cron.schedule('engine-trim', '17 9 * * *', $cron$
  select net.http_post(
    url := 'https://niuslslcmzacodgaklwl.supabase.co/functions/v1/trim',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-engine-push', (select decrypted_secret from vault.decrypted_secrets where name = 'engine_push_secret')),
    body := '{}'::jsonb);
$cron$);

-- ---------- the old share-with-everyone table ----------
-- Its one row (your weekly totals and PRs) is rebuilt from your data under the new privacy settings.
drop table if exists public.friend_shares;
