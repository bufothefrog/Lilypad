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
//  RATIOS (per-track fields): as a precise alternative to dragging dividers, a
//  small number field sits ABOVE each column and to the LEFT of each row, each
//  aligned to the actual (possibly non-uniform) track center computed from
//  `colBoundaries` / `rowBoundaries` inside the canvas `GeometryReader`, so the
//  fields line up with the tracks and re-align live when a divider is dragged or
//  the grid resizes. Each field shows that track's current proportion (from
//  `currentColumnRatios` / `currentRowRatios`, normalized to small integers). On
//  commit it resizes ONLY that track via the pure `settingColumnRatio(atIndex:to:)`
//  / `settingRowRatio(atIndex:to:)` ops (same track count -> merges preserved).
//  Invalid input (empty / non-numeric / zero / negative) is a no-op with inline
//  feedback.
//
//  NATIVE LOOK: the sheet uses standard system controls + fonts + spacing, a
//  subtle native divider/handle styling, labeled `GroupBox` sections (Dividers,
//  Zones), and a proper bottom-trailing button bar (Cancel = .cancelAction/Esc,
//  Save = the default button via .defaultAction/Return).
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
            dividersSection
            zonesSection
            feedbackBar
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 600)
    }

    // MARK: - Per-track ratio strip geometry

    /// Width of the left gutter holding the per-ROW ratio fields.
    private let rowFieldGutter: CGFloat = 52
    /// Height of the top gutter holding the per-COLUMN ratio fields.
    private let colFieldGutter: CGFloat = 26
    /// Size of one small ratio number field.
    private let ratioFieldWidth: CGFloat = 44
    private let ratioFieldHeight: CGFloat = 20

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
        return "\(displayName) — \(Int(pixelSize.width))×\(Int(pixelSize.height)) \(unit)"
    }

    // MARK: - Canvas

    private var canvasContainer: some View {
        // Reserve a top gutter for the per-column ratio fields and a left gutter
        // for the per-row ratio fields; fit the monitor's aspect ratio inside the
        // remaining space. The ratio fields are positioned in the SAME coordinate
        // space as the canvas (offset by the gutters) so they line up with the
        // actual track centers — even non-uniform ones — and re-align live.
        GeometryReader { geo in
            let canvasArea = CGSize(width: max(geo.size.width - rowFieldGutter, 1),
                                    height: max(geo.size.height - colFieldGutter, 1))
            let fitted = LayoutEditorView.fittedRect(aspect: pixelSize, in: canvasArea)
            // The canvas origin in the GeometryReader's space (shifted past the gutters).
            let canvasOriginX = rowFieldGutter + fitted.minX
            let canvasOriginY = colFieldGutter + fitted.minY
            let canvas = CGRect(x: canvasOriginX, y: canvasOriginY, width: fitted.width, height: fitted.height)

            ZStack(alignment: .topLeading) {
                Color.clear
                // Per-column ratio fields, centered over each column track.
                columnRatioFields(canvas: canvas)
                // Per-row ratio fields, centered beside each row track.
                rowRatioFields(canvas: canvas)
                // The canvas itself.
                canvasBody(canvas: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)
            }
        }
        .frame(minHeight: 280)
    }

    // MARK: - Per-track ratio fields

    /// One small number field horizontally CENTERED over each column track, in the
    /// gutter above the canvas. Each field's x-center is the midpoint of that
    /// column's boundaries — `(colBoundaries[i] + colBoundaries[i+1]) / 2` × canvas
    /// width — so non-uniform columns get their fields placed correctly and the
    /// fields re-align whenever a divider drag changes the boundaries.
    @ViewBuilder
    private func columnRatioFields(canvas: CGRect) -> some View {
        let ratios = trackIntegerRatios(working.currentColumnRatios)
        ForEach(0..<working.cols, id: \.self) { i in
            let mid = (working.colBoundaries[i] + working.colBoundaries[i + 1]) / 2
            let x = canvas.minX + CGFloat(mid) * canvas.width
            TrackRatioField(value: ratios[i], onCommit: { applyColumnRatio(atIndex: i, $0) })
                .frame(width: ratioFieldWidth, height: ratioFieldHeight)
                .position(x: x, y: colFieldGutter / 2)
        }
    }

    /// One small number field vertically CENTERED beside each row track, in the
    /// gutter left of the canvas. Row 0 is the TOP, and `rowBoundaries` are
    /// measured from the top, so the y-center is simply the midpoint fraction ×
    /// canvas height (no flip), matching the canvas's own row layout.
    @ViewBuilder
    private func rowRatioFields(canvas: CGRect) -> some View {
        let ratios = trackIntegerRatios(working.currentRowRatios)
        ForEach(0..<working.rows, id: \.self) { i in
            let mid = (working.rowBoundaries[i] + working.rowBoundaries[i + 1]) / 2
            let y = canvas.minY + CGFloat(mid) * canvas.height
            TrackRatioField(value: ratios[i], onCommit: { applyRowRatio(atIndex: i, $0) })
                .frame(width: ratioFieldWidth, height: ratioFieldHeight)
                .position(x: rowFieldGutter / 2, y: y)
        }
    }

    /// Reduce raw fractional track proportions to small whole-number labels for the
    /// fields, reusing the same display reduction as the ratio strings (so a
    /// 25/50/25 split shows `1`, `2`, `1`). Falls back to a one-decimal value when
    /// no clean small-integer ratio fits. The returned array is aligned 1:1 with
    /// the tracks.
    private func trackIntegerRatios(_ proportions: [Double]) -> [String] {
        let string = ZoneLayout.ratioString(from: proportions)
        let parts = string.split(separator: ":").map(String.init)
        if parts.count == proportions.count { return parts }
        // Fallback: a direct proportional readout if the string didn't split 1:1.
        return proportions.map { String(format: "%.2g", $0) }
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
        // The group-box label uses the same bold regular-system-size weight as the
        // AppKit panes' section headers, so the sheet reads at the app's density.
        GroupBox(label: Text(title).font(.system(size: NSFont.systemFontSize, weight: .bold))) {
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

    // MARK: - Per-track ratio actions

    /// Commit a typed number into the COLUMN ratio field at `index`: resize ONLY
    /// that column, keeping every other column's proportion (and all merges, since
    /// the track count is unchanged). The base ratio array is the DISPLAYED
    /// small-integer ratios — what the fields show — with `index` replaced by the
    /// entered value, so "type 2 into a field showing 1" gives the intuitive 2:1:1
    /// rather than weighting against the raw fractional widths. The same-count
    /// `settingColumnRatios` path repositions boundaries and preserves merges.
    /// Invalid input (empty / non-numeric / non-positive) is a no-op with inline
    /// feedback; the boundaries change but not the track count, so the selection
    /// stays valid and is preserved.
    private func applyColumnRatio(atIndex index: Int, _ string: String) {
        guard let value = parsePositiveNumber(string) else {
            showError(invalidNumberMessage)
            return
        }
        let base = displayRatios(working.currentColumnRatios)
        guard index >= 0, index < base.count else { return }
        var ratios = base
        ratios[index] = value
        guard let next = working.settingColumnRatios(ratios) else {
            showError(NSLocalizedString("Couldn\u{2019}t apply that column size.", tableName: "Main", value: "Couldn\u{2019}t apply that column size.", comment: "Per-track ratio apply failed"))
            return
        }
        clearFeedback()
        // Defer the working-copy swap to the next runloop tick. This commit fires
        // from a TextField's onCommit (Return); replacing `working` synchronously
        // re-creates the field (its `.id(value)` changes as the normalized ratio
        // updates, e.g. "2" -> "1") WHILE it is still the first responder, which
        // thrashes AppKit's end-editing cycle into a 100%-CPU render loop. Letting
        // the field finish resigning first responder before its identity changes
        // breaks the loop.
        DispatchQueue.main.async { working = next }
    }

    /// Commit a typed number into the ROW ratio field at `index`. Same contract as
    /// `applyColumnRatio`, on the row axis.
    private func applyRowRatio(atIndex index: Int, _ string: String) {
        guard let value = parsePositiveNumber(string) else {
            showError(invalidNumberMessage)
            return
        }
        let base = displayRatios(working.currentRowRatios)
        guard index >= 0, index < base.count else { return }
        var ratios = base
        ratios[index] = value
        guard let next = working.settingRowRatios(ratios) else {
            showError(NSLocalizedString("Couldn\u{2019}t apply that row size.", tableName: "Main", value: "Couldn\u{2019}t apply that row size.", comment: "Per-track ratio apply failed"))
            return
        }
        clearFeedback()
        // Deferred to the next runloop tick — see applyColumnRatio for why
        // (TextField .id-on-commit first-responder render loop).
        DispatchQueue.main.async { working = next }
    }

    /// Parse a single positive finite number from a field's text. Returns `nil`
    /// for empty / non-numeric / zero / negative input (the no-op case).
    private func parsePositiveNumber(_ string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The base ratio array used when committing one field — the SAME values the
    /// fields display (the small-integer reduction via `trackIntegerRatios`),
    /// parsed back to numbers, so editing one field is consistent with the shown
    /// numbers. Falls back to the raw proportions if the displayed labels don't
    /// parse 1:1 (e.g. a decimal fallback readout).
    private func displayRatios(_ proportions: [Double]) -> [Double] {
        let labels = trackIntegerRatios(proportions)
        let parsed = labels.compactMap { Double($0) }
        if parsed.count == proportions.count, parsed.allSatisfy({ $0 > 0 }) {
            return parsed
        }
        return proportions
    }

    private var invalidNumberMessage: String {
        NSLocalizedString("Enter a positive number.", tableName: "Main", value: "Enter a positive number.", comment: "Invalid per-track ratio input")
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

// MARK: - Per-track ratio field

/// A single small number field for ONE column or row track. It keeps the
/// in-progress text in its OWN local `@State` and only reports a final value
/// through `onCommit` (Return / focus loss), mirroring `LayoutNameField`. It
/// re-seeds its text from the committed `value` (via `.id(value)`) whenever the
/// working layout's proportions change externally — e.g. after a divider drag
/// updates the proportions, or a rejected invalid commit snaps the field back to
/// the current value.
///
/// `TextField(_:text:onCommit:)` and `RoundedBorderTextFieldStyle` are both
/// available at the 10.15 deployment target.
private struct TrackRatioField: View {
    let value: String
    let onCommit: (String) -> Void

    @State private var text: String

    init(value: String, onCommit: @escaping (String) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _text = State(initialValue: value)
    }

    var body: some View {
        TextField("", text: $text, onCommit: { onCommit(text) })
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .font(.system(size: 11, design: .monospaced))
            .multilineTextAlignment(.center)
            .id(value)
    }
}
