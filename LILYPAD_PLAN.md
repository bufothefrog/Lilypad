# Lilypad — Implementation Plan

A fork of Rectangle that replaces edge "snap areas" with a per-monitor **grid** system
(named layouts, drag-to-span, chord selection, keyboard nav), modeled on BentoBox but
unified into Rectangle's existing settings and persistence.

This plan is grounded in a file-level analysis of the Rectangle codebase. File:line
references are accurate as of branch `per-monitor-snap-areas`.

---

## Locked design decisions

| Decision | Choice |
|---|---|
| Layout model | Per-monitor **non-uniform zone layouts** (FancyZones-style grid **cut + merge**); multiple named layouts per monitor, one Active |
| Grid representation | **Fractional column/row boundaries + a cell→zone merge map**; uniform grids (2×2, 3×2…) are quick-starter templates, not the only option |
| Layout editor | Split/merge canvas with **divider snapping to 1/2, 1/4, 1/6, 1/8** and **live pixel readout per zone** (computed for the selected monitor) |
| Free-form Canvas zones | **Deferred** — v1 is grid cut+merge only, which keeps keyboard/chord navigation well-defined (overlapping free zones do not) |
| Runtime fraction snapping | **Not a separate feature** — fractions are an *editor* aid only; at runtime a window snaps to your layout's zones (quick-starters give halves/quarters/etc.) |
| Per-monitor keying | Display **UUID**, reusing the existing `knownDisplays` registry (disconnected monitors configurable) |
| Drag activation | Hold **Shift** → grid overlay on monitor under cursor, single-**zone** preview |
| Span sub-mode | Hold span modifier → extend selection from anchor zone; **configurable, default Option (⌥)** |
| Chord commit | Overlapping key holds; **commit on full key release** (no double-tap needed) |
| Keyboard nav | `gridMove*` (to adjacent zone), `gridSpan*` (grow/shrink); current zone inferred from window rect each press |
| Edge wall action | Per-edge configurable table (none / maximize / minimize / half / next-display) |
| Monitor-relative shortcuts | Slot actions (`activateLayoutSlot1..N`); active monitor resolved at trigger time; **cursor-vs-front-window is a setting** |
| Classic shortcuts | **Kept**: center-third, thirds/fourths columns, vertical-thirds, corner quadrants |
| Min macOS / launcher | **Drop < 13**; delete the `RectangleLauncher` target (rely on `SMAppService`) |
| Settings migration | **Clean break** — new bundle id, fresh settings, reconfigure in the new UI |

---

## Reconciliation: BentoBox behavior → Lilypad status

| BentoBox behavior | Status | Where it lands |
|---|---|---|
| Named layouts per monitor (Layout 1 = 4×2, etc.), Active/Rename/Remove/Edit | **Net-new (core)** | Stage 2 (model), Stage 9 (UI) |
| Configure a **disconnected** monitor | **Already solved** — reuse `knownDisplays` | Stage 2 |
| Shift-drag to snap | **Modify** existing drag loop | Stage 3 |
| ⌥-drag to select multiple zones | **Easy** — `snapModifiers` is already a configurable `IntDefault`; add a parallel one | Stage 3 |
| Space-aware Move (⌃⌘ H/J/K/L) | **Net-new** action set | Stage 4 |
| Space-aware Span (⇧⌘ H/J/K/L) | **Net-new** action set | Stage 4 |
| Monitor-relative layout-activation shortcuts | **Net-new architecture** (slot→active-monitor resolver) | Stage 5 |
| Chord (overlay → `q`+`s` = span) | **Net-new** (CGEventTap) | Stage 6 |
| "Tiled" auto-arrange all windows | **~70% built** — reuse `tileAllWindowsOnScreen` | Stage 7a |
| Cycle windows within a zone (⌃⇧⌘←/→) | **Net-new** (needs real AXRaise) | Stage 7b |
| Hold ⌘⇧ while *moving* mouse to snap | **Net-new, optional** (`.mouseMoved` + commit-on-modifier-release) | Stage 7c (optional) |
| "Layout shortcuts apply to: All spaces" | **Partially infeasible** — physical cross-space tiling can't be done via AX `setFrame` | See Deferred |
| Unified config (not a separate app) | **Constraint honored** — new tab in existing prefs window | Stage 9 |

