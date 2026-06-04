//
//  LayoutsRootView.swift
//  Rectangle / Lilypad
//
//  M14 (Stage 9a). The SwiftUI Layouts preferences pane (the first SwiftUI in the
//  project), hosted by `LayoutsViewController` via `NSHostingController`. Backed by
//  `GridSettingsModel`, which reads/writes the grid `Defaults` and round-trips all
//  layout data through `GridModel`.
//
//  Sections:
//  - MONITOR PICKER over `DisplayRegistry.allKnownDisplays()` (disconnected ones
//    marked), selection by uuid.
//  - LAYOUTS LIST for the selected display: rename (editable text field),
//    make-active, remove, a disabled "Edit…" placeholder (the FancyZones editor is
//    M15), and an Add picker of quick-starters.
//  - GRID SETTINGS bound to the grid Defaults (mode toggle, activation/span
//    modifiers, shortcut target, the four wall actions, zone colors + accent
//    toggle, gap size).
//
//  AVAILABILITY: the deployment target is 10.15, so this view sticks to SwiftUI API
//  available there — no `Menu` / `Label` / `Image(systemName:)` / `.help` (all
//  11+). The Add control is a `Button` that presents a `.popover` containing a
//  hover-to-pick grid (like a word processor's "insert table"): moving the pointer
//  over the grid highlights an N × M region (via `onHover`, available at 10.15) and
//  clicking creates a uniform N × M layout. The active marker is a drawn `Circle`.
//  The only 11+ API used is `ColorPicker`, gated with `#available` and degraded to
//  a label on 10.15.
//

import SwiftUI

struct LayoutsRootView: View {
    // Owned by the view (the pane is created once). `@ObservedObject` is available
    // at 10.15, unlike `@StateObject` (11+). The hosting controller keeps this view
    // — and thus the model — alive for the pane's lifetime.
    @ObservedObject private var model = GridSettingsModel()

    // Whether the hover-to-pick "Add" grid popover is showing.
    @State private var addPopoverShown = false

    // The layout currently open in the FancyZones editor sheet (M15). `nil` =
    // no sheet. Identifiable so `.sheet(item:)` (10.15) drives presentation.
    @State private var editingLayout: ZoneLayout? = nil

    // The layout awaiting a Remove confirmation (`nil` = no prompt). Removal is
    // destructive and has no in-pane undo, so we confirm before deleting.
    @State private var layoutPendingRemoval: ZoneLayout? = nil

    // Visual conventions extracted from the AppKit prefs panes (Settings / Snap
    // Areas scenes in Main.storyboard): a single fixed-width content column,
    // centered, with standard outer margins, rows spaced 10pt apart within a
    // section, and sections separated by a horizontal rule (the SwiftUI analogue
    // of the storyboard's `boxType="separator"`) with even spacing above and
    // below. Kept in one place so every section reads at the same density as the
    // neighbouring tabs.
    private enum Metrics {
        /// Matches the 500pt content stack width of the AppKit panes.
        static let contentWidth: CGFloat = 500
        /// Standard outer margin around the content column.
        static let outerMargin: CGFloat = 20
        /// Vertical gap between rows inside a section (storyboard `spacing="10"`).
        static let rowSpacing: CGFloat = 10
        /// Gap above/below a section separator (storyboard separators reserve ~24pt).
        static let sectionSpacing: CGFloat = 12
        /// Fixed leading-label column width so trailing controls line up across rows.
        static let labelColumnWidth: CGFloat = 160
        /// Width of the trailing value readout column (e.g. "12 px").
        static let valueColumnWidth: CGFloat = 50
    }

