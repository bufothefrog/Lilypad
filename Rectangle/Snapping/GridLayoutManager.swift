//
//  GridLayoutManager.swift
//  Rectangle / Lilypad
//
//  M7/M8a — keyboard navigation across the active grid. A static `execute(parameters:)`
//  interceptor (mirroring `MultiWindowManager.execute` / `TodoManager.execute`) that
//  the `ShortcutManager.windowActionTriggered` early-return chain calls before
//  `WindowManager.execute`. For a `gridMove*` action it infers the focused window's
//  current zone on its monitor's active layout and moves it one zone in the arrow
//  direction (M7). For a `gridSpan*` action (M8a, grow-only) it infers the window's
//  current cell range and grows it by one zone-line toward the arrow, beeping when the
//  edge is already at the grid boundary. For anything else it returns false untouched.
//
//  This path is purely additive: the new shortcuts don't override existing behavior,
//  so unlike the drag path it is NOT gated by the grid activation modifier.
//
//  COORDINATE SPACE: the window frame from AccessibilityElement is top-left (AX)
//  space. `GridCalculation` works in Cocoa bottom-left within the screen's
//  `adjustedVisibleFrame`. We convert the window rect with `.screenFlipped` BEFORE
//  inferring its zone, and commit the resulting zone rect through
//  `WindowManager.applyGridRect`, which re-applies `.screenFlipped` on commit (the
//  same flip WindowManager.execute uses), reusing the mover chains + recordAction
//  history (for repeat/last-action detection). Restore-to-original is preserved by
//  seeding `restoreRects` with the pre-move AX frame before committing, mirroring the
//  M5/M6 drag commit paths (`applyGridRect`/`recordAction` themselves never touch
//  `restoreRects`).
//

import Cocoa

class GridLayoutManager {

