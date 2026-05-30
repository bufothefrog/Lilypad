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
//  RATIOS: as a precise alternative to dragging dividers the user can type an
//  axis ratio like "1:2:1" (=> 25/50/25) into the Column / Row ratio fields.
//  Each commit runs the pure `settingColumnRatios` / `settingRowRatios` op on the
//  working copy; the field shows the CURRENT ratios via `currentColumn/RowRatioString`.
//  Invalid input (empty / non-numeric / zero / negative) is a no-op with inline
//  feedback. Changing the track COUNT on an axis resets that axis's merges (the
//  pure op rebuilds an identity grid — documented in ZoneLayoutEditor.swift).
//
//  NATIVE LOOK: the sheet is grouped into labeled `GroupBox` sections (Layout
//  ratios, Dividers, Zones), uses standard system controls + fonts + spacing, a
//  subtle native divider/handle styling, and a proper bottom-trailing button bar
//  (Cancel = .cancelAction/Esc, Save = the default button via .defaultAction/Return).
//
//  AVAILABILITY: deployment target is 10.15, so this view avoids 11+ SwiftUI
//  API (`Menu` / `Label` / `Image(systemName:)`); it uses `GeometryReader`,
//  `Path`, `DragGesture`, plain `Button`s, and `GroupBox` (all 10.15). The
//  `.keyboardShortcut` button modifiers are 11+, so they're gated with `#available`.
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

    /// Transient user feedback (e.g. a rejected non-rectangular merge or an
    /// invalid ratio string). When non-empty the inline feedback bar shows it.
    @State private var feedback: String = ""

    /// Whether the current `feedback` is an error (shown in a warning color) vs
    /// a neutral note. Errors use the system warning tint; otherwise secondary.
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

    // MARK: - A reference to one interior divider.

    enum DividerAxis { case column, row }
    struct DividerRef: Equatable {
        var axis: DividerAxis
        var index: Int // boundary index in the relevant array (interior: 1...count-2)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            canvasContainer
            ratiosSection
            dividersSection
            zonesSection
            feedbackBar
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NSLocalizedString("Edit Layout", tableName: "Main", value: "Edit Layout", comment: "Layout editor sheet title"))
                .font(.headline)
            Text(resolutionSubtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .cornerRadius(4)
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
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.22)
                      : Color(NSColor.unemphasizedSelectedContentBackgroundColor))
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSelected ? Color.accentColor : Color(NSColor.separatorColor),
                        lineWidth: isSelected ? 2 : 1)
            Text(pixelReadout(for: cocoaRect, canvas: local))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(isSelected ? Color.accentColor : Color(NSColor.secondaryLabelColor))
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
            .fill(isSel ? Color.accentColor : Color(NSColor.separatorColor))
            .frame(width: isSel ? 4 : 2, height: local.height)
            // Widen the interactive target without widening the drawn line.
            .frame(width: 11)
            .contentShape(Rectangle())
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
            .fill(isSel ? Color.accentColor : Color(NSColor.separatorColor))
            .frame(width: local.width, height: isSel ? 4 : 2)
            // Widen the interactive target without widening the drawn line.
            .frame(height: 11)
            .contentShape(Rectangle())
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

    // MARK: - Ratios section

    /// Type-in column / row ratios, the precise alternative to dragging dividers.
    /// Shows the current ratios; commits via the pure ratio ops on Return / focus
    /// loss. Invalid input is a no-op with inline feedback.
    private var ratiosSection: some View {
        editorGroupBox(NSLocalizedString("Layout Ratios", tableName: "Main", value: "Layout Ratios", comment: "Ratio inputs section header")) {
            VStack(alignment: .leading, spacing: 8) {
                ratioRow(
                    label: NSLocalizedString("Columns", tableName: "Main", value: "Columns", comment: "Column ratios field label"),
                    current: working.currentColumnRatioString,
                    onCommit: { applyColumnRatios($0) }
                )
                ratioRow(
                    label: NSLocalizedString("Rows", tableName: "Main", value: "Rows", comment: "Row ratios field label"),
                    current: working.currentRowRatioString,
                    onCommit: { applyRowRatios($0) }
                )
                Text(NSLocalizedString("Type proportions like \u{201C}1:2:1\u{201D}. Changing the number of tracks resets that axis\u{2019}s merges.", tableName: "Main", value: "Type proportions like \u{201C}1:2:1\u{201D}. Changing the number of tracks resets that axis\u{2019}s merges.", comment: "Ratio field help"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func ratioRow(label: String, current: String, onCommit: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 70, alignment: .leading)
            // A self-seeding field: it re-reads `current` whenever the working
            // layout's ratios change (via `.id`), so dragging a divider updates
            // the displayed ratio, and a rejected commit snaps back.
            RatioField(current: current, onCommit: onCommit)
                .frame(maxWidth: 200, alignment: .leading)
            Spacer()
        }
    }

    // MARK: - Dividers section

    private var dividersSection: some View {
        editorGroupBox(NSLocalizedString("Dividers", tableName: "Main", value: "Dividers", comment: "Dividers section header")) {
            HStack(spacing: 8) {
                Button(NSLocalizedString("Add Column", tableName: "Main", value: "Add Column", comment: "")) { addColumn() }
                Button(NSLocalizedString("Add Row", tableName: "Main", value: "Add Row", comment: "")) { addRow() }
                Button(NSLocalizedString("Remove Divider", tableName: "Main", value: "Remove Divider", comment: "")) { removeSelectedDivider() }
                    .disabled(selectedDivider == nil)
                Spacer()
            }
        }
    }

    // MARK: - Zones section

    private var zonesSection: some View {
        editorGroupBox(NSLocalizedString("Zones", tableName: "Main", value: "Zones", comment: "Zones section header")) {
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
                    clearFeedback()
                }
                .disabled(selectedZones.isEmpty && selectedDivider == nil)
                Spacer()
                Text("\(working.cols)×\(working.rows), \(working.zoneIds.count) " + NSLocalizedString("zones", tableName: "Main", value: "zones", comment: "zone count suffix"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Feedback + footer

    private var feedbackBar: some View {
        Text(feedback)
            .font(.caption)
            .foregroundColor(feedbackIsError ? Color(NSColor.systemRed) : .secondary)
            .frame(height: 14, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Spacer()
            cancelButton
            saveButton
        }
    }

    @ViewBuilder
    private var cancelButton: some View {
        let button = Button(NSLocalizedString("Cancel", tableName: "Main", value: "Cancel", comment: "")) { onClose() }
        if #available(macOS 11.0, *) {
            button.keyboardShortcut(.cancelAction)
        } else {
            button
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        // Save is the default button (highlighted, triggered by Return).
        let button = Button(NSLocalizedString("Save", tableName: "Main", value: "Save", comment: "")) { save() }
            .disabled(!working.isValid)
        if #available(macOS 11.0, *) {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    /// A labeled `GroupBox` (10.15) wrapping section content with the native
    /// grouped-section look and consistent inner padding.
    private func editorGroupBox<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GroupBox(label: Text(title).font(.subheadline).bold()) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }

    // MARK: - Selection state

    private var canUnmergeSelection: Bool {
        // Unmerge is meaningful for a single selected zone that spans >1 cell.
        guard selectedZones.count == 1, let z = selectedZones.first else { return false }
        return working.cellZones.filter { $0 == z }.count > 1
    }

    private func toggleZoneSelection(_ zoneId: Int) {
        clearFeedback()
        if selectedZones.contains(zoneId) {
            selectedZones.remove(zoneId)
        } else {
            selectedZones.insert(zoneId)
        }
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

    // MARK: - Ratio actions

    /// Apply a typed COLUMN ratio string (e.g. "1:2:1"). Parses, then runs the
    /// pure `settingColumnRatios`. Invalid input is a no-op with inline feedback.
    private func applyColumnRatios(_ string: String) {
        guard let ratios = ZoneLayout.parseRatios(string) else {
            showError(NSLocalizedString("Enter positive numbers like \u{201C}1:2:1\u{201D}.", tableName: "Main", value: "Enter positive numbers like \u{201C}1:2:1\u{201D}.", comment: "Invalid ratio input"))
            return
        }
        guard let next = working.settingColumnRatios(ratios) else {
            showError(NSLocalizedString("Couldn\u{2019}t apply those column ratios.", tableName: "Main", value: "Couldn\u{2019}t apply those column ratios.", comment: "Ratio apply failed"))
            return
        }
        clearFeedback()
        working = next
        // A track-count change rebuilds zones, so stale selection must drop.
        resetSelectionAfterStructuralEdit()
    }

    /// Apply a typed ROW ratio string. Same contract as `applyColumnRatios`.
    private func applyRowRatios(_ string: String) {
        guard let ratios = ZoneLayout.parseRatios(string) else {
            showError(NSLocalizedString("Enter positive numbers like \u{201C}1:2:1\u{201D}.", tableName: "Main", value: "Enter positive numbers like \u{201C}1:2:1\u{201D}.", comment: "Invalid ratio input"))
            return
        }
        guard let next = working.settingRowRatios(ratios) else {
            showError(NSLocalizedString("Couldn\u{2019}t apply those row ratios.", tableName: "Main", value: "Couldn\u{2019}t apply those row ratios.", comment: "Ratio apply failed"))
            return
        }
        clearFeedback()
        working = next
        resetSelectionAfterStructuralEdit()
    }

    // MARK: - Edit actions (all run a pure op on `working`)

    private func addColumn() {
        // Split the widest column down the middle (the largest gap).
        guard let mid = midpointOfLargestGap(working.colBoundaries) else { return }
        if let next = working.addingColumnBoundary(at: mid) {
            working = next
            resetSelectionAfterStructuralEdit()
        } else {
            showError(NSLocalizedString("Could not add a column there.", tableName: "Main", value: "Could not add a column there.", comment: ""))
        }
    }

    private func addRow() {
        guard let mid = midpointOfLargestGap(working.rowBoundaries) else { return }
        if let next = working.addingRowBoundary(at: mid) {
            working = next
            resetSelectionAfterStructuralEdit()
        } else {
            showError(NSLocalizedString("Could not add a row there.", tableName: "Main", value: "Could not add a row there.", comment: ""))
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
            showError(NSLocalizedString("That divider can't be removed.", tableName: "Main", value: "That divider can't be removed.", comment: ""))
        }
    }

    private func mergeSelection() {
        guard selectedZones.count >= 2 else { return }
        if let next = working.merging(selectedZones) {
            working = next
            resetSelectionAfterStructuralEdit()
        } else {
            showError(NSLocalizedString("Those zones don't form a rectangle — can't merge.", tableName: "Main", value: "Those zones don't form a rectangle — can't merge.", comment: "Non-rectangular merge rejection"))
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
            showError(NSLocalizedString("Layout is invalid; not saved.", tableName: "Main", value: "Layout is invalid; not saved.", comment: ""))
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

// MARK: - Ratio text field

/// A single-line ratio editor that keeps the in-progress text in its OWN local
/// `@State` and only reports a final value through `onCommit` (Return / focus
/// loss), mirroring `LayoutNameField`. It re-seeds its text from the committed
/// `current` value (via `.id(current)`) whenever the working layout's ratios
/// change externally — e.g. after a divider drag updates the proportions, or a
/// rejected invalid commit snaps the field back to the current ratios.
///
/// `TextField(_:text:onCommit:)` and `RoundedBorderTextFieldStyle` are both
/// available at the 10.15 deployment target.
private struct RatioField: View {
    let current: String
    let onCommit: (String) -> Void

    @State private var text: String

    init(current: String, onCommit: @escaping (String) -> Void) {
        self.current = current
        self.onCommit = onCommit
        _text = State(initialValue: current)
    }

    var body: some View {
        TextField("1:2:1", text: $text, onCommit: { onCommit(text) })
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .font(.system(.body, design: .monospaced))
            .id(current)
    }
}
