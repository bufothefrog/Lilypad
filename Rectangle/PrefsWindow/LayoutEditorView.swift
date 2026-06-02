//
//  LayoutEditorView.swift
//  Rectangle / Lilypad
//
//  M15+. A PowerToys-FancyZones-style grid editor with macOS design language,
//  presented as a sheet from the Layouts pane's "Edit…" button. The user edits a
//  WORKING COPY of a `ZoneLayout` (`@State`) using the pure operations in
//  `ZoneLayoutEditor.swift`, then Saves (writes the geometry back through
//  `GridModel.updateLayout`) or Cancels (discards).
//
//  INTERACTION (replaces the old ratio-fields / +/− / button-row editor):
//   - SPLIT: hover a zone to see a SNAPPING split GUIDE that follows the cursor.
//     The guide is VERTICAL by default; pressing SPACE (or holding Option) rotates
//     it to HORIZONTAL. Click a zone to commit the split at the snapped guide
//     position via `splittingZone`, dividing only that zone. Zones are NUMBERED
//     1…n like FancyZones.
//   - MERGE: press-drag across the canvas to sweep a rubber-band; covered zones
//     highlight. On release, a valid rectangular set (`canMerge`) shows a native
//     "Merge" chip near the selection; clicking it merges them. A non-rectangular
//     sweep shows a brief "can't merge" hint and clears.
//   - RESIZE: drag the divider lines between zones to resize, with snapping
//     (`movingColumn/RowBoundary` + `snapFraction`).
//   - UNDO: an in-editor snapshot stack; ⌘Z undo, ⌘⇧Z redo. The working copy is
//     pushed before each structural edit (split / merge / resize-commit).
//
//  CANVAS GEOMETRY: the canvas is a scaled instance of `GridCalculation` in a local
//  rect. We hand `GridCalculation.zoneRect` / `cellRect` a local CGRect the size of
//  the drawn canvas (origin 0,0, BOTTOM-LEFT like the runtime), then flip y once at
//  draw time for SwiftUI's top-left space. ROW 0 IS THE TOP. No rect math is
//  duplicated here.
//
//  PIXEL READOUT (kept): each zone is labeled with its size in the selected
//  monitor's PIXELS — point size × backingScaleFactor when connected, falling back
//  to a point readout for a disconnected display.
//
//  AVAILABILITY: deployment target is 13.0, so modern SwiftUI is fine
//  (`.onContinuousHover`, `.keyboardShortcut`, `.focusable`). No text fields remain,
//  so the prior focused-field-commit render loop cannot recur.
//

import SwiftUI

struct LayoutEditorView: View {

    /// The display whose layout is being edited (for the pixel readout + title).
    let displayUUID: String
    let displayName: String
    /// The layout id being edited (geometry is written back to this id on Save).
    let layoutId: String

    /// Called after a successful Save so the pane can refresh its list.
    let onSaved: () -> Void
    /// Dismisses the sheet (Save and Cancel both call it).
    let onClose: () -> Void

    /// The working copy. Every edit replaces this with a new valid `ZoneLayout`
    /// from the pure operations; the original is untouched until Save.
    @State private var working: ZoneLayout

    // MARK: Split-guide state

    /// The zone the cursor is hovering (for the split guide), or nil when the
    /// cursor is off the canvas / over a divider.
    @State private var hoverZone: Int? = nil
    /// The cursor location inside the canvas's LOCAL top-left space (SwiftUI), used
    /// to position the split guide. nil when not hovering.
    @State private var hoverPoint: CGPoint? = nil
    /// The current split orientation. Vertical (a vertical cut line) by default;
    /// Space / Option rotates it to horizontal.
    @State private var splitAxis: ZoneSplitAxis = .vertical
    /// True while Option is held (an alternative to Space for rotating the guide).
    @State private var optionDown: Bool = false
    /// The local `flagsChanged` monitor that tracks the Option key, installed while
    /// the sheet is on screen and removed on disappear.
    @State private var flagsMonitor: Any? = nil

    // MARK: Merge sweep state

