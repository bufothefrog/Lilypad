//
//  LayoutEditorWindow.swift
//  Rectangle / Lilypad
//
//  M15b (Stage 9b, revised). The FULL-SCREEN INTERACTIVE layout editor. Replaces
//  the M15 in-prefs sheet (`LayoutEditorView` presented via `.sheet`) with a
//  borderless window that COVERS the layout's target monitor, so the user edits
//  the layout directly on the real screen at TRUE scale — like the Shift-drag
//  grid overlay (`GridOverlayWindow`), but the OPPOSITE for interaction: it
//  RECEIVES mouse + keyboard events and can become key.
//
//  THREE PIECES:
//  - `LayoutEditorWindow` (an `NSPanel`): borderless, screen-covering, high level,
//    translucent dim backdrop, `isOpaque = false`. CRUCIALLY interactive — it does
//    NOT set `ignoresMouseEvents` (so divider drags / zone taps land) and overrides
//    `canBecomeKey = true` (so Escape = Cancel and Return = Save work). This is the
//    mirror image of `GridOverlayWindow`, which is click-through and never key.
//  - `LayoutEditorWindowController`: resolves the target `NSScreen` from the
//    layout's display UUID (`NSScreen.screens.first where displayUUIDString == uuid`),
//    falling back to the main screen when that display is disconnected; builds the
//    window covering `screen.frame`; hosts `FullScreenLayoutEditorView` via an
//    `NSHostingView` filling the content; and tears everything down cleanly on Save
//    or Cancel, returning focus to the prefs window. Holds a strong self-reference
//    while open so it isn't deallocated mid-edit, released on close (no leak, no
//    stranded window).
//  - `FullScreenLayoutEditorView` (SwiftUI): the same editing LOGIC as the M15
//    `LayoutEditorView` (working-copy `ZoneLayout`, divider drags through
//    `snapFraction` + `movingColumn/RowBoundary`, tap-multi-select, add / remove
//    divider, merge / unmerge, true-pixel readout, Save / Cancel) — only the
//    presentation changes: zones are drawn in the screen's `adjustedVisibleFrame`
//    region at true scale, with a floating toolbar that doesn't obscure the work.
//
//  COORDINATE INTEGRATION (mirrors GridOverlayWindow): zones are laid out by the
//  same `GridCalculation.zoneRect` the runtime uses, inside the screen's
//  `adjustedVisibleFrame()`, then converted into the screen-covering view's LOCAL
//  top-left SwiftUI space. So the editor preview lands exactly where the runtime
//  snaps. The window covers the FULL `screen.frame`; the editable grid occupies the
//  visible-frame sub-region (excluding menu bar / notch / Stage strip), drawn with
//  a faint outline so the user sees the working area.
//
//  AVAILABILITY: deployment target is 10.15, so the SwiftUI view avoids 11+ API
//  (`Menu` / `Label` / `Image(systemName:)` / `.keyboardShortcut`); key handling
//  (Escape / Return) is done in AppKit on the panel instead.
//

import Cocoa
import SwiftUI

// MARK: - The interactive full-screen window

/// A borderless, screen-covering panel that hosts the layout editor and — unlike
/// `GridOverlayWindow` — RECEIVES mouse and keyboard events and can become key.
///
/// It is an `NSPanel` (not a plain `NSWindow`) so it can float as a utility
/// surface above the app without taking over as the main window; `.nonactivatingPanel`
/// is deliberately NOT set, because we want it to become key and receive the key
/// equivalents (Escape / Return) routed by the controller.
class LayoutEditorWindow: NSPanel {

    /// Invoked for Escape (cancel) — wired by the controller.
    var onCancel: (() -> Void)?
    /// Invoked for Return / Enter (save) — wired by the controller.
    var onSave: (() -> Void)?

    init(screenFrame: NSRect) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Translucent dim backdrop so it reads as a modal editing surface over the
        // real screen. The SwiftUI view paints the dim layer + grid; the window
        // itself is non-opaque with a clear background.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false

