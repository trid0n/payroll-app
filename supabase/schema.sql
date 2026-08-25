-- ===========================================================================
-- Support Beyond — Timesheet, Rates & Km Calculator
-- Supabase schema.
--
-- HOW TO RUN: Supabase dashboard -> SQL Editor -> New query -> paste all of
-- this -> Run. The whole file is re-runnable; running it again on an existing
-- database changes nothing and destroys nothing.
--
-- SHAPE: the app holds all of its state as one JSON object. Everything in it
-- except the committed weekly sheets is small and hand-maintained, so it lives
-- in a single JSONB column — which means adding a new setting to the app is
-- never a database migration. The committed sheets grow by one row per payroll
-- week forever, so they get their own table with one row each, which the app
-- pages on read and upserts-and-prunes on write.
-- ===========================================================================

-- ===== helper: auto-bump updated_at =====
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

-- ===== singleton config row =====
-- roster, rate levels, aliases, public holidays, km settings, allowances, theme.
create table if not exists public.payroll_config (
  id         text primary key default 'main',
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

drop trigger if exists set_updated_at on public.payroll_config;
create trigger set_updated_at before update on public.payroll_config
  for each row execute function public.set_updated_at();

-- ===== one row per committed payroll week =====
-- id is the app's own uid() for the sheet, so the app can upsert by it.
-- date_from / date_to are lifted out of the JSON only so the table is legible
-- in the dashboard and sortable; the app reads everything from `sheet`.
create table if not exists public.committed_sheets (
  id          text primary key,
  sheet       jsonb not null,
  date_from   text,
  date_to     text,
  imported_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists committed_sheets_date_idx on public.committed_sheets(date_from);

drop trigger if exists set_updated_at on public.committed_sheets;
create trigger set_updated_at before update on public.committed_sheets
  for each row execute function public.set_updated_at();

-- ===========================================================================
-- ROW LEVEL SECURITY
--
-- READ THIS BEFORE CHANGING IT.
--
-- This deployment has no login, by explicit decision (see the README's "Access
-- model" section). These policies therefore allow ANYONE holding the anon key
-- — which is public, embedded in index.html, and so held by anyone who opens
-- the app's URL — to read, edit and delete all of the payroll data.
--
-- That is deliberate, not an oversight. It is written as an explicit
-- `using (true)` policy rather than by disabling RLS, so that the intent is
-- visible and so that locking it down later is a change to these four lines
-- rather than a rebuild. supabase/lock-down.sql does exactly that.
-- ===========================================================================
do $$
declare t text;
begin
  foreach t in array array['payroll_config','committed_sheets']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I_open on public.%I', t, t);
    execute format(
      'create policy %I_open on public.%I for all to anon, authenticated using (true) with check (true)',
      t, t);
    execute format('grant select, insert, update, delete on public.%I to anon, authenticated', t);
  end loop;
end $$;

notify pgrst, 'reload schema';