    /// The in-progress merge sweep: the anchor zone where the press began and the
    /// zone currently under the cursor. nil when no sweep is active.
    @State private var sweepAnchorZone: Int? = nil
    @State private var sweepCurrentZone: Int? = nil
    /// Whether the active gesture has moved far enough / across zones to count as a
    /// drag (merge) rather than a click (split).
    @State private var gestureIsDrag: Bool = false
    /// The press-start location in canvas-local space, to measure drag distance.
    @State private var pressStart: CGPoint? = nil
    /// True when the current press began on the Merge chip's hit rect. While set,
    /// the canvas gesture stays out of the way (no sweep, no candidate clear, no
    /// split on release) so the chip's own Button action wins the tap.
    @State private var pressOnChip: Bool = false

    /// The committed merge candidate awaiting the chip click: the set of zones the
    /// sweep covered (a valid rectangle) and the SwiftUI-space point to anchor the
    /// chip. nil when there is no pending merge.
    @State private var mergeCandidate: MergeCandidate? = nil

    // MARK: Resize state

    /// The interior divider currently being dragged (for highlight), or nil.
    @State private var activeDivider: DividerRef? = nil
    /// Whether the current divider drag has pushed a snapshot yet (so a drag pushes
    /// exactly one undo entry, not one per frame).
    @State private var dividerDragSnapshotted: Bool = false

    // MARK: Undo / redo

    /// Snapshots of the working copy BEFORE each structural edit. ⌘Z pops.
    @State private var undoStack: [ZoneLayout] = []
    /// Snapshots popped by undo, for ⌘⇧Z redo. Cleared on any new edit.
    @State private var redoStack: [ZoneLayout] = []

    // MARK: Feedback

    /// Transient user feedback (e.g. a rejected non-rectangular merge). When
    /// non-empty the inline feedback bar shows it.
    @State private var feedback: String = ""
    @State private var feedbackIsError: Bool = false

    /// The selected monitor's pixel size (point size × backing scale), resolved
    /// once at init from the connected `NSScreen` if available.
    private let pixelSize: CGSize
    /// Whether `pixelSize` is true device pixels (connected) or just points
    /// (disconnected fallback), so the label can say "px" vs "pt".
    private let isPixelResolution: Bool

    init(displayUUID: String,
         displayName: String,
         layout: ZoneLayout,
         onSaved: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.displayUUID = displayUUID
        self.displayName = displayName
        self.layoutId = layout.id
        self.onSaved = onSaved
        self.onClose = onClose
        _working = State(initialValue: layout)

        let resolved = LayoutEditorView.resolveResolution(forDisplay: displayUUID)
        self.pixelSize = resolved.size
        self.isPixelResolution = resolved.isPixels
    }

    // MARK: - Supporting types

    enum DividerAxis { case column, row }
    struct DividerRef: Equatable {
        var axis: DividerAxis
        var index: Int // boundary index in the relevant array (interior: 1...count-2)
    }

