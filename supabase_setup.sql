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
  file_size  bigint,

  -- NEW: read receipt & reply
  seen_at    bigint,          -- epoch ms when peer saw it
  reply_to   bigint,          -- ts of message being replied to
  reply_text text,            -- snapshot of replied message text
  reply_from text             -- who sent the replied message
);

-- Add new columns to existing messages table (safe — no data loss)
alter table public.messages add column if not exists seen_at    bigint;
alter table public.messages add column if not exists reply_to   bigint;
alter table public.messages add column if not exists reply_text text;
alter table public.messages add column if not exists reply_from text;

-- Add push_sub to existing profiles table (safe — no data loss)
alter table public.profiles add column if not exists push_sub text;
alter table public.profiles add column if not exists disappearing_messages boolean default false;

-- ─── 2. REACTIONS TABLE ───────────────────────────────────────
create table if not exists public.reactions (
  id         uuid    primary key default gen_random_uuid(),
  msg_ts     bigint  not null,   -- references messages.ts
  "from"     text    not null check ("from" in ('kinny', 'cosmic')),
  emoji      text    not null,
  created_at timestamptz default now(),
  unique(msg_ts, "from")          -- one reaction per user per message
);


-- ─── 3. PROFILES TABLE ────────────────────────────────────────
create table if not exists public.profiles (
  username   text primary key check (username in ('kinny', 'cosmic')),
  avatar_url text,
  push_sub   text,            -- Web Push subscription JSON (for mobile notifications)
  disappearing_messages boolean default false,
  updated_at timestamptz default now()
);

insert into public.profiles (username) values ('kinny'), ('cosmic')
  on conflict do nothing;


-- ─── 4. ROW LEVEL SECURITY (idempotent — safe to re-run) ────────
alter table public.messages  enable row level security;
alter table public.reactions enable row level security;
alter table public.profiles  enable row level security;

-- messages policies
drop policy if exists "Allow select messages" on public.messages;
drop policy if exists "Allow insert messages" on public.messages;
drop policy if exists "Allow delete messages" on public.messages;
drop policy if exists "Allow update messages" on public.messages;
-- legacy names from old setup
drop policy if exists "Allow select" on public.messages;
drop policy if exists "Allow insert" on public.messages;
drop policy if exists "Allow delete" on public.messages;

create policy "Allow select messages" on public.messages  for select using (true);
create policy "Allow insert messages" on public.messages  for insert with check (true);
create policy "Allow delete messages" on public.messages  for delete using (true);
create policy "Allow update messages" on public.messages  for update using (true);

-- reactions policies
drop policy if exists "Allow select reactions" on public.reactions;
drop policy if exists "Allow insert reactions" on public.reactions;
drop policy if exists "Allow delete reactions" on public.reactions;
drop policy if exists "Allow update reactions" on public.reactions;

create policy "Allow select reactions" on public.reactions for select using (true);
create policy "Allow insert reactions" on public.reactions for insert with check (true);
create policy "Allow delete reactions" on public.reactions for delete using (true);
create policy "Allow update reactions" on public.reactions for update using (true);

-- profiles policies
drop policy if exists "Allow select profiles" on public.profiles;
drop policy if exists "Allow update profiles" on public.profiles;

create policy "Allow select profiles" on public.profiles for select using (true);
create policy "Allow update profiles" on public.profiles for update using (true);


-- ─── 5. ENABLE REALTIME (idempotent — safe to re-run) ──────────
DO $$
BEGIN
  -- messages
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
  END IF;

  -- reactions
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'reactions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.reactions;
  END IF;

  -- profiles
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'profiles'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;
  END IF;
END $$;


-- ─── 6. STORAGE BUCKET ────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'chat-files',
  'chat-files',
  true,
  52428800,   -- 50 MB per file
  null        -- all file types allowed
)
on conflict (id) do nothing;

-- avatar bucket
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars',
  'avatars',
  true,
  5242880,    -- 5 MB per avatar
  array['image/jpeg','image/png','image/gif','image/webp']
)
on conflict (id) do nothing;


-- ─── 7. STORAGE POLICIES (idempotent — safe to re-run) ──────────

-- drop legacy policy names from original setup
drop policy if exists "Allow public read"  on storage.objects;
drop policy if exists "Allow upload"        on storage.objects;
drop policy if exists "Allow delete files"  on storage.objects;

-- drop current names so we can cleanly recreate
drop policy if exists "Allow public read chat-files" on storage.objects;
drop policy if exists "Allow upload chat-files"      on storage.objects;
drop policy if exists "Allow delete chat-files"      on storage.objects;
drop policy if exists "Allow public read avatars"    on storage.objects;
drop policy if exists "Allow upload avatars"         on storage.objects;
drop policy if exists "Allow update avatars"         on storage.objects;
drop policy if exists "Allow delete avatars"         on storage.objects;

