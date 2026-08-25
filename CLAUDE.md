# CLAUDE.md — project notes

Notes for a future Claude session with no memory of this one. Read this before
changing anything.

---

## What this is

**Support Beyond — Timesheet, Rates & Km Calculator.** It turns a raw Jibble
time-tracking export into a checked, SCHADS-award-correct pay breakdown per
employee, tracks km reimbursement and allowances, and cross-checks the result
against what was actually entered into Payroller.

It used to be a double-click-and-open HTML file with everything in
`localStorage`. It is now a web app: one static `index.html` served by Vercel,
with the data in Supabase (Postgres). The React app itself did not change in
that move — see "How the port worked" below.

### Business context

- **Business**: Support Beyond, a disability support worker business in
  Warragul, VIC. ~14 casual support workers.
- **Time tracking**: Jibble. Staff clock in/out via the app; the business
  exports a **"Weekly Raw Time Entries"** CSV each week. This is a specific
  Jibble export — a different "Weekly Raw Timesheet" export looks similar but
  lacks the shift notes column this app depends on for km/break/sleepover
  detection.
- **Payroll**: Payroller. Hours are manually re-entered into Payroller from
  what this app calculates. The Payroller cross-check feature exists because
  that manual re-entry is where mistakes happen.
- **Award**: SCHADS, casual SACS-classified employees, Victoria. Rates are
  updated roughly once a financial year from a Fair Work pay summary.

---

## The stack, and why

One static `index.html` on Vercel. Data and nothing else in Supabase. A GitHub
Actions cron keeps the free-tier Supabase project from pausing. Vanilla
everything — **no build step, no bundler, no package.json, no server process.**
The file you edit is the file that gets served.

Do not introduce a framework, a bundler or a build step. The entire value of
this arrangement is that there is nothing to keep alive. This machine has no
`node`, no `npm`, no `gh` and no `supabase` CLI, and the app is expected to keep
working without them. `python` resolves to the Windows Store stub, not an
interpreter — for text processing, use Git Bash's `awk`/`sed`/`grep` or
PowerShell.

### How the port worked (and why it was cheap)

The offline app routed **all** of its persistence through a single shim:

```js
window.storage.get(STORAGE_KEY)        // -> { key, value } | null
window.storage.set(STORAGE_KEY, json)  // value is one big JSON blob
```

That was the whole surface. So going online meant reimplementing
`window.storage` against Postgres and changing **nothing** in the ~3,100 lines
of React below it. The SCHADS calculation engine that was validated against real
payslips is byte-for-byte the code that was validated. Keep it that way: if you
need new persistence behaviour, put it in the online layer, not in the app.

The only edits made to the app source during the port were mechanical:

- the three `import` lines became `const { useState, ... } = React` etc.
- `export default function App()` became `function App()`, with
  `window.__PayrollApp = App` at the very bottom (the compiled source runs
  inside a function scope, so `App` has to be handed out explicitly)
- the 16 `lucide-react` icons are now hand-rolled inline components with the
  same API, so there is no icon package to load at runtime

### JSX with no build step

The source is JSX, so something has to compile it. It sits in a
`<script type="text/x-jsx-source" id="app-source">` tag — inert to the browser —
and is compiled at runtime by `@babel/standalone`.

Compiling ~190KB on every page load is about a second of nothing, so the
compiled output is cached in `localStorage` keyed by a hash of the source
(`compileApp()`). Edit the source and the hash changes, so **a stale cache is
not possible**. On a cache hit Babel is never even downloaded.

If the app ever fails to start after an edit, the first thing to check is
whether the edit is valid JSX — a syntax error surfaces as the "Could not start
the app" screen with the Babel message in it, not as a silent failure.

---

## File map

```
index.html                     the whole app. Edit this. Served as-is.
  ├─ <head>                    splash CSS + pre-paint theme
  ├─ script #1                 THE ONLINE LAYER (config, db, window.storage, stash, compile)
  └─ script #app-source        the React app, ~3,100 lines of JSX
supabase/schema.sql            run this in the SQL Editor. Re-runnable.
supabase/repair-columns.sql    run if saves start failing
supabase/lock-down.sql         optional: put the app behind a login (not run)
.github/workflows/keepalive.yml  daily ping so Supabase doesn't pause
robots.txt                     noindex (there is no login — see below)
archive/                       the pre-online originals, for reference. Do not edit.
```