        // Float above normal windows so the editor overlays everything on that
        // screen, matching the Shift overlay's level.
        level = .modalPanel

        // Pin to the one screen / current Space (no .canJoinAllSpaces) and survive
        // Mission Control cycling, like GridOverlayWindow.
        collectionBehavior.insert(.transient)

        // CRUCIAL: this is the OPPOSITE of GridOverlayWindow. We must NOT set
        // ignoresMouseEvents — the editor needs divider drags and zone taps — and
        // we must be able to become key so Escape / Return reach us.
        // (ignoresMouseEvents defaults to false; stated here for the contrast.)
        ignoresMouseEvents = false

        setFrame(screenFrame, display: true)
    }

    // The mirror image of GridOverlayWindow's `false`/`false`: a borderless panel
    // returns false by default, so we override to true to accept key input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Keyboard: Escape = Cancel, Return = Save

    /// Escape cancels. `cancelOperation(_:)` is the standard responder hook for the
    /// Escape key / ⌘. so we don't have to inspect raw key codes.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onCancel?()
        case 36, 76: // Return, keypad Enter
            onSave?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - The controller that opens / tears down the window

/// Opens the full-screen editor on a layout's monitor and tears it down cleanly.
///
/// Lifetime: while the editor is open the controller keeps a STRONG reference to
/// itself (`retainCycle`) so it survives even though the caller (a SwiftUI button)
/// doesn't hold it. On Save / Cancel it drops that reference, closes the window,
/// and restores focus to the previously-key window (the prefs window), so nothing
/// is leaked or stranded.
final class LayoutEditorWindowController {

    /// The only live editor, so a second Edit press doesn't stack windows. A new
    /// open replaces (closes) any existing one first.
    private static var current: LayoutEditorWindowController?

    private var window: LayoutEditorWindow?
    private var hostingView: NSView?
    private var previousKeyWindow: NSWindow?
    /// The strong self-reference held while open (see class doc).
    private var retainCycle: LayoutEditorWindowController?

    private let displayUUID: String
    private let displayName: String
    private let layout: ZoneLayout
    private let onSaved: () -> Void

    private init(displayUUID: String, displayName: String, layout: ZoneLayout, onSaved: @escaping () -> Void) {
        self.displayUUID = displayUUID
        self.displayName = displayName
        self.layout = layout
        self.onSaved = onSaved
    }

    /// Open the full-screen editor for `layout` on its monitor (`displayUUID`).
    /// `onSaved` is invoked after a successful Save so the Layouts pane can refresh.
    static func open(displayUUID: String, displayName: String, layout: ZoneLayout, onSaved: @escaping () -> Void) {
        // Replace any editor already on screen so Edit can't stack windows.
        current?.close()

        let controller = LayoutEditorWindowController(
            displayUUID: displayUUID,
            displayName: displayName,
            layout: layout,
            onSaved: onSaved
        )
        current = controller
        controller.show()
    }

    // MARK: - Show