    var body: some View {
        // No ScrollView here: the content lays out at its natural intrinsic height
        // so the hosting view reports a real fitting size and the toolbar window
        // GROWS to fit (the way each fixed-size IB tab sizes the window to itself
        // on selection), instead of clipping into a vertical scroll bar. The
        // height is driven by `LayoutsViewController`'s hosting-view intrinsic
        // content size; the width stays pinned at 850 there so the window never
        // jumps horizontally across tabs and this 500pt column stays centered.
        //
        // The hosting view is the document of a capped NSScrollView in
        // `LayoutsViewController`: while this content fits the active screen no
        // scroller shows and the window sizes to it exactly (the desired behavior);
        // only when the layouts list grows past the screen height does a scroller
        // appear there so the bottom Gaps control stays reachable. That cap lives
        // in the AppKit host (where the screen size is known) so this body stays
        // ScrollView-free and keeps reporting a real intrinsic height.
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            monitorPicker
            sectionSeparator
            layoutsSection
            sectionSeparator
            gridSettingsSection
        }
        .frame(width: Metrics.contentWidth, alignment: .leading)
        .padding(Metrics.outerMargin)
        // Center the fixed-width content column the way the AppKit panes
        // center their 500pt stack in the wider window.
        .frame(maxWidth: .infinity, alignment: .center)
        .sheet(item: $editingLayout) { layout in
            LayoutEditorView(
                displayUUID: model.selectedDisplayUUID ?? "",
                displayName: model.selectedDisplayName,
                layout: layout,
                onSaved: { model.reloadLayouts() },
                onClose: { editingLayout = nil }
            )
        }
    }

    // MARK: - Monitor picker

    private var monitorPicker: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            sectionHeader(NSLocalizedString("Monitor", tableName: "Main", value: "Monitor", comment: "Layouts pane: monitor picker header"))
            Picker(selection: Binding(
                get: { model.selectedDisplayUUID ?? "" },
                set: { model.selectedDisplayUUID = $0.isEmpty ? nil : $0 }
            ), label: EmptyView()) {
                ForEach(model.displays, id: \.uuid) { choice in
                    Text(model.displayLabel(choice)).tag(choice.uuid)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360, alignment: .leading)
            if model.displays.isEmpty {
                secondaryText(NSLocalizedString("No displays known yet.", tableName: "Main", value: "No displays known yet.", comment: "Empty monitor list"))
            }
        }
    }

    // MARK: - Layouts list

    private var layoutsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack {
                sectionHeader(NSLocalizedString("Layouts", tableName: "Main", value: "Layouts", comment: "Layouts pane: layouts list header"))
                Spacer()
                addButton
            }
            if model.selectedDisplayUUID == nil {
                secondaryText(NSLocalizedString("Select a monitor to configure its layouts.", tableName: "Main", value: "Select a monitor to configure its layouts.", comment: "No monitor selected"))
            } else if model.layouts.isEmpty {
                secondaryText(NSLocalizedString("No layouts yet. Use Add to create one.", tableName: "Main", value: "No layouts yet. Use Add to create one.", comment: "No layouts for display"))
            } else {
                VStack(spacing: Metrics.rowSpacing) {
                    ForEach(model.layouts, id: \.id) { layout in
                        layoutRow(layout)
                    }
                }
            }
        }
        .alert(
            NSLocalizedString("Remove layout?", tableName: "Main", value: "Remove layout?", comment: "Remove layout confirmation title"),
            isPresented: Binding(get: { layoutPendingRemoval != nil },
                                 set: { if !$0 { layoutPendingRemoval = nil } }),
            presenting: layoutPendingRemoval
        ) { layout in
            Button(NSLocalizedString("Remove", tableName: "Main", value: "Remove", comment: ""), role: .destructive) {
                model.removeLayout(id: layout.id)
                layoutPendingRemoval = nil
            }
            Button(NSLocalizedString("Cancel", tableName: "Main", value: "Cancel", comment: ""), role: .cancel) {
                layoutPendingRemoval = nil
            }
        } message: { layout in
            Text(String(format: NSLocalizedString("“%@” will be removed from this monitor. This can’t be undone.", tableName: "Main", value: "“%@” will be removed from this monitor. This can’t be undone.", comment: "Remove layout confirmation message"), layout.name))
        }
    }

    /// The "Add…" button. Tapping it opens a `.popover` with a hover-to-pick grid
    /// (insert-table style): the user hovers to choose an N × M size and clicks to
    /// create a uniform layout of that size. Disabled until a monitor is selected.
    private var addButton: some View {
        Button(NSLocalizedString("Add…", tableName: "Main", value: "Add…", comment: "Add layout button")) {
            addPopoverShown = true
        }
        .disabled(model.selectedDisplayUUID == nil)
        .popover(isPresented: $addPopoverShown, arrowEdge: .bottom) {
            AddGridPicker { cols, rows in
                model.addUniformLayout(cols: cols, rows: rows)
                addPopoverShown = false
            }
        }
    }

    private func layoutRow(_ layout: ZoneLayout) -> some View {
        let isActive = layout.id == model.activeLayoutId
        return HStack(spacing: 8) {
            // Active marker (a filled accent circle when active, hollow otherwise).
            Circle()
                .strokeBorder(isActive ? Color.accentColor : Color.secondary, lineWidth: 1.5)
                .background(Circle().fill(isActive ? Color.accentColor : Color.clear))
                .frame(width: 12, height: 12)
                .onTapGesture { model.makeActive(id: layout.id) }

            // Editable name. Edits live in the row's own local state and only
            // commit (through the model) on return / focus loss, so typing never
            // re-serializes Defaults per keystroke or replaces the array the
            // enclosing ForEach is iterating mid-edit.
            LayoutNameField(
                name: layout.name,
                onCommit: { model.renameLayout(id: layout.id, to: $0) }
            )
            .frame(maxWidth: 200)

            Text("\(layout.cols)×\(layout.rows)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()

            Button(NSLocalizedString("Make Active", tableName: "Main", value: "Make Active", comment: "")) {
                model.makeActive(id: layout.id)
            }
            .disabled(isActive)

            // M15 FancyZones canvas editor — opens the sheet on the working copy.
            Button(NSLocalizedString("Edit…", tableName: "Main", value: "Edit…", comment: "")) {
                editingLayout = layout
            }

            Button(NSLocalizedString("Remove", tableName: "Main", value: "Remove", comment: "")) {
                layoutPendingRemoval = layout
            }
        }
    }

    // MARK: - Grid settings

    private var gridSettingsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            sectionHeader(NSLocalizedString("Grid Behavior", tableName: "Main", value: "Grid Behavior", comment: "Grid settings header"))

            settingRow(NSLocalizedString("Activation modifier", tableName: "Main", value: "Activation modifier", comment: "")) {
                modifierPicker(get: { model.activationModifierRaw }, set: { model.activationModifierRaw = $0 })
            }
            settingRow(NSLocalizedString("Span modifier", tableName: "Main", value: "Span modifier", comment: "")) {
                modifierPicker(get: { model.spanModifierRaw }, set: { model.spanModifierRaw = $0 })
            }

            sectionSubheader(NSLocalizedString("Proximity span", tableName: "Main", value: "Proximity span", comment: ""))
            Toggle(NSLocalizedString("Span by proximity (no modifier)", tableName: "Main", value: "Span by proximity (no modifier)", comment: "Proximity span toggle"), isOn: $model.proximitySpanEnabled)
            sliderRow(
                NSLocalizedString("Radius", tableName: "Main", value: "Radius", comment: "Proximity span radius"),
                value: $model.proximitySpanRadius, in: 10...120
            )
            .disabled(!model.proximitySpanEnabled)

            settingRow(NSLocalizedString("Shortcut targets", tableName: "Main", value: "Shortcut targets", comment: "")) {
                Picker("", selection: $model.shortcutTargetMode) {
                    ForEach(ShortcutTargetMode.allCasesOrdered, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }.labelsHidden().frame(width: 220)
            }

            sectionSubheader(NSLocalizedString("Wall actions (hit the edge again)", tableName: "Main", value: "Wall actions (hit the edge again)", comment: ""))
            settingRow(NSLocalizedString("Up", tableName: "Main", value: "Up", comment: "")) { edgeActionPicker($model.wallActionUp) }
            settingRow(NSLocalizedString("Down", tableName: "Main", value: "Down", comment: "")) { edgeActionPicker($model.wallActionDown) }
            settingRow(NSLocalizedString("Left", tableName: "Main", value: "Left", comment: "")) { edgeActionPicker($model.wallActionLeft) }
            settingRow(NSLocalizedString("Right", tableName: "Main", value: "Right", comment: "")) { edgeActionPicker($model.wallActionRight) }

            sectionSubheader(NSLocalizedString("Overlay colors", tableName: "Main", value: "Overlay colors", comment: ""))
            colorControls

            sectionSubheader(NSLocalizedString("Gaps", tableName: "Main", value: "Gaps", comment: ""))
            sliderRow(
                NSLocalizedString("Gap size", tableName: "Main", value: "Gap size", comment: ""),
                value: $model.gapSize, in: 0...50
            )
        }
    }

    @ViewBuilder
    private var colorControls: some View {
        if #available(macOS 11.0, *) {
            Toggle(NSLocalizedString("Use accent color for selected zone", tableName: "Main", value: "Use accent color for selected zone", comment: ""), isOn: $model.useAccentForSelected)
            settingRow(NSLocalizedString("Selected zone", tableName: "Main", value: "Selected zone", comment: "")) {
                ColorPicker("", selection: Binding(
                    get: { Color(model.selectedZoneColor) },
                    set: { model.selectedZoneColor = NSColor($0) }
                )).labelsHidden()
                .disabled(model.useAccentForSelected)
            }
            settingRow(NSLocalizedString("Unselected zone", tableName: "Main", value: "Unselected zone", comment: "")) {
                ColorPicker("", selection: Binding(
                    get: { Color(model.unselectedZoneColor) },
                    set: { model.unselectedZoneColor = NSColor($0) }
                )).labelsHidden()
            }
        } else {
            secondaryText(NSLocalizedString("Zone colors require macOS 11 or later.", tableName: "Main", value: "Zone colors require macOS 11 or later.", comment: ""))
        }
    }

    // MARK: - Reusable pieces

    private func modifierPicker(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> some View {
        Picker("", selection: Binding(
            get: { GridModifierChoice.from(rawValue: get()) },
            set: { set($0.modifierRawValue) }
        )) {
            ForEach(GridModifierChoice.allCases) { choice in
                Text(choice.label).tag(choice)
            }
        }.labelsHidden().frame(width: 160)
    }

    private func edgeActionPicker(_ binding: Binding<EdgeAction>) -> some View {
        Picker("", selection: binding) {
            ForEach(EdgeAction.allCasesOrdered, id: \.self) { action in
                Text(action.label).tag(action)
            }
        }.labelsHidden().frame(width: 160)
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Metrics.rowSpacing) {
            Text(title).frame(width: Metrics.labelColumnWidth, alignment: .leading)
            content()
            Spacer()
        }
    }

    /// A label + slider + stepper + value-readout row, with the same fixed label
    /// and value columns as `settingRow` so the slider rows line up with the
    /// picker rows above them.
    private func sliderRow(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>) -> some View {
        HStack(spacing: Metrics.rowSpacing) {
            Text(title).frame(width: Metrics.labelColumnWidth, alignment: .leading)
            Slider(value: value, in: range)
                .frame(width: 200)
            Stepper("", value: value, in: range, step: 1).labelsHidden()
            Text("\(Int(value.wrappedValue)) px").frame(width: Metrics.valueColumnWidth, alignment: .leading)
            Spacer()
        }
    }

    /// A horizontal rule between sections — the SwiftUI equivalent of the AppKit
    /// panes' `boxType="separator"`. Constrained to the content column width so it
    /// doesn't run edge-to-edge.
    private var sectionSeparator: some View {
        Divider().frame(width: Metrics.contentWidth)
    }

    /// Section header: bold, regular system size, matching the AppKit panes'
    /// `NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)` group headers.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: NSFont.systemFontSize, weight: .bold))
    }

    /// Sub-section header within a section: same bold weight as the section
    /// header but in the secondary color, to read as a quieter grouping label.
    private func sectionSubheader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: NSFont.systemFontSize, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.top, 2)
    }

    /// Secondary / explanatory text, matching the AppKit panes' 11pt
    /// `secondaryLabelColor` message font.
    private func secondaryText(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
    }
}

