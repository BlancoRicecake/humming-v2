-- Humming V2 — initial schema (P0)
-- Maps to docs/infra-mvp.html §8 (Supabase 스키마).
-- Apply via: supabase db push, or `psql $DATABASE_URL -f 001_initial_schema.sql`.
--
-- Conventions
--   * All user-scoped tables enable RLS (user_id = auth.uid()).
--   * uuid primary keys (gen_random_uuid). pgcrypto must be enabled.
--   * Nested cascade: project → tracks → chunks → notes.
--   * chunks.audio_url is NOT NULL only for vocal role (enforced via CHECK).

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- projects --
create table if not exists public.projects (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  name        text not null default 'Untitled',
  bpm         integer not null default 90 check (bpm between 20 and 320),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists projects_user_id_idx on public.projects(user_id);

-- ------------------------------------------------------------------ tracks --
create table if not exists public.tracks (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references public.projects(id) on delete cascade,
  role        text not null check (role in ('vocal','instrument','drum','chord')),
  program     integer not null default 0,
  options     jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists tracks_project_id_idx on public.tracks(project_id);

-- ------------------------------------------------------------------ chunks --
create table if not exists public.chunks (
  id              uuid primary key default gen_random_uuid(),
  track_id        uuid not null references public.tracks(id) on delete cascade,
  timeline_start  double precision not null default 0,
  in_point        double precision not null default 0,
  out_point       double precision not null default 0,
  original_length double precision not null default 0,
  audio_url       text,
  created_at      timestamptz not null default now()
);
create index if not exists chunks_track_id_idx on public.chunks(track_id);

-- Enforce: vocal-role tracks must store audio_url; non-vocal must NOT.
-- We can't see track.role directly from chunk row constraint, so we use a trigger.
create or replace function public.chunks_enforce_audio_url() returns trigger
language plpgsql as $$
declare r text;
begin
  select role into r from public.tracks where id = new.track_id;
  if r = 'vocal' and new.audio_url is null then
    raise exception 'chunks.audio_url required for vocal track';
  end if;
  return new;
end;
$$;
drop trigger if exists chunks_audio_url_trg on public.chunks;
create trigger chunks_audio_url_trg
  before insert or update on public.chunks
  for each row execute function public.chunks_enforce_audio_url();

-- ------------------------------------------------------------------- notes --
create table if not exists public.notes (
  id         uuid primary key default gen_random_uuid(),
  chunk_id   uuid not null references public.chunks(id) on delete cascade,
  pitch      integer not null check (pitch between 0 and 127),
  start      double precision not null default 0,
  duration   double precision not null default 0,
  velocity   integer not null default 100 check (velocity between 0 and 127)
);
create index if not exists notes_chunk_id_idx on public.notes(chunk_id);

-- ----------------------------------------------------------- subscriptions --
create table if not exists public.subscriptions (
  user_id              uuid primary key references auth.users(id) on delete cascade,
  store                text not null check (store in ('app_store','play_store')),
  product_id           text not null,
  status               text not null check (status in ('trial','active','cancelled','expired')),
  trial_ends_at        timestamptz,
  expires_at           timestamptz,
  original_purchase_at timestamptz,
  last_renewed_at      timestamptz,
  cancel_reason        text,
  updated_at           timestamptz not null default now()
);

-- IAP webhook idempotency (Apple notificationUUID / Google notificationId).
create table if not exists public.iap_notifications (
  notification_id text primary key,
  store           text not null check (store in ('app_store','play_store')),
  payload         jsonb,
  received_at     timestamptz not null default now()
);

-- ===================================================================== RLS ==
alter table public.projects      enable row level security;
alter table public.tracks        enable row level security;
alter table public.chunks        enable row level security;
alter table public.notes         enable row level security;
alter table public.subscriptions enable row level security;

-- projects: owner-only
drop policy if exists projects_owner on public.projects;
create policy projects_owner on public.projects
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- tracks: owner-via-project
drop policy if exists tracks_owner on public.tracks;
create policy tracks_owner on public.tracks
  using (exists (select 1 from public.projects p
                  where p.id = tracks.project_id and p.user_id = auth.uid()))
  with check (exists (select 1 from public.projects p
                  where p.id = tracks.project_id and p.user_id = auth.uid()));

-- chunks: owner-via-track→project
drop policy if exists chunks_owner on public.chunks;
create policy chunks_owner on public.chunks
  using (exists (select 1 from public.tracks t
                  join public.projects p on p.id = t.project_id
                  where t.id = chunks.track_id and p.user_id = auth.uid()))
  with check (exists (select 1 from public.tracks t
                  join public.projects p on p.id = t.project_id
                  where t.id = chunks.track_id and p.user_id = auth.uid()));

-- notes: owner-via-chunk→track→project
drop policy if exists notes_owner on public.notes;
create policy notes_owner on public.notes
  using (exists (select 1 from public.chunks c
                  join public.tracks t on t.id = c.track_id
                  join public.projects p on p.id = t.project_id
                  where c.id = notes.chunk_id and p.user_id = auth.uid()))
  with check (exists (select 1 from public.chunks c
                  join public.tracks t on t.id = c.track_id
                  join public.projects p on p.id = t.project_id
                  where c.id = notes.chunk_id and p.user_id = auth.uid()));

-- subscriptions: owner-read-only via RLS. Writes go through service-role backend.
drop policy if exists subscriptions_self_read on public.subscriptions;
create policy subscriptions_self_read on public.subscriptions
  for select using (user_id = auth.uid());

-- updated_at auto-touch on projects
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists projects_touch_trg on public.projects;
create trigger projects_touch_trg
  before update on public.projects
  for each row execute function public.touch_updated_at();