    private func show() {
        // Resolve the target screen from the display UUID; fall back to the main
        // screen when that display isn't connected, so we never crash on a
        // disconnected monitor.
        let resolved = LayoutEditorWindowController.resolveScreen(forDisplay: displayUUID)
        let screen = resolved.screen
        let isOnTargetDisplay = resolved.isTargetDisplay

        let pixel = LayoutEditorWindowController.pixelSize(for: screen, isTargetDisplay: isOnTargetDisplay)

        let win = LayoutEditorWindow(screenFrame: screen.frame)
        self.window = win
        self.previousKeyWindow = NSApp.keyWindow

        // The grid is laid out in the screen's adjusted visible frame, converted to
        // the screen-covering view's LOCAL coordinates (origin at the window's
        // bottom-left = screen.frame.origin).
        let visible = screen.adjustedVisibleFrame()
        let localVisible = CGRect(
            x: visible.minX - screen.frame.minX,
            y: visible.minY - screen.frame.minY,
            width: visible.width,
            height: visible.height
        )

        let editor = FullScreenLayoutEditorView(
            displayUUID: displayUUID,
            displayName: displayName,
            layout: layout,
            screenSize: screen.frame.size,
            visibleFrameLocal: localVisible,
            pixelSize: pixel.size,
            isPixelResolution: pixel.isPixels,
            isOnTargetDisplay: isOnTargetDisplay,
            onSave: { [weak self] working in self?.commitSave(working) },
            onCancel: { [weak self] in self?.close() }
        )

        let hosting = NSHostingView(rootView: editor)
        hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting
        self.hostingView = hosting

        // Wire the panel's key equivalents to the same handlers the toolbar uses.
        win.onCancel = { [weak self] in self?.close() }
        win.onSave = { [weak self] in
            // Save via the SwiftUI view's current working copy. The view owns the
            // working state, so it drives Save through the toolbar; the keyboard
            // Return is forwarded by posting the notification the view listens for.
            NotificationCenter.default.post(name: .layoutEditorSaveRequested, object: self)
        }

        // Hold ourselves alive while the window is open.
        retainCycle = self

        win.makeKeyAndOrderFront(nil)
        // Bring the app forward so the key window actually receives events even
        // though the panel is non-activating (the prefs window was already in the
        // active app, so this is a no-op in the common path).
        NSApp.activate(ignoringOtherApps: true)
        win.makeKey()
    }

    // MARK: - Save / Cancel / teardown

    private func commitSave(_ working: ZoneLayout) {
        guard working.isValid else { return }
        GridModel.instance.updateLayout(working, forDisplay: displayUUID)
        onSaved()
        close()
    }

    /// Tear the window down cleanly and return focus to the prefs window. Idempotent.
    func close() {
        guard let win = window else {
            // Already closed; just drop the static + self references.
            if LayoutEditorWindowController.current === self { LayoutEditorWindowController.current = nil }
            retainCycle = nil
            return
        }

        win.onCancel = nil
        win.onSave = nil
        win.orderOut(nil)
        win.contentView = nil
        self.hostingView = nil
        self.window = nil

        // Return focus to whatever was key before (the prefs window).
        previousKeyWindow?.makeKeyAndOrderFront(nil)
        previousKeyWindow = nil

        if LayoutEditorWindowController.current === self {
            LayoutEditorWindowController.current = nil
        }
        // Release the strong self-reference last, so any in-flight closure that
        // still touches `self` completes first.
        retainCycle = nil
    }

    // MARK: - Screen + pixel resolution

    /// Resolve a display UUID to a connected `NSScreen`, falling back to the main
    /// screen (then the first screen) when that display isn't connected. Never nil
    /// while at least one screen exists.
    static func resolveScreen(forDisplay uuid: String) -> (screen: NSScreen, isTargetDisplay: Bool) {
        if let match = NSScreen.screens.first(where: { $0.displayUUIDString == uuid }) {
            return (match, true)
        }
        let fallback = NSScreen.main ?? NSScreen.screens.first!
        return (fallback, false)
    }

    /// The pixel size used for the readout, measured over the SAME region the zones
    /// are drawn in — the screen's `adjustedVisibleFrame` (which excludes the menu
    /// bar / notch and any Stage strip / screen-edge gaps), NOT the full
    /// `screen.frame`. Zones lay out as fractions of that visible frame, so the
    /// readout must multiply those fractions by the visible frame's device pixels;
    /// using the full frame would overstate every zone by the menu-bar / Stage ratio.
    ///
    /// On the real target display the visible-frame points are scaled by
    /// `backingScaleFactor` for true device pixels; on a disconnected-fallback
    /// display we report visible-frame points (scale 1) since we can't claim the
    /// target's true pixels.
    static func pixelSize(for screen: NSScreen, isTargetDisplay: Bool) -> (size: CGSize, isPixels: Bool) {
        let pts = screen.adjustedVisibleFrame().size
        if isTargetDisplay {
            let scale = screen.backingScaleFactor
            return (CGSize(width: pts.width * scale, height: pts.height * scale), true)
        }
        // Fallback display: report points (scale 1) — we can't claim true device
        // pixels of the disconnected target.
        return (pts, false)
    }
}