    /// Intercept a `gridMove*` action and move the focused window one zone in the
    /// arrow direction along its monitor's active grid layout.
    ///
    /// Returns `false` immediately for any non-grid action (so it is untouched and
    /// flows on to the rest of the `windowActionTriggered` chain). For a grid action
    /// it ALWAYS returns `true` (consuming it) — even on failure (no window / no
    /// screen / no layout / wall), where it beeps — so `WindowManager.execute` is
    /// never reached for a grid action (it has no `calculationsByAction` entry and
    /// would beep on the missing action).
    static func execute(parameters: ExecutionParameters) -> Bool {
        // M9: monitor-relative layout-activation slots. Resolved + consumed here before
        // the gridMove/gridSpan path so they never reach WindowManager.execute (which
        // would beep — they have no calculationsByAction entry).
        if let slot = parameters.action.layoutSlotNumber {
            return activateLayoutSlot(slot)
        }

        // Resolve the action's kind + direction. Non-grid actions return false
        // untouched so they flow on to WindowManager.execute.
        guard let resolved = gridAction(for: parameters.action) else {
            return false
        }
        let kind = resolved.kind
        let direction = resolved.direction

        // Resolve the target window: the carried element (e.g. from a drag/title-bar
        // source) or the current front window.
        guard let windowElement = parameters.windowElement ?? AccessibilityElement.getFrontWindowElement(),
              let windowId = parameters.windowId ?? windowElement.getWindowId()
        else {
            NSSound.beep()
            Logger.log("Grid move: no front window")
            return true
        }

        // Resolve the window's screen. Front-window screen detection is the natural
        // default for keyboard nav (the window, not the cursor, is what moves), but
        // honor the global cursor-screen preference so behavior matches the rest of
        // the app when the user has opted into it.
        let screenDetection = ScreenDetection()
        let usableScreens = Defaults.useCursorScreenDetection.enabled
            ? screenDetection.detectScreensAtCursor()
            : screenDetection.detectScreens(using: windowElement)
        guard let screen = usableScreens?.currentScreen,
              let displayUUID = screen.displayUUIDString
        else {
            NSSound.beep()
            Logger.log("Grid move: no usable screen / display UUID")
            return true
        }

        // The active layout for this monitor, seeding the starter set on first use.
        guard let layout = GridModel.instance.ensureActiveLayout(forDisplay: displayUUID) else {
            NSSound.beep()
            Logger.log("Grid move: no active layout for display \(displayUUID)")
            return true
        }

        let ignoreTodo = TodoManager.isTodoWindow(windowId)
        let area = screen.adjustedVisibleFrame(ignoreTodo)
        guard !area.isNull else {
            NSSound.beep()
            Logger.log("Grid move: invalid screen area")
            return true
        }

        // AX top-left frame -> Cocoa bottom-left, the space GridCalculation works in.
        let windowRect = windowElement.frame
        guard !windowRect.isNull else {
            NSSound.beep()
            Logger.log("Grid move: invalid window frame")
            return true
        }
        let cocoaWindowRect = windowRect.screenFlipped

        // Resolve the target Cocoa-space rect for this action kind.
        let gapSize = Defaults.gapSize.value
        let targetRect: CGRect
        switch kind {
        case .move:
            // MOVE: hop the window one zone in the arrow direction.
            guard let targetZone = GridCalculation.targetZone(forWindowRect: cocoaWindowRect, in: area, layout: layout, direction: direction) else {
                // Aligned window already at the WALL in this direction (no neighbor).
                // Either fire the configured per-edge wall action ("hit it again"), or
                // beep + prime so the NEXT consecutive press fires. See the helper docs.
                return handleWall(direction: direction,
                                  action: parameters.action,
                                  windowElement: windowElement,
                                  windowId: windowId,
                                  screen: screen)
            }
            targetRect = gapSize > 0
                ? GridCalculation.zoneRectWithGaps(layout: layout, zoneId: targetZone, in: area, gapSize: gapSize)
                : GridCalculation.zoneRect(layout: layout, zoneId: targetZone, in: area)

        case .span:
            // SPAN (M8a, grow-only): infer the window's current cell range, grow it one
            // cell-line toward the arrow, and commit the grown range's bounding rect.
            guard let range = GridCalculation.cellRange(matchingWindowRect: cocoaWindowRect, in: area, layout: layout) else {
                // The window's center is off the active grid — nothing to anchor on.
                NSSound.beep()
                return true
            }
            guard let grown = GridCalculation.grownRange(range, direction: direction, cols: layout.cols, rows: layout.rows) else {
                // The relevant edge is already at the grid boundary — can't grow.
                NSSound.beep()
                return true
            }
            targetRect = gapSize > 0
                ? GridCalculation.rangeRectWithGaps(grown, in: area, layout: layout, gapSize: gapSize)
                : GridCalculation.rangeRect(grown, in: area, layout: layout)
        }

        guard !targetRect.isNull else {
            NSSound.beep()
            Logger.log("Grid \(kind): null target rect")
            return true
        }

        // Commit through the M5 rect-carrying path (mover chains + recordAction, which
        // records lastRectangleActions for repeat/last-action detection). applyGridRect
        // re-applies the .screenFlipped on commit.
        guard let windowManager = WindowManager.instance else {
            NSSound.beep()
            Logger.log("Grid move: no WindowManager instance")
            return true
        }

        // Seed the pre-move restore rect so `restore` (ctrl+alt+Delete) can bring the
        // window back to where it was before this grid move. applyGridRect/recordAction
        // only write lastRectangleActions, NOT restoreRects, and .restore reads ONLY
        // restoreRects — so without this a grid move on a free/never-snapped window
        // would leave restoreRects[windowId] == nil and Restore would be a no-op. This
        // mirrors the M5/M6 drag commits (commitGridSnap/commitGridSpanSnap). Use the
        // AX/top-left frame (windowRect), captured before the move — the same value
        // WindowManager.execute stores as currentWindowRect, NOT the screenFlipped rect.
        if Defaults.unsnapRestore.enabled != false,
           AppDelegate.windowHistory.restoreRects[windowId] == nil {
            AppDelegate.windowHistory.restoreRects[windowId] = windowRect
        }

        windowManager.applyGridRect(targetRect, screen: screen, windowElement: windowElement, windowId: windowId)

        // Record the grid action itself as the last action on this window so the
        // repeat-at-wall detection (M8b) recognizes a CONSECUTIVE grid move. The
        // first move that lands the window in the edge zone records `gridMove<dir>`;
        // the NEXT press that finds no neighbor (targetZone == nil) sees this same
        // action recorded and fires the configured edge wall action. applyGridRect
        // itself records `.specified` (for restore/history); we overwrite the action
        // here with the window's actual resulting frame so a later non-grid action's
        // `windowMovedExternally` check still compares against the true frame.
        // SPAN does not participate in wall actions, so only the MOVE kind records.
        if kind == .move {
            recordGridMove(parameters.action, windowElement: windowElement, windowId: windowId)
        }
        return true
    }

