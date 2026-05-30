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
//  so unlike the drag path it is NOT gated by `Defaults.gridModeEnabled`.
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
                // Aligned window already at the wall in this direction (no neighbor).
                NSSound.beep()
                return true
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
}