// MARK: - Editable layout name field

/// A single-row name editor that keeps the in-progress text in its OWN local
/// `@State` and only reports a final value through `onCommit` (return / focus
/// loss). This deliberately avoids writing through the model on every keystroke,
/// which would re-serialize Defaults per character and reassign the `@Published`
/// `layouts` array the parent `ForEach` is iterating — the documented cause of
/// cursor jumps and dropped characters.
///
/// The caller passes the committed `name`; the field re-seeds its local state
/// from it (via `.id(name)`) whenever the model's value changes — e.g. when a
/// blank commit is rejected and snaps back to the previous name, or the list is
/// reordered after add / remove. `TextField(_:text:onCommit:)` and its
/// `onCommit` closure are available on macOS 10.15.
private struct LayoutNameField: View {
    let name: String
    let onCommit: (String) -> Void

    @State private var text: String

    init(name: String, onCommit: @escaping (String) -> Void) {
        self.name = name
        self.onCommit = onCommit
        _text = State(initialValue: name)
    }

    var body: some View {
        TextField("", text: $text, onCommit: { onCommit(text) })
            .textFieldStyle(RoundedBorderTextFieldStyle())
            // Re-create (and thus re-seed `text`) when the committed name changes
            // externally, including a rejected blank rename snapping back.
            .id(name)
    }
}

