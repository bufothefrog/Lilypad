//
//  GridSettingsModel.swift
//  Rectangle / Lilypad
//
//  M14 (Stage 9a). The `ObservableObject` backing `LayoutsRootView`. It is the
//  single bridge between the SwiftUI Layouts pane and the runtime:
//
//  - LAYOUT DATA round-trips purely through `GridModel` (which persists
//    `Defaults.gridLayoutsByDisplay`), so the pane stays consistent with the
//    drag / chord / keyboard runtime — the UI never writes the layout default
//    directly.
//  - GRID SETTINGS read/write the individual grid `Defaults` with the correct
//    accessor per type (`BoolDefault.enabled`, `IntDefault.value`,
//    `IntEnumDefault.value`, `FloatDefault.value`, `JSONDefault.typedValue`).
//    Mutations that the running managers must pick up live
//    (`gridModeEnabled` toggles the drag path; the modifiers / wall actions /
//    colors are read live by the snapping + grid managers) post
//    `Notification.Name.changeDefaults`, mirroring the existing panes.
//
//  The model refreshes its display list on `didChangeScreenParametersNotification`
//  and `configImported` so a docking change or an imported config is reflected
//  without reopening the pane.
//

import AppKit
import Combine

class GridSettingsModel: ObservableObject {

    // MARK: - Displays

    /// The displays offered in the monitor picker (connected first, then
    /// previously-seen disconnected ones), refreshed on screen / config changes.
    @Published var displays: [DisplayChoice] = []

    /// The UUID of the display whose layouts the pane is editing.
    @Published var selectedDisplayUUID: String? {
        didSet { reloadLayouts() }
    }

    /// The layouts for `selectedDisplayUUID`, mirrored from `GridModel` so SwiftUI
    /// rows can observe them. Always written back through `GridModel`.
    @Published var layouts: [ZoneLayout] = []

    /// The active layout id for the selected display (drives the "Active" marker).
    @Published var activeLayoutId: String?

    // MARK: - Grid settings (read current Default, write back on change)

    @Published var gridModeEnabled: Bool {
        didSet {
            Defaults.gridModeEnabled.enabled = gridModeEnabled
            Notification.Name.changeDefaults.post()
        }
    }

    /// Activation / span modifiers stored as `NSEvent.ModifierFlags` raw values
    /// (the same Ints the drag path reads). 0 == None.
    @Published var activationModifierRaw: Int {
        didSet {
            Defaults.gridActivationModifier.value = activationModifierRaw
            Notification.Name.changeDefaults.post()
        }
    }
    @Published var spanModifierRaw: Int {
        didSet {
            Defaults.gridSpanModifier.value = spanModifierRaw
            Notification.Name.changeDefaults.post()
        }
    }

    @Published var shortcutTargetMode: ShortcutTargetMode {
        didSet {
            Defaults.shortcutTargetMode.value = shortcutTargetMode
            Notification.Name.changeDefaults.post()
        }
    }

    @Published var wallActionUp: EdgeAction {
        didSet {
            Defaults.gridWallActionUp.value = wallActionUp
            Notification.Name.changeDefaults.post()
        }
    }
    @Published var wallActionDown: EdgeAction {
        didSet {
            Defaults.gridWallActionDown.value = wallActionDown
            Notification.Name.changeDefaults.post()
        }
    }
    @Published var wallActionLeft: EdgeAction {
        didSet {
            Defaults.gridWallActionLeft.value = wallActionLeft
            Notification.Name.changeDefaults.post()
        }
    }
    @Published var wallActionRight: EdgeAction {
        didSet {
            Defaults.gridWallActionRight.value = wallActionRight
            Notification.Name.changeDefaults.post()
        }
    }

    /// Selected zone color. nil in Defaults means "use the in-code default"; the
    /// model surfaces a concrete `NSColor` so the picker always has a value, and
    /// writes the chosen color back as a `CodableColor`.
    @Published var selectedZoneColor: NSColor {
        didSet {
            Defaults.gridSelectedZoneColor.typedValue = CodableColor(nsColor: selectedZoneColor)
            Notification.Name.changeDefaults.post()
        }
    }
    @Published var unselectedZoneColor: NSColor {
        didSet {
            Defaults.gridUnselectedZoneColor.typedValue = CodableColor(nsColor: unselectedZoneColor)
            Notification.Name.changeDefaults.post()
        }
    }
    @Published var useAccentForSelected: Bool {
        didSet {
            Defaults.gridUseAccentForSelected.enabled = useAccentForSelected
            Notification.Name.changeDefaults.post()
        }
    }

    @Published var gapSize: Float {
        didSet {
            Defaults.gapSize.value = gapSize
            Notification.Name.changeDefaults.post()
        }
    }

    /// Set while loading from Defaults so the `didSet` observers don't write the
    /// value straight back (and re-post) during initialization / refresh.
    private var loadingFromDefaults = false