    // MARK: - M9: monitor-relative layout-activation slots

    /// The overlay used for the brief activation FLASH, plus its auto-hide timer.
    /// A single shared instance (mirroring the M4 debug overlay): re-activating
    /// re-shows it on whatever screen resolves and replaces the timer, so rapid
    /// activations never leak or strand the overlay.
    private static var activationOverlay: GridOverlayWindow?
    private static var activationOverlayHideTimer: Timer?

    /// How long the activation flash stays visible before auto-hiding.
    private static let activationFlashDuration: TimeInterval = 0.8

    /// Activate the layout in `slot` (1-based) on the currently-active monitor (resolved
    /// per `Defaults.shortcutTargetMode`), set it as that monitor's active layout, and
    /// briefly flash its grid overlay as confirmation. Always returns `true` (the slot
    /// action is consumed — even on failure, where it beeps — so it never reaches
    /// `WindowManager.execute`).
    static func activateLayoutSlot(_ slot: Int) -> Bool {
        // Resolve the active monitor per the user's target-mode preference.
        let screenDetection = ScreenDetection()
        let usableScreens: UsableScreens?
        switch Defaults.shortcutTargetMode.value {
        case .frontWindow:
            usableScreens = screenDetection.detectScreens(using: AccessibilityElement.getFrontWindowElement())
        case .cursor:
            usableScreens = screenDetection.detectScreensAtCursor()
        }
        guard let screen = usableScreens?.currentScreen,
              let displayUUID = screen.displayUUIDString
        else {
            NSSound.beep()
            Logger.log("Activate layout slot \(slot): no usable screen / display UUID")
            return true
        }

        // Seed the starter set on a fresh monitor so slot 1 works on first use.
        if GridModel.instance.activeLayout(forDisplay: displayUUID) == nil {
            GridModel.instance.seedDefaultLayouts(forDisplays: [displayUUID])
        }

        // Resolve the slot to a layout id via the pure helper (testable).
        let perDisplay = GridModel.instance.layouts(forDisplay: displayUUID)
        guard let layoutId = layoutId(forSlot: slot, in: perDisplay) else {
            NSSound.beep()
            Logger.log("Activate layout slot \(slot): no such slot for display \(displayUUID)")
            return true
        }

        GridModel.instance.setActiveLayout(id: layoutId, forDisplay: displayUUID)

        // FLASH the now-active layout's overlay on that screen as visible confirmation.
        if let layout = perDisplay.layouts.first(where: { $0.id == layoutId }) {
            flashLayout(layout, on: screen)
        }
        return true
    }

    /// PURE slot resolution: given a `PerDisplayLayouts` and a 1-based slot number,
    /// return the layout id at that slot, or `nil` when the slot is out of range
    /// (including an empty layout list). Unit-tested directly.
    static func layoutId(forSlot slot: Int, in perDisplay: PerDisplayLayouts) -> String? {
        let index = slot - 1
        guard index >= 0, index < perDisplay.layouts.count else { return nil }
        return perDisplay.layouts[index].id
    }

