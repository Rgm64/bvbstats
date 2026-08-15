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

## Where the data lives

Rallies are stored in `localStorage` on the device, written through on every
tap. Nothing is uploaded anywhere.

That means the data is only as safe as the device. iOS can evict storage for
apps unused for long periods, and clearing Safari's website data wipes it. Use
**Download backup** after each match — the JSON file it produces can be restored
with **Import backup** and lives outside the browser's sandbox.
