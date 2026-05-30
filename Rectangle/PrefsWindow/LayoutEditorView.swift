//
//  LayoutEditorView.swift
//  Rectangle / Lilypad
//
//  M15 (Stage 9b). The FancyZones-style cut / merge canvas editor, presented as
//  a sheet from the Layouts pane's "Edit…" button. The user edits a WORKING COPY
//  of a `ZoneLayout` (`@State`) using the pure operations in
//  `ZoneLayoutEditor.swift`, then Saves (writes the geometry back through
//  `GridModel.updateLayout`) or Cancels (discards).
//
//  CANVAS GEOMETRY: the canvas is just a scaled instance of `GridCalculation` in
//  a local rect. We hand `GridCalculation.zoneRect` / `cellRect` a local CGRect
//  the size of the drawn canvas (origin at 0,0, BOTTOM-LEFT like the runtime),
//  then flip y once at draw time for SwiftUI's top-left coordinate space. This
//  reuses the runtime geometry verbatim — no rect math is duplicated here.
//
//  PIXEL READOUT: each zone is labeled with its size in the selected monitor's
//  PIXELS — point size (NSScreen.frame.size) × backingScaleFactor when the
//  display is connected, falling back to a point readout (scale 1) for a
//  disconnected display whose backing scale we can't query.
//
//  AVAILABILITY: deployment target is 10.15, so this view avoids 11+ SwiftUI
//  API (`Menu` / `Label` / `Image(systemName:)`); it uses `GeometryReader`,
//  `Path`, `DragGesture`, plain `Button`s, all available at 10.15.
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

    /// Zones the user has tapped (multi-select drives merge). Cleared after any
    /// structural edit so stale ids can't be merged.
    @State private var selectedZones: Set<Int> = []

    /// The interior divider the user last touched (for "Remove divider").
    @State private var selectedDivider: DividerRef? = nil

    /// Transient user feedback (e.g. a rejected non-rectangular merge).
    @State private var feedback: String = ""

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

    // MARK: - A reference to one interior divider.

    enum DividerAxis { case column, row }
    struct DividerRef: Equatable {
        var axis: DividerAxis
        var index: Int // boundary index in the relevant array (interior: 1...count-2)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            canvasContainer
            feedbackBar
            controlBar
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NSLocalizedString("Edit Layout", tableName: "Main", value: "Edit Layout", comment: "Layout editor sheet title"))
                .font(.headline)
            Text(resolutionSubtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var resolutionSubtitle: String {
        let unit = isPixelResolution ? "px" : "pt"
        return "\(displayName) — \(Int(pixelSize.width))×\(Int(pixelSize.height)) \(unit)"
    }

    // MARK: - Canvas

    private var canvasContainer: some View {
        // Fit the monitor's aspect ratio inside the available space.
        GeometryReader { geo in
            let canvas = LayoutEditorView.fittedRect(aspect: pixelSize, in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                canvasBody(canvas: canvas)
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)
            }
        }
        .frame(minHeight: 280)
    }

    private func canvasBody(canvas: CGRect) -> some View {
        // Local bottom-left rect the size of the drawn canvas — exactly the space
        // GridCalculation expects (origin 0,0). We flip y per-zone for SwiftUI.
        let local = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        return ZStack(alignment: .topLeading) {
            // Zone rects + readouts.
            ForEach(working.zoneIds, id: \.self) { zoneId in
                zoneView(zoneId: zoneId, local: local)
            }
            // Interior divider handles (drawn on top so they're draggable).
            dividerHandles(local: local)
        }
        .background(Color(white: 0.12))
        .border(Color.secondary, width: 1)
    }

    private func zoneView(zoneId: Int, local: CGRect) -> some View {
        let cocoaRect = GridCalculation.zoneRect(layout: working, zoneId: zoneId, in: local)
        // Flip from Cocoa bottom-left (GridCalculation) to SwiftUI top-left.
        let frame = CGRect(x: cocoaRect.minX,
                           y: local.height - cocoaRect.maxY,
                           width: cocoaRect.width,
                           height: cocoaRect.height)
        let isSelected = selectedZones.contains(zoneId)
        return ZStack {
            Rectangle()
                .fill(isSelected ? Color.accentColor.opacity(0.35) : Color(white: 0.28))
            Rectangle()
                .stroke(isSelected ? Color.accentColor : Color(white: 0.5), lineWidth: isSelected ? 2 : 1)
            Text(pixelReadout(for: cocoaRect, canvas: local))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .padding(2)
        }
        .frame(width: max(frame.width - 2, 0), height: max(frame.height - 2, 0))
        .position(x: frame.midX, y: frame.midY)
        .onTapGesture { toggleZoneSelection(zoneId) }
    }

    /// The live pixel/point readout for a zone: its fractional size × the
    /// monitor's resolution, recomputed every render so it updates during drags.
    private func pixelReadout(for cocoaRect: CGRect, canvas: CGRect) -> String {
        guard canvas.width > 0, canvas.height > 0 else { return "" }
        let w = cocoaRect.width / canvas.width * pixelSize.width
        let h = cocoaRect.height / canvas.height * pixelSize.height
        return "\(Int(w.rounded()))×\(Int(h.rounded()))"
    }

    // MARK: - Divider handles

    @ViewBuilder
    private func dividerHandles(local: CGRect) -> some View {
        // Interior column boundaries: indices 1...cols-1.
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
        let isSel = selectedDivider == DividerRef(axis: .column, index: index)
        return Rectangle()
            .fill(isSel ? Color.accentColor : Color.orange.opacity(0.85))
            .frame(width: isSel ? 5 : 3, height: local.height)
            .position(x: x, y: local.height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectedDivider = DividerRef(axis: .column, index: index)
                        let raw = Double(value.location.x / local.width)
                        let snapped = ZoneLayout.snapFraction(raw)
                        if let next = working.movingColumnBoundary(at: index, to: snapped) {
                            working = next
                        }
                    }
            )
            .onTapGesture { selectedDivider = DividerRef(axis: .column, index: index) }
    }

    private func rowHandle(index: Int, local: CGRect) -> some View {
        // rowBoundaries are measured from the TOP, and SwiftUI y is top-down, so
        // the y position is the fraction × height directly (no flip).
        let y = CGFloat(working.rowBoundaries[index]) * local.height
        let isSel = selectedDivider == DividerRef(axis: .row, index: index)
        return Rectangle()
            .fill(isSel ? Color.accentColor : Color.orange.opacity(0.85))
            .frame(width: local.width, height: isSel ? 5 : 3)
            .position(x: local.width / 2, y: y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectedDivider = DividerRef(axis: .row, index: index)
                        let raw = Double(value.location.y / local.height)
                        let snapped = ZoneLayout.snapFraction(raw)
                        if let next = working.movingRowBoundary(at: index, to: snapped) {
                            working = next
                        }
                    }
            )
            .onTapGesture { selectedDivider = DividerRef(axis: .row, index: index) }
    }

    // MARK: - Feedback + controls

    private var feedbackBar: some View {
        Text(feedback)
            .font(.caption)
            .foregroundColor(.orange)
            .frame(height: 14, alignment: .leading)
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(NSLocalizedString("Add Column", tableName: "Main", value: "Add Column", comment: "")) { addColumn() }
                Button(NSLocalizedString("Add Row", tableName: "Main", value: "Add Row", comment: "")) { addRow() }
                Button(NSLocalizedString("Remove Divider", tableName: "Main", value: "Remove Divider", comment: "")) { removeSelectedDivider() }
                    .disabled(selectedDivider == nil)
            }
            HStack(spacing: 8) {
                // Enabled for ANY 2+ selection (not only rectangular ones) so a
                // non-rectangular pick reaches the rejection feedback in
                // mergeSelection() — a true no-op-with-explanation, per the spec's
                // "reject L-shaped / disjoint selections with clear feedback".
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
                Spacer()
                Text("\(working.cols)×\(working.rows), \(working.zoneIds.count) " + NSLocalizedString("zones", tableName: "Main", value: "zones", comment: "zone count suffix"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            // No `.keyboardShortcut` (11+ only); the project targets 10.15.
            Button(NSLocalizedString("Cancel", tableName: "Main", value: "Cancel", comment: "")) { onClose() }
            Button(NSLocalizedString("Save", tableName: "Main", value: "Save", comment: "")) { save() }
                .disabled(!working.isValid)
        }
    }

    // MARK: - Selection state

    private var canUnmergeSelection: Bool {
        // Unmerge is meaningful for a single selected zone that spans >1 cell.
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

    // MARK: - Edit actions (all run a pure op on `working`)

    private func addColumn() {
        // Split the widest column down the middle (the largest gap).
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
        // Ids shift after a structural edit — drop stale selection so we never
        // act on an id that no longer exists.
        selectedZones = []
        selectedDivider = nil
    }

    private func save() {
        guard working.isValid else {
            feedback = NSLocalizedString("Layout is invalid; not saved.", tableName: "Main", value: "Layout is invalid; not saved.", comment: "")
            return
        }
        GridModel.instance.updateLayout(working, forDisplay: displayUUID)
        onSaved()
        onClose()
    }

    // MARK: - Pure helpers

    /// The midpoint of the largest gap between consecutive boundaries (where a new
    /// divider should land), or nil if the array has no interior room.
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