---

## Deltas vs. our prior (pre-screenshot) plan — read before starting

1. **One grid per monitor → a *list* of named layouts per monitor.** Data model grows from a
   single value to `PerDisplayLayouts { layouts: [DisplayLayout], activeLayoutId }`. Mirrors the
   shape of the existing `PerDisplaySnapAreas` (`SnapAreaModel.swift:269-291`) but is a list+activeId.
2. **Span modifier flips from ctrl → Option (configurable).** Trivial: a new `IntDefault` next to
   `Defaults.snapModifiers` (`Defaults.swift:63`).
3. **New: monitor-relative layout-activation shortcuts.** This is the single largest *new*
   architectural piece beyond the grid itself. It does **not** require MASShortcut changes — see
   Stage 5.
4. **New: "Tiled" layouts** (activate a layout → arrange all windows into it). Folds into the
   existing `MultiWindowManager.tileAllWindowsOnScreen` (`MultiWindow/MultiWindowManager.swift:74-91`).
5. **New: zone cycling** and **optional: snap-while-moving-mouse.**
6. **Display-registry extraction is now a prerequisite.** `knownDisplays`/`allKnownDisplays`/
   `DisplayChoice` currently live *inside* `SnapAreaModel`, which gets gutted. They must be moved to a
   surviving `DisplayRegistry` *before* the snap-area code is deleted (Stage 2).
7. **"All spaces" needs reframing.** macOS won't `setFrame` a window on a non-active space, so
   "apply layout to all spaces" can only mean "the shortcut/layout is valid on every space," not
   "physically arrange windows across spaces." Default scope = current space.
8. **Rebrand carries a settings-orphan + TCC re-auth caveat** (no UserDefaults suite exists; prefs
   live under the bundle id). See Stage 10.

---

## Data model (new)

```swift
// One named, non-uniform layout (FancyZones grid cut+merge). Geometry is inline
// per layout (each monitor has arbitrary layouts; quick-starters just generate these).
struct ZoneLayout: Codable {
    var id: String
    var name: String              // "Layout 1"
    var colBoundaries: [Double]   // arbitrary, non-uniform; cols+1 fractions in 0...1
    var rowBoundaries: [Double]   // arbitrary, non-uniform; rows+1 fractions in 0...1
    var cellZones: [Int]          // length cols*rows; cell index → zone id.
                                  // Merged cells share a zone id. A zone's rect = bounding
                                  // box of its cells and MUST stay rectangular (editor enforces).
    // future: type (.tiled), per-layout overrides
}

// Per-monitor instance, keyed by display UUID.
struct PerDisplayLayouts: Codable {
    var layouts: [ZoneLayout]
    var activeLayoutId: String?
}
```

A **zone** is the union of all cells sharing a `cellZones` id. Its rect = the bounding box of
those cells; its **pixel size** = fractional size × the assigned monitor's resolution (so the same
layout reads differently on a 5120×1440 vs a 1080p panel — the editor shows pixels for the monitor
being edited). Uniform N×M = evenly-spaced boundaries with an identity `cellZones` (no merges).
**Quick-starters are code generators, not a persisted shared library** — there is no `gridPresets`
store; geometry lives in each `ZoneLayout`. (A user "saved templates" library could be added later.)

**New `Defaults` (all must be added to `Defaults.array`, `Defaults.swift:104-191`, or they silently
drop from config export/import):**
- `gridLayoutsByDisplay = JSONDefault<[String:PerDisplayLayouts]>` (full zone geometry inline)
- `knownDisplays` — **reuse existing**
- `gridSpanModifier = IntDefault` (default = Option rawValue) — drag span / chord multi-select
- `shortcutTargetMode = IntEnumDefault<ShortcutTargetMode>` `{ frontWindow, cursorMonitor }`
- `edgeWallActions = JSONDefault<[GridEdge:EdgeAction]>` (none/maximize/minimize/half/nextDisplay)
- `chordAutoKeys = BoolDefault`, `chordCellKeyOverrides = JSONDefault<[String:String]>`
- Grid-overlay activation reuses the existing `snapModifiers` (Shift).