extension Notification.Name {
    /// Posted when the editor window's Return key equivalent fires, so the SwiftUI
    /// view (which owns the working copy) performs the Save.
    static let layoutEditorSaveRequested = Notification.Name("lilypad.layoutEditorSaveRequested")
}

// MARK: - The full-screen SwiftUI editor

/// The interactive editor drawn edge-to-edge on the real screen. It reuses the M15
/// `LayoutEditorView` editing LOGIC verbatim — a working-copy `ZoneLayout` in
/// `@State`, divider drags routed through `ZoneLayout.snapFraction` +
/// `movingColumn/RowBoundary`, tap-multi-select, add / remove divider, merge /
/// unmerge, a live true-pixel readout — and changes only the PRESENTATION:
///
/// - A dim translucent backdrop fills the whole window so the editor reads as a
///   modal surface over the live screen.
/// - Zones are laid out in `visibleFrameLocal` (the screen's `adjustedVisibleFrame`
///   converted into the screen-covering view's local space), so the preview lands
///   exactly where the runtime snaps — NOT a scaled-down canvas. Each zone is
///   styled like the Shift overlay's footprint tiles (the `gridSelected/
///   UnselectedZoneColor` fills + the footprint corner radius) with an inset gap.
/// - A floating toolbar (Add Column / Add Row / Remove Divider / Merge / Unmerge /
///   Clear / Save / Cancel) is centered near the top so it never sits over the work.
/// - The pixel readout per zone is `pixelSize × the zone's fractional size`, where
///   `pixelSize` is the screen's VISIBLE-frame points × `backingScaleFactor` (true
///   device pixels) on the real target display, or visible-frame points on a
///   disconnected-fallback display. The visible frame (not the full frame) is used
///   because zones are fractions of that same editable region.
///
/// The window owns the Escape / Return key equivalents; Return is routed here via
/// `.layoutEditorSaveRequested` so this view (which holds the working copy) performs
/// the Save. The view never reads/writes Defaults' layout data directly — Save goes
/// through `onSave` -> the controller -> `GridModel.updateLayout`.
struct FullScreenLayoutEditorView: View {

    let displayUUID: String
    let displayName: String
    /// The screen's full point size (the window/view fill this).
    let screenSize: CGSize
    /// The screen's `adjustedVisibleFrame` in the view's LOCAL coordinates
    /// (origin = window bottom-left = screen.frame.origin), where the grid is drawn.
    let visibleFrameLocal: CGRect
    /// The readout resolution (true device pixels on target, points on fallback).
    let pixelSize: CGSize
    let isPixelResolution: Bool
    /// False when we fell back to another screen (the target display is
    /// disconnected); surfaces a small banner so the readout's "pt" is explained.
    let isOnTargetDisplay: Bool

    /// Save with the current working copy. The controller validates + writes via
    /// `GridModel.updateLayout`, then closes.
    let onSave: (ZoneLayout) -> Void
    /// Cancel: close without writing.
    let onCancel: () -> Void

    /// The working copy. Every edit replaces it with a new valid `ZoneLayout` from
    /// the pure operations; the original is untouched until Save.
    @State private var working: ZoneLayout
    /// Zones the user has tapped (multi-select drives merge).
    @State private var selectedZones: Set<Int> = []
    /// The interior divider last touched (for "Remove divider").
    @State private var selectedDivider: DividerRef? = nil
    /// Transient feedback (e.g. a rejected non-rectangular merge).
    @State private var feedback: String = ""

