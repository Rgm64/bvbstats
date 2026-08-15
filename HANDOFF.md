# Beach Volleyball Stat Collector — Handoff

**Status:** working prototype, needs storage swap + PWA packaging before deployment
**Prototype file:** `beach_stat_collector.html` — since renamed to `index.html` so GitHub Pages serves it at the site root (single file, no build step, no dependencies)
**Audience:** Claude Code, continuing design and implementation

---

## 1. What this is

A single-user, courtside stat collection tool for collegiate beach volleyball. One person (the user) stands on the sideline with an iPad or iPhone and taps to record what happens on each rally, live, while watching the match. The app aggregates those taps into a spreadsheet.

Design constraints that drive everything else:

- **Eyes are on the court, not the screen.** Every rally must be recordable in as few taps as possible with no scrolling, no dropdowns, no typing. Current cost is **2 taps per rally** (1 for an ace). Do not regress this.
- **Outdoors, bright sun, one-handed.** Large targets, high contrast, no thin gray-on-gray text.
- **Offline.** No network at most venues. Must work fully offline once installed.
- **iOS delivery without an Apple Developer account.** Ships as a Progressive Web App via Safari's "Add to Home Screen." Not an App Store app.

The output is a spreadsheet called Master_Data. **Each match produces exactly two rows — one per player**, because beach volleyball teams are two people and every stat is attributed to an individual.

---

## 2. Domain background

For a reader with no volleyball context.

Two players per side. A rally begins with a serve. This app **only tracks rallies where the user's team is receiving serve** — the "serve receive" or SR side. Rallies where the user's team serves are not recorded at all. This is a deliberate scope boundary (see §6).

A receive rally has up to three touches:

1. **First ball — the pass.** One of the two players receives the serve and passes it. Graded 0–3 (0 = aced, 3 = perfect).
2. **Second ball — the set, or the option.** The *other* player (the non-passer) plays the second ball. Normally they set it back to the passer. Sometimes they attack it themselves — this is called going "on 2" or **taking the option**, abbreviated **A2**. They can also commit a **ball-handling error (BHE)**, which ends the rally.
3. **Third ball — the attack.** The passer swings. This is the "first ball side out" (**FBSO**) opportunity.

Any attack (on 2 or on 3) ends in a kill (point won), an error (point lost), or is dug by the opponent (rally continues). The app records the first two outcomes as terminal and the third as "attempt happened, rally moved on."

Key abbreviations used throughout the code and spreadsheet:

| Term | Meaning |
|---|---|
| SR | Serve receive |
| BHE | Ball-handling error (on the second ball) |
| A2 | Attack on 2 — the non-passer attacking the second ball instead of setting |
| FB | First ball side out — the third-ball attack off a serve receive |
| MTP | "Make the play" — a rate metric from last season (see §9) |

---

## 3. The decision tree — source of truth

**If the code and this section ever disagree, this section is correct.** This is the logic the user validated. It originated as a Colab notebook and was extended during design (extensions marked ★).

```
RALLY (user's team is receiving)
│
├─ Opponent missed the serve
│    └─ record kind='oppServeError'. No SR attempt charged to either player.
│       (Point is won by the team but is NOT attributed to a player — see §6.)
│
└─ Serve is in play
     │  record passer ∈ {a, b} and rating ∈ {0,1,2,3}
     │  passer.sr[rating]++
     │
     ├─ rating = 0  (aced)
     │    └─ passer.pointsGiven++ ; rally ends, nothing further recorded
     │
     └─ rating ∈ {1,2,3}
          │  the SECOND BALL is always played by the PARTNER (the non-passer)
          │
          ├─ partner commits a ball-handling error
          │    └─ partner.bhe++ ; partner.pointsGiven++
          │
          ├─ partner takes the option (attacks on 2)
          │    │  partner.a2Attempts++
          │    ├─ kill   → partner.a2Kills++  ; partner.pointsEarned++
          │    ├─ error  → partner.a2Errors++ ; partner.pointsGiven++
          │    └─ dug ★  → attempt only; rally continues, nothing further recorded
          │
          ├─ partner sets, PASSER attacks on 3
          │    │  passer.swings++
          │    ├─ kill   → passer.fbKills++  ; passer.pointsEarned++
          │    ├─ error  → passer.fbErrors++ ; passer.pointsGiven++
          │    └─ dug ★  → swing only; rally continues, nothing further recorded
          │
          └─ no attack — ball stayed in play ★
               └─ nothing further recorded (free ball over, scramble, etc.)
```