> Pitfall (from analysis): `Defaults.array` is hand-maintained and already has dupes/typos
> (`showAdditionalSizesInMenu` listed twice at lines 140 & 190). Add each new key explicitly.
> Also: never write a `JSONDefault` dict on every mouse-move — keep transient drag/chord state in
> memory, persist only on commit (`saveToJSON` re-encodes the whole dict, `Defaults.swift:428-437`).

---

## The keystone: `GridCalculation` (one replaces ~100)

A single `WindowCalculation` subclass that, given a `ZoneLayout` (non-uniform boundaries + merge
map) and a zone (or a span of zones), produces a rect. **All grid features route through it** so
drag, chord, keyboard-nav, and tile-all produce identical rects for the same logical selection.

- All geometry stays in **Cocoa bottom-left coords** (same space as `NSEvent.mouseLocation`,
  `NSScreen.frame`, `adjustedVisibleFrame`, `FootprintWindow.setFrame`). Only the existing
  `WindowManager` commit step flips to top-left (`WindowManager.swift:107,178` via `.screenFlipped`).
  **Doing grid math in the wrong space mirrors zones vertically — this is the #1 risk; unit-test it.**
- `cellRect(col,row)` from `area = screen.adjustedVisibleFrame()`:
  `x = area.minX + xs[col]*area.width`, `w = (xs[col+1]-xs[col])*area.width`, etc. Non-uniform
  `xs`/`ys` make every cell potentially a different size.
- `zoneRect(zoneId)` = bounding box of the cells mapped to that zone in `cellZones`.
- `cursor→zone`: locate the cell via binary-search on the boundary arrays, then map cell→zone.
- `selection rect`: union of all zones from the anchor zone to the current zone.
- `rect→zone` inference (keyboard nav): match the window rect to the nearest zone with tolerance.
- **Zone neighbor graph** (for `gridMove*`/`gridSpan*`): the spatially-adjacent zone in each
  direction, derived from shared boundary edges. Powers "move to next zone" and "grow into next zone."
- Reapply `GapCalculation.applyGaps` exactly as `SnappingManager.getBoxRect` does today
  (`SnappingManager.swift:391`).

---

## Staged implementation

Each stage is independently buildable and testable. Dependencies noted.

### Phase A — Foundation (no visible behavior change)

#### Stage 1 — Zone model + `GridCalculation` + Defaults
- Add `ZoneLayout` / `PerDisplayLayouts` and the new `Defaults` keys (above).
- Add `Rectangle/WindowCalculation/GridCalculation.swift` (zone↔rect, cursor→zone, rect→zone,
  selection union, **zone neighbor graph**, gaps).
- Add **quick-starter generators** (uniform 2×2 / 3×2 / 4×2 / halves / thirds → `ZoneLayout`s) so the
  editor can seed a layout to then cut/merge.
- **Unit tests** in `RectangleTests` for the geometry: coordinate-space correctness, non-uniform
  boundaries, merged-zone bounding boxes, neighbor lookups, gap application. Cheapest place to kill
  the mirroring bug.
- Outcome: model + math exist and are tested; nothing wired yet.

#### Stage 2 — Display registry extraction + `GridModel`
- Extract `knownDisplays` / `recordCurrentDisplays` / `allKnownDisplays` / `DisplayChoice` /
  `forgetDisplay` out of `SnapAreaModel` (`SnapAreaModel.swift:91-158,254-264`) into a new
  `DisplayRegistry` singleton. **Keep the unnamed-display skip guard** (`SnapAreaModel.swift:107`).
- Add a `GridModel` singleton (analogous to `SnapAreaModel.instance`) with layout CRUD
  (`add/rename/remove/setActive(forDisplay:)`) using the copy-mutate-writeback idiom from
  `setConfig` (`SnapAreaModel.swift:177-183`).