// MARK: - Hover-to-pick Add grid

/// A small "insert table" style grid of square cells (up to `maxCols` × `maxRows`).
/// Moving the pointer over the grid highlights the rectangle from the TOP-LEFT
/// cell to the cell under the pointer and updates the "cols × rows" caption;
/// clicking that cell calls `onPick(cols, rows)` to create a uniform layout of
/// that size.
///
/// Hover tracking uses a SINGLE, STABLE, location-based tracker (`HoverTracker`)
/// overlaid on the cell-grid VStack — NOT per-cell `onHover`. Per-cell tracking
/// areas are torn down and rebuilt every time the grid grows a track, so the cell
/// newly under the pointer often failed to re-fire `onHover` (growth stalled
/// until the pointer left and re-entered) and the leave handler could collapse
/// the grid back to base size (flicker). The single tracking area is installed
/// once and survives relayout, so growth stays smooth at the edge. The reported
/// pointer location is converted to a 1-based (col, row) in SwiftUI; the
/// highlighted extent is every cell at or before it on BOTH axes.
private struct AddGridPicker: View {
    /// Called with the chosen (cols, rows) when a cell is clicked.
    let onPick: (Int, Int) -> Void

    /// Hard cap on how large the picker can grow.
    private let maxCols = 12
    private let maxRows = 12

