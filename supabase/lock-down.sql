-- ===========================================================================
-- OPTIONAL: put the app behind a login.
--
-- The live deployment has no login by explicit decision (README -> "Access
-- model"). This file is the reverse of that decision, kept ready so it is a
-- five minute job rather than a rebuild.
--
-- IMPORTANT: this SQL is only half of the change. Running it on its own will
-- lock the app out of its own data — the page has no login screen yet, so it
-- would connect as an anonymous caller and every read would come back empty.
-- Do both halves in one sitting, in this order:
--
--   1. Supabase dashboard -> Authentication -> Providers -> Email: enabled.
--      Authentication -> Sign In / Providers -> turn "Allow new users to sign
--      up" OFF, so the login screen cannot be used to create an account.
--   2. Authentication -> Users -> "Add user" -> create the one account, with a
--      real password. This is the account that will own the payroll data.
--   3. Add the login screen to index.html (sketch at the bottom of this file).
--   4. Run this SQL.
--   5. Reload the app, log in, confirm the roster and history are all there.
--
-- What this gives you: anyone who opens the URL gets a login screen and can
-- neither read nor write anything without the password. The data itself is not
-- reshaped — it stays one shared dataset — so nothing has to be migrated, and
-- every account you create sees the same payroll data. That matches how the
-- app is actually used (one business, one set of books).
-- ===========================================================================

do $$
declare t text;
begin
  foreach t in array array['payroll_config','committed_sheets']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I_open on public.%I', t, t);
    execute format('drop policy if exists %I_signed_in on public.%I', t, t);
    -- `to authenticated` is the whole change: an anonymous caller now matches no
    -- policy at all, and RLS denies by default when nothing matches.
    execute format(
      'create policy %I_signed_in on public.%I for all to authenticated using (true) with check (true)',
      t, t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

notify pgrst, 'reload schema';

-- ===========================================================================
-- The client half. In index.html:
--
-- 1. Give the Supabase client somewhere to keep the session, so logging in is
--    a once-per-device thing rather than a once-per-visit thing:
--
--      const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
--        auth: { persistSession: true, autoRefreshToken: true },
--      });
--
--    (it is currently created with both of those false, since there is no
--    session to keep)
--
-- 2. At the top of boot(), before loadEverything(), wait for a session:
--
--      const { data: { session } } = await sb.auth.getSession();
--      if (!session) { await showLoginOverlay(); }   // resolves once signed in
--
--    showLoginOverlay() renders an email + password form over the splash and
--    calls sb.auth.signInWithPassword({ email, password }). There is no sign-up
--    button — accounts are created in the Supabase dashboard.
--
-- 3. Add a "Sign out" control that calls sb.auth.signOut() then
--    location.reload().
--
-- Prove it worked before trusting it: open the deployed URL in a private
-- window, and confirm you see a login screen and no payroll data.
-- ===========================================================================