- Add the version-gated migration hook in `AppDelegate.checkVersion()` (`AppDelegate.swift:107-128`):
  seed default presets (e.g. 2×2, 3×2, 4×2) rather than attempting a semantic snap-area→grid migration.
- Outcome: registry + grid model survive independently of the snap-area code that Stage 8 deletes.

### Phase B — Core interactions

#### Stage 3 — Drag-to-grid overlay (replaces edge snapping)  ·  depends on 1, 2
- New `GridOverlayWindow` (reuse `FootprintWindow`'s window recipe — level `.modalPanel`,
  `.transient`, non-opaque, no shadow, fade via `animator().alphaValue`) **plus**
  `ignoresMouseEvents = true` so it never swallows the drag. One per monitor, lazily created.
  Draw N×M cells + a moving highlight sublayer for the live preview / span.
- In `SnappingManager`:
  - Add `.flagsChanged` to the event mask (`SnappingManager.swift:149`) and a `handle()` case so the
    span modifier reacts without cursor motion (anchor on down, revert on up).
  - Rewrite the `.leftMouseDragged` branch: pick monitor via `ScreenDetection().detectScreensAtCursor()`
    (`ScreenDetection.swift:36-52`), `cursor→cell`, single-cell preview; span when modifier held.
  - Commit on `.leftMouseUp` via a **rect-carrying** execution path (extend `ExecutionParameters`, or
    a synthetic `gridSpan` action) so the existing `WindowManager`/restore/history pipeline is reused.
  - Read the span modifier with the same `.deviceIndependentFlagsMask` idiom as `canSnap`
    (`SnappingManager.swift:182-194`).
- This is where `CompoundSnapArea` + `directionalLocationOfCursor` + `snapAreaContainingCursor` stop
  being used (their deletion is finished in Stage 8).
- Outcome: hold Shift, drag → grid lights up, single-cell or ⌥-span snap on release.

#### Stage 4 — Keyboard nav: move + span + edge wall actions  ·  depends on 1, 2
- Add `gridMoveLeft/Right/Up/Down` and `gridSpanLeft/Right/Up/Down` `WindowAction` cases (fresh raw
  ints ≥ 129) and a `GridLayoutManager.execute(parameters:) -> Bool` interceptor at the top of
  `windowActionTriggered` (`ShortcutManager.swift:73-105`), mirroring `MultiWindowManager`/`TodoManager`.
  Intercepted actions need **no** `calculationsByAction` entry (they return before `WindowManager.execute`
  would beep — same as `.restore`).
- Infer current span from the window rect via `GridCalculation`; shift one cell / grow-shrink one edge.
- On a repeated press into a wall (detect via `RectangleAction.count` + `isRepeatedCommand`), apply the
  per-edge action. Add a **minimize** action (`AXMinimized`) since Rectangle has none today.
- Outcome: `⌃⌘`+arrows move, `⇧⌘`+arrows span, configurable edge behavior.

#### Stage 5 — Monitor-relative layout-activation shortcuts  ·  depends on 1, 2
- Add `activateLayoutSlot1..N` (recommend N = 9) `WindowAction` slot cases, bound normally by
  MASShortcut. **Bind by slot, not by layout name** → rename-safe.
- Handler resolves the active monitor at fire time (`shortcutTargetMode`: cursor via
  `detectScreensAtCursor` vs front-window via `detectScreens(using:)`), gets its `displayUUIDString`,
  looks up `gridLayoutsByDisplay[uuid].layouts[slot]`, and applies it (set active + optionally
  tile — see Stage 7a). Pass the resolved screen forward via `ExecutionParameters.screen`
  (`WindowManager.swift:64-65` short-circuits to that screen).
- **No MASShortcut change** — the binding stays one key→one action; the monitor is read at post time.
- Outcome: one binding activates "Layout N of whichever monitor is active," same keys at work and home.

### Phase C — Advanced

