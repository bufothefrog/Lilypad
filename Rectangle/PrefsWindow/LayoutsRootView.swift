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
//  11+). The Add control is a self-resetting `Picker` (which renders as a popup on
//  macOS); the active marker is a drawn `Circle`. The only 11+ API used is
//  `ColorPicker`, gated with `#available` and degraded to a label on 10.15.
//

import SwiftUI

struct LayoutsRootView: View {
    // Owned by the view (the pane is created once). `@ObservedObject` is available
    // at 10.15, unlike `@StateObject` (11+). The hosting controller keeps this view
    // — and thus the model — alive for the pane's lifetime.
    @ObservedObject private var model = GridSettingsModel()

    // Transient selection backing the self-resetting "Add" popup. `nil` is the
    // visible placeholder; choosing a starter fires the add and resets to `nil`.
    @State private var pendingStarter: QuickStarter? = nil

    // The layout currently open in the FancyZones editor sheet (M15). `nil` =
    // no sheet. Identifiable so `.sheet(item:)` (10.15) drives presentation.
    @State private var editingLayout: ZoneLayout? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                monitorPicker
                Divider()
                layoutsSection
                Divider()
                gridSettingsSection
            }
            .padding(20)
        }
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
        VStack(alignment: .leading, spacing: 6) {
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
                Text(NSLocalizedString("No displays known yet.", tableName: "Main", value: "No displays known yet.", comment: "Empty monitor list"))
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: - Layouts list

    private var layoutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader(NSLocalizedString("Layouts", tableName: "Main", value: "Layouts", comment: "Layouts pane: layouts list header"))
                Spacer()
                addPicker
            }
            if model.selectedDisplayUUID == nil {
                Text(NSLocalizedString("Select a monitor to configure its layouts.", tableName: "Main", value: "Select a monitor to configure its layouts.", comment: "No monitor selected"))
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else if model.layouts.isEmpty {
                Text(NSLocalizedString("No layouts yet. Use Add to create one.", tableName: "Main", value: "No layouts yet. Use Add to create one.", comment: "No layouts for display"))
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.layouts, id: \.id) { layout in
                        layoutRow(layout)
                    }
                }
            }
        }
    }

    /// Self-resetting popup that acts as an "Add" menu. Choosing a starter adds it
    /// and resets the selection to the `nil` placeholder.
    private var addPicker: some View {
        Picker(selection: Binding(
            get: { pendingStarter },
            set: { newValue in
                if let starter = newValue {
                    model.addLayout(starter)
                }
                pendingStarter = nil
            }
        ), label: EmptyView()) {
            Text(NSLocalizedString("Add…", tableName: "Main", value: "Add…", comment: "Add layout placeholder"))
                .tag(QuickStarter?.none)
            ForEach(QuickStarter.allCases) { starter in
                Text(starter.label).tag(QuickStarter?.some(starter))
            }
        }
        .labelsHidden()
        .frame(width: 120)
        .disabled(model.selectedDisplayUUID == nil)
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
                .font(.caption)
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
                model.removeLayout(id: layout.id)
            }
        }
    }

    // MARK: - Grid settings

    private var gridSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(NSLocalizedString("Grid Behavior", tableName: "Main", value: "Grid Behavior", comment: "Grid settings header"))

            Toggle(NSLocalizedString("Enable grid mode", tableName: "Main", value: "Enable grid mode", comment: ""), isOn: $model.gridModeEnabled)

            settingRow(NSLocalizedString("Activation modifier", tableName: "Main", value: "Activation modifier", comment: "")) {
                modifierPicker(get: { model.activationModifierRaw }, set: { model.activationModifierRaw = $0 })
            }
            settingRow(NSLocalizedString("Span modifier", tableName: "Main", value: "Span modifier", comment: "")) {
                modifierPicker(get: { model.spanModifierRaw }, set: { model.spanModifierRaw = $0 })
            }

            sectionSubheader(NSLocalizedString("Proximity span", tableName: "Main", value: "Proximity span", comment: ""))
            Toggle(NSLocalizedString("Span by proximity (no modifier)", tableName: "Main", value: "Span by proximity (no modifier)", comment: "Proximity span toggle"), isOn: $model.proximitySpanEnabled)
            HStack {
                Text(NSLocalizedString("Radius", tableName: "Main", value: "Radius", comment: "Proximity span radius"))
                    .frame(width: 160, alignment: .leading)
                Slider(value: $model.proximitySpanRadius, in: 10...120)
                    .frame(width: 200)
                Stepper("", value: $model.proximitySpanRadius, in: 10...120, step: 1).labelsHidden()
                Text("\(Int(model.proximitySpanRadius)) px").frame(width: 50, alignment: .leading)
            }
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
            HStack {
                Text(NSLocalizedString("Gap size", tableName: "Main", value: "Gap size", comment: ""))
                    .frame(width: 160, alignment: .leading)
                Slider(value: $model.gapSize, in: 0...50)
                    .frame(width: 200)
                Stepper("", value: $model.gapSize, in: 0...50, step: 1).labelsHidden()
                Text("\(Int(model.gapSize)) px").frame(width: 50, alignment: .leading)
            }
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
            Text(NSLocalizedString("Zone colors require macOS 11 or later.", tableName: "Main", value: "Zone colors require macOS 11 or later.", comment: ""))
                .foregroundColor(.secondary)
                .font(.caption)
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
        HStack {
            Text(title).frame(width: 160, alignment: .leading)
            content()
            Spacer()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func sectionSubheader(_ title: String) -> some View {
        Text(title).font(.subheadline).bold().foregroundColor(.secondary)
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