    /// Briefly show `layout`'s grid overlay (no highlighted zones) on `screen`, then
    /// auto-hide after `activationFlashDuration`. Reuses one shared `GridOverlayWindow`
    /// and replaces the auto-hide timer on every call, so rapid activations don't leak
    /// or strand the overlay (mirrors the M4 debug-overlay auto-hide pattern).
    private static func flashLayout(_ layout: ZoneLayout, on screen: NSScreen) {
        let overlay = activationOverlay ?? GridOverlayWindow()
        activationOverlay = overlay
        // No highlighted zones: the flash confirms WHICH layout is now active, not a selection.
        overlay.show(layout: layout, on: screen, highlightZones: [])

        activationOverlayHideTimer?.invalidate()
        activationOverlayHideTimer = Timer.scheduledTimer(withTimeInterval: activationFlashDuration, repeats: false) { _ in
            activationOverlay?.hide()
            activationOverlayHideTimer = nil
        }
    }

    /// Overwrite `lastRectangleActions[windowId]` with `action` (a `gridMove<dir>`)
    /// and the window's CURRENT frame, so a consecutive grid move into the wall is
    /// detectable. Mirrors `WindowManager.recordAction`'s count bookkeeping (bump the
    /// count when the previous action matched) so the value behaves like any other
    /// recorded action.
    private static func recordGridMove(_ action: WindowAction, windowElement: AccessibilityElement, windowId: CGWindowID) {
        let resultingRect = windowElement.frame
        let newCount: Int
        if let last = AppDelegate.windowHistory.lastRectangleActions[windowId], last.action == action {
            newCount = last.count + 1
        } else {
            newCount = 1
        }
        AppDelegate.windowHistory.lastRectangleActions[windowId] = RectangleAction(
            action: action,
            subAction: nil,
            rect: resultingRect,
            count: newCount
        )
    }

    /// Decide what happens when a `gridMove<dir>` lands on a wall (no neighbor zone in
    /// `direction`): either FIRE the per-edge `EdgeAction` (the user's "hit it again"
    /// behavior) or BEEP and PRIME so the next consecutive press fires. Always returns
    /// `true` (the grid action is consumed either way).
    ///
    /// REPEAT-AT-WALL: the edge action fires only on a CONSECUTIVE wall press —
    /// `shouldFireWallAction` requires the previously recorded action on this window to
    /// be the same `gridMove<dir>`. A window that STARTS at the wall (no prior grid
    /// move, or a different last action) does NOT fire on the first press: it beeps and
    /// records `gridMove<dir>`, so the SECOND press fires. When the configured action is
    /// `.none`, it always just beeps + primes.
    private static func handleWall(direction: GridCalculation.Direction,
                                   action: WindowAction,
                                   windowElement: AccessibilityElement,
                                   windowId: CGWindowID,
                                   screen: NSScreen) -> Bool {
        let edgeAction = Self.wallAction(for: direction)
        let lastWasSameMove = AppDelegate.windowHistory.lastRectangleActions[windowId]?.action == action

        guard Self.shouldFireWallAction(edgeAction: edgeAction, atWall: true, lastActionWasSameMove: lastWasSameMove) else {
            // Either edgeAction is .none, or this is the first press at the wall.
            // Beep, and record the grid move so the next consecutive press fires.
            NSSound.beep()
            recordGridMove(action, windowElement: windowElement, windowId: windowId)
            return true
        }

        // Fire the configured edge action.
        switch edgeAction {
        case .none:
            // Unreachable (guarded above), but keep exhaustive.
            NSSound.beep()
        case .minimize:
            // AX-minimize the window directly (Rectangle has no minimize action).
            windowElement.minimize()
            // Clear history so a subsequent press starts fresh (don't re-fire on the
            // now-minimized window).
            AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
        case .maximize, .half, .nextDisplay:
            // Reuse the existing WindowManager machinery (calculation + gaps + history +
            // restore) by firing the corresponding WindowAction through the normal path.
            guard let mappedAction = Self.windowAction(for: edgeAction, direction: direction),
                  let windowManager = WindowManager.instance else {
                NSSound.beep()
                return true
            }
            // Clear the grid-move history BEFORE executing so the fired action's own
            // recordAction is what lands in history (preventing a loop where the next
            // press would see the gridMove and immediately re-fire). The fired action
            // records its own last action + (for non-display actions) restore rect.
            AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
            // For .maximize/.half a fixed single screen is correct, so pass the
            // already-resolved screen so the action acts on the same target. For the
            // display actions (.nextDisplay/.previousDisplay) DO NOT force a screen:
            // WindowManager.execute would build `UsableScreens(currentScreen:, numScreens: 1)`
            // with `adjacentScreens == nil`, and NextPrevDisplayCalculation bails on its
            // `numScreens > 1` guard — so the move would always no-op + beep no matter how
            // many displays are attached. Passing `screen: nil` lets execute run full
            // ScreenDetection (real numScreens + adjacentScreens) against the same window.
            let forcedScreen: NSScreen? = (mappedAction == .nextDisplay || mappedAction == .previousDisplay)
                ? nil
                : screen
            windowManager.execute(ExecutionParameters(mappedAction,
                                                      screen: forcedScreen,
                                                      windowElement: windowElement,
                                                      windowId: windowId))
        }
        return true
    }