#### Stage 6 — Chord mode  ·  depends on 1, 2, 3 (shared overlay)
- New `ChordKeyboardTap` modeled on `ActiveEventMonitor` (`Utilities/EventMonitor.swift:55-108`):
  a `CGEvent.tapCreate` on `.cgSessionEventTap`/`.headInsertEventTap`/`.defaultTap` over a **raw
  `CGEventMask`** for `keyDown|keyUp|flagsChanged` (not the mouse-shaped `NSEvent.EventTypeMask`),
  running on the existing `RunLoopThread`, callback returns `nil` to **suppress** mapped chord keys
  and passes through everything else (Esc cancels). Reuse `CUtil.bridge` and the
  `tapDisabledByTimeout` restart guard (`EventMonitor.swift:97-99`). **Tap is live only while the
  overlay is open**; torn down on commit/cancel.
- `openChordGrid` action (normal MASShortcut binding) shows the overlay with auto-assigned QWERTY-block
  keys (`chordAutoKeys`, optional `chordCellKeyOverrides`); overlapping holds → bounding box of touched
  cells; commit when held-key count returns to zero.
- Gate entry on `AXIsProcessTrusted()`; **Input Monitoring may prompt** a new permission on first use.
- Outcome: shortcut → grid → `q`+`s` = first-two-thirds, single tap = single cell.

#### Stage 7 — Tile-all + zone cycling (+ optional snap-on-move)
- **7a — "Tiled" layouts**  ·  depends on 1, 2: make `tileAllWindowsOnScreen`
  (`MultiWindow/MultiWindowManager.swift:74-103`) grid-aware — reuse `allWindowsOnScreen`
  (filtering/sort) and the screen-flip plumbing, swap the `sqrt` column/row math for a `GridModel`
  lookup by display UUID + `GridCalculation`, **apply gaps** for consistency with single-window snaps
  (`WindowManager.swift:121-125`), and wire window history (`tileWindow` TODO at line 96) so tiled
  windows are restorable. Decide overflow policy when #windows > #cells.
- **7b — Zone cycling**  ·  depends on 1: add `cycleZoneForward/Backward` actions + a
  `ZoneCycleManager`. Enumerate `getAllWindowElements()` (`AccessibilityElement.swift:383-389`), map
  each frame→span via `GridCalculation`, filter to the focused window's span, cycle focus. **Add a real
  `kAXRaiseAction`** to `AccessibilityElement` — current `bringToFront` (`:289-296`) is app-level
  `activate`, unreliable for same-app windows in one zone.
- **7c — Snap while moving mouse (optional, off by default):** add `.mouseMoved` + `.flagsChanged` to
  the mask; drive the overlay off cursor while the modifier is held; commit on modifier release; target
  via `getWindowElementUnderCursor`. Flag CPU cost of `.mouseMoved`. Share the Stage 3 overlay.

### Phase D — Cleanup, UI, rebrand

#### Stage 8 — Calculation cleanup (~68 files deleted)  ·  couples with Stage 3
Sequence (build-green at each step):
1. Delete `Snapping/CompoundSnapArea/` (7 files); finish rewiring `SnapAreaModel` / `SnappingManager`
   / `SnapAreaViewController` off `.compound`.
2. Delete the 6 `*Repeated` helpers (`SixthsRepeated`, `NinthsRepeated`, `EighthsRepeated`,
   `TwelfthsRepeated`, `SixteenthsRepeated`, `HorizontalThirdsRepeated`). **Keep** `QuartersRepeated`,
   `RepeatedExecutionsCalculation`, `RepeatedExecutionsInThirdsCalculation`, `OrientationAware`.
3. Delete the 55 pure cell calcs (sixths 6, ninths 9, eighths 8, twelfths 12, sixteenths 16,
   corner-thirds 4).
4. Remove their 55 factory statics + map entries in `WindowCalculation.swift` (158-184, 193-220,
   263-333). Repoint `getBoxRect` at `GridCalculation`.