    init(displayUUID: String,
         displayName: String,
         layout: ZoneLayout,
         screenSize: CGSize,
         visibleFrameLocal: CGRect,
         pixelSize: CGSize,
         isPixelResolution: Bool,
         isOnTargetDisplay: Bool,
         onSave: @escaping (ZoneLayout) -> Void,
         onCancel: @escaping () -> Void) {
        self.displayUUID = displayUUID
        self.displayName = displayName
        self.screenSize = screenSize
        self.visibleFrameLocal = visibleFrameLocal
        self.pixelSize = pixelSize
        self.isPixelResolution = isPixelResolution
        self.isOnTargetDisplay = isOnTargetDisplay
        self.onSave = onSave
        self.onCancel = onCancel
        _working = State(initialValue: layout)
    }

    // MARK: - A reference to one interior divider (same shape as M15).

    enum DividerAxis { case column, row }
    struct DividerRef: Equatable {
        var axis: DividerAxis
        var index: Int // boundary index in the relevant array (interior: 1...count-2)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dim translucent backdrop so the editor reads as a modal surface over
            // the live screen.
            Color.black.opacity(0.55)
                .edgesIgnoringSafeArea(.all)
                // A tap on empty backdrop clears the selection (and any feedback).
                .onTapGesture {
                    selectedZones = []
                    selectedDivider = nil
                    feedback = ""
                }

            // The grid, drawn in the screen's visible-frame sub-region at true scale.
            gridLayer