    /// In-code fallbacks for the zone colors when the Default has no stored value
    /// yet, matching the GridOverlayView defaults (selected = footprint dark grey,
    /// unselected = lighter grey).
    private static let defaultSelectedColor = NSColor(white: 0.3, alpha: 1.0)
    private static let defaultUnselectedColor = NSColor(white: 0.7, alpha: 1.0)

    private var observers: [NSObjectProtocol] = []

    init() {
        // Seed every published settings property from its Default before wiring
        // observers. `loadingFromDefaults` is irrelevant here (the initializers
        // run before `self` is fully formed), but the values must be read with
        // the correct accessor per Default type.
        gridModeEnabled = Defaults.gridModeEnabled.enabled
        activationModifierRaw = Defaults.gridActivationModifier.value
        spanModifierRaw = Defaults.gridSpanModifier.value
        shortcutTargetMode = Defaults.shortcutTargetMode.value
        wallActionUp = Defaults.gridWallActionUp.value
        wallActionDown = Defaults.gridWallActionDown.value
        wallActionLeft = Defaults.gridWallActionLeft.value
        wallActionRight = Defaults.gridWallActionRight.value
        selectedZoneColor = Defaults.gridSelectedZoneColor.typedValue?.nsColor ?? GridSettingsModel.defaultSelectedColor
        unselectedZoneColor = Defaults.gridUnselectedZoneColor.typedValue?.nsColor ?? GridSettingsModel.defaultUnselectedColor
        useAccentForSelected = Defaults.gridUseAccentForSelected.userEnabled
        gapSize = Defaults.gapSize.value

        refreshDisplays()
        // Default to the first connected display (falling back to the first
        // known display, or none).
        selectedDisplayUUID = displays.first(where: { $0.isConnected })?.uuid ?? displays.first?.uuid
        reloadLayouts()

        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshDisplays() }
        let configObserver = Notification.Name.configImported.onPost { [weak self] _ in
            self?.reloadFromDefaults()
        }
        observers = [screenObserver, configObserver]
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Display list

    /// Rebuild the display list from `DisplayRegistry`. Keeps the current
    /// selection if it still exists; otherwise falls back to the first connected
    /// (then first known) display.
    func refreshDisplays() {
        displays = DisplayRegistry.instance.allKnownDisplays()
        if let uuid = selectedDisplayUUID, displays.contains(where: { $0.uuid == uuid }) {
            // selection still valid — keep it, but refresh its layouts in case the
            // display reconnected.
            reloadLayouts()
        } else {
            selectedDisplayUUID = displays.first(where: { $0.isConnected })?.uuid ?? displays.first?.uuid
        }
    }

    /// The display name for the picker, marking disconnected displays.
    func displayLabel(_ choice: DisplayChoice) -> String {
        choice.isConnected
            ? choice.name
            : "\(choice.name) \(NSLocalizedString("(disconnected)", tableName: "Main", value: "(disconnected)", comment: "Disconnected display marker"))"
    }

    // MARK: - Layout list (round-trips through GridModel)

    /// Pull the selected display's layouts from `GridModel` into the published
    /// mirror.
    func reloadLayouts() {
        guard let uuid = selectedDisplayUUID else {
            layouts = []
            activeLayoutId = nil
            return
        }
        let perDisplay = GridModel.instance.layouts(forDisplay: uuid)
        layouts = perDisplay.layouts
        // Resolve the *effective* active id (falls back to the first layout when
        // none is explicitly set) so the marker matches runtime behavior.
        activeLayoutId = perDisplay.activeLayout?.id
    }

    /// Add a quick-starter layout (a fresh UUID id each time) for the selected
    /// display, then make it active and refresh.
    func addLayout(_ starter: QuickStarter) {
        guard let uuid = selectedDisplayUUID else { return }
        let layout = starter.makeLayout()
        GridModel.instance.addLayout(layout, forDisplay: uuid)
        reloadLayouts()
    }

    func renameLayout(id: String, to newName: String) {
        guard let uuid = selectedDisplayUUID else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        GridModel.instance.renameLayout(id: id, to: trimmed, forDisplay: uuid)
        reloadLayouts()
    }

    func removeLayout(id: String) {
        guard let uuid = selectedDisplayUUID else { return }
        GridModel.instance.removeLayout(id: id, forDisplay: uuid)
        reloadLayouts()
    }

    func makeActive(id: String) {
        guard let uuid = selectedDisplayUUID else { return }
        GridModel.instance.setActiveLayout(id: id, forDisplay: uuid)
        reloadLayouts()
    }

    // MARK: - Reload settings after a config import