5. Scrub `WindowAction.swift`: delete the 62 grid enum cases + their arms in
   `active/name/displayName/image/gapsApplicable/category/firstInGroup/isDragSnappable/classification`,
   and the dead `SubWindowAction` members + `gapSharedEdge` arms. **Never renumber survivors**
   (raw ints are persisted).
6. Prune `WindowActionCategory` (`.sixths/.ninths/.eighths/.twelfths/.sixteenths`), `README.md:51`
   URL list, `TerminalCommands.md` ninths/eighths sections, dead `*.title` rows in `Main` strings.
- **Explicitly keep** (not folded into the grid): `firstThird/centerThird/lastThird` (20-24), fourths
  (31-36), vertical-thirds (87-91), corner quadrants (`Upper/Lower Left/Right`) + their quarter cycle.
- Outcome: `WindowCalculation/` drops ~109 → ~48 files; menu and URL endpoints self-prune (data-driven).

#### Stage 9 — Unified settings UI + FancyZones-style layout editor  ·  depends on 2 + features
> **Elevated effort.** This is no longer "pick an N×M" — it's a real split/merge editor. Treat as the
> largest UI stage; consider splitting into 9a (pane + layout list) and 9b (the canvas editor).
- Add a tiny `PrefsTabViewController: NSTabViewController` subclass (one `customClass` attribute edit
  in `Main.storyboard:2660` — avoids 4500-line scene surgery) and `addTabViewItem` for a **Layouts**
  tab in code, hosting a `LayoutsViewController`.
- Build the editor as a **SwiftUI island** via `NSHostingController` (valid at the 10.15 target; no
  SwiftUI exists yet — a deliberate new paradigm, justified by the canvas editor being painful in
  AppKit). Reuse `DisplayRegistry.allKnownDisplays()` + the per-display `NSPopUpButton` +
  `representedObject = UUID` idiom from `SnapAreaViewController.installDisplaySelectorRow` (`:206-283`)
  for the monitor selector.
- **Layout list per monitor:** add / rename / remove / make-active (mutations on
  `gridLayoutsByDisplay`), seeded from a quick-starter.
- **Canvas editor (FancyZones grid cut+merge):**
  - Drag a divider to **split** a zone; select adjacent zones and **merge** (editor must reject
    non-rectangular merges — `GridCalculation` assumes rectangular zones).
  - **Divider snapping** to 1/2, 1/4, 1/6, 1/8 of the relevant span while dragging.
  - **Live pixel readout** drawn in each zone, computed from the *selected monitor's* resolution.
- Keep MASShortcut recorders in AppKit (`MASShortcutView` + `setAssociatedUserDefaultsKey`); add
  recorders for move/span/chord-open/layout-slots + the modifier / edge-action / target-mode settings.
  Post `Notification.Name.changeDefaults` after shortcut edits to trigger rebinding
  (`ShortcutManager.reloadFromDefaults`).
- Retire the Snap Areas pane.
- Outcome: design arbitrary per-monitor layouts in-app with pixel-accurate balancing; feels native.

#### Stage 10 — Rebrand → Lilypad
**Delete the `RectangleLauncher` target entirely** (macOS < 13 dropped → `SMAppService.mainApp`
handles login-at-launch; `LaunchOnLogin.swift` needs no change). Removes one bundle id and the
exe-name coupling. **Clean break on settings** — no migration; fresh bundle id = fresh defaults.

**Functional (must change):**
- Main-app bundle id `com.knollsoft.Rectangle` → `com.lilypad.Lilypad` (`project.pbxproj` Debug/Release
  + 3 hardcoded literals: `AppDelegate.swift:17` *(launcher-kill code is removed with the target)*,
  `ApplicationToggle.swift:14`, `Config.swift:38`). The `launcherAppId` constant + `AppDelegate.swift:303-306`
  kill code can be deleted with the launcher.
- URL scheme `rectangle` → `lilypad` (`Info.plist:26`); **register both** for back-compat (handler is
  scheme-agnostic, so `open rectangle://…` scripts keep working).
- Sparkle: new `SUFeedURL` host + **new EdDSA keypair** (`SUPublicEDKey`, `Info.plist:45-47`) — the old
  key can't be reused; no in-place auto-update path from Rectangle.
