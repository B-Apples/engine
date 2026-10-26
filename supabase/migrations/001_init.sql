-- Engine stores every record as a JSON document: (col, id) -> data, one set per account.
create table public.docs (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  col text not null check (col in ('workouts', 'blocks', 'templates', 'folders', 'body', 'exercises', 'meta')),
  id text not null check (length(id) between 1 and 200),
  data jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, col, id)
);

alter table public.docs enable row level security;

create policy "Read own docs" on public.docs for select to authenticated
  using (user_id = (select auth.uid()));
create policy "Add own docs" on public.docs for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "Change own docs" on public.docs for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Delete own docs" on public.docs for delete to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.docs from anon;
grant select, insert, update, delete on public.docs to authenticated;

-- Live sync between devices.
alter publication supabase_realtime add table public.docs;

-- Progress photos: private bucket, each account limited to its own folder (<user id>/<file>.jpg).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 10485760, array['image/jpeg', 'image/png', 'image/webp']);

create policy "Read own photos" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Add own photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Delete own photos" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