Inside `index.html`, useful landmarks in the app source: `DEFAULT_LEVELS` and
the other constants at the top, `T_DARK`/`T_LIGHT` and `makeStyles(T)` for
theming, `function App()` about a third of the way down, then the small
presentational components below it.

---

## Access model — read before touching RLS

**This deployment has no login.** Anyone who opens the URL can read and edit all
of the payroll data, including employee names and pay rates.

**The repo is also public** (github.com/trid0n/payroll-app), so the project URL
and anon key are published, and with the policies below that is full access to
the data. Liam was told this plainly before the first push and chose it anyway.

Both were his explicit decisions, made after the trade-offs were spelled out.
They are not oversights, and not something to "fix" unprompted — but they are
also not settled forever, so if he asks about tightening things up, the two
independent levers are repo visibility and `supabase/lock-down.sql`.

Access is written as an explicit `using (true)` RLS policy rather than by
disabling RLS, so the intent is visible in the schema. `robots.txt` plus a
`noindex` meta keep the deployed URL out of search results, though they do
nothing about the repo.

If he ever changes his mind, `supabase/lock-down.sql` is written and ready — it
needs a matching login screen in `index.html`, and the file carries the sketch
for it. Both halves have to land together or the app locks itself out.

---

## The online layer

All of it is in the first `<script>` block of `index.html`.

### Data shape

The app holds one JSON blob. It is split in two on the way to Postgres:

| In the blob | Where it goes |
| --- | --- |
| `levels`, `levelOrder`, `roster`, `aliases`, `holidays`, `kmSettings`, `allowances`, `themeMode`, `lastBackupAt` | `payroll_config.data` — one JSONB column, one row (`id = 'main'`) |
| `committedSheets` | `committed_sheets` — one row per payroll week |

**Everything that can be JSONB is JSONB, deliberately.** Every column is a
migration a human has to run by hand in a dashboard; a JSONB blob absorbs shape
changes for free. Adding a new setting to the app therefore needs no migration
at all. Only put something in its own column if you need to query or sort by it
— `date_from`/`date_to` on `committed_sheets` are lifted out only so the table
is legible in the dashboard.

### The rules the layer follows

Each of these exists because of a specific failure mode. Do not remove them
because they look defensive.

1. **Paging on `committed_sheets`.** Supabase caps a REST response at 1000 rows
   with **no error and no warning**. A plain `.select('*')` on a table that
   grows per user action silently truncates, and it reads as "my data didn't
   save" while the rows sit safely on the server. The read is paged with a
   stable `.order('id')` — `range()` without a stable sort skips and repeats
   rows. Verified with 2,350 seeded rows: 4 requests, no gaps, no duplicates.
2. **Upsert-and-prune, never delete-then-insert.** Deleting all rows and
   re-inserting leaves a window where the table is empty; a refresh in that
   window destroys everything. Instead the current set is upserted and only
   genuinely-departed ids are deleted, tracked in `store.savedIds`.
   `store.savedJson` additionally skips re-sending rows whose JSON hasn't
   changed — a save that edits one week out of 2,349 sends exactly one row.
3. **Sheets are written before config.** If the second write fails, the visible
   result is a committed week whose km hasn't been added to anyone's YTD yet,
   which is obvious and fixable. The other order bumps YTD km with no sheet to
   explain it, and re-committing would double it.
4. **Writes are serialised** through `store.writeChain`. Two overlapping writes
   could otherwise prune rows using a `savedIds` picture built before the first
   one landed.
5. **A failed initial load is fatal, on purpose.** If the load fails, the app
   does not mount. Mounting anyway would show `DEFAULT_ROSTER` as if it were the
   real roster, and the first edit would overwrite good server data with the
   defaults. It retries three times with backoff first, and `store.loadFailed`
   makes any later `set()` throw rather than write.

### The unsaved-work stash

Firing a pending save on unload does **not** work — the request is async and the
browser tears the page down long before a round trip completes. What works is
synchronous: `stashUnsaved()` parks the unsaved blob in `localStorage` on
`pagehide`/`visibilitychange`, and `replayStash()` writes it on the next load
*before* the app loads anything else, so nothing has to reconcile against
already-loaded state. This also survives a crash, a killed tab or a flat
battery.