- `DEVELOPMENT_TEAM` → your team (notarization); `PRODUCT_NAME`/target → `Lilypad` (sets `Lilypad.app`).
- Config dir + `RectangleConfig.json` → `Lilypad`/`LilypadConfig.json` (`Config.swift:92-107`); icon
  art (`AppIcon.icon` SVGs + appiconset PNGs) and `StatusTemplate` menu-bar glyph (design tasks).

**User-facing (should change):** ~12 storyboard titles + 596 `Rectangle` values in `Main.xcstrings`
(scripted value-only replace, spot-check translations); hardcoded strings in
`ApplicationToggle`/`FootprintWindow`/`AppDelegate`/`SettingsViewController`/`MacTilingDefaults`;
`InternetAccessPolicy.plist`; docs.

**Optional (skip for upstream-merge-ability):** `RectangleStatusItem` class, `RectangleTests`,
~270 `//  Rectangle` file headers.

**Caveat:** changing the bundle id **invalidates the Accessibility (TCC) grant** — you'll re-authorize
Accessibility (and Input Monitoring, for chord mode) once after the rebrand. Expected with a clean break.

---

## Decisions

**Resolved (locked):**
- Layout model = **non-uniform per-monitor zone layouts, FancyZones grid cut+merge**; geometry inline
  per layout; uniform grids are quick-starter generators.
- Fraction snapping (1/2,1/4,1/6,1/8) = **editor divider-snapping only**, not a runtime feature.
- Free-form Canvas zones = **deferred** (grid cut+merge only in v1).
- macOS < 13 = **dropped**; `RectangleLauncher` target **deleted**.
- Settings = **clean break** (no migration).

**Still open (sensible defaults assumed; reversible):**
1. **Layout slots with bindable shortcuts:** default **9** (`activateLayoutSlot1..9`).
2. **"Active monitor" default** (the setting exists either way): default **cursor monitor** for layout
   activation, **front-window** for keyboard move/span.
3. **Keep `rectangle://` alongside `lilypad://`?** Default: **keep both.**
4. **Tile-all overflow** when #windows > #zones: round-robin into zones vs fall back to sqrt-auto-grid.
5. **"All spaces":** ship as current-space-only in v1; "all spaces" = layout/shortcut validity, not
   physical cross-space arrangement.

---

## Risk register (top items)

- **Coordinate-space mirroring** — keep all grid math in Cocoa coords; unit-test (Stage 1).
- **Overlay swallowing drag/chord events** — `ignoresMouseEvents = true` on `GridOverlayWindow`.
- **Chord tap freezing the keyboard** — tap live only during chord; handle `tapDisabledByTimeout`;
  pass through Esc/unmapped keys.
- **`WindowManager.execute` beeps on actions with no `calculationsByAction` entry** — grid/move/span/
  slot actions must return from the `GridLayoutManager` interceptor first.
- **Deleting an action a user has a saved shortcut for** silently drops it (acceptable for removed grid
  actions; document).
- **`Defaults.array` omissions** silently break config export/import (no compile error).
- **Same-app zone cycling** unreliable without a real `kAXRaiseAction`.
- **Non-rectangular merges** — the editor must forbid L-shaped/disjoint zone merges; `GridCalculation`
  assumes each zone's cells form a rectangle. Validate at merge time.
- **Layout editor scope creep** — the FancyZones-style canvas (split/merge/divider-snap/pixel readout)
  is the biggest UI surface; budget it as its own sub-stage (9b).
- **Rebrand:** TCC re-authorization + a new Sparkle EdDSA key are unavoidable (clean break, so no
  settings-migration work).

---

## Dependency graph

```
Stage 1 ─┬─> Stage 3 ─┬─> Stage 6
         │            └─(couples)─> Stage 8
Stage 2 ─┤   Stage 4
         ├─> Stage 5
         ├─> Stage 7a / 7b / 7c
         └─> Stage 9 (also needs features)
Stage 10 (last; a few decisions gate its scope)
```