            // The floating toolbar, centered near the top so it doesn't obscure work.
            toolbar
                .position(x: screenSize.width / 2, y: toolbarY)
        }
        .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
        // Return (routed from the panel's key equivalent) performs the Save.
        .onReceive(NotificationCenter.default.publisher(for: .layoutEditorSaveRequested)) { _ in
            save()
        }
    }

    /// Toolbar y in SwiftUI top-left space: a little below the top of the visible
    /// frame. `visibleFrameLocal` is in Cocoa bottom-left, so its top is at
    /// `screenSize.height - visibleFrameLocal.maxY` from the SwiftUI top.
    private var toolbarY: CGFloat {
        let topInset = screenSize.height - visibleFrameLocal.maxY
        return topInset + 44
    }

    // MARK: - Grid layer (zones + divider handles), at TRUE scale

    private var gridLayer: some View {
        // The local rect (in SwiftUI top-left space) the grid occupies.
        let regionTopY = screenSize.height - visibleFrameLocal.maxY
        let region = CGRect(x: visibleFrameLocal.minX,
                            y: regionTopY,
                            width: visibleFrameLocal.width,
                            height: visibleFrameLocal.height)
        // The Cocoa bottom-left rect GridCalculation lays zones out in: origin 0,0,
        // sized to the visible frame — exactly the runtime space, just shifted to
        // local origin. We flip y per-zone for SwiftUI.
        let cocoaLocal = CGRect(x: 0, y: 0, width: region.width, height: region.height)

        return ZStack(alignment: .topLeading) {
            // Faint outline of the working area (the visible frame).
            Rectangle()
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                .frame(width: region.width, height: region.height)
                .position(x: region.midX, y: region.midY)

            ForEach(working.zoneIds, id: \.self) { zoneId in
                zoneView(zoneId: zoneId, region: region, cocoaLocal: cocoaLocal)
            }
            dividerHandles(region: region, cocoaLocal: cocoaLocal)

            if !isOnTargetDisplay {
                fallbackBanner(region: region)
            }
        }
    }

    private func zoneView(zoneId: Int, region: CGRect, cocoaLocal: CGRect) -> some View {
        let cocoaRect = GridCalculation.zoneRect(layout: working, zoneId: zoneId, in: cocoaLocal)
        // Cocoa bottom-left -> SwiftUI top-left, then shift into the region.
        let frame = CGRect(x: region.minX + cocoaRect.minX,
                           y: region.minY + (cocoaLocal.height - cocoaRect.maxY),
                           width: cocoaRect.width,
                           height: cocoaRect.height)
        let isSelected = selectedZones.contains(zoneId)
        // Inset gap so adjacent zones read as separate footprint tiles (mirrors
        // GridOverlayView's `gap`).
        let gap = FullScreenLayoutEditorView.tileGap
        let tileW = max(frame.width - gap * 2, 0)
        let tileH = max(frame.height - gap * 2, 0)

        return ZStack {
            RoundedRectangle(cornerRadius: FullScreenLayoutEditorView.cornerRadius)
                .fill(isSelected ? selectedFill : unselectedFill)
            RoundedRectangle(cornerRadius: FullScreenLayoutEditorView.cornerRadius)
                .stroke(isSelected ? Color.white : Color.white.opacity(0.5),
                        lineWidth: isSelected ? 3 : 1)
            Text(pixelReadout(for: cocoaRect, canvas: cocoaLocal))
                .font(.system(size: 15, design: .monospaced))
                .foregroundColor(.white)
                .padding(4)
        }
        .frame(width: tileW, height: tileH)
        .position(x: frame.midX, y: frame.midY)
        .onTapGesture { toggleZoneSelection(zoneId) }
    }

    /// The live pixel/point readout for a zone: its fractional size × the monitor's
    /// resolution, recomputed every render so it updates during drags.
    private func pixelReadout(for cocoaRect: CGRect, canvas: CGRect) -> String {
        guard canvas.width > 0, canvas.height > 0 else { return "" }
        let w = cocoaRect.width / canvas.width * pixelSize.width
        let h = cocoaRect.height / canvas.height * pixelSize.height
        let unit = isPixelResolution ? "px" : "pt"
        return "\(Int(w.rounded()))×\(Int(h.rounded())) \(unit)"
    }

    // MARK: - Divider handles (drag through snapFraction + movingColumn/RowBoundary)

    @ViewBuilder
    private func dividerHandles(region: CGRect, cocoaLocal: CGRect) -> some View {
        ForEach(interiorColumnIndices, id: \.self) { idx in
            columnHandle(index: idx, region: region, cocoaLocal: cocoaLocal)
        }
        ForEach(interiorRowIndices, id: \.self) { idx in
            rowHandle(index: idx, region: region, cocoaLocal: cocoaLocal)
        }
    }

    private var interiorColumnIndices: [Int] {
        guard working.colBoundaries.count > 2 else { return [] }
        return Array(1...(working.colBoundaries.count - 2))
    }
    private var interiorRowIndices: [Int] {
        guard working.rowBoundaries.count > 2 else { return [] }
        return Array(1...(working.rowBoundaries.count - 2))
    }

    private func columnHandle(index: Int, region: CGRect, cocoaLocal: CGRect) -> some View {
        let x = region.minX + CGFloat(working.colBoundaries[index]) * region.width
        let isSel = selectedDivider == DividerRef(axis: .column, index: index)
        // A wide invisible hit area around a thin visible line, so the handle is
        // easy to grab at true scale.
        return ZStack {
            Color.white.opacity(0.001)
                .frame(width: 22, height: region.height)
            Rectangle()
                .fill(isSel ? Color.white : Color.orange.opacity(0.9))
                .frame(width: isSel ? 5 : 3, height: region.height)
        }
        .frame(width: 22, height: region.height)
        .position(x: x, y: region.midY)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    selectedDivider = DividerRef(axis: .column, index: index)
                    // location is in the local ZStack space; convert to a fraction
                    // of the grid region.
                    let raw = Double((value.location.x - region.minX) / region.width)
                    let snapped = ZoneLayout.snapFraction(raw)
                    if let next = working.movingColumnBoundary(at: index, to: snapped) {
                        working = next
                    }
                }
        )
        .onTapGesture { selectedDivider = DividerRef(axis: .column, index: index) }
    }

    private func rowHandle(index: Int, region: CGRect, cocoaLocal: CGRect) -> some View {
        // rowBoundaries are measured from the TOP and SwiftUI y is top-down, so the
        // y position is the fraction × height directly (no flip) within the region.
        let y = region.minY + CGFloat(working.rowBoundaries[index]) * region.height
        let isSel = selectedDivider == DividerRef(axis: .row, index: index)
        return ZStack {
            Color.white.opacity(0.001)
                .frame(width: region.width, height: 22)
            Rectangle()
                .fill(isSel ? Color.white : Color.orange.opacity(0.9))
                .frame(width: region.width, height: isSel ? 5 : 3)
        }
        .frame(width: region.width, height: 22)
        .position(x: region.midX, y: y)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    selectedDivider = DividerRef(axis: .row, index: index)
                    let raw = Double((value.location.y - region.minY) / region.height)
                    let snapped = ZoneLayout.snapFraction(raw)
                    if let next = working.movingRowBoundary(at: index, to: snapped) {
                        working = next
                    }
                }
        )
        .onTapGesture { selectedDivider = DividerRef(axis: .row, index: index) }
    }

    // MARK: - Fallback banner

    private func fallbackBanner(region: CGRect) -> some View {
        Text(String(format: NSLocalizedString("“%@” is disconnected — editing on this screen; sizes shown in points.", tableName: "Main", value: "“%@” is disconnected — editing on this screen; sizes shown in points.", comment: "Disconnected target display banner"), displayName))
            .font(.system(size: 13))
            .foregroundColor(.white)
            .padding(8)
            .background(Color.orange.opacity(0.85))
            .cornerRadius(6)
            .position(x: region.midX, y: region.maxY - 24)
    }

    // MARK: - Floating toolbar

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(toolbarTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("\(working.cols)×\(working.rows), \(working.zoneIds.count) " + NSLocalizedString("zones", tableName: "Main", value: "zones", comment: "zone count suffix"))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
            HStack(spacing: 8) {
                Button(NSLocalizedString("Add Column", tableName: "Main", value: "Add Column", comment: "")) { addColumn() }
                Button(NSLocalizedString("Add Row", tableName: "Main", value: "Add Row", comment: "")) { addRow() }
                Button(NSLocalizedString("Remove Divider", tableName: "Main", value: "Remove Divider", comment: "")) { removeSelectedDivider() }
                    .disabled(selectedDivider == nil)
                // Merge is enabled for ANY 2+ selection so a non-rectangular pick
                // reaches the rejection feedback in mergeSelection() (per spec).
                Button(NSLocalizedString("Merge", tableName: "Main", value: "Merge", comment: "")) { mergeSelection() }
                    .disabled(selectedZones.count < 2)
                Button(NSLocalizedString("Unmerge", tableName: "Main", value: "Unmerge", comment: "")) { unmergeSelection() }
                    .disabled(!canUnmergeSelection)
                Button(NSLocalizedString("Clear Selection", tableName: "Main", value: "Clear Selection", comment: "")) {
                    selectedZones = []
                    selectedDivider = nil
                    feedback = ""
                }
                .disabled(selectedZones.isEmpty && selectedDivider == nil)
                Divider().frame(height: 16)
                Button(NSLocalizedString("Cancel", tableName: "Main", value: "Cancel", comment: "")) { onCancel() }
                Button(NSLocalizedString("Save", tableName: "Main", value: "Save", comment: "")) { save() }
                    .disabled(!working.isValid)
            }
            if !feedback.isEmpty {
                Text(feedback)
                    .font(.system(size: 12))
                    .foregroundColor(.yellow)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .fixedSize()
    }

    private var toolbarTitle: String {
        NSLocalizedString("Edit Layout", tableName: "Main", value: "Edit Layout", comment: "Layout editor title") + " — " + displayName
    }

    // MARK: - Selection state

    private var canUnmergeSelection: Bool {
        guard selectedZones.count == 1, let z = selectedZones.first else { return false }
        return working.cellZones.filter { $0 == z }.count > 1
    }

    private func toggleZoneSelection(_ zoneId: Int) {
        feedback = ""
        if selectedZones.contains(zoneId) {
            selectedZones.remove(zoneId)
        } else {
            selectedZones.insert(zoneId)
        }
    }

    // MARK: - Edit actions (each runs a pure op on `working` — same as M15)

    private func addColumn() {
        guard let mid = midpointOfLargestGap(working.colBoundaries) else { return }
        if let next = working.addingColumnBoundary(at: mid) {
            working = next
            resetSelectionAfterStructuralEdit()
        } else {
            feedback = NSLocalizedString("Could not add a column there.", tableName: "Main", value: "Could not add a column there.", comment: "")
        }
    }

    private func addRow() {
        guard let mid = midpointOfLargestGap(working.rowBoundaries) else { return }
        if let next = working.addingRowBoundary(at: mid) {
            working = next
            resetSelectionAfterStructuralEdit()
        } else {
            feedback = NSLocalizedString("Could not add a row there.", tableName: "Main", value: "Could not add a row there.", comment: "")
        }
    }

    private func removeSelectedDivider() {
        guard let divider = selectedDivider else { return }
        let result: ZoneLayout?
        switch divider.axis {
        case .column: result = working.removingColumnBoundary(at: divider.index)
        case .row:    result = working.removingRowBoundary(at: divider.index)
        }
        if let next = result {
            working = next
            resetSelectionAfterStructuralEdit()
        } else {
            feedback = NSLocalizedString("That divider can't be removed.", tableName: "Main", value: "That divider can't be removed.", comment: "")
        }
    }

    private func mergeSelection() {
        guard selectedZones.count >= 2 else { return }
        if let next = working.merging(selectedZones) {
            working = next
            resetSelectionAfterStructuralEdit()
        } else {
            feedback = NSLocalizedString("Those zones don't form a rectangle — can't merge.", tableName: "Main", value: "Those zones don't form a rectangle — can't merge.", comment: "Non-rectangular merge rejection")
        }
    }

    private func unmergeSelection() {
        guard selectedZones.count == 1, let z = selectedZones.first else { return }
        if let next = working.unmerging(z) {
            working = next
            resetSelectionAfterStructuralEdit()
        }
    }

    private func resetSelectionAfterStructuralEdit() {
        selectedZones = []
        selectedDivider = nil
    }

    private func save() {
        guard working.isValid else {
            feedback = NSLocalizedString("Layout is invalid; not saved.", tableName: "Main", value: "Layout is invalid; not saved.", comment: "")
            return
        }
        onSave(working)
    }

    // MARK: - Pure helpers

    private func midpointOfLargestGap(_ boundaries: [Double]) -> Double? {
        guard boundaries.count >= 2 else { return nil }
        var bestMid: Double? = nil
        var bestGap = -1.0
        for i in 1..<boundaries.count {
            let gap = boundaries[i] - boundaries[i - 1]
            if gap > bestGap {
                bestGap = gap
                bestMid = (boundaries[i] + boundaries[i - 1]) / 2
            }
        }
        return bestMid
    }

    // MARK: - Footprint styling (reuses the grid overlay's colors + radius)

    /// The selected-zone fill, mirroring `GridOverlayView`: the system accent when
    /// `gridUseAccentForSelected`, else the configured / default selected color.
    private var selectedFill: Color {
        if Defaults.gridUseAccentForSelected.userEnabled {
            if #available(macOS 11.0, *) { return Color.accentColor }
            return Color(NSColor.controlAccentColor)
        }
        let ns = Defaults.gridSelectedZoneColor.typedValue?.nsColor ?? NSColor(white: 0.3, alpha: 1)
        return Color(ns)
    }

    private var unselectedFill: Color {
        let ns = Defaults.gridUnselectedZoneColor.typedValue?.nsColor ?? NSColor(white: 0.6, alpha: 1)
        return Color(ns)
    }

    /// Inset gap so adjacent zones read as separate footprint tiles (matches
    /// GridOverlayView's `gap = max(borderWidth, 4)`).
    private static var tileGap: CGFloat {
        max(CGFloat(Defaults.footprintBorderWidth.value), 4)
    }

    /// Footprint corner radius, matching FootprintWindow / GridOverlayView.
    private static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 16 }
        if #available(macOS 11.0, *) { return 10 }
        return 5
    }
}
