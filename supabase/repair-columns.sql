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