    /// Re-read every settings property from Defaults (used after a config import).
    /// `loadingFromDefaults` suppresses the `didSet` write-back / notification so a
    /// reload doesn't re-persist or re-post.
    func reloadFromDefaults() {
        loadingFromDefaults = true
        defer { loadingFromDefaults = false }
        gridModeEnabled = Defaults.gridModeEnabled.enabled
        activationModifierRaw = Defaults.gridActivationModifier.value
        spanModifierRaw = Defaults.gridSpanModifier.value
        shortcutTargetMode = Defaults.shortcutTargetMode.value
        wallActionUp = Defaults.gridWallActionUp.value
        wallActionDown = Defaults.gridWallActionDown.value
        wallActionLeft = Defaults.gridWallActionLeft.value
        wallActionRight = Defaults.gridWallActionRight.value
        selectedZoneColor = Defaults.gridSelectedZoneColor.typedValue?.nsColor ?? GridSettingsModel.defaultSelectedColor
        unselectedZoneColor = Defaults.gridUnselectedZoneColor.typedValue?.nsColor ?? GridSettingsModel.defaultUnselectedColor
        useAccentForSelected = Defaults.gridUseAccentForSelected.userEnabled
        gapSize = Defaults.gapSize.value
        refreshDisplays()
    }
}

// MARK: - Quick-starters

/// The quick-starter layouts the Add control offers. Each builds a fresh
/// `ZoneLayout` with a UUID id via the M2 `ZoneLayout` generators.
enum QuickStarter: String, CaseIterable, Identifiable {
    case grid2x2
    case grid3x2
    case grid4x2
    case halves
    case thirds

    var id: String { rawValue }

    /// The menu label for this starter.
    var label: String {
        switch self {
        case .grid2x2: return "2 × 2"
        case .grid3x2: return "3 × 2"
        case .grid4x2: return "4 × 2"
        case .halves:  return NSLocalizedString("Halves", tableName: "Main", value: "Halves", comment: "Quick-starter layout name")
        case .thirds:  return NSLocalizedString("Thirds", tableName: "Main", value: "Thirds", comment: "Quick-starter layout name")
        }
    }

    /// Build the `ZoneLayout` with a fresh UUID id (the human label lives in
    /// `name`), so ids never collide with existing layouts.
    func makeLayout() -> ZoneLayout {
        let id = UUID().uuidString
        switch self {
        case .grid2x2: return ZoneLayout.grid2x2(id: id, name: label)
        case .grid3x2: return ZoneLayout.grid3x2(id: id, name: label)
        case .grid4x2: return ZoneLayout.grid4x2(id: id, name: label)
        case .halves:  return ZoneLayout.halves(id: id, name: label)
        case .thirds:  return ZoneLayout.thirds(id: id, name: label)
        }
    }
}

/// A choosable modifier for the activation / span pickers, mapping a label to the
/// `NSEvent.ModifierFlags` raw value the drag path stores. `none` is raw 0.
enum GridModifierChoice: Int, CaseIterable, Identifiable {
    case none = 0
    case shift
    case control
    case option
    case command

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none:    return NSLocalizedString("None", tableName: "Main", value: "None", comment: "No modifier")
        case .shift:   return "⇧ Shift"
        case .control: return "⌃ Control"
        case .option:  return "⌥ Option"
        case .command: return "⌘ Command"
        }
    }

    /// The `NSEvent.ModifierFlags` raw value this choice persists.
    var modifierRawValue: Int {
        switch self {
        case .none:    return 0
        case .shift:   return Int(NSEvent.ModifierFlags.shift.rawValue)
        case .control: return Int(NSEvent.ModifierFlags.control.rawValue)
        case .option:  return Int(NSEvent.ModifierFlags.option.rawValue)
        case .command: return Int(NSEvent.ModifierFlags.command.rawValue)
        }
    }

    /// Resolve a stored modifier raw value to a choice (falls back to `.none` for
    /// any value that isn't one of the offered single modifiers).
    static func from(rawValue raw: Int) -> GridModifierChoice {
        allCases.first(where: { $0.modifierRawValue == raw }) ?? .none
    }
}

extension EdgeAction {
    /// The picker label for a wall action.
    var label: String {
        switch self {
        case .none:        return NSLocalizedString("Beep (none)", tableName: "Main", value: "Beep (none)", comment: "Edge action: do nothing")
        case .maximize:    return NSLocalizedString("Maximize", tableName: "Main", value: "Maximize", comment: "Edge action: maximize")
        case .minimize:    return NSLocalizedString("Minimize", tableName: "Main", value: "Minimize", comment: "Edge action: minimize")
        case .half:        return NSLocalizedString("Half", tableName: "Main", value: "Half", comment: "Edge action: snap to half")
        case .nextDisplay: return NSLocalizedString("Next display", tableName: "Main", value: "Next display", comment: "Edge action: move to next display")
        }
    }

    static let allCasesOrdered: [EdgeAction] = [.none, .maximize, .minimize, .half, .nextDisplay]
}

extension ShortcutTargetMode {
    var label: String {
        switch self {
        case .frontWindow: return NSLocalizedString("Front window's display", tableName: "Main", value: "Front window's display", comment: "Shortcut target: front window")
        case .cursor:      return NSLocalizedString("Display under cursor", tableName: "Main", value: "Display under cursor", comment: "Shortcut target: cursor")
        }
    }

    static let allCasesOrdered: [ShortcutTargetMode] = [.frontWindow, .cursor]
}