    /// A pending merge: the zones to merge and where to anchor the chip (SwiftUI
    /// top-left canvas-local point).
    struct MergeCandidate: Equatable {
        var zones: Set<Int>
        var chipPoint: CGPoint
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            canvasContainer
            hintBar
            feedbackBar
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 560)
        // Keyboard: Space rotates the split guide; ⌘Z / ⌘⇧Z undo / redo. Hosted on
        // invisible buttons so the shortcuts work without stealing focus from the
        // canvas hover tracking.
        .background(keyboardShortcuts)
        // Track the Option key so holding it live-rotates the split guide (the
        // "and/or hold Option" half of the rotate gesture).
        .onAppear { installFlagsMonitor() }
        .onDisappear { removeFlagsMonitor() }
    }

    private func installFlagsMonitor() {
        removeFlagsMonitor()
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            optionDown = event.modifierFlags.contains(.option)
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NSLocalizedString("Edit Layout", tableName: "Main", value: "Edit Layout", comment: "Layout editor sheet title"))
                .font(.system(size: NSFont.systemFontSize, weight: .bold))
            Text(resolutionSubtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolutionSubtitle: String {
        let unit = isPixelResolution ? "px" : "pt"
        return "\(displayName) — \(Int(pixelSize.width))×\(Int(pixelSize.height)) \(unit) · \(working.cols)×\(working.rows), \(working.zoneIds.count) " + NSLocalizedString("zones", tableName: "Main", value: "zones", comment: "zone count suffix")
    }

    // MARK: - Canvas container

    private var canvasContainer: some View {
        GeometryReader { geo in
            let fitted = LayoutEditorView.fittedRect(aspect: pixelSize, in: geo.size)
            let canvas = CGRect(x: fitted.minX, y: fitted.minY, width: fitted.width, height: fitted.height)
            ZStack(alignment: .topLeading) {
                Color.clear
                canvasBody(local: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)
            }
        }
        .frame(minHeight: 320)
    }

    private func canvasBody(local: CGRect) -> some View {
        // The interactive canvas layer (zones, guide, dividers) carries the
        // press-drag gesture. The Merge chip is layered as an OVERLAY SIBLING on
        // top of this layer so its Button is hit-tested ABOVE the canvas gesture —
        // a tap on the chip reaches the Button instead of being arbitrated into the
        // parent minimumDistance:0 drag (which would clear the chip and split). The
        // gesture also guards `mergeChipHitRect` as a defensive backstop.
        ZStack(alignment: .topLeading) {
            // Zone rects + numbers + pixel readouts.
            ForEach(working.zoneIds, id: \.self) { zoneId in
                zoneView(zoneId: zoneId, local: local)
            }
            // The snapping split guide (only while hovering a zone, no sweep/chip).
            splitGuide(local: local)
            // Interior divider handles (drawn on top so they're draggable).
            dividerHandles(local: local)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .cornerRadius(4)
        .contentShape(Rectangle())
        // Hover tracking for the split guide (13+).
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                updateHover(at: point, local: local)
            case .ended:
                hoverPoint = nil
                hoverZone = nil
            }
        }
        // Press-drag: distinguishes a click-to-split from a drag-to-merge.
        .gesture(canvasGesture(local: local))
        // The Merge chip sits above the gesture layer so its tap is not stolen.
        .overlay(mergeChip(local: local))
    }

    // MARK: - Zone view

    private func zoneView(zoneId: Int, local: CGRect) -> some View {
        let cocoaRect = GridCalculation.zoneRect(layout: working, zoneId: zoneId, in: local)
        // Flip from Cocoa bottom-left (GridCalculation) to SwiftUI top-left.
        let frame = CGRect(x: cocoaRect.minX,
                           y: local.height - cocoaRect.maxY,
                           width: cocoaRect.width,
                           height: cocoaRect.height)
        let inSweep = sweepZones.contains(zoneId)
        let isHovered = hoverZone == zoneId && sweepAnchorZone == nil && mergeCandidate == nil
        let number = (working.zoneIds.firstIndex(of: zoneId) ?? 0) + 1
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(inSweep
                      ? Color.accentColor.opacity(0.22)
                      : Color(NSColor.unemphasizedSelectedContentBackgroundColor))
            RoundedRectangle(cornerRadius: 3)
                .stroke(inSweep || isHovered ? Color.accentColor : Color(NSColor.separatorColor),
                        lineWidth: inSweep || isHovered ? 2 : 1)
            VStack(spacing: 2) {
                Text("\(number)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(inSweep ? Color.accentColor : Color(NSColor.tertiaryLabelColor))
                Text(pixelReadout(for: cocoaRect, canvas: local))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(inSweep ? Color.accentColor : Color(NSColor.secondaryLabelColor))
            }
            .padding(2)
        }
        .frame(width: max(frame.width - 2, 0), height: max(frame.height - 2, 0))
        .position(x: frame.midX, y: frame.midY)
        // No tap gesture here — the canvas-level gesture owns click-vs-drag.
        .allowsHitTesting(false)
    }

    /// The live pixel/point readout for a zone: its fractional size × the
    /// monitor's resolution, recomputed every render so it updates during drags.
    private func pixelReadout(for cocoaRect: CGRect, canvas: CGRect) -> String {
        guard canvas.width > 0, canvas.height > 0 else { return "" }
        let w = cocoaRect.width / canvas.width * pixelSize.width
        let h = cocoaRect.height / canvas.height * pixelSize.height
        return "\(Int(w.rounded()))×\(Int(h.rounded()))"
    }

    // MARK: - Split guide

    @ViewBuilder
    private func splitGuide(local: CGRect) -> some View {
        if sweepAnchorZone == nil, mergeCandidate == nil,
           let zoneId = hoverZone, let point = hoverPoint,
           let guide = splitGuideGeometry(zoneId: zoneId, point: point, local: local) {
            Path { p in
                p.move(to: guide.start)
                p.addLine(to: guide.end)
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            .allowsHitTesting(false)
        }
    }

    /// The snapped split-guide line segment for the hovered zone, in SwiftUI
    /// top-left canvas-local coordinates, or nil if the cut would be degenerate.
    private func splitGuideGeometry(zoneId: Int, point: CGPoint, local: CGRect) -> (start: CGPoint, end: CGPoint)? {
        // The hovered zone's rect in SwiftUI top-left space.
        let cocoa = GridCalculation.zoneRect(layout: working, zoneId: zoneId, in: local)
        guard !cocoa.isNull else { return nil }
        let zoneRect = CGRect(x: cocoa.minX, y: local.height - cocoa.maxY, width: cocoa.width, height: cocoa.height)

        let axis = effectiveSplitAxis
        switch axis {
        case .vertical:
            // A vertical cut line: snap the x fraction across the whole canvas, then
            // clamp the drawn line into the zone's vertical span.
            let raw = Double(point.x / local.width)
            let snapped = ZoneLayout.snapFraction(raw)
            let x = CGFloat(snapped) * local.width
            guard x > zoneRect.minX + 1, x < zoneRect.maxX - 1 else { return nil }
            return (CGPoint(x: x, y: zoneRect.minY), CGPoint(x: x, y: zoneRect.maxY))
        case .horizontal:
            // A horizontal cut line: rowBoundaries are measured from the TOP and
            // SwiftUI y is top-down, so the fraction maps to y directly (no flip).
            let raw = Double(point.y / local.height)
            let snapped = ZoneLayout.snapFraction(raw)
            let y = CGFloat(snapped) * local.height
            guard y > zoneRect.minY + 1, y < zoneRect.maxY - 1 else { return nil }
            return (CGPoint(x: zoneRect.minX, y: y), CGPoint(x: zoneRect.maxX, y: y))
        }
    }

    /// The split axis to use right now: Option held forces horizontal regardless of
    /// the Space-toggled `splitAxis`, matching "Space and/or hold Option".
    private var effectiveSplitAxis: ZoneSplitAxis {
        if optionDown { return splitAxis == .vertical ? .horizontal : .vertical }
        return splitAxis
    }

    // MARK: - Divider handles (resize)

    @ViewBuilder
    private func dividerHandles(local: CGRect) -> some View {
        ForEach(interiorColumnIndices, id: \.self) { idx in
            columnHandle(index: idx, local: local)
        }
        ForEach(interiorRowIndices, id: \.self) { idx in
            rowHandle(index: idx, local: local)
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

    private func columnHandle(index: Int, local: CGRect) -> some View {
        let x = CGFloat(working.colBoundaries[index]) * local.width
        let isActive = activeDivider == DividerRef(axis: .column, index: index)
        return Rectangle()
            .fill(isActive ? Color.accentColor : Color(NSColor.separatorColor))
            .frame(width: isActive ? 4 : 2, height: local.height)
            .frame(width: 11)
            .contentShape(Rectangle())
            .position(x: x, y: local.height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dividerDragSnapshotted {
                            pushUndoSnapshot()
                            dividerDragSnapshotted = true
                        }
                        activeDivider = DividerRef(axis: .column, index: index)
                        let raw = Double(value.location.x / local.width)
                        let snapped = ZoneLayout.snapFraction(raw)
                        if let next = working.movingColumnBoundary(at: index, to: snapped) {
                            working = next
                        }
                    }
                    .onEnded { _ in
                        activeDivider = nil
                        dividerDragSnapshotted = false
                    }
            )
    }

    private func rowHandle(index: Int, local: CGRect) -> some View {
        // rowBoundaries are measured from the TOP, SwiftUI y is top-down — no flip.
        let y = CGFloat(working.rowBoundaries[index]) * local.height
        let isActive = activeDivider == DividerRef(axis: .row, index: index)
        return Rectangle()
            .fill(isActive ? Color.accentColor : Color(NSColor.separatorColor))
            .frame(width: local.width, height: isActive ? 4 : 2)
            .frame(height: 11)
            .contentShape(Rectangle())
            .position(x: local.width / 2, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dividerDragSnapshotted {
                            pushUndoSnapshot()
                            dividerDragSnapshotted = true
                        }
                        activeDivider = DividerRef(axis: .row, index: index)
                        let raw = Double(value.location.y / local.height)
                        let snapped = ZoneLayout.snapFraction(raw)
                        if let next = working.movingRowBoundary(at: index, to: snapped) {
                            working = next
                        }
                    }
                    .onEnded { _ in
                        activeDivider = nil
                        dividerDragSnapshotted = false
                    }
            )
    }

    // MARK: - Merge chip

    @ViewBuilder
    private func mergeChip(local: CGRect) -> some View {
        // Sized to the full canvas (top-leading) so the inner `.position` is in the
        // same canvas-local space as the zones; allowsHitTesting only the chip.
        ZStack(alignment: .topLeading) {
            if let candidate = mergeCandidate {
                Button(action: { commitMerge(candidate.zones) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 11, weight: .semibold))
                        Text(NSLocalizedString("Merge", tableName: "Main", value: "Merge", comment: "Merge chip"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundColor(.white)
                    .background(Capsule().fill(Color.accentColor))
                    .shadow(radius: 2, y: 1)
                }
                .buttonStyle(PlainButtonStyle())
                .position(x: clampChipX(candidate.chipPoint.x, local: local),
                          y: clampChipY(candidate.chipPoint.y, local: local))
            }
        }
        .frame(width: local.width, height: local.height, alignment: .topLeading)
        // Only the chip itself should swallow hits; empty canvas stays interactive.
        .allowsHitTesting(mergeCandidate != nil)
    }

    private func clampChipX(_ x: CGFloat, local: CGRect) -> CGFloat {
        min(max(x, 44), local.width - 44)
    }
    private func clampChipY(_ y: CGFloat, local: CGRect) -> CGFloat {
        min(max(y, 16), local.height - 16)
    }

    /// The approximate hit rect of the visible Merge chip in SwiftUI top-left
    /// canvas-local space, or nil when no chip is shown. Used to keep the
    /// canvas-level press-drag gesture from intercepting a tap on the chip (which
    /// would otherwise clear the candidate on press-down and commit a split on
    /// release). Sized generously around the chip's clamped center so the whole
    /// capsule (plus a touch of slop) is treated as "on the chip".
    private func mergeChipHitRect(local: CGRect) -> CGRect? {
        guard let candidate = mergeCandidate else { return nil }
        let cx = clampChipX(candidate.chipPoint.x, local: local)
        let cy = clampChipY(candidate.chipPoint.y, local: local)
        // The capsule is ~84pt wide × ~26pt tall (icon + "Merge" + padding); pad it.
        let halfW: CGFloat = 56
        let halfH: CGFloat = 20
        return CGRect(x: cx - halfW, y: cy - halfH, width: halfW * 2, height: halfH * 2)
    }

    // MARK: - Hover update

    private func updateHover(at point: CGPoint, local: CGRect) {
        // Ignore hover while a sweep / merge chip / divider drag owns the canvas.
        guard sweepAnchorZone == nil, activeDivider == nil else { return }
        guard local.width > 0, local.height > 0 else { return }
        hoverPoint = point
        hoverZone = zoneAt(point: point, local: local)
    }

    /// The zone under a SwiftUI top-left canvas-local point, via the runtime
    /// hit-test in Cocoa bottom-left space (flip y once).
    private func zoneAt(point: CGPoint, local: CGRect) -> Int? {
        let cocoaPoint = CGPoint(x: point.x, y: local.height - point.y)
        return GridCalculation.zone(at: cocoaPoint, in: local, layout: working)
    }

    // MARK: - Canvas press-drag gesture (click-to-split vs drag-to-merge)

    private func canvasGesture(local: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // A live divider drag owns the gesture stream; bail.
                guard activeDivider == nil else { return }
                if pressStart == nil {
                    pressStart = value.startLocation
                    // If the press began on the Merge chip, stay out of the way so
                    // the chip's Button action wins: don't start a sweep and don't
                    // clear the candidate. (SwiftUI arbitration between a child
                    // Button and a parent minimumDistance:0 drag is ambiguous, so we
                    // explicitly defer to the chip here.)
                    if let chip = mergeChipHitRect(local: local), chip.contains(value.startLocation) {
                        pressOnChip = true
                        return
                    }
                    // A press elsewhere starts a fresh sweep and clears a stale chip.
                    sweepAnchorZone = zoneAt(point: value.startLocation, local: local)
                    sweepCurrentZone = sweepAnchorZone
                    gestureIsDrag = false
                    mergeCandidate = nil
                }
                // While the press owns the chip, ignore movement entirely.
                guard !pressOnChip else { return }
                let dx = value.location.x - value.startLocation.x
                let dy = value.location.y - value.startLocation.y
                let movedZone = zoneAt(point: value.location, local: local)
                // Promote to a drag once the cursor moves enough OR crosses into a
                // different zone than the anchor.
                if hypot(dx, dy) > 6 || (movedZone != nil && movedZone != sweepAnchorZone) {
                    gestureIsDrag = true
                }
                sweepCurrentZone = movedZone ?? sweepCurrentZone
            }
            .onEnded { value in
                defer { resetGestureTransients() }
                guard activeDivider == nil else { return }
                // The press was on the chip — let the Button's action handle it; do
                // not commit a split or sweep here.
                if pressOnChip { return }
                if gestureIsDrag {
                    finishSweep(local: local)
                } else {
                    commitSplit(at: value.location, local: local)
                }
            }
    }

    private func resetGestureTransients() {
        pressStart = nil
        sweepAnchorZone = nil
        sweepCurrentZone = nil
        gestureIsDrag = false
        pressOnChip = false
    }

    /// The zones currently covered by the active sweep (bounding cell-range of the
    /// anchor + current zone), for highlighting.
    private var sweepZones: Set<Int> {
        guard let anchor = sweepAnchorZone else { return [] }
        let current = sweepCurrentZone ?? anchor
        return GridCalculation.zonesInSpan(fromZone: anchor, toZone: current, layout: working)
    }

    // MARK: - Commit: split

    private func commitSplit(at point: CGPoint, local: CGRect) {
        clearFeedback()
        guard let zoneId = zoneAt(point: point, local: local) else { return }
        let axis = effectiveSplitAxis
        let fraction: Double
        switch axis {
        case .vertical:   fraction = ZoneLayout.snapFraction(Double(point.x / local.width))
        case .horizontal: fraction = ZoneLayout.snapFraction(Double(point.y / local.height))
        }
        guard let next = working.splittingZone(zoneId, axis: axis, at: fraction) else {
            // Degenerate / out-of-zone cut — no-op (no nag, the guide already hid).
            return
        }
        pushUndoSnapshot()
        working = next
    }

    // MARK: - Commit: merge

    private func finishSweep(local: CGRect) {
        clearFeedback()
        guard let anchor = sweepAnchorZone else { return }
        let current = sweepCurrentZone ?? anchor
        let zones = GridCalculation.zonesInSpan(fromZone: anchor, toZone: current, layout: working)
        // A single zone (or empty) isn't a merge.
        guard zones.count >= 2 else { return }
        if working.canMerge(zones) {
            // Anchor the chip at the top-center of the selection's bounding box
            // (SwiftUI top-left space).
            let cocoa = GridCalculation.boundingRect(ofZones: zones, in: local, layout: working)
            let chip = CGPoint(x: cocoa.midX, y: local.height - cocoa.maxY + 16)
            mergeCandidate = MergeCandidate(zones: zones, chipPoint: chip)
        } else {
            showError(NSLocalizedString("Those zones don\u{2019}t form a rectangle — can\u{2019}t merge.", tableName: "Main", value: "Those zones don\u{2019}t form a rectangle — can\u{2019}t merge.", comment: "Non-rectangular merge rejection"))
            mergeCandidate = nil
        }
    }

    private func commitMerge(_ zones: Set<Int>) {
        clearFeedback()
        guard let next = working.merging(zones) else {
            showError(NSLocalizedString("Those zones don\u{2019}t form a rectangle — can\u{2019}t merge.", tableName: "Main", value: "Those zones don\u{2019}t form a rectangle — can\u{2019}t merge.", comment: "Non-rectangular merge rejection"))
            mergeCandidate = nil
            return
        }
        pushUndoSnapshot()
        working = next
        mergeCandidate = nil
    }

    // MARK: - Undo / redo

    private func pushUndoSnapshot() {
        undoStack.append(working)
        redoStack.removeAll()
        // Any structural edit invalidates a pending merge chip.
        mergeCandidate = nil
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(working)
        working = previous
        clearTransientSelection()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(working)
        working = next
        clearTransientSelection()
    }

    private func clearTransientSelection() {
        mergeCandidate = nil
        hoverZone = nil
        hoverPoint = nil
        activeDivider = nil
    }

    // MARK: - Hint + feedback + footer

    private var hintBar: some View {
        Text(NSLocalizedString("Click a zone to split (Space to rotate). Drag across zones to merge. Drag a line to resize. \u{2318}Z to undo.", tableName: "Main", value: "Click a zone to split (Space to rotate). Drag across zones to merge. Drag a line to resize. \u{2318}Z to undo.", comment: "Editor gesture hint"))
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var feedbackBar: some View {
        Text(feedback)
            .font(.caption)
            .foregroundColor(feedbackIsError ? Color(NSColor.systemRed) : .secondary)
            .frame(height: 14, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(NSLocalizedString("Undo", tableName: "Main", value: "Undo", comment: "")) { undo() }
                .disabled(undoStack.isEmpty)
            Button(NSLocalizedString("Redo", tableName: "Main", value: "Redo", comment: "")) { redo() }
                .disabled(redoStack.isEmpty)
            Spacer()
            Button(NSLocalizedString("Cancel", tableName: "Main", value: "Cancel", comment: "")) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button(NSLocalizedString("Save", tableName: "Main", value: "Save", comment: "")) { save() }
                .disabled(!working.isValid)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Keyboard shortcuts (Space rotate, ⌘Z / ⌘⇧Z, Option track)

    /// Invisible buttons hosting the editor keyboard shortcuts. Kept off-screen so
    /// they don't take canvas space; they don't grab focus from hover tracking.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { rotateSplitAxis() }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { undo() }
                .keyboardShortcut("z", modifiers: [.command])
            Button("") { redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func rotateSplitAxis() {
        splitAxis = splitAxis == .vertical ? .horizontal : .vertical
    }

    // MARK: - Feedback helpers

    private func showError(_ message: String) {
        feedback = message
        feedbackIsError = true
    }

    private func clearFeedback() {
        feedback = ""
        feedbackIsError = false
    }

    // MARK: - Save

    private func save() {
        guard working.isValid else {
            showError(NSLocalizedString("Layout is invalid; not saved.", tableName: "Main", value: "Layout is invalid; not saved.", comment: ""))
            return
        }
        GridModel.instance.updateLayout(working, forDisplay: displayUUID)
        onSaved()
        onClose()
    }

    // MARK: - Pure helpers

    /// The aspect-fitted CGRect (origin offset + size) for a canvas of `aspect`
    /// ratio inside `available`, leaving a small margin.
    static func fittedRect(aspect: CGSize, in available: CGSize) -> CGRect {
        let margin: CGFloat = 8
        let w = max(available.width - margin * 2, 1)
        let h = max(available.height - margin * 2, 1)
        guard aspect.width > 0, aspect.height > 0 else {
            return CGRect(x: margin, y: margin, width: w, height: h)
        }
        let targetAspect = aspect.width / aspect.height
        var drawW = w
        var drawH = w / targetAspect
        if drawH > h {
            drawH = h
            drawW = h * targetAspect
        }
        let x = margin + (w - drawW) / 2
        let y = margin + (h - drawH) / 2
        return CGRect(x: x, y: y, width: drawW, height: drawH)
    }

    /// Resolve a display UUID to its resolution. Connected displays report true
    /// device pixels (`frame.size` × `backingScaleFactor`); a disconnected display
    /// we can't query falls back to a 1920×1080 point canvas (scale 1) so the
    /// editor still renders a sensible aspect ratio.
    static func resolveResolution(forDisplay uuid: String) -> (size: CGSize, isPixels: Bool) {
        for screen in NSScreen.screens where screen.displayUUIDString == uuid {
            let scale = screen.backingScaleFactor
            let pts = screen.frame.size
            return (CGSize(width: pts.width * scale, height: pts.height * scale), true)
        }
        return (CGSize(width: 1920, height: 1080), false)
    }
}
