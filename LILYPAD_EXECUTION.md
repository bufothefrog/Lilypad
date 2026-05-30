# Lilypad — Execution & Verification Roadmap

Companion to `LILYPAD_PLAN.md`. That doc is the architecture (*what* to build). This is the
*order* to build it in, sliced into **milestones that each end on a green build + a concrete
verification gate**, so you never go more than a short increment without confirming the app works.

## Guiding strategy

1. **Additive first, destructive last.** The new grid system is built *alongside* the existing edge
   snap areas, gated behind a dev setting `Defaults.gridModeEnabled` (default OFF). The old behavior
   keeps working — you flip the flag to exercise new features. The old system is deleted only at M16–M17,
   after the grid system is proven.
2. **One milestone = one commit** (or a few small commits). Every milestone is independently
   build-green and revertable, so a regression can be bisected.
3. **Automated where cheap, manual where necessary.** Pure logic (model, `GridCalculation`, CRUD,
   migrations) is gated by **unit tests**. Interaction (drag, chord, keyboard) is gated by **manual
   checks** on a running app, listed explicitly per milestone.
4. **Never leave the build red across a pause point.** The cleanup sweep (M17) is itself broken into
   ordered sub-steps that each compile.

## Branching

- Cut an integration branch `lilypad` from the current `per-monitor-snap-areas` HEAD.
- Optionally one short-lived branch per milestone merged into `lilypad`.
- Tag `lilypad-baseline` at M0 as the known-good reference.

## The build + verify ritual (run at every pause point)

```bash
# Build
xcodebuild -project Rectangle.xcodeproj -scheme Rectangle -configuration Debug build

# Unit tests (where the milestone adds/edits testable logic)
xcodebuild -project Rectangle.xcodeproj -scheme Rectangle test
```
Then for manual milestones: run the app (Xcode ▶︎ or the built product), ensure Accessibility is
granted, and perform the milestone's **Verify** checks. **Regression sweep** (every manual milestone,
until the relevant system is removed): a few existing keyboard shortcuts (left-half, maximize, center),
one edge drag-snap, and one menu action still behave. Commit when green.

> I can drive these gates for you with the `run` and `verify` skills at each pause point.

Legend: **[additive]** no behavior change · **[gated]** new behavior behind `gridModeEnabled` ·
**[destructive]** removes/replaces existing behavior.

---

## Phase 0 — Baseline

### M0 — Known-good baseline  ·  [additive]
- Create `lilypad` branch; add the `gridModeEnabled` dev flag (`BoolDefault`, default false) and put it
  in `Defaults.array`. Nothing reads it yet.
- **Build:** compiles. **Verify:** app runs; existing snapping + shortcuts work. Tag `lilypad-baseline`.
- *Pause.* This is your rollback floor.

---

## Phase A — Foundation (Plan Stages 1–2)  ·  all [additive]

### M1 — Zone data model + Defaults
- Add `ZoneLayout`, `PerDisplayLayouts`; add `gridLayoutsByDisplay` + the modifier / edge-action /
  target-mode / chord Defaults; register **every** new key in `Defaults.array`.
- **Build:** compiles. **Verify (automated):** unit test that each new struct/Default JSON round-trips;
  unit test that `Config` export→import preserves them (catches a missing `Defaults.array` entry).
  App runs unchanged.
- *Pause / commit.*

### M2 — `GridCalculation` + quick-starter generators  ·  ⚠️ correctness-critical
- Implement zone↔rect, `cursor→zone`, `rect→zone` inference, selection-union, the **zone neighbor
  graph**, gap application; add uniform quick-starter generators (2×2, 3×2, 4×2, halves, thirds).
