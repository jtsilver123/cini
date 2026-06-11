-- Desktop import transfer (mirrors prod migration `desktop_import_transfer`).
insert into storage.buckets (id, name, public)
values ('imports', 'imports', false)
on conflict (id) do nothing;

create table public.pending_imports (
  code text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'waiting' check (status in ('waiting','ready')),
  path text,
  created_at timestamptz not null default now()
);

alter table public.pending_imports enable row level security;

create policy "pending_imports_select_own" on public.pending_imports
  for select using (auth.uid() = user_id);
create policy "pending_imports_insert_own" on public.pending_imports
  for insert with check (auth.uid() = user_id);

create policy "imports_read_own" on storage.objects
  for select to authenticated
  using (bucket_id = 'imports' and (storage.foldername(name))[1] = auth.uid()::text);
