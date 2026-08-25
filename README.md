# Support Beyond — Timesheet, Rates & Km Calculator

Weekly payroll for a Victorian disability support work business: it turns a raw
Jibble time export into a checked, SCHADS-award-correct pay breakdown per
employee, tracks km reimbursement and allowances, and cross-checks the result
against what was entered into Payroller.

This is the **online version**. It runs at a URL, from any device, with the data
living in a database instead of in one browser's storage.

- One static `index.html`, served by **Vercel**. No build step, no server.
- Data in **Supabase** (Postgres).
- A **GitHub Actions** cron pings Supabase daily so the free tier doesn't pause.

The offline double-click-and-open version it grew out of is kept in `archive/`.

---

## Access model — please read

**There is no login.** Anyone who opens the URL can read and edit everything,
including your employees' names, hours and pay rates.

That was a deliberate choice, so that the app just opens. It does mean:

- **Treat the URL like a password.** Don't post it anywhere public, and be
  careful pasting it into anything that might index or share it.
- `robots.txt` and a `noindex` tag keep it out of Google, so it won't be found
  by searching — but a guessed or leaked URL is full access.
- Anyone who reaches it can also **delete** everything, which is the real reason
  to keep the automatic backups switched on (see "Backups" below).

If you want to change this later, it's a small job, not a rebuild:
`supabase/lock-down.sql` puts the app behind a single login and explains the
matching change needed in `index.html`. Both halves have to be done together.

---

## Setup from scratch

Steps 1–7 need a logged-in browser on supabase.com, github.com and vercel.com,
so they're yours to do. Everything else is already written.

### 1. Create the Supabase project

1. Go to **supabase.com** → **New project**.
2. Name it something like `support-beyond-payroll`. Pick the **Sydney** region.
3. Save the database password somewhere — you won't need it for this app, but
   you'll want it eventually.

### 2. Create the tables

1. In the project, open **SQL Editor → New query**.
2. Paste the entire contents of [`supabase/schema.sql`](supabase/schema.sql) and
   press **Run**.
3. You should see "Success. No rows returned."

The whole file is safe to run again any time; it won't duplicate or destroy
anything.

### 3. Get your two values

**Settings → API**, and copy:

- **Project URL** — looks like `https://abcdefghijk.supabase.co`
- **Publishable / anon key** — the long one starting `sb_publishable_…`

That key is *meant* to be public and to sit in the page source — the same
category as a Stripe publishable key. It is not a leak.

### 4. Paste them into two files

In **`index.html`**, near the top of the first `<script>` block (search for
`YOURPROJECT`), replace both lines:

```js
const SUPABASE_URL = 'https://YOURPROJECT.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_REPLACE_ME';
```

In **`.github/workflows/keepalive.yml`**, replace the same two placeholders —
note the key appears **twice** there:

```yaml
curl -sf "https://YOURPROJECT.supabase.co/rest/v1/payroll_config?select=id&limit=1" \
  -H "apikey: sb_publishable_REPLACE_ME" \
  -H "Authorization: Bearer sb_publishable_REPLACE_ME" \
  -o /dev/null
```

Until you do this, the app shows "Not connected to a database yet" instead of
loading.

### 5. Put it on GitHub

Create a new **private** repo on github.com, then from this folder:

```bash
git remote add origin https://github.com/YOURNAME/YOURREPO.git
```

```bash
git push -u origin main
```

### 6. Deploy on Vercel

1. **vercel.com/new** → import the repo.
2. Framework preset: **Other**. Leave the build command and output directory
   **empty**.
3. Deploy. It serves `index.html` at the root and redeploys on every push to
   `main`.

### 7. Start the keep-alive

In the repo on GitHub: **Actions → Supabase keep-alive → Run workflow**. Confirm
it goes green. After that it runs itself, daily.

If you skip this, Supabase pauses the project after 7 days of no requests and
the app stops loading until you un-pause it by hand.

---

## Moving your existing data across

Your current data lives in the old offline app's browser storage. Nothing
transfers automatically — you export it and import it once:

1. Open the old app (`archive/schads-timesheet-calculator_36.html`).
2. Click **Download app + backup**. It saves a
   `support-beyond-backup-YYYY-MM-DD-HHMMSS.json` file.
3. Open the new app's URL.
4. Click **Import backup** and choose that file.

That brings across the roster, rate levels, aliases, public holidays, km
settings, allowances and **every committed week of history**.

Do this once, and check the Km's History tab looks right before you start using
the online version for real. Keep the old file and its backup until you're
confident.

**Importing a backup replaces everything**, it doesn't merge. Don't import an
old backup over newer online work.

---

## Backups

The app still backs itself up on every commit:

- On Chrome or Edge, click **Choose backup folder** once and it writes backup
  JSON straight into that folder from then on, keeping the 2 most recent.
- Otherwise it downloads the backup file.

With no login on the app, this is your safety net against someone finding the
URL and wiping the data, as well as against ordinary mistakes. It's worth
setting the folder up on whichever machine you use most.

---

## Using it day to day

Nothing about the workflow changed. Export the **Weekly Raw Time Entries** CSV
from Jibble (the one *with* the shift notes column — the similar "Weekly Raw
Timesheet" export won't work), upload it, check the week, commit it.

Changes save to the database automatically as you make them. If a save can't get
through, the app tells you, and it parks the unsaved work so it can be finished
next time you open it — including if the browser or the machine dies mid-edit.

---

## If something goes wrong

**"Could not reach the database"** — the app won't start rather than show you
made-up defaults you might then save over the top of your real data. Check your
internet and hit Try again. If it persists, check the Supabase dashboard for a
paused project.

**A setting won't stick** — run
[`supabase/repair-columns.sql`](supabase/repair-columns.sql) in the SQL Editor.
Safe to run any time.

**Saves seem to be going missing** — in the browser console (F12):

```js
startSaveDebug()
```

Reproduce the problem, then run `dumpSaveLog()` and send what it prints. The log
survives a refresh, which is the whole point of it.

---

## What's deliberately not done

- **No login.** See "Access model" above.
- **No offline mode.** "Download app + backup" still saves a copy of the app
  itself, but that copy needs the internet — it's the backup JSON that matters
  now.
- **No multi-device conflict handling.** Two devices editing at the same time is
  last-write-wins. Fine for one person; worth revisiting if that changes.
- **No test suite.** Changes to the pay engine are validated against real Jibble
  CSVs and real Payroller payslips, which is a higher bar than unit tests would
  be, and a manual one.

Project notes for future work — including the SCHADS rules the calculations
implement and the traps in the persistence layer — are in
[`CLAUDE.md`](CLAUDE.md).