    /// Whether a grid action MOVES the window to a new zone or GROWS its span.
    private enum GridActionKind: CustomStringConvertible {
        case move, span
        var description: String { self == .move ? "move" : "span" }
    }

    /// The kind + `GridCalculation.Direction` for a grid action, or `nil` if `action`
    /// is not a grid action (so `execute` returns false untouched).
    private static func gridAction(for action: WindowAction) -> (kind: GridActionKind, direction: GridCalculation.Direction)? {
        switch action {
        case .gridMoveLeft: return (.move, .left)
        case .gridMoveRight: return (.move, .right)
        case .gridMoveUp: return (.move, .up)
        case .gridMoveDown: return (.move, .down)
        case .gridSpanLeft: return (.span, .left)
        case .gridSpanRight: return (.span, .right)
        case .gridSpanUp: return (.span, .up)
        case .gridSpanDown: return (.span, .down)
        default: return nil
        }
    }

    // MARK: - Per-edge wall-action decisions (M8b, pure + unit-tested)

    /// The configured `EdgeAction` for the wall in `direction`, read from the per-edge
    /// Defaults (`gridWallAction<Edge>`). Pure mapping from direction -> edge -> action.
    static func wallAction(for direction: GridCalculation.Direction) -> EdgeAction {
        switch direction {
        case .up:    return Defaults.gridWallActionUp.value
        case .down:  return Defaults.gridWallActionDown.value
        case .left:  return Defaults.gridWallActionLeft.value
        case .right: return Defaults.gridWallActionRight.value
        }
    }

    /// Whether a wall press should FIRE the edge action vs. just beep + prime.
    ///
    /// Fires only when the configured `edgeAction` is not `.none`, the window is at the
    /// wall, AND the previous recorded action on this window was the SAME `gridMove<dir>`
    /// (a consecutive repeat — the "hit it again" gesture). Pure, so it is unit-tested
    /// directly.
    static func shouldFireWallAction(edgeAction: EdgeAction, atWall: Bool, lastActionWasSameMove: Bool) -> Bool {
        guard edgeAction != .none else { return false }
        return atWall && lastActionWasSameMove
    }