### Why the ★ extensions exist

**"Dug" as a third attack outcome is mandatory, not optional.** The original notebook gave an attack only kill or error. But last season's `MTP %` formula computes `(Swings − FB Errors) / opportunities`, which is only meaningful if a swing can be neither a kill nor an error. In the real 2024 data for one player, 66 of 157 swings were neither. Without this branch those rallies have nowhere to go and the collector is forced to miscode them.

**"No attack" exists to absorb the residual.** In that same real data there were 11 receive attempts that produced no swing at all. Eight were aces; the other three had no valid path through the original tree. This branch catches playable-but-ugly passes where nobody swings.

---

## 4. Data model

### 4.1 Event log

The app stores a **rally-by-rally event log** and derives everything else by replaying it. This is deliberate and should be preserved. It buys: undo, per-set splits, the ability to change a metric definition and recompute historical data, and the ability to answer questions nobody has asked yet.

**Do not store aggregated counters as primary state.** Aggregates are always a pure function of the log.

```js
// One rally
{
  id:     string,                                    // unique
  set:    1 | 2 | 3,
  kind:   'sr' | 'oppServeError',
  passer: 'a' | 'b',                                 // slot, not player identity
  rating: 0 | 1 | 2 | 3,
  second: 'attack' | 'option' | 'bhe' | 'none' | null,
  result: 'kill' | 'error' | 'inplay' | null
}
```

`'a'` and `'b'` are **positional slots**, not player identities. Slot `a` is the left column in the UI, slot `b` the right. Player numbers/names live in the match config, so renaming or renumbering a player does not require touching the log.

### 4.2 Match

```js
{
  id:      string,
  cfg: {
    date:    'YYYY-MM-DD',
    school:  string,          // user's own school, uppercase
    oppo:    string,          // opponent school, uppercase
    oppPair: string,          // e.g. "18/21"
    a: { num: string, name: string },
    b: { num: string, name: string }
  },
  scores:  ['21-18', '22-20', ''],   // manually typed, see §6
  rallies: [ /* rally objects */ ]
}
```

### 4.3 Aggregation

Per player, replaying the log (this is the `tally()` function in the prototype):

```
counters = { sr:[0,0,0,0], bhe, a2a, a2k, a2e, sw, fbk, fbe, pe, pg }
```

Then for the two output rows, **player X's row uses X's own counters for most columns, and the partner's counters for the four `(Partner)` columns.**

---

## 5. Master_Data column reference

28 columns, in exact sheet order. `M` = per-match/metadata, `P` = this player's own counters, `Q` = the partner's counters.

| # | Column | Src | Meaning |
|---|---|---|---|
| 1 | Date | M | Match date |
| 2 | School | M | User's school |
| 3 | Pair | M | e.g. `8/88` |
| 4 | Player | M | This row's player, e.g. `#8` |
| 5 | Partner | M | The other player, e.g. `#88` |
| 6 | Opponent | M | Opponent school |
| 7 | Opponent Pair | M | e.g. `18/21` |
| 8 | Final Score | M | e.g. `21-18; 22-20` |
| 9 | Sets Won | M | Derived from typed scores |
| 10 | Sets Lost | M | Derived from typed scores |
| 11 | Points Earned (+) | P | `fbKills + a2Kills` — **receive-side only** |
| 12 | Points Given (-) | P | `sr[0] + bhe + a2Errors + fbErrors` — **receive-side only** |
| 13 | Total SR Attempts | P | `sum(sr)` |
| 14 | 0 SR Attempts | P | Times aced |
| 15 | 1 SR Attempts | P | Poor passes |
| 16 | 2 SR Attempts | P | Medium passes |
| 17 | 3 SR Attempts | P | Perfect passes |
| 18 | SR BHE (2nd Ball) | P | Ball-handling errors *this player* committed |
| 19 | SR A2 Attempts | P | Times *this player* attacked on 2 |
| 20 | SR A2 Kills | P | |
| 21 | SR A2 Errors | P | |
| 22 | SR FB Swings (3rd Ball) | P | Third-ball swings after this player's own pass |
| 23 | SR FB Kills (3rd Ball) | P | |
| 24 | SR FB Errors (3rd Ball) | P | |
| 25 | SR BHE (2nd Ball) (Partner) | Q | BHEs the *partner* committed |
| 26 | SR A2 Attempts (Partner) | Q | Times the *partner* attacked on 2 |
| 27 | SR A2 Kills (Partner) | Q | |
| 28 | SR A2 Errors (Partner) | Q | |

