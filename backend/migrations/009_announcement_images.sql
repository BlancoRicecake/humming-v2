-- Optional announcement images. PREPARED ONLY: not applied to production.
-- Apply after 005_app_announcements.sql and 006_announcements_admin.sql.
-- Existing rows and older clients remain valid. No rows are inserted/published.
begin;

alter table public.app_announcements
  add column if not exists image_url text,
  add column if not exists image_alt_ko text,
  add column if not exists image_alt_en text;

-- Curated static assets only: no arbitrary remote trackers, SVG, query strings,
-- credentials, ports, traversal or custom schemes. Keep the same rule in Dart/JS.
alter table public.app_announcements drop constraint if exists app_announcements_image;
alter table public.app_announcements add constraint app_announcements_image check (
  (image_url is null and image_alt_ko is null and image_alt_en is null)
  or (
    image_url is not null and image_alt_ko is not null and image_alt_en is not null
    and char_length(image_url) <= 512
    and image_url ~ '^https://(www[.])?hum-track[.]com/assets/notices/[A-Za-z0-9_-]+[.](png|jpg|jpeg|webp)$'
    and image_url !~ '[[:space:][:cntrl:]]'
    and char_length(image_alt_ko) between 1 and 300 and char_length(btrim(image_alt_ko)) > 0
    and char_length(image_alt_en) between 1 and 300 and char_length(btrim(image_alt_en)) > 0
  )
);

-- Image/alternative-text edits are content edits, with the same unread and
-- critical-confirmation behavior as edits to the title or body.
create or replace function public.app_announcements_revision()
returns trigger language plpgsql as $$
begin
  if new.revision < old.revision then
    raise exception 'revision cannot go down (% -> %)', old.revision, new.revision;
  end if;
  if new.revision = old.revision and (
    new.kind, new.title_ko, new.title_en, new.body_ko, new.body_en,
    new.action_label_ko, new.action_label_en, new.action_url,
    new.image_url, new.image_alt_ko, new.image_alt_en
  ) is distinct from (
    old.kind, old.title_ko, old.title_en, old.body_ko, old.body_en,
    old.action_label_ko, old.action_label_en, old.action_url,
    old.image_url, old.image_alt_ko, old.image_alt_en
  ) then
    new.revision := old.revision + 1;
  end if;
  new.updated_at := now();
  return new;
end $$;

-- Preserve the original trigger function's access boundary and all RLS policies.
revoke all on function public.app_announcements_revision() from public, anon, authenticated;
commit;
