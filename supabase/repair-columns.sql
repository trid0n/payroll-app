-- ===========================================================================
-- Repair script. Safe to run any time, changes nothing that is already right.
--
-- Run this if the app starts reporting save errors, or if a value stops
-- persisting for no obvious reason: the usual cause is a column that the code
-- writes but the database doesn't have, and PostgREST also caches the schema,
-- so a column that exists can still read as missing until the cache reloads.
--
-- Note that this app deliberately keeps almost everything in JSONB, so there
-- are very few columns that CAN go missing — which is the point.
-- ===========================================================================

-- ===== wrong-project guard =====
-- Every Supabase project's database is named `postgres` and the SQL Editor
-- names no project, so it is easy to run this against the wrong one and see
-- nothing but successes. This file only makes sense on the payroll database,
-- so it refuses to run anywhere payroll_config doesn't already exist.
do $$
begin
  if to_regclass('public.payroll_config') is null then
    raise exception
      'Wrong project: payroll_config does not exist here. Open https://supabase.com/dashboard/project/grspmjuuqfvjkwlswioj/sql/new and run it there.';
  end if;
end $$;

create table if not exists public.payroll_config (
  id text primary key default 'main'
);
alter table public.payroll_config add column if not exists data       jsonb not null default '{}'::jsonb;
alter table public.payroll_config add column if not exists updated_at timestamptz not null default now();

create table if not exists public.committed_sheets (
  id text primary key
);
alter table public.committed_sheets add column if not exists sheet       jsonb;
alter table public.committed_sheets add column if not exists date_from   text;
alter table public.committed_sheets add column if not exists date_to     text;
alter table public.committed_sheets add column if not exists imported_at timestamptz;
alter table public.committed_sheets add column if not exists created_at  timestamptz not null default now();
alter table public.committed_sheets add column if not exists updated_at  timestamptz not null default now();

notify pgrst, 'reload schema';