- `pagehide`, not `beforeunload`: `beforeunload` is unreliable on mobile Safari
  and blocks bfcache. `visibilitychange` covers backgrounding the tab, where the
  page can be discarded without `pagehide` ever firing.
- The stash is cleared **only** after a save that covers all of it.
- A stash older than the config row's `updated_at` is dropped, not replayed — it
  came from a session that was superseded on another device, and replaying it
  would undo the newer work.

### Save diagnostics

In the browser console:

```js
startSaveDebug()   // then reproduce the problem
dumpSaveLog()      // console.table of everything that happened
stopSaveDebug()
```

Entries go to `localStorage`, **not the console**, because the moment worth
seeing is usually the one that tears the page down and takes the console with
it. Off by default; costs one string compare when off.

---

## Core business logic

The part most worth understanding before changing anything. These rules were
reverse-engineered against real Payroller payslips over many iterations and
verified to match exactly. If you touch the overtime engine, **re-validate
against real payslip data** — grab a real CSV + payslip pair, not synthetic
data, and check every bucket, not just the total.

### Rate levels

`DEFAULT_LEVELS`: `l21`, `l22`, `l24`, `custom13`, `admin`. Each has 8 rate
fields — `hourly, afternoon, night, saturday, sunday, publicHoliday, otTier1,
otTier2` — except `admin`, which has `flat: true` and pays every hour at
`hourly`. `custom13` is a negotiated individual rate structure, not a standard
award level.

### Day-type classification (`baseDayType`, `splitSegmentByWindow`)

1. Public holiday beats everything else.
2. Otherwise Saturday / Sunday / weekday, from the calendar date.
3. **Only on a weekday** is a shift split by time of day: before 8pm = ordinary
   weekday, 8pm–midnight = afternoon, midnight–8am = night. A shift crossing 8am
   rolls onto the *next calendar day's own* classification. Saturday, Sunday and
   public holiday shifts are **never** split by time of day.

### Overtime (`computeWeekBuckets`) — the trickiest part

Two **independent** checks; whichever produces the bigger number governs (they
do not stack):

1. **Daily**: any Mon–Fri day where weekday+afternoon+night exceeds 10 hours in
   that single day. Sat/Sun/PH are excluded from this check entirely.
2. **Weekly**: `weekday + afternoon + night + saturday` exceeds 38 across the
   week. Saturday *counts toward* the 38-hour pool but is never itself reduced
   by it.
3. `totalOT = max(dailyExcess, weeklyExcess)`. If weekly governs, the OT comes
   out of the **weekday bucket only**. If daily governs, each day's excess comes
   out of that day's own buckets — night first, then afternoon, then weekday.
4. Tiers: `otTier1 = min(2, totalOT)`, `otTier2 = max(0, totalOT - 2)`.

**Saturday has its own separate overtime rule**, layered on afterward: the
threshold is **12 hours**, not 10, and there is no under-2-hours grace tier —
hours past 12 go straight to `otTier2`. Computed per Saturday date and added in
at the end.

### Km reimbursement

`kmSettings` (`underTaxable`, `underExempt`, `overExempt`, `threshold`; defaults
`$0.08 / $0.91 / $0.99 / 5000km`). Below the YTD threshold, km split into a
taxable-and-super component plus an exempt component; above it the whole amount
is exempt. YTD km is tracked live as sheets are committed, and the app flags
when someone is about to *cross* the threshold mid-week — a real
action-required moment, since the business has to update that person's rate in
Payroller by hand.

### Auto-detection from Jibble shift notes

- **Km**: matches `26km`, `26 kms`, and the common typo `26kn`. Any other bare
  number in a note becomes an **approval candidate** rather than being silently
  trusted — a stray number is more often a golf score than a missed km figure.
- **Breaks**: `"N break(s) @ $X"` or `"N break(s) at $X"` (both separators occur
  in practice), matched against the two configured break-allowance amounts.
- **Sleepovers**: notes containing "sleepover", "slept over", or "overnight
  stay".