    /// The existing `WindowAction` an `EdgeAction` reuses for a given edge `direction`,
    /// or `nil` for actions that don't map to a WindowAction (`.none`, `.minimize` —
    /// minimize is handled by the AX minimize path, not a WindowAction).
    ///
    /// - `.maximize`    -> `.maximize` (fills the screen's adjusted visible frame).
    /// - `.half`        -> the half TOWARD that edge: left -> leftHalf, right -> rightHalf,
    ///                     up -> topHalf, down -> bottomHalf.
    /// - `.nextDisplay` -> the adjacent display in the edge's direction. Horizontal maps
    ///                     naturally (left -> previousDisplay, right -> nextDisplay). For
    ///                     vertical there is no separate up/down display traversal in
    ///                     Rectangle, so up reuses `previousDisplay` and down reuses
    ///                     `nextDisplay` (the same adjacent-display cycle).
    static func windowAction(for edgeAction: EdgeAction, direction: GridCalculation.Direction) -> WindowAction? {
        switch edgeAction {
        case .none, .minimize:
            return nil
        case .maximize:
            return .maximize
        case .half:
            switch direction {
            case .left:  return .leftHalf
            case .right: return .rightHalf
            case .up:    return .topHalf
            case .down:  return .bottomHalf
            }
        case .nextDisplay:
            switch direction {
            case .left, .up:    return .previousDisplay
            case .right, .down: return .nextDisplay
            }
        }
    }
}

/// A configurable action fired when a `gridMove<dir>` shortcut is pressed into a wall
/// (the window is already at the edge zone in that direction) on a consecutive repeat —
/// the user's "if I hit the edge again, do X" behavior (M8b). One value per edge, stored
/// via `IntEnumDefault<EdgeAction>` (`Defaults.gridWallAction<Edge>`).
///
/// Raw values are STABLE (persisted + exported): do not renumber once shipped.
///
/// Raw values START AT 1 by convention shared with every other `IntEnumDefault` enum
/// in Rectangle (`EnhancedUI`, `TodoSidebarSide`, `TodoSidebarWidthUnit`): `0` is
/// RESERVED as the "unset" sentinel. `IntEnumDefault.init` reads
/// `UserDefaults.standard.integer(forKey:)`, which returns `0` for a never-set key,
/// then does `E(rawValue: intValue) ?? defaultValue`. The `?? defaultValue` fallback
/// only fires when `0` is NOT a valid case — so if `.none` were `0`, a fresh install
/// would resolve to `.none` and the documented per-edge defaults
/// (`gridWallActionUp` -> `.maximize`, `gridWallActionDown` -> `.minimize`) would
/// silently never apply. Keeping `.none` at `1` lets the unset sentinel fall through
/// to `defaultValue` as intended.
/// Which monitor a monitor-relative shortcut (M9 `activateLayoutSlot*`) targets when
/// fired. Stored via `IntEnumDefault<ShortcutTargetMode>` (`Defaults.shortcutTargetMode`).
///
/// Raw values START AT 1 by the shared `IntEnumDefault` convention: `0` is the reserved
/// "unset" sentinel, so a fresh install (never-set key reads back `0`) falls through to
/// the `defaultValue` (`.frontWindow`) rather than decoding to a real case. Do not
/// renumber once shipped (the value is persisted + exported).
enum ShortcutTargetMode: Int, Codable {
    /// Resolve the active monitor from the FRONT WINDOW's screen (default).
    case frontWindow = 1
    /// Resolve the active monitor from the screen under the CURSOR.
    case cursor = 2
}

enum EdgeAction: Int, Codable {
    /// Do nothing special — just beep, as before.
    case none = 1
    /// Fill the screen's adjusted visible frame (reuses the `.maximize` action).
    case maximize = 2
    /// AX-minimize the window (reuses `AccessibilityElement.minimize()`).
    case minimize = 3
    /// Snap to the half toward that edge (left/right/top/bottom half).
    case half = 4
    /// Move to the adjacent display in that edge's direction (prev/next display).
    case nextDisplay = 5
}