### Critical note on A2 attribution

When player X passes and player Y takes the option, the attempt is credited to **Y**:

- Y's row: `SR A2 Attempts` (col 19) increments
- X's row: `SR A2 Attempts (Partner)` (col 26) increments

This means **columns 19–21 and 26–28 are mirror images across the two rows of the same match.** Player X's col 26 always equals player Y's col 19, and vice versa.

This convention was verified against the user's real 2024 data (values 49 and 9 cross-matched exactly between the two players of a pair). It is **provisional** — the user was asked to confirm and has not yet explicitly done so. Confirm before collecting a full season.

Last season the own-side columns (18–21) did not exist; only the `(Partner)` columns did, which forced a cross-row lookup to compute a player's own A2 efficiency. The new schema stores both sides. **Both must be written from the same event so they can never disagree.**

---

## 6. Decisions already made — flag as reversible, do not silently "fix"

These were discussed with the user and decided provisionally. They are choices, not oversights. Surface them; don't quietly change them.

**1. Serve-side rallies are not tracked at all.** The app only records rallies where the user's team receives. There is no logging of the user's own serves, aces, service errors, blocks, digs, or transition play.

**2. Consequently, Points Earned / Points Given are receive-side only.** They do not mean "points in the match." They mean "points won or lost on first-ball side-out sequences." The user has been told this and it remains an open item — either rename the columns or extend the tree. **Do not extend scope to full rally tracking without asking.**

**3. Opponent service errors are recorded but not attributed.** The team wins the point; no player gets credit. There is currently no column for this in Master_Data, so the event is logged but does not surface in the export.

**4. The third-ball attacker is always assumed to be the passer.** True in the overwhelming majority of beach rallies. There is currently no override for scramble cases where the non-passer ends up hitting on 3. The user was told; not yet prioritized.

**5. Set scores are typed by hand, not derived.** The app cannot know the score because it never sees the serving rallies. `Sets Won` / `Sets Lost` are parsed from strings like `21-18`. Do not attempt to auto-derive these from the event log — the information genuinely is not there.

**6. Statistical calculations are deliberately out of scope for now.** The user stated they are redoing all the metrics this year. The app currently produces **raw totals only**. Do not add computed ratios without being asked. See §9 for last season's formulas, provided for reference only.

---

## 7. UI/UX decisions — driven by user feedback, preserve these

**Fixed left/right player columns.** The two players occupy fixed screen positions — left player is always on the left, on every screen, in every step. The user explicitly requested this over a top/bottom layout. It builds muscle memory so the collector doesn't have to read labels mid-rally. Role labels ("3rd ball" / "2nd ball") change beneath the player headers; **positions never move.**

**Two-tap rally entry.** Because the second-ball screen is split by player, choosing *who* and choosing *what happened* collapse into a single tap:

- Tap 1: pass grid — picks the passer *and* the 0–3 rating together
- Tap 2: outcome — picks the actor *and* the result together

Pass ratings are ordered **3 at top, 0 at bottom** (best first), per the user's sketch, and color-ramped from teal (3) through green, amber, to red (0) so quality is encoded in the target itself.

**Attempt and outcome are recorded in one button.** "Kill", "Error", and "Swing, dug" all increment Swings; only the first two also increment kills/errors. The user's original sketch listed "Swings" and "A2 Attempt" as separate rows, which would imply a third tap. The user has been told this and invited to ask for the intermediate step back if it better matches how they think during a rally — **ask before changing.**

**Rally log and live totals panel.** Both explicitly praised by the user. The log shows a plain-English description of each rally, newest first, color-dotted by outcome. Keep both.

**Undo.** One-tap undo of the last completed rally; "Back" while mid-rally.

**Match library.** Multiple matches persist. New matches carry forward school and player numbers from the previous match, since the user typically stats the same pair repeatedly.

**Season filter.** Aggregates raw totals across saved matches, filterable by player and by opponent. Currently a demonstration that the data model supports the query — the user's stated eventual goal is richer interactive filtering.

---

## 8. Current implementation state and next tasks

### What exists

