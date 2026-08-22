# Beach Stat Collector

A courtside beach volleyball stat collection app. One person stands on the
sideline with an iPad or iPhone and taps to record each rally live; the app
aggregates the taps into the `Master_Data` spreadsheet format.

It is a single self-contained HTML file — no build step, no dependencies, no
external requests — installed to the home screen as a Progressive Web App and
fully usable with no signal.

## Files

| File | What it is |
|---|---|
| `index.html` | The whole app |
| `sync.js` | Cross-device sync and sign-in |
| `config.js` | Your Supabase URL and public key — blank means local-only |
| `supabase/schema.sql` | Database tables, roles and access rules |
| `supabase/tests/policy_test.sql` | Proves the access rules hold |
| `sw.js` | Service worker — makes it open offline |
| `manifest.json`, `*.png` | Home-screen install metadata and icons |
| `HANDOFF.md` | v1 design notes — architecture, serve receive, constraints |
| `HANDOFF_v2_ServeTransition.md` | v2 spec — serve/transition, 45-column export |
| `Statting_DecisionTree.ipynb` | The decision trees and SR formulas |
| `app pages.docx` | Screen-by-screen flow and button wording |
| `Master_Data.xlsx` | The 45-column header row the export must match |

## Deploying to GitHub Pages

The repository must be **public** for free-tier Pages (GitHub Pro also allows
private).

1. **Settings** → **Pages** in the left sidebar.
2. Under **Build and deployment**: Source **Deploy from a branch**, Branch
   **`main`**, folder **`/ (root)`** → **Save**.
3. Wait about a minute and refresh. It will show
   `https://<user>.github.io/bvbstats/`.

Every later push to `main` updates the live site.

## Installing on the iPad

1. Open the Pages URL in **Safari** (not Chrome — only Safari can install to the
   home screen on iOS).
2. Share → **Add to Home Screen**.
3. Launch it from the icon. It runs full screen with no browser chrome.

To confirm offline works: launch it once with signal, turn on airplane mode,
then launch it again. It should open normally and let you log a full match.

## Updating an installed copy

The service worker is network-first, so an installed app picks up whatever was
last pushed the next time it launches with a connection. Bump `VERSION` in
`sw.js` on each release so old caches are purged.

## Turning on sync (optional)

Leave `config.js` blank and the app behaves exactly as described above:
everything works, stored on this device only, with no sign-in offered. Sync is
additive.

To switch it on:

1. Create a free project at **supabase.com** (sign in with GitHub). Save the
   database password it asks you to set — it is not recoverable.
2. Open the **SQL editor**, paste the whole of `supabase/schema.sql`, and run
   it. It is safe to run more than once.
3. Go to **Settings → API** and copy the **Project URL** and the **anon public**
   key into `config.js`. Both are safe to commit — the anon key is meant to sit
   in browser code, and the access rules in the schema are what protect the
   data. **Never** put the `service_role` key anywhere near this repo; it
   bypasses every rule.
4. Open the app, enter your email, and follow the link it sends.
5. Back in the SQL editor, run the BOOTSTRAP statements at the bottom of
   `schema.sql` with your email to make yourself an administrator. New accounts
   default to the least-privileged role and can see nothing until promoted.

### Who can see what

| Role | Matches | Stats | Roster |
|---|---|---|---|
| Admin | full | full | full |
| Coach | reads their school | reads their school | reads their school |
| Stat-taker | creates and edits their own | reads their own | reads, can add players |
| Player | — | **only their own rows** | reads their own profile |

These are enforced by the database, not by the app, so they hold even if
someone calls the API directly.

## Pulling a report

`match_stats` is the Master_Data spreadsheet stored as a real table, rebuilt
from the rally log on every sync. The `master_data` view exposes it under the
exact header names from `Master_Data.xlsx`, so you can copy a column name
straight from the sheet:

```sql
select "Player",
       sum("SR FB Kills (3rd Ball)") as kills,
       sum("Total SR Attempts")      as attempts
from master_data
where "School" = 'TEXAS'
group by "Player";
```

Run that in the Supabase SQL editor and use **Download CSV**. Your notebooks can
also connect straight to the database with the Postgres connection string from
Settings → Database, so `pandas.read_sql` works with no export step.

Sum raw counts and divide once, as above — never average a column of
percentages.

## Where the data lives

Rallies are written to `localStorage` on the device, synchronously, on every
tap. That never waits on the network, so a slow, failing or paused backend can
never interrupt a match — sync catches up afterwards.

Signed out, or with `config.js` blank, nothing is uploaded anywhere and the data
is only as safe as the device. iOS can evict storage for
apps unused for long periods, and clearing Safari's website data wipes it. Use
**Download backup** after each match — the JSON file it produces can be restored
with **Import backup** and lives outside the browser's sandbox.