    /// The picker starts at this size and grows a track whenever the pointer
    /// reaches the current edge ("insert table" style dynamic growth).
    private let baseCols = 3
    private let baseRows = 3

    /// Visual sizing of each square cell + the spacing between cells.
    private let cellSize: CGFloat = 18
    private let cellSpacing: CGFloat = 3

    /// The 1-based (col, row) currently under the pointer, or `nil` when the
    /// pointer is outside the grid. Drives the highlight, the caption, and the
    /// live size.
    @State private var hovered: (col: Int, row: Int)? = nil

    /// The grid currently shown: one track BEYOND the hovered cell (a buffer to
    /// grow into), clamped to [base, max]; back to the base size when idle. So
    /// reaching the right/bottom edge reveals another column/row and the popover
    /// grows with it.
    private var displayedCols: Int {
        guard let h = hovered else { return baseCols }
        return min(maxCols, max(baseCols, h.col + 1))
    }
    private var displayedRows: Int {
        guard let h = hovered else { return baseRows }
        return min(maxRows, max(baseRows, h.row + 1))
    }

    /// Center-to-center distance between adjacent cells, used to map a pointer
    /// location back to a 1-based (col, row).
    private var pitch: CGFloat { cellSize + cellSpacing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Caption: the size that a click would create, or a prompt when idle.
            Text(captionText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)

            // Grows toward the bottom-right as the pointer reaches an edge.
            VStack(alignment: .leading, spacing: cellSpacing) {
                ForEach(1...displayedRows, id: \.self) { row in
                    HStack(spacing: cellSpacing) {
                        ForEach(1...displayedCols, id: \.self) { col in
                            cell(col: col, row: row)
                        }
                    }
                }
            }
            // ONE stable location tracker over EXACTLY the cell-grid bounds (its
            // origin is cell (1,1)'s top-left, not the caption or outer padding),
            // so the math below lines up with the cells. The tracker reports a
            // TOP-LEFT-origin location (its NSView is `isFlipped`), so larger y is
            // lower on screen is a higher row number — row 1 stays the TOP row.
            .overlay(
                HoverTracker(
                    onMove: { point in updateHover(at: point) },
                    onExit: { hovered = nil }
                )
            )
            // Map a click over the grid to the same cell the tracker is reporting.
            .onTapGesture {
                if let h = hovered { onPick(h.col, h.row) }
            }
        }
        .padding(12)
    }

    /// Convert a TOP-LEFT-origin pointer location within the cell grid to a
    /// 1-based (col, row) and store it. `nil` location (pointer outside) clears.
    private func updateHover(at point: CGPoint?) {
        guard let point = point else { hovered = nil; return }
        // x grows rightward → column; y grows downward (flipped view) → row, so
        // row 1 is the TOP row. `+ 1` makes the index 1-based; clamp to [1, max].
        let col = min(maxCols, max(1, Int(point.x / pitch) + 1))
        let row = min(maxRows, max(1, Int(point.y / pitch) + 1))
        hovered = (col, row)
    }

    private var captionText: String {
        if let h = hovered {
            return "\(h.col) × \(h.row)"
        }
        return NSLocalizedString("Pick a size", tableName: "Main", value: "Pick a size", comment: "Add grid picker idle caption")
    }

    private func cell(col: Int, row: Int) -> some View {
        let filled = isFilled(col: col, row: row)
        return RoundedRectangle(cornerRadius: 2)
            .fill(filled
                  ? Color.accentColor.opacity(0.85)
                  : Color(NSColor.unemphasizedSelectedContentBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .frame(width: cellSize, height: cellSize)
    }

    /// A cell is filled iff it is at or before the hovered cell on BOTH axes
    /// (the top-left rectangle up to the pointer).
    private func isFilled(col: Int, row: Int) -> Bool {
        guard let h = hovered else { return false }
        return col <= h.col && row <= h.row
    }
}

// MARK: - Stable location-based hover tracker

/// A thin transparent overlay that installs ONE `NSTrackingArea` and reports the
/// pointer location (or `nil` on exit) back to SwiftUI. Used by `AddGridPicker`
/// instead of per-cell `onHover` so that the grid growing a track does NOT tear
/// down and rebuild the tracking — the single area is reinstalled in place on
/// resize and keeps reporting continuously, so edge growth stays smooth and never
/// flickers back to base size.
///
/// COORDINATE CONVENTION: the backing `NSView` overrides `isFlipped` to return
/// `true`, giving it a TOP-LEFT origin where y increases DOWNWARD. That matches
/// `AddGridPicker`'s top-to-bottom row order, so a larger reported y maps to a
/// higher (lower-on-screen) row number and ROW 1 IS THE TOP ROW. Without the
/// flip, AppKit's default bottom-left origin would mirror the rows vertically
/// (hovering the top row would highlight the bottom).
private struct HoverTracker: NSViewRepresentable {
    /// Reports the pointer location in the view's flipped (top-left origin)
    /// coordinate space on enter/move.
    let onMove: (CGPoint) -> Void
    /// Reports that the pointer left the view.
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let v = TrackingNSView()
        v.onMove = onMove
        v.onExit = onExit
        return v
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        // Keep the closures fresh (they capture the current SwiftUI state setters).
        nsView.onMove = onMove
        nsView.onExit = onExit
    }

    /// The single-tracking-area NSView. Flipped so y increases downward (row 1 =
    /// top). One `NSTrackingArea` with `.inVisibleRect` is reinstalled whenever the
    /// view resizes (grid growth), but it always covers the whole bounds and keeps
    /// reporting `.mouseMoved`, so tracking never lapses mid-growth.
    final class TrackingNSView: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?

        /// TOP-LEFT origin: y increases DOWNWARD to match the grid's row order, so
        /// row 1 is the TOP row. This is the load-bearing line for vertical
        /// orientation — do not remove.
        override var isFlipped: Bool { true }

        /// Stay transparent to mouse-DOWN/clicks so SwiftUI's `.onTapGesture` on
        /// the underlying grid still fires (this view only tracks movement). The
        /// tracking area continues to deliver enter/move/exit regardless.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            // `.inVisibleRect` makes the area auto-track the current bounds, so it
            // stays correct as the grid grows; `.activeInKeyWindow` keeps it live
            // while the popover is up; mouse moved/entered/exited drive the report.
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        private func report(_ event: NSEvent) {
            // Flipped view → this point already has a top-left origin.
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onExit?() }
    }
}