`beach_stat_collector.html` — one self-contained file. Vanilla JS, no framework, no build step, no external requests. Roughly: a state object `S`, a `tally()` function implementing §3, a set of render functions returning HTML strings, and a `wire()` function attaching listeners after each render. Full re-render on every state change; simple and fast enough at this scale.

### Task 1 — storage swap (blocking deployment)

The prototype persists via `window.storage`, **which only exists inside Claude's artifact runtime.** It will silently no-op once the file is hosted anywhere else. Replace with `localStorage` (or `IndexedDB` if size becomes a concern — a season of rallies is small, so `localStorage` is almost certainly sufficient).

Requirements:
- Include a schema version field so future migrations are possible.
- Write-through on every mutation. A crash mid-match must not lose rallies.
- Keep the existing JSON backup export, and **add a restore/import** — `localStorage` is wiped if the user clears Safari data, and there is currently no recovery path.

### Task 2 — PWA packaging

- `manifest.json` with `display: "standalone"`, name, theme color (`#0B1F29`), background color.
- `apple-touch-icon` at 180×180. iOS ignores manifest icons; it needs the link tag.
- `<meta name="apple-mobile-web-app-capable" content="yes">` for older iOS.
- A service worker caching the app shell so it opens with no network. Since it's one file, this is trivial — but get the cache-busting right so pushed updates actually reach an installed instance.
- Verify: add to home screen, enable airplane mode, launch, log a full match, confirm data survives a force-quit.

### Task 3 — deployment

GitHub Pages, deploying from `main` at repo root. Public repo (free-tier Pages requires it). The user opens the resulting `https://<user>.github.io/<repo>/` URL in Safari once and adds it to the home screen; subsequent pushes update the installed app automatically.

### Task 4 — quality pass

Not yet done and worth doing: real-device testing on iPad in sunlight, verifying tap target sizes with a thumb, checking that the two-column layout holds on iPhone portrait, and confirming that rapid consecutive taps during a fast rally don't double-register.

---

## 9. Reference — last season's metrics (for context only, not to implement)

The user is redoing all calculations this year. This is recorded so the intent behind the raw columns is not lost.

Verified against the 2024 data:

- `SR Pass Rating = (0·sr0 + 1·sr1 + 2·sr2 + 3·sr3) / totalSRAttempts`
- `MTP % = (Swings − FB Errors) / (Total SR Attempts − Partner A2 Attempts)`
- `3rd Ball FBSO % = FB Kills / (Total SR Attempts − Partner A2 Attempts)`
- `Partner Option % = Partner A2 Attempts / Total SR Attempts`
- `A2 Efficiency % = (A2 Kills − A2 Errors) / A2 Attempts`

Two defects were found in last season's workbook. Both stemmed from aggregating percentages rather than the underlying counts, and both are avoided by construction if metrics are computed from summed raw totals:

1. `A2 Efficiency %` and `SR Attempt Share` were aggregated with `AVERAGEIF` over a per-match percentage column, producing an **unweighted mean of ratios**. A 1-for-2 match counted as heavily as a 12-for-30 match. Correct weighted A2 efficiency for one player was 33.3%; the workbook reported 29.2%.
2. The same flaw in `SR Attempt Share` propagated into the generated PDF reports (70.1% reported where the weighted figure is 72.1%).

**Rule for the calculation layer whenever it is built: sum raw counts first, divide once at the end. Never average a percentage.**

Note also the denominator question in `MTP %`: it subtracts partner A2 attempts but not partner BHEs, and it counts aces against the passer. Now that BHE is tracked separately for the first time, the user may want to revisit whether a partner's handling error should count against the passer's MTP. Unresolved.

---

## 10. Open questions for the user

Ask; do not guess.

1. Confirm the A2 attribution direction in §5 before a full season is collected on it.
2. Should `Points Earned` / `Points Given` be renamed to reflect that they are receive-side only, or should the decision tree be extended to the serving side?
3. Should there be an override for the rare case where the non-passer attacks on the third ball?
4. Should opponent service errors get a Master_Data column?
5. Does the combined attempt+outcome button (§7) match how they think during a rally, or should the intermediate "Swings / A2 Attempt" step be restored?
6. Is per-set granularity wanted in the export? The event log already stores `set` on every rally, so per-set rows are essentially free — currently only match-level rows are exported.
7. What does the interactive filtering in the eventual version need to answer? "Filter by player and who they played" was the stated goal; the specifics will shape whether local storage remains sufficient or a backend is warranted.
