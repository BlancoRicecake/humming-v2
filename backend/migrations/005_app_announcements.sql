-- 005 — in-app announcements feed (2026-10-30)
--
-- NOT APPLIED to any environment. Operators manage rows in the Supabase
-- dashboard (Table editor / SQL editor run as the owner); the apps read the
-- published, currently active rows anonymously over PostgREST:
--   GET {SUPABASE_URL}/rest/v1/app_announcements?select=...&order=starts_at.desc
-- with the public anon key. No app holds a write key; there is no RPC.
--
-- Guide: docs/specs/announcements/announcements-mvp-2026-10-30.md
--
-- Rollback:
--   DROP TABLE IF EXISTS public.app_announcements;
--   DROP FUNCTION IF EXISTS public.app_announcements_revision();

create table if not exists public.app_announcements (
  id               text primary key
                   check (id ~ '^[a-z0-9][a-z0-9_-]{0,63}$'),
  -- bumped automatically when the shown content changes (trigger below);
  -- a new revision is a new announcement for "read" / "acknowledged"
  revision         integer not null default 1 check (revision >= 1),
  kind             text not null check (kind in ('info', 'important', 'critical')),
  title_ko         text not null check (char_length(title_ko) between 1 and 120),
  title_en         text not null check (char_length(title_en) between 1 and 120),
  body_ko          text not null check (char_length(body_ko) between 1 and 4000),
  body_en          text not null check (char_length(body_en) between 1 and 4000),
  -- drafts are invisible to the apps until this is true
  published        boolean not null default false,
  starts_at        timestamptz not null default now(),
  ends_at          timestamptz,
  platforms        text[] not null default array['android', 'ios', 'windows', 'macos'],
  min_build        integer check (min_build >= 0),
  max_build        integer check (max_build >= 0),
  -- optional button: https on hum-track.com (or a subdomain), the stores,
  -- or mail to support. Nothing else (the apps check it again).
  action_label_ko  text check (char_length(action_label_ko) between 1 and 40),
  action_label_en  text check (char_length(action_label_en) between 1 and 40),
  action_url       text check (char_length(action_url) <= 300 and action_url ~ (
                     '^(https://([a-z0-9-]+\.)*hum-track\.com(/[^\s]*)?'
                     || '|https://apps\.apple\.com/[^\s]*'
                     || '|https://play\.google\.com/[^\s]*'
                     || '|mailto:humtrack@gmail\.com)$')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint app_announcements_period check (ends_at is null or ends_at > starts_at),
  constraint app_announcements_builds check (min_build is null or max_build is null or max_build >= min_build),
  constraint app_announcements_platforms check (
    cardinality(platforms) >= 1
    and platforms <@ array['android', 'ios', 'windows', 'macos']),
  constraint app_announcements_action check (
    (action_url is null) = (action_label_ko is null)
    and (action_url is null) = (action_label_en is null))
);

create index if not exists app_announcements_active
  on public.app_announcements (published, starts_at desc);

-- Revision: any change to what the user reads (kind, titles, bodies, action)
-- raises it, unless the editor raised it already. It never goes down.
-- Publishing / scheduling / targeting changes keep it (same announcement).
create or replace function public.app_announcements_revision()
returns trigger language plpgsql as $$
begin
  if new.revision < old.revision then
    raise exception 'revision cannot go down (% -> %)', old.revision, new.revision;
  end if;
  if new.revision = old.revision and (
       new.kind, new.title_ko, new.title_en, new.body_ko, new.body_en,
       new.action_label_ko, new.action_label_en, new.action_url
     ) is distinct from (
       old.kind, old.title_ko, old.title_en, old.body_ko, old.body_en,
       old.action_label_ko, old.action_label_en, old.action_url
     ) then
    new.revision := old.revision + 1;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists app_announcements_revision on public.app_announcements;
create trigger app_announcements_revision
  before update on public.app_announcements
  for each row execute function public.app_announcements_revision();

-- Apps: read only, published and active only. No writes, no functions.
alter table public.app_announcements enable row level security;
revoke all on table public.app_announcements from anon, authenticated;
grant select on table public.app_announcements to anon, authenticated;
revoke all on function public.app_announcements_revision() from public, anon, authenticated;

drop policy if exists "read_published_active" on public.app_announcements;
create policy "read_published_active" on public.app_announcements
  for select to anon, authenticated
  using (published and starts_at <= now() and (ends_at is null or ends_at > now()));