### Name matching (`matchNameToRoster`)

In order: known alias lookup → exact name → slugified match → **first word only**
against the alias table. That last tier exists because Payroller sometimes
spells a nickname out in full ("Tristen Holland") where the alias table only has
the bare nickname from Jibble.

---

## Key reusable components

- **`ClickCopyEdit`** — click to copy, double-click to edit in place. Debounces
  the click so a double-click doesn't fire two copies first. **Always pass a
  fixed `width`** matching whatever editor replaces it, or switching in and out
  of edit mode visibly jolts the layout. This bit us once already.
- **`StepperInput`** — −/+ counter. Manages its own focus via `useEffect` +
  `focus({ preventScroll: true })` rather than the native `autofocus`
  attribute, because native autofocus forces a scroll-into-view with no way to
  opt out — another layout jolt.
- **`CopyableHeader`** — column headers that copy their full word on click
  (clicking "Aft" copies "Afternoon").
- **`Dropdown`** — custom select; portals its option list to `document.body` so
  it isn't clipped by scrolling containers, and flips upward if there's no room.
- **`CollapseBody`** — CSS grid `0fr`/`1fr` height animation. **Use this**, not
  ad-hoc `{condition && <div>}`, for any new expand/collapse UI. Inconsistency
  here was a recurring complaint earlier in the build.
- **Theming** — pull colours from `T`; never hardcode them in a component.

---

## Migrations are a human step

There is no `supabase` CLI here. A schema change means writing SQL, and Liam
pasting it into **SQL Editor → New query → Run**. So:

- Keep `supabase/schema.sql` re-runnable (`if not exists` / `or replace` /
  `drop … if exists`). It will be run again many times.
- Prefer putting the new thing in JSONB, where it needs no migration at all.
- If you genuinely need a column, update `schema.sql`, write the code to work
  without it, and say **plainly which behaviour is dead until the SQL is run**.
- **Never trust a "migration confirmed run" note**, including one you wrote. The
  cheap check is to attempt a write and read the error. PostgREST names a
  missing column in a `PGRST204`.
- `supabase/repair-columns.sql` re-adds every declared column with
  `add column if not exists` and ends in `notify pgrst, 'reload schema'`.

Also: **a code fix is not a data fix.** If a bug has been writing bad rows,
guarding the write path fixes the future and nothing else. Ask separately what
is already in the database and repair it in the same change. A read filter that
hides bad rows is not a repair. With no `psql` here, repairs run from the
browser console against live data via the app's own `window.storage` methods —
write the snippet, explain it, and have Liam run it.

---

## Testing

There is no way to syntax-check JS outside a browser here, and no test suite.
The workflow that works:

1. `cp index.html index-test.html`
2. Replace the supabase-js CDN `<script>` tag with a fake client, and the
   URL/key placeholders with fake values. The fake used during the port is
   described below; rebuild it rather than trying to stub `db` directly, since
   `db` and `sb` are `const` and can't be overridden from outside.
3. `serve-test.ps1` (a `System.Net.HttpListener` static server on 8787) plus
   `.claude/launch.json` pointing at it, then `preview_start`.
4. **Exercise the feature.** Console errors, scripted interaction, computed
   styles. Confirm it works, not merely that it loads.
5. **Remove `index-test.html`, `serve-test.ps1` and `.claude/launch.json` before
   committing.** They are in `.gitignore` as a second line of defence.

Facts about this harness worth knowing before you write one:

- **A synchronous in-memory fake cannot reproduce a persistence race.** The fake
  needs real latency *and* a store that survives a reload (`localStorage`). Give
  it a latency knob and a failure-injection flag — testing the load-failure path
  needs one.
- Implement only the PostgREST surface the db layer uses, and **throw loudly on
  anything else**, so a silent wrong answer isn't possible.
- The stash from `replayStash()` means a harness reload replays whatever the
  previous test left behind. That is usually what you want to test; when it
  isn't, clear the stash key explicitly before reloading.
- Each `javascript_exec` is a separate round trip with seconds of real
  wall-clock between calls, so anything with a timeout expires between them.
  **Drive multi-step timing-sensitive interactions in ONE call.**
