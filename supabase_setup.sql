-- ══════════════════════════════════════════════════════════════
--  Ghost Chat — Supabase Setup  (run in: Dashboard → SQL Editor)
-- ══════════════════════════════════════════════════════════════


-- ─── 1. MESSAGES TABLE ────────────────────────────────────────
create table if not exists public.messages (
  id         uuid        primary key default gen_random_uuid(),
  "from"     text        not null check ("from" in ('kinny', 'cosmic')),
  text       text        not null default '',
  ts         bigint      not null unique,   -- epoch ms, used as DOM key
  created_at timestamptz default now(),

  -- file sharing columns
  file_url   text,
  file_name  text,
  file_type  text,
  file_size  bigint
);


-- ─── 2. ROW LEVEL SECURITY ────────────────────────────────────
alter table public.messages enable row level security;

create policy "Allow select" on public.messages
  for select using (true);

create policy "Allow insert" on public.messages
  for insert with check (true);

create policy "Allow delete" on public.messages
  for delete using (true);


-- ─── 3. ENABLE REALTIME ───────────────────────────────────────
alter publication supabase_realtime add table public.messages;


-- ─── 4. STORAGE BUCKET ────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'chat-files',
  'chat-files',
  true,
  52428800,   -- 50 MB per file
  null        -- all file types allowed
)
on conflict (id) do nothing;


-- ─── 5. STORAGE POLICIES ──────────────────────────────────────
create policy "Allow public read" on storage.objects
  for select using (bucket_id = 'chat-files');

create policy "Allow upload" on storage.objects
  for insert with check (bucket_id = 'chat-files');

create policy "Allow delete files" on storage.objects
  for delete using (bucket_id = 'chat-files');


-- ══════════════════════════════════════════════════════════════
--  DONE. Next steps:
--  1. Supabase Dashboard → Settings → API
--  2. Copy "Project URL" and "anon public" key
--  3. Paste into index.html:
--       const SUPABASE_URL  = 'https://xxxx.supabase.co';
--       const SUPABASE_ANON = 'eyJh...';
-- ══════════════════════════════════════════════════════════════