- **Build:** compiles. **Verify (automated — this is the cheapest place to catch the #1 risk):**
  unit tests for uniform *and* non-uniform boundaries, merged-zone bounding boxes, `cursor→zone`
  at boundaries, neighbor lookups in all 4 directions, selection union, gaps, and an explicit
  **coordinate-space assertion** (top row maps to the top of the screen, not mirrored).
- *Pause / commit.* Do not proceed until these are green.

### M3 — `DisplayRegistry` extraction + `GridModel`
- Move `knownDisplays` / `recordCurrentDisplays` / `allKnownDisplays` / `DisplayChoice` / `forgetDisplay`
  out of `SnapAreaModel` into a new `DisplayRegistry` (keep the unnamed-display skip guard); have
  `SnapAreaModel` delegate so the existing Snap Areas UI is untouched. Add `GridModel` CRUD
  (add/rename/remove/setActive per display). Add the version-gated migration that seeds default layouts.
- **Build:** compiles. **Verify:** unit tests for `GridModel` CRUD + the seeding migration; **manual
  regression** — the existing Snap Areas pane still lists connected *and* disconnected displays and
  still saves per-display config. App runs.
- *Pause / commit.*

---

## Phase B — Core interactions (Plan Stages 3–5)  ·  all [gated] behind `gridModeEnabled`

### M4 — Grid overlay rendering
- Add `GridOverlayWindow` (`ignoresMouseEvents`, per-monitor) that draws a `ZoneLayout` + a highlight.
  Drive it from a temporary hidden menu item "Debug: show grid overlay".
- **Build:** compiles. **Verify (manual, visual):** trigger it — zones render on the correct monitor at
  the correct rects (also a visual catch for any mirroring). No effect on normal use.
- *Pause / commit.*

### M5 — Drag → single-zone snap (grid mode)
- Add `.flagsChanged` to the event mask. When `gridModeEnabled`: Shift-drag shows the overlay +
  single-zone preview on the cursor's monitor, commits on mouseUp via the rect-carrying path. When OFF:
  old edge snapping, unchanged.
- **Build:** compiles. **Verify (manual):** flag ON → drag a window, it snaps to the hovered zone;
  flag OFF → original edge snap behavior intact (regression).
- *Pause / commit.*

### M6 — Drag span sub-mode (⌥)
- Holding the span modifier (default ⌥) extends the selection from the anchor zone; releasing reverts;
  `.flagsChanged` updates the preview with no cursor motion.
- **Build:** compiles. **Verify (manual):** drag + hold ⌥ → multi-zone span preview; release ⌥ → back to
  single zone; commit snaps to the span.
- *Pause / commit.*

### M7 — Keyboard: move to adjacent zone
- Add `gridMove*` actions + the `GridLayoutManager.execute` interceptor; infer current zone, move to the
  neighbor. Bind to temp shortcuts.
- **Build:** compiles. **Verify (manual):** press → window jumps one zone in the arrow direction on its
  monitor; off the edge with no neighbor = no-op/beep for now.
- *Pause / commit.*

### M8 — Keyboard: span + edge wall actions + minimize
- Add `gridSpan*` (grow/shrink) and the per-edge wall-action table on repeat-at-wall (reuse
  `RectangleAction.count`). Add an `AXMinimized` minimize action.
- **Build:** compiles. **Verify (manual):** span grows/shrinks a window; at a wall, a second press fires
  the configured action — test each of maximize / minimize / half / next-display.
- *Pause / commit.*

### M9 — Monitor-relative layout-activation shortcuts
- Add `activateLayoutSlot1..9`; handler resolves the active monitor (cursor vs front-window per setting)
  → that monitor's slot layout → **set it active** (full auto-tile lands in M12).
- **Build:** compiles. **Verify (manual):** bind slot1/slot2 to two different layouts on a monitor;
  activate → subsequent drag-snap uses the newly active layout; move the cursor to another monitor and
  the *same* binding activates *that* monitor's slot. This is the work-vs-home requirement.
- *Pause / commit.*

---

## Phase C — Advanced (Plan Stages 6–7)

### M10 — Chord mode  ·  ⚠️ riskiest single piece · [gated]
- Add `ChordKeyboardTap` (CGEventTap, keyDown/keyUp/flagsChanged, suppress mapped keys) + `openChordGrid`
  + auto QWERTY-block key labels on the overlay + span selection + commit-on-release + Esc cancel.
- **Build:** compiles. **Verify (manual):** open chord → tap `q` = that zone; hold `q` tap `s` = span;
  Esc cancels; **chord keys do NOT leak into the focused app**; releasing all keys commits. Confirm the
  Input-Monitoring permission prompt is handled, and the keyboard never stays "stuck" after cancel.
- *Pause / commit.* Isolate this milestone; it's the most likely to need iteration.

### M11 — (Optional) Snap while moving the mouse  ·  [gated, default off]
- Add `.mouseMoved`; while the modifier is held, drive the overlay off the cursor and commit on modifier
  release. Default OFF (CPU).
- **Build:** compiles. **Verify (manual):** toggle on → hold modifier + move → overlay tracks, commits on
  release. Toggle off → no overhead.
- *Pause / commit.* (Skippable.)

### M12 — Tile-all into the active layout ("Tiled")  ·  [gated]
- Make `tileAllWindowsOnScreen` grid-aware (route through `GridCalculation` + gaps + UUID lookup; wire
  window history for restore; pick an overflow policy). Wire `activateLayoutSlot*` to also tile.
- **Build:** compiles. **Verify (manual):** run tile-all / activate a layout → all eligible windows fill
  the zones; `restore` brings them back; overflow behaves as chosen.
- *Pause / commit.*

### M13 — Zone cycling + real AXRaise  ·  [gated]
- Add `cycleZoneForward/Backward` + a `ZoneCycleManager`; add `kAXRaiseAction` to `AccessibilityElement`.
- **Build:** compiles. **Verify (manual):** put 2+ windows in one zone (incl. two of the *same* app) →
  cycle raises/focuses through them reliably.
- *Pause / commit.*

---

## Phase D — UI, cutover, cleanup, rebrand (Plan Stages 9, 3-finish, 8, 10)

### M14 — Layouts pane shell + per-monitor layout list (Stage 9a)
- Add the `PrefsTabViewController` subclass + programmatic **Layouts** tab hosting a SwiftUI island.
  Per-monitor layout list: add / rename / remove / make-active (incl. disconnected monitors via
  `DisplayRegistry`). Replace the temp dev shortcuts/menu items with real recorders/controls.
- **Build:** compiles. **Verify (manual + automated):** create/rename/remove/activate layouts per
  monitor; **relaunch** → everything persists; config export/import round-trips (unit). Disconnected
  monitor is still configurable.
- *Pause / commit.*

### M15 — FancyZones canvas editor (Stage 9b)  ·  largest UI surface
- The split/merge canvas: drag dividers to split, select-and-merge zones, **divider snapping to
  1/2·1/4·1/6·1/8**, **live per-zone pixel readout** for the selected monitor, and **rejection of
  non-rectangular merges**.
- **Build:** compiles. **Verify (manual):** cut a uniform starter into a custom layout; merge two zones;
  confirm dividers snap to fractions; pixel numbers match the monitor's resolution; an L-shaped merge is
  refused; the saved custom layout then drives drag / chord / keyboard nav correctly.
- *Pause / commit.*

### M16 — Cut over to grid; remove the dev flag  ·  [destructive]
- Make grid the only drag-snap path; remove `gridModeEnabled` and the old edge path in `SnappingManager`
  (`snapAreaContainingCursor` / `directionalLocationOfCursor`); begin `CompoundSnapArea` removal.
- **Build:** compiles. **Verify (manual):** drag-snap is always grid; no dead toggles; the app is fully
  functional on the grid system alone. Full regression sweep of keyboard shortcuts + menu.
- *Pause / commit.*

### M17 — Calculation cleanup sweep (Stage 8)  ·  [destructive], ordered sub-commits
Follow the analysis's safe sequence, **building green after each**:
1. delete `Snapping/CompoundSnapArea/` + finish rewiring `SnapAreaModel`/`SnapAreaViewController`.
2. delete the 6 `*Repeated` helpers (keep `QuartersRepeated` + the infra protocols).
3. delete the 55 cell calcs.
4. remove their factory statics + map entries; repoint `getBoxRect`.
5. scrub `WindowAction` (62 cases + the 9 switch tables + dead `SubWindowAction` members) — **never
   renumber survivors**.
6. prune `WindowActionCategory`, `README.md:51`, `TerminalCommands.md`, dead `Main` strings.
- **Build:** green after each sub-step. **Verify:** run the unit suite; **manually confirm the KEPT
  classic shortcuts still work** (center-third, fourths, vertical-thirds, corner quadrants, halves,
  maximize, display nav); removed grid URL endpoints are gone; the menu self-pruned.
- *Pause / commit* (one commit per sub-step). File count `WindowCalculation/` ~109 → ~48.

### M18 — Rebrand → Lilypad (Stage 10)  ·  [destructive]
- Delete the `RectangleLauncher` target. Change the bundle id + the hardcoded literals; `lilypad://`
  (keep `rectangle://` too); new Sparkle feed + **new EdDSA key**; `DEVELOPMENT_TEAM`; `PRODUCT_NAME`
  → `Lilypad`; config dir/filename; icon + status glyph; user-facing strings (storyboard + xcstrings).
- **Build:** compiles, signs, launches as **Lilypad.app**. **Verify (manual):** Finder shows Lilypad;
  re-authorize Accessibility + Input Monitoring; `lilypad://execute-action?name=…` and the legacy
  `rectangle://` both work; strings/menus rebranded; (Sparkle check if the feed is hosted).
- *Pause / commit.* Tag `lilypad-v0.1`.

---

## Milestone map & risk

| # | Milestone | Plan stage | Type | Verify | Risk |
|---|---|---|---|---|---|
| M0 | Baseline | — | additive | run | — |
| M1 | Zone model + Defaults | 1 | additive | unit | low |
| M2 | `GridCalculation` | 1 | additive | **unit** | **high (coords)** |
| M3 | DisplayRegistry + GridModel | 2 | additive | unit + manual | med |
| M4 | Overlay rendering | 3 | gated | manual visual | low |
| M5 | Drag → single zone | 3 | gated | manual | med |
| M6 | Drag span (⌥) | 3 | gated | manual | med |
| M7 | Keyboard move | 4 | gated | manual | med |
| M8 | Keyboard span + edge actions | 4 | gated | manual | med |
| M9 | Monitor-relative shortcuts | 5 | gated | manual | med |
| M10 | Chord mode | 6 | gated | manual | **high (event tap)** |
| M11 | Snap-on-move (optional) | 7c | gated | manual | low |
| M12 | Tile-all | 7a | gated | manual | med |
| M13 | Zone cycling + AXRaise | 7b | gated | manual | med |
| M14 | Layouts pane + list | 9a | additive | manual + unit | med |
| M15 | Canvas editor | 9b | additive | manual | **high (UI scope)** |
| M16 | Cut over, remove flag | 3 | destructive | manual regression | med |
| M17 | Calc cleanup sweep | 8 | destructive | unit + manual | med |
| M18 | Rebrand | 10 | destructive | manual | med |

**Natural "ship something usable" checkpoints:** after **M9** (grid + drag + keyboard + per-monitor
activation all work behind the flag) and after **M16** (grid is the real, default system). M14–M15 make
it configurable without code; M17–M18 are polish/identity.