- Screenshots were unavailable in the session that did the port (the browser
  pane wasn't compositing). Computed-style checks are a workable substitute for
  contrast bugs; they are not a substitute for layout review.
- **Selector order matters.** `document.querySelector('input[type=file]')` picks
  the *backup JSON* input, not the CSV one — the CSV input is
  `input[accept*="csv"]`. Grabbing the wrong one reads as "the import silently
  did nothing".

### Bugs found only by exercising the app

- **Invisible error message.** The fatal-error heading hardcoded the dark
  theme's `#EEF1F7` while the pre-paint script switched the splash background to
  the light theme's `#F7F9FC` — 1.05:1 contrast, a completely invisible error
  screen for anyone using light mode. Static review missed it entirely; it
  turned up in a computed-style check. All splash/error colours now come from
  CSS custom properties that the pre-paint script re-points as a set.
- From the offline era, same category: a button whose text was the same colour
  as its own background, a click handler on an element that could never receive
  the click, and an invisible scroll container.

**Scroll bugs specifically:** don't reason from the CSS. Per the CSS Overflow
spec, setting one of `overflow-x`/`overflow-y` to a non-`visible` value silently
computes the other to `auto`, so any element setting one axis is a latent scroll
container. Sweep the live DOM instead: check `getComputedStyle(el).overflowX/Y`
across `document.querySelectorAll('*')` and flag where `scrollHeight >
clientHeight` is actually true. For "the page is taller than it should be", hide
children one at a time and watch `document.documentElement.scrollHeight`.

---

## Working expectations

- **Commit and push directly to `main` without asking**, once a change is
  verified working. Don't ask "should I commit?" for routine fixes and features.
- If a commit is blocked by a secret-detection classifier over the Supabase anon
  key, it's a false positive — that key is meant to be public. Don't fight it;
  explain, and hand over the exact `git commit` / `git push` commands to run.
- **Minimal, verified-necessary changes** over defensive or speculative ones.
- Comments explain *why*, never *what*, and only when non-obvious.
- For an open-ended request, give a short set of concrete options and a
  recommendation. For architecturally significant ambiguity, ask one clarifying
  question before building rather than guessing.
- **An action the app will silently undo on the next load is worse than no
  action** — don't offer it.
- On dependencies: this was built dependency-free on purpose, after earlier
  CDN-based approaches proved less reliable than writing the ~150 lines needed
  (there is a hand-rolled ZIP writer and PDF writer in here). Don't reach for a
  library reflexively for something the file already solves in 20 lines.

---

## Known gaps / flagged but not resolved

- **`wagesPay` and `grandTotal` in committed sheets are wrong, and dead.** The
  pay loop looks up `level[dt]` where `dt` is `"weekday"`, but the rate field is
  named `hourly` — so every weekday hour is priced at $0. This is pre-existing
  (it is in the offline build too) and currently harmless: both fields are
  written into the committed-sheet record and **never read back anywhere**. The
  UI works in hours, not dollars. Fixing it means either renaming the bucket or
  mapping `weekday → hourly` at the lookup, and then re-validating against a
  real payslip. Don't fix it casually — and if you do, the historical rows
  already in `committed_sheets` hold the wrong values and need repairing too.
- Karren Web's Saturday/OT rates on real payslips don't cleanly match a standard
  Level 2.1 — likely an individually negotiated rate, never fully reconciled.
- Tristan Holland's payslips have shown an "Ordinary Hours - higher rate" line
  that doesn't map to any standard award category.
- Payslips from before ~July 2026 use an older rate table; the rate card only
  reflects what's current, not history.
- A reminder ("take 40% off pre-tax income for Brytnie") is surfaced in the UI
  but not computed anywhere.
- The Payroller cross-check's "Other units" column is breaks + sleepovers
  *combined*, because Payroller only exposes one "Other - General" line — it
  can't tell you which type a mismatch belongs to.
- **"Download app + backup"** still works and still writes a pristine copy of
  `index.html`, but that copy is no longer a working offline app — it points at
  Supabase and needs the internet. The **backup JSON is the part that matters**
  now. Worth revisiting if a genuine offline mode is ever wanted.
- The app has no multi-device conflict handling: two devices editing at once is
  last-write-wins on the whole config blob. Fine for one person; would need
  thought if that ever changes.