create policy "Allow public read chat-files" on storage.objects
  for select using (bucket_id = 'chat-files');

create policy "Allow upload chat-files" on storage.objects
  for insert with check (bucket_id = 'chat-files');

create policy "Allow delete chat-files" on storage.objects
  for delete using (bucket_id = 'chat-files');

create policy "Allow public read avatars" on storage.objects
  for select using (bucket_id = 'avatars');

create policy "Allow upload avatars" on storage.objects
  for insert with check (bucket_id = 'avatars');

create policy "Allow update avatars" on storage.objects
  for update using (bucket_id = 'avatars');

create policy "Allow delete avatars" on storage.objects
  for delete using (bucket_id = 'avatars');


-- ══════════════════════════════════════════════════════════════
--  8. SERVER-SIDE PUSH TRIGGER  (pg_net — works even when app is closed)
--
--  ★ Before running this section, fill in your service_role key below.
--    Get it from: Supabase Dashboard → Settings → API → service_role (secret)
-- ══════════════════════════════════════════════════════════════

-- Enable pg_net (already available on all Supabase projects)
create extension if not exists pg_net;

-- Trigger function — values are hardcoded directly (no ALTER DATABASE needed)
create or replace function public.fn_push_on_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- ★ Paste your service_role key here (Dashboard → Settings → API → service_role)
  c_edge_url  constant text := 'https://goigpzpyvwgriftfnoeg.supabase.co/functions/v1/push-notify';
  c_svc_key   constant text := 'YOUR_SERVICE_ROLE_KEY';

  recipient     text;
  recipient_sub text;
  msg_preview   text;
  req_body      jsonb;
begin
  -- Skip if not yet configured
  if c_svc_key = 'YOUR_SERVICE_ROLE_KEY' then
    return NEW;
  end if;

  -- Determine recipient (only two users in this app)
  recipient := case when NEW."from" = 'kinny' then 'cosmic' else 'kinny' end;

  -- Look up recipient's stored push subscription
  select push_sub into recipient_sub
  from public.profiles
  where username = recipient;

  -- Nothing to do if the recipient hasn't subscribed to push yet
  if recipient_sub is null or recipient_sub = '' then
    return NEW;
  end if;

  -- Build the notification preview text
  msg_preview := case
    when NEW.file_url is not null then '📎 ' || coalesce(NEW.file_name, 'Sent a file')
    when length(NEW.text) > 100   then left(NEW.text, 100) || '…'
    else NEW.text
  end;

  -- Payload matches Mode 1 of the edge function (DB-webhook shape)
  req_body := jsonb_build_object(
    'type',   'INSERT',
    'table',  'messages',
    'schema', 'public',
    'record', jsonb_build_object(
      'from',      NEW."from",
      'text',      NEW.text,
      'ts',        NEW.ts,
      'file_url',  NEW.file_url,
      'file_name', NEW.file_name
    )
  );

  -- Async HTTP POST — never blocks the INSERT even if the edge function is slow
  perform net.http_post(
    url     := c_edge_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || c_svc_key
    ),
    body    := req_body
  );

  return NEW;
exception
  when others then
    -- Push failure must NEVER block message delivery
    raise warning 'fn_push_on_new_message error: %', sqlerrm;
    return NEW;
end;
$$;


-- Attach trigger to messages table
drop trigger if exists trg_push_on_new_message on public.messages;

create trigger trg_push_on_new_message
  after insert on public.messages
  for each row
  execute function public.fn_push_on_new_message();


-- ══════════════════════════════════════════════════════════════
--  DONE — Full setup checklist:
--
--  ① Supabase Dashboard → Settings → API
--      Copy "Project URL" and "anon public" key
--      Paste into index.html (SUPABASE_URL / SUPABASE_ANON)
--
--  ② Generate VAPID keys:
--      npx web-push generate-vapid-keys
--      Put the Public Key in index.html → VAPID_PUBLIC_KEY
--
--  ③ Deploy the Edge Function:
--      supabase functions deploy push-notify
--
--  ④ Set Edge Function secrets (Dashboard → Edge Functions → Secrets):
--      VAPID_PUBLIC_KEY   = <from step ②>
--      VAPID_PRIVATE_KEY  = <from step ②>
--      VAPID_EMAIL        = mailto:you@example.com
--      SUPABASE_URL       = https://xxxx.supabase.co
--      SUPABASE_SERVICE_ROLE_KEY = <service_role key from Dashboard>
--
--  ⑤ In the SQL above, replace YOUR_SERVICE_ROLE_KEY with your
--      actual service_role key, then re-run section 8 only.
--
--  ⑥ Serve the app over HTTPS (e.g. Vercel) so sw.js can register.
--      The app already has vercel.json — just push to GitHub.
--
--  That's it! Push will now fire even when both users have the app closed.
-- ══════════════════════════════════════════════════════════════
