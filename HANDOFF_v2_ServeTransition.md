# Beach Volleyball Stat Collector — Handoff v2 (Serve/Transition Expansion)

**Status:** spec finalized with the user, ready to implement
**Relationship to `HANDOFF.md` (v1):** v1 covers the original architecture, the Serve Receive (SR) tree, and the storage/PWA tasks. **This document supersedes v1 wherever they conflict** (mainly: Master_Data schema, the "dug" outcome wording, per-set tracking, and the storage task's priority). Where v1 is silent — general architecture principles like "event log is the source of truth, aggregates are a pure function of the log," the two-tap philosophy, outdoor/offline/iOS constraints — it still applies and should be read first for context.
**Prototype file:** `beach_stat_collector.html` — since renamed to `index.html` so GitHub Pages serves it at the site root (single file, no build step, no dependencies)
**Audience:** Claude Code, continuing implementation from a design conversation with the user

---

## 1. Summary of what's changing

1. **New tracking mode: Serve/Transition (ST).** Previously the app only tracked Serve Receive (SR) rallies. Match Details now gets a checkbox to also track ST rallies. If unchecked, the app behaves exactly as it does today (SR-only, looping straight back to Serve Receive after every rally). If checked, the app alternates between SR and ST screens as rallies dictate.
2. **Automatic routing between SR and ST after each rally**, based on who won the point — except for a specific set of ambiguous outcomes, which now present the user with an explicit chooser.
3. **Per-set tracking is removed.** No set toggle, no `set` field on rallies. Instead, every collection screen gets an "End Match" button leading to an End Results screen (set scores + win/loss).
4. **Master_Data grows from 28 to 45 columns** to capture ST stats, with the same own/partner mirroring convention used for SR.
5. **New SR statistics formulas** (Pass Rating, MTP%, FBSO%, FB Kill Rate, A2 Efficiency%, SR Attempt Share) to be computed in live totals, in the raw per-match totals, and at end-of-match. **These are SR-only** — the user did not provide ST formulas, so ST columns remain raw totals only, consistent with v1 §6 decision #6 ("statistical calculations are deliberately out of scope" until formulas are explicitly given). Do not invent ST ratios.
6. **`window.storage` → `localStorage` swap**, with schema versioning and JSON backup/restore. This is being folded into the same pass since the state/save logic is being touched anyway.

**Preserved, do not regress:** fixed left/right player columns, live totals panel, rally log, one-tap undo.

---

## 2. New domain terms (ST side)

| Term | Meaning |
|---|---|
| ST | Serve/Transition — rallies where the user's team is serving |
| KO | Knock-out — an aggressive serve that isn't an ace but produces a shanked, hard-to-run reception; play continues |
| SB | Stuff block — immediate kill block, ends rally |
| Tooled | Opponent redirects a block attempt for a kill against the blocker — ends rally, point given |
| Dig | A defensive touch that keeps the ball alive without immediately setting up an easy attack |
| Dig-to-swing | A dig good enough that the digger can also be the attacker on the next contact (a subtype of dig, not exclusive of it — see §6 note on columns 36/37) |
| TK / TE | Transition Kill / Transition Error — the "3rd ball" attack outcome during a transition rally (mirrors SR's FB Kill/Error, different name because it's not off a serve receive) |
| POS | "Points on Serve" — increments for a player whenever their **team** wins a rally while **that player is the one serving**, regardless of which of the two players actually produced the winning action. This is a rotation/serve-turn stat, not a personal-credit stat. |

---

## 3. Decision trees

### 3.1 Serve Receive — unchanged from v1

The SR tree in `HANDOFF.md` §3 is unchanged in its branching logic, **with one wording change**: the outcome previously called "dug" is gone as a distinct label. It is not replaced with new logic — it's the same "rally continues, nothing further recorded" behavior, just relabeled to match how the buttons read on screen:

- Passer's attack, rally continues → button reads **"Swing (rally continues)"**
- Partner's attack-on-2, rally continues → button reads **"Attack on 2 (rally continues)"**
- No attack at all, ball stays in play → button reads **"No attack (ball stays in play)"**

All three of these, plus `Opponent misses serve`'s counterpart on the ST side (see 3.3), are the only places nothing is recorded about the outcome — the attempt itself was already counted (Swing / A2 Attempt increments happen on the button before this one), but whether it was dug, blocked, or just continued is not tracked. All three route to the **rally chooser** (§4.2), except `Opponent misses serve`, which routes directly to ST (see 3.3).

Full SR tree (source of truth — reproduced from the finalized notebook):

```
SERVE RECEIVE
│
├─ Opponent misses serve
│    └─ no stat recorded to either player → go directly to SERVE/TRANSITION
│
├─ Player_X passes 0 (aced)
│    └─ X_SR_0++, X_SR_TA++, X_POINTS_GIVEN++ → go to SERVE RECEIVE
│
└─ Player_X passes 1, 2, or 3
     │  X_SR_{rating}++, X_SR_TA++
     │  (Y = X's partner; the second ball is always Y's)
     │
     ├─ Y commits a ball-handling error
     │    └─ Y_SR_BHE++, Y_POINTS_GIVEN++ → go to SERVE RECEIVE
     │
     ├─ Y takes the option (attacks on 2)
     │    │  Y_SR_A2A++
     │    ├─ kill  → Y_SR_A2K++, Y_POINTS_EARNED++ → auto-route (§4.1)
     │    ├─ error → Y_SR_A2E++, Y_POINTS_GIVEN++ → go to SERVE RECEIVE
     │    └─ "Attack on 2 (rally continues)" → nothing further recorded → rally chooser (§4.2)
     │
     └─ Y sets, X attacks (3rd ball)
          │  X_SR_A++
          ├─ kill  → X_SR_K++, X_POINTS_EARNED++ → auto-route (§4.1)
          ├─ error → X_SR_HE++, X_POINTS_GIVEN++ → go to SERVE RECEIVE
          └─ "Swing (rally continues)" → nothing further recorded → rally chooser (§4.2)

  (Also available at 1st contact: "No attack — ball stays in play" → rally chooser (§4.2))
```

### 3.2 Serve/Transition — new

Unlike SR, an ST rally is not a single flat sequence — it can **loop**. A serve that isn't an ace, error, or knockout begins a rally that may cycle through multiple dig → attack exchanges before someone scores. The data model must account for this (see §4.3).

```
SERVE/TRANSITION
│
├─ Player_X serves
│    X_ST_A++
│    ├─ Ace       → X_ST_K++, X_POS++, X_POINTS_EARNED++ → END, auto-route (§4.1)
│    ├─ Error     → X_ST_E++, X_POINTS_GIVEN++ → END, auto-route (§4.1)
│    ├─ Knock-out → X_ST_KO++ → go to BEGIN RALLY (server = X)
│    └─ Serve (ball in play, normal) → go to BEGIN RALLY (server = X)
│
└─ BEGIN RALLY (server = X, X's partner = Y)
     │  Either player may be the one who touches the ball first.
     │  Let P = whichever of X/Y makes this contact.
     │
     ├─ P gets a stuff block → P_ST_SB++, {server}_POS++, P_POINTS_EARNED++ → END, auto-route
     ├─ P gets tooled        → P_ST_T++, P_POINTS_GIVEN++ → END, auto-route
     │
     ├─ P gets a dig (or dig-to-swing)
     │    │  P_ST_D++  (and P_ST_DTS++ too, if it was specifically a dig-to-swing)
     │    │  Q = the other player (P's partner)
     │    │
     │    ├─ P attacks (this is the natural continuation of a dig/dig-to-swing)
     │    │    ├─ kill  → P_ST_TK++, {server}_POS++, P_POINTS_EARNED++ → END, auto-route
     │    │    ├─ error → P_ST_TE++, P_POINTS_GIVEN++ → END, auto-route
     │    │    └─ rally continues → return to BEGIN RALLY (server unchanged)
     │    │
     │    └─ Q attacks on 2 (the option)
     │         ├─ kill → Q_ST_A2K++, {server}_POS++, Q_POINTS_EARNED++ → END, auto-route
     │         ├─ error → Q_ST_A2E++, Q_POINTS_GIVEN++ → END, auto-route
     │         ├─ ball-handling error → Q_ST_BHE++, Q_POINTS_GIVEN++ → END, auto-route
     │         └─ rally continues → return to BEGIN RALLY (server unchanged)
     │
     └─ Opponent kill/error (the point ends on the opponent's own action —
          nothing about it is attributable to our players)
          └─ nothing recorded → END, rally chooser (§4.2)
```

Notes:
- `{server}_POS++` always credits **whichever player served this rally**, even when the point was won by their partner's action (block, dig, kill, A2, etc.). This is the "rotation credit" behavior described in §2.
- The BEGIN RALLY loop can repeat any number of times; each pass through it is one more dig/attack exchange, all still charged against the same original server for POS purposes.
- "Opponent kill/error" can happen at either the 1st-contact-in-transition stage or the attack-in-transition stage (see the two docx screens in §5) — behaviorally identical, both go to the rally chooser.

---

## 4. Routing logic

### 4.1 Automatic routing

Whenever a rally ends with a clear, attributable point outcome:

- **Point earned by our team** → next rally starts in **Serve/Transition** (only if ST tracking is enabled for this match; otherwise stays in Serve Receive, matching current behavior)
- **Point given by our team** → next rally starts in **Serve Receive**
- **Opponent misses their serve** (SR side) → next rally starts in **Serve/Transition** directly, no chooser — this is unambiguous even though it isn't attributed to a specific player

### 4.2 The rally chooser

A shared interstitial screen: **"Track next rally as: Serve Receive / Serve/Transition."** Reached only when the app cannot infer which side comes next because nothing about the outcome was recorded. This happens from exactly four places:

1. SR: "Swing (rally continues)"
2. SR: "Attack on 2 (rally continues)"
3. SR: "No attack (ball stays in play)"
4. ST: "Opponent kill/error (end rally)" — from either the 1st-contact-in-transition screen or the attack-in-transition screen

If ST tracking is **disabled** for the match, this chooser never appears — those four cases simply loop back to Serve Receive, matching current (v1) behavior exactly, per the user's requirement that unchecking ST tracking preserves the app as-is.

The chooser is also the **first screen shown when a new match starts**, if ST tracking is enabled (matching the docx's "NEXT: Serve Receive / Serve/Transition" page right after Match Details is saved). If ST tracking is disabled, the match starts directly in Serve Receive with no chooser, again matching current behavior.

### 4.3 Data model implication — ST rallies need internal structure

SR rallies fit in one flat record because they can only ever have up to three touches with no looping. ST rallies can loop indefinitely, so a single ST rally record needs to hold an ordered sequence of contacts, e.g.:

```js
{
  id: string,
  kind: 'st',
  server: 'a' | 'b',
  serve: 'ace' | 'error' | 'knockout' | 'inplay',
  // present only if serve is 'knockout' or 'inplay' — the rally continued past the serve
  contacts: [
    {
      by: 'a' | 'b',              // who made this first-contact-in-transition touch
      action: 'stuffBlock' | 'tooled' | 'dig' | 'digToSwing' | 'oppKillError',
      // present only if action is 'dig' or 'digToSwing'
      attack: {
        by: 'a' | 'b',            // same player (attack) or their partner (optionA2)
        type: 'attack' | 'optionA2',
        result: 'kill' | 'error' | 'bhe' | 'continue'
      } | null
    },
    // additional entries if result was 'continue' — the loop repeats
  ]
}
```

This is a recommendation, not a rigid requirement — implement whatever concrete shape is cleanest in the actual code — but two properties must hold regardless of exact field names:
- **One rally = one log record**, even for looping ST rallies, so that "undo" removes exactly one rally and the rally log shows one line per rally (per the "preserve rally log and undo" requirement).
- **The full sequence within the rally is preserved**, not just the final outcome, so aggregates can still be computed by pure replay of the log (per v1's "event log is the source of truth" principle) and so a rally description string can narrate the whole sequence in the log panel.

SR rallies keep their existing flat shape from v1 §4.1, unchanged.

Match config (`cfg`) gains one field: `trackST: boolean` (default `false`), set from the new Match Details checkbox.

---

## 5. Screen-by-screen UI flow

Reference: `app_pages.docx` (finalized). Button labels below are exact wording to use in the UI.

**Match Details** — adds one control: a checkbox "Track Serve/Transition" (unchecked by default — Serve Receive tracking is always on). Everything else on this screen (date, school, player numbers/names, opponent, opponent pair) is unchanged from v1. **Do not** implement the UT/Scouting checkboxes or the player-dropdown scouting mode mentioned elsewhere in the docx — those are explicitly deferred (see §9).

**Next** (only shown if `trackST` is true, otherwise skipped) — two large buttons: **Serve Receive** / **Serve/Transition**. This is the same component as the rally chooser in §4.2.

**Serve Receive – 1st Contact** — unchanged from v1: per-player pass grid (3/2/1/0), plus "Opponent misses serve" as a wide button below.

**Serve Receive – 2nd/3rd Contact** — same two-column split as v1 (passer's column: Kill / Attack Error / Swing (rally continues); partner's column: A2 Kill / A2 Error / Attack on 2 (rally continues) / Ball Handling Error), plus a wide "No attack (ball stays in play)" button. Button wording updated per §3.1.

**Serve/Transition – Serve** (new) — two columns, one per player, each showing: Ace (point earned) / Serving Error (point given) / Knock Out → go to Begin Rally / Serve → go to Begin Rally. Whichever player's button is tapped is the server for this rally.

**Serve/Transition – (Begin Rally) 1st Contact in Transition** (new) — two columns, one per player, each showing: Stuff Block (point earned) / Tooled (point given) / Dig to Swing / Dig. Plus a wide "Opponent Kill/Error (end rally) → go to next" button.

**Serve/Transition – Attack in Transition** (new) — shown after a Dig or Dig-to-Swing. Same two-column shape as SR's 2nd/3rd contact screen: the digger's column shows Kill (point earned) / Hitting Error (point given) / Attack (rally continues) → go to Begin Rally; the partner's column shows A2 Kill (point earned) / A2 Error (point given) / Attack on 2 (rally continues) → go to Begin Rally / Ball Handling Error (point given). Plus a wide "Opponent Kill/Error (end rally) → go to next" button.

**End Results** (new, replaces per-set tracking) — reachable via an "End Match" button present on every collection screen (SR and ST alike). Fields: Set 1 Score, Set 2 Score, Set 3 Score (free text, same `21-18` format as v1), plus a new Win/Loss checkbox. Sets Won/Sets Lost derivation from typed scores stays as in v1 §6 decision #5 — still cannot be auto-derived, still typed by hand.

---

## 6. Master_Data column reference (v2 — 45 columns)

Columns 1–28 are **unchanged from v1** (`HANDOFF.md` §5) — same names, same order, same own/partner split for SR. Reproduced here for completeness, followed by the 17 new columns.

| # | Column | Src | Meaning |
|---|---|---|---|
| 1 | Date | M | Match date |
| 2 | School | M | User's school |
| 3 | Pair | M | e.g. `8/88` |
| 4 | Player | M | This row's player |
| 5 | Partner | M | The other player |
| 6 | Opponent | M | Opponent school |
| 7 | Opponent Pair | M | e.g. `18/21` |
| 8 | Final Score | M | e.g. `21-18; 22-20` |
| 9 | Sets Won | M | From typed scores |
| 10 | Sets Lost | M | From typed scores |
| 11 | Points Earned (+) | P | SR + ST kills/blocks/aces, combined |
| 12 | Points Given (-) | P | SR + ST errors/BHE, combined |
| 13 | Total SR Attempts | P | `sum(sr[0..3])` |
| 14 | 0 SR Attempts | P | Times aced |
| 15 | 1 SR Attempts | P | Poor passes |
| 16 | 2 SR Attempts | P | Medium passes |
| 17 | 3 SR Attempts | P | Perfect passes |
| 18 | SR BHE (2nd Ball) | P | Own BHEs on serve receive |
| 19 | SR A2 Attempts | P | Own attacks on 2 |
| 20 | SR A2 Kills | P | |
| 21 | SR A2 Errors | P | |
| 22 | SR FB Swings (3rd Ball) | P | Own 3rd-ball swings |
| 23 | SR FB Kills (3rd Ball) | P | |
| 24 | SR FB Errors (3rd Ball) | P | |
| 25 | SR BHE (2nd Ball) (Partner) | Q | Partner's BHEs |
| 26 | SR A2 Attempts (Partner) | Q | Partner's on-2 attempts |
| 27 | SR A2 Kills (Partner) | Q | |
| 28 | SR A2 Errors (Partner) | Q | |
| 29 | Serve Attempts | P | `ST_A` |
| 30 | Aces | P | `ST_K` (service ace only) |
| 31 | Serving Errors | P | `ST_E` (service error only) |
| 32 | Knockouts | P | `ST_KO` |
| 33 | Points on Serve | P | `POS` — see §2 |
| 34 | Stuff Blocks | P | `ST_SB` |
| 35 | Tools | P | `ST_T` |
| 36 | Digs -> Swing | P | `ST_DTS` — subset of Digs, not exclusive (see note below) |
| 37 | Digs | P | `ST_D` — **includes** dig-to-swing occurrences, not a separate bucket |
| 38 | Transition BHE | P | `ST_BHE` |
| 39 | Transition A2 Kills | P | `ST_A2K` |
| 40 | Transition A2 Errors | P | `ST_A2E` |
| 41 | Transition Kills (3rd Ball) | P | `ST_TK` |
| 42 | Transition Hitting Errors (3rd Ball) | P | `ST_TE` |
| 43 | Transition BHE (Partner) | Q | Partner's `ST_BHE` |
| 44 | Transition A2 Kills (Partner) | Q | Partner's `ST_A2K` |
| 45 | Transition A2 Errors (Partner) | Q | Partner's `ST_A2E` |

**Important note on columns 36/37:** every dig-to-swing increments **both** `Digs` and `Digs -> Swing`; a plain dig increments only `Digs`. Do not treat these as mutually exclusive buckets that should sum to a total — `Digs` is already the total, and `Digs -> Swing` is a flag on how many of those digs were good enough to swing on.

**Note on asymmetry with SR:** unlike SR (which mirrors BHE, A2 Attempts, A2 Kills, and A2 Errors to the partner's columns), ST only mirrors BHE, A2 Kills, and A2 Errors — there is no "Transition A2 Attempts" column at all (own or partner), and Transition Kills/Errors (3rd ball) have no partner mirror, matching how SR's FB Kills/Errors (22–24) also have no partner mirror. This is intentional per the finalized spreadsheet — don't add columns beyond this list.

**Points Earned / Points Given (columns 11–12) are no longer SR-only.** Unlike v1 (where these were explicitly receive-side-only, per v1 §6 decision #2), they now combine both SR and ST outcomes, since ST rallies also feed `POINTS_EARNED`/`POINTS_GIVEN` per the decision tree in §3.2. This resolves the open item from v1 §6 #2 — no rename needed, the columns now mean what their names say.

---

## 7. Statistics formulas

**SR only** — implement these in the live totals panel, in the per-match raw totals, and at end-of-match. As always: **sum raw counts first, divide once at the end — never average a percentage** (v1 §9's rule still applies and matters even more now that there are more columns to get wrong).

For player X with partner Y:

```
Pass Rating   = ((SR_0*0) + (SR_1*1) + (SR_2*2) + (SR_3*3)) / SR_TA
MTP %         = (SR_A - SR_HE) / (SR_TA - Y_SR_A2A)
3rd Ball FBSO %  = SR_K / (SR_TA - Y_SR_A2A)
FB Kill Rate  = (SR_K + SR_A2K) / (SR_A + SR_A2A)
SR A2 Efficiency % = (SR_A2K - SR_A2E) / SR_A2A
SR Attempt Share %  = SR_TA / (SR_TA + Y_SR_TA)
```

Guard all divisions against zero denominators (e.g., a player with 0 SR attempts, or 0 A2 attempts) — show as blank/dash in the UI rather than `NaN` or a crash.

**ST columns are raw totals only for now.** No ratios were specified for the ST side; don't invent MTP-style formulas for serve/transition stats until asked.

---

## 8. UI/UX — preserved requirements (unchanged from v1)

- Fixed left/right player columns on every screen, in every step.
- Live totals panel and rally log — both stay, now need to also reflect ST rallies (the log's `describe()`-style narration needs new phrasing for ST sequences; use the same button wording as §5).
- One-tap undo of the last completed rally, including ST rallies (removes the whole rally record per §4.3, regardless of how many internal contacts it had).
- Two-tap-ish rally entry philosophy for SR is unchanged. ST is inherently more taps because of the looping structure — that's expected and fine; don't try to compress it artificially.

---

## 9. Explicitly deferred — do not implement yet

- The Home screen's "Texas Season Totals (By Pair)" and "Scouting" entries, and Match Details' UT/Scouting checkboxes with a school-name dropdown for scouting mode. The user wants these eventually as a player dropdown for UT vs. scouting-mode opponents, but asked to leave this alone for now. Keep Home and the School field exactly as they are in v1, aside from adding the `trackST` checkbox to Match Details.

---

## 10. Storage task: `window.storage` → `localStorage`

Carried over from v1 §8 Task 1, now folded into this same implementation pass since the state/save/load logic is being restructured anyway for the ST data model.

- Replace `window.storage` calls with `localStorage`.
- Include a schema version field in the persisted blob (e.g. `{ schemaVersion: 2, matches: [...], cur: ... }`) so future migrations are possible. Bump this version now that the match/rally shapes are changing (`trackST` on `cfg`, new ST rally shape, no `set` field).
- Write-through on every mutation — a crash mid-match must not lose rallies.
- Keep the existing JSON backup export, and **add a restore/import** — `localStorage` is wiped if the user clears Safari data, and there's currently no recovery path.
- PWA packaging (manifest, service worker, apple-touch-icon) from v1 §8 Task 2 is still a separate, later task — not part of this pass unless it's trivial to include alongside the storage swap.

---

## 11. Suggested order of implementation

1. Data model: add `trackST` to `cfg`, define the new ST rally shape, drop `set` from rally records.
2. `localStorage` swap + schema versioning + backup/restore, since everything downstream depends on the persistence layer being solid.
3. SR tree: rename "dug" outcomes to "Swing (rally continues)" / "Attack on 2 (rally continues)," wire to the rally chooser.
4. ST tree: serve screen, begin-rally/1st-contact screen, attack-in-transition screen, with the looping "return to Begin Rally" behavior.
5. Rally chooser component (shared between match-start and ambiguous-ending routing).
6. Auto-routing logic (§4.1) wired into every terminal SR and ST outcome.
7. `tally()` replay function extended to also fold in ST stats per §6's column mapping.
8. Master_Data export: extend `HEAD` array and `matchRows()` to the 45-column schema in §6.
9. SR formulas from §7, in live totals + export + end-of-match.
10. End Match button + End Results screen (set scores + win/loss checkbox), remove the old set-selector UI.
11. Rally log narration for ST sequences.
12. QA pass: full match with both SR and ST enabled, confirm undo works mid-loop, confirm chooser only appears where specified, confirm a match with `trackST=false` behaves byte-for-byte like the v1 app.

---

## 12. Source files for reference

- `beach_stat_collector.html` — current working prototype (SR-only), starting point for this update.
- `HANDOFF.md` — v1 handoff; still the reference for general architecture, storage/PWA background, and anything not touched by this document.
- `Statting_DecisionTree.ipynb` — finalized decision tree and SR formulas (source of truth for §3 and §7 above).
- `app_pages.docx` — finalized screen-by-screen flow and button wording (source of truth for §5 above).
- `Master_Data.xlsx` — finalized 45-column header row (source of truth for §6 above).
