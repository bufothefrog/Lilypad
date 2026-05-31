//
//  SnapAreaViewController.swift
//  Rectangle
//
//  Created by Ryan Hanson on 8/13/22.
//  Copyright © 2022 Ryan Hanson. All rights reserved.
//

import Cocoa

class SnapAreaViewController: NSViewController {

    @IBOutlet weak var windowSnappingCheckbox: NSButton!
    @IBOutlet weak var unsnapRestoreButton: NSButton!
    @IBOutlet weak var animateFootprintCheckbox: NSButton!
    @IBOutlet weak var hapticFeedbackCheckbox: NSButton!
    @IBOutlet weak var missionControlDraggingCheckbox: NSButton!

    @IBOutlet weak var topLeftLandscapeSelect: NSPopUpButton!
    @IBOutlet weak var topLandscapeSelect: NSPopUpButton!
    @IBOutlet weak var topRightLandscapeSelect: NSPopUpButton!
    @IBOutlet weak var leftLandscapeSelect: NSPopUpButton!
    @IBOutlet weak var rightLandscapeSelect: NSPopUpButton!
    @IBOutlet weak var bottomLeftLandscapeSelect: NSPopUpButton!
    @IBOutlet weak var bottomLandscapeSelect: NSPopUpButton!
    @IBOutlet weak var bottomRightLandscapeSelect: NSPopUpButton!

    @IBOutlet weak var portraitStackView: NSStackView!

    @IBOutlet weak var topLeftPortraitSelect: NSPopUpButton!
    @IBOutlet weak var topPortraitSelect: NSPopUpButton!
    @IBOutlet weak var topRightPortraitSelect: NSPopUpButton!
    @IBOutlet weak var leftPortraitSelect: NSPopUpButton!
    @IBOutlet weak var rightPortraitSelect: NSPopUpButton!
    @IBOutlet weak var bottomLeftPortraitSelect: NSPopUpButton!
    @IBOutlet weak var bottomPortraitSelect: NSPopUpButton!
    @IBOutlet weak var bottomRightPortraitSelect: NSPopUpButton!

    /// Built programmatically in `viewDidLoad`; selects which monitor's snap-area
    /// config the popups below edit. nil tag (`representedObject`) means
    /// "Default (all displays)" — i.e. the existing global config.
    private var displaySelector: NSPopUpButton!
    private var resetDisplayButton: NSButton!
    private var forgetDisplayButton: NSButton!

    /// nil = editing the global landscape/portrait config (default).
    /// non-nil = editing the per-display override for that display UUID.
    private var selectedDisplayUUID: String?

    @IBAction func toggleWindowSnapping(_ sender: NSButton) {
        let newSetting: Bool = sender.state == .on
        Defaults.windowSnapping.enabled = newSetting
        Notification.Name.windowSnapping.post(object: newSetting)
        if newSetting {
            MacTilingDefaults.checkForBuiltInTiling(skipIfAlreadyNotified: false)
        }
    }

    @IBAction func toggleUnsnapRestore(_ sender: NSButton) {
        let newSetting: Bool = sender.state == .on
        Defaults.unsnapRestore.enabled = newSetting
    }

    @IBAction func toggleAnimateFootprint(_ sender: NSButton) {
        let newSetting: Float = sender.state == .on ? 0.75 : 0
        Defaults.footprintAnimationDurationMultiplier.value = newSetting
    }

    @IBAction func toggleHapticFeedback(_ sender: NSButton) {
        let newSetting: Bool = sender.state == .on
        Defaults.hapticFeedbackOnSnap.enabled = newSetting
    }

    @IBAction func toggleMissionControlDragging(_ sender: NSButton) {
        let newSetting: Bool = sender.state == .off
        Defaults.missionControlDragging.enabled = newSetting
        Notification.Name.missionControlDragging.post(object: newSetting)
    }

    @IBAction func setLandscapeSnapArea(_ sender: NSPopUpButton) {
        setSnapArea(sender: sender, type: .landscape)
    }

    @IBAction func setPortraitSnapArea(_ sender: NSPopUpButton) {
        setSnapArea(sender: sender, type: .portrait)
    }

    private func setSnapArea(sender: NSPopUpButton, type: DisplayOrientation) {
        guard let directional = Directional(rawValue: sender.tag) else { return }
        let selectedTag = sender.selectedTag()
        var snapAreaConfig: SnapAreaConfig?
        if selectedTag > -1, let action = WindowAction(rawValue: selectedTag) {
            snapAreaConfig = SnapAreaConfig(action: action)
        }
        SnapAreaModel.instance.setConfig(type: type, directional: directional, snapAreaConfig: snapAreaConfig, displayUUID: selectedDisplayUUID)
        updateResetButtonState()
    }

    override func viewDidLoad() {
        windowSnappingCheckbox.state = Defaults.windowSnapping.userDisabled ? .off : .on
        unsnapRestoreButton.state = Defaults.unsnapRestore.userDisabled ? .off : .on
        animateFootprintCheckbox.state = Defaults.footprintAnimationDurationMultiplier.value > 0 ? .on : .off
        hapticFeedbackCheckbox.state = Defaults.hapticFeedbackOnSnap.userEnabled ? .on : .off
        missionControlDraggingCheckbox.state = Defaults.missionControlDragging.userDisabled ? .on : .off
        missionControlDraggingCheckbox.isHidden = !Defaults.missionControlDragging.userDisabled
        installDisplaySelectorRow()
        rebuildDisplaySelectorItems()
        loadSnapAreas()
        showHidePortrait()

        Notification.Name.configImported.onPost(using: { [weak self] _ in
            self?.rebuildDisplaySelectorItems()
            self?.loadSnapAreas()
        })
        Notification.Name.defaultSnapAreas.onPost(using: { [weak self] _ in
            self?.loadSnapAreas()
        })
        Notification.Name.appWillBecomeActive.onPost() { [weak self] _ in
            self?.showHidePortrait()
        }
        Notification.Name.windowSnapping.onPost { [weak self] _ in
            self?.windowSnappingCheckbox.state = Defaults.windowSnapping.userDisabled ? .off : .on
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
            self?.rebuildDisplaySelectorItems()
            self?.showHidePortrait()
        }
    }

    func showHidePortrait() {
        portraitStackView.isHidden = !NSScreen.portraitDisplayConnected
    }

    func loadSnapAreas() {

        let landscapeSelects: [NSPopUpButton] = [
            topLeftLandscapeSelect,
            topLandscapeSelect,
            topRightLandscapeSelect,
            leftLandscapeSelect,
            rightLandscapeSelect,
            bottomLeftLandscapeSelect,
            bottomLandscapeSelect,
            bottomRightLandscapeSelect
        ]

        let portraitSelects: [NSPopUpButton] = [
            topLeftPortraitSelect,
            topPortraitSelect,
            topRightPortraitSelect,
            leftPortraitSelect,
            rightPortraitSelect,
            bottomLeftPortraitSelect,
            bottomPortraitSelect,
            bottomRightPortraitSelect
        ]

        landscapeSelects.forEach { configure(select: $0, orientation: .landscape)}
        portraitSelects.forEach { configure(select: $0, orientation: .portrait)}
        updateResetButtonState()
    }

    private func configure(select: NSPopUpButton, orientation: DisplayOrientation) {
        guard let directional = Directional(rawValue: select.tag) else { return }
        let snapAreaConfig = SnapAreaModel.instance.snapAreas(for: orientation, displayUUID: selectedDisplayUUID)[directional]

        select.removeAllItems()
        select.addItem(withTitle: "-")
        select.menu?.items.first?.tag = -1

        let selectedTag = snapAreaConfig?.action?.rawValue ?? -1

        for windowAction in WindowAction.active {
            if windowAction.isDragSnappable,
                let name = windowAction.displayName {
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.tag = windowAction.rawValue
                item.image = windowAction.image.copy() as? NSImage
                item.image?.size.height = 12
                item.image?.size.width = 18
                select.menu?.addItem(item)
                if selectedTag == item.tag {
                    select.select(item)
                }
            }
        }
    }

    // MARK: - Per-display selector

    /// Inserts the "Configure for: <display>" row at the top of the snap-area pane.
    /// Done programmatically so the storyboard doesn't need to be rewritten.
    private func installDisplaySelectorRow() {
        guard let columnStack = topLeftLandscapeSelect?.superview,
              let gridStack = columnStack.superview,
              let outerVStack = gridStack.superview as? NSStackView
        else { return }

        let label = NSTextField(labelWithString: NSLocalizedString("Configure for:", tableName: "Main", comment: "Per-display snap area selector label"))
        label.translatesAutoresizingMaskIntoConstraints = false

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self
        popup.action = #selector(displaySelectorChanged(_:))
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        self.displaySelector = popup

        let resetButton = NSButton(title: NSLocalizedString("Reset this display to default", tableName: "Main", comment: "Removes per-display snap area override"), target: self, action: #selector(resetCurrentDisplay(_:)))
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.bezelStyle = .rounded
        resetButton.isEnabled = false
        self.resetDisplayButton = resetButton

        let forgetButton = NSButton(title: NSLocalizedString("Forget this display", tableName: "Main", comment: "Removes a disconnected display from the per-display registry"), target: self, action: #selector(forgetCurrentDisplay(_:)))
        forgetButton.translatesAutoresizingMaskIntoConstraints = false
        forgetButton.bezelStyle = .rounded
        forgetButton.isEnabled = false
        forgetButton.toolTip = NSLocalizedString("Only available when a previously-seen display is selected and not currently connected.", tableName: "Main", comment: "Tooltip explaining when Forget is enabled")
        self.forgetDisplayButton = forgetButton

        let row = NSStackView(views: [label, popup, resetButton, forgetButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        outerVStack.insertArrangedSubview(row, at: 0)
    }

    /// Rebuild the popup items from the union of currently-connected displays
    /// and previously-seen displays in `Defaults.knownDisplays`. Disconnected
    /// entries are still selectable so users can pre-configure e.g. their
    /// laptop screen while docked.
    private func rebuildDisplaySelectorItems() {
        guard let popup = displaySelector else { return }

        popup.removeAllItems()

        let defaultTitle = NSLocalizedString("Default (all displays)", tableName: "Main", comment: "Per-display selector: shared default config")
        popup.addItem(withTitle: defaultTitle)
        popup.itemArray.first?.representedObject = nil as String?

        let choices = SnapAreaModel.instance.allKnownDisplays()
        let knownUUIDs = Set(choices.map { $0.uuid })
        let disconnectedSuffix = NSLocalizedString("(disconnected)", tableName: "Main", comment: "Marker for displays that are saved but not currently connected")

        for choice in choices {
            let title = choice.isConnected ? choice.name : "\(choice.name) \(disconnectedSuffix)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = choice.uuid
            popup.menu?.addItem(item)
        }

        // If the previously-selected display has been forgotten entirely, fall
        // back to default. (A simply-disconnected display is still in the
        // registry, so we keep showing it.)
        if let uuid = selectedDisplayUUID, !knownUUIDs.contains(uuid) {
            selectedDisplayUUID = nil
        }

        if let uuid = selectedDisplayUUID,
           let item = popup.itemArray.first(where: { ($0.representedObject as? String) == uuid }) {
            popup.select(item)
        } else {
            popup.selectItem(at: 0)
        }

        updateResetButtonState()
    }

    /// True if the currently-selected display is in the registry but not
    /// physically connected right now.
    private var selectedDisplayIsDisconnected: Bool {
        guard let uuid = selectedDisplayUUID else { return false }
        return !NSScreen.screens.contains { $0.displayUUIDString == uuid }
    }

    @objc private func displaySelectorChanged(_ sender: NSPopUpButton) {
        selectedDisplayUUID = sender.selectedItem?.representedObject as? String
        loadSnapAreas()
    }

    @objc private func resetCurrentDisplay(_ sender: NSButton) {
        guard let uuid = selectedDisplayUUID else { return }
        SnapAreaModel.instance.clearOverride(displayUUID: uuid)
        loadSnapAreas()
    }

    @objc private func forgetCurrentDisplay(_ sender: NSButton) {
        guard let uuid = selectedDisplayUUID, selectedDisplayIsDisconnected else { return }
        SnapAreaModel.instance.forgetDisplay(uuid: uuid)
        selectedDisplayUUID = nil
        rebuildDisplaySelectorItems()
        loadSnapAreas()
    }

    /// Reset is enabled whenever a per-display override exists.
    /// Forget is enabled only for disconnected displays — forgetting a
    /// connected one would just re-register it on the next screen change.
    private func updateResetButtonState() {
        if let uuid = selectedDisplayUUID {
            resetDisplayButton?.isEnabled = SnapAreaModel.instance.hasOverride(displayUUID: uuid)
            forgetDisplayButton?.isEnabled = selectedDisplayIsDisconnected
        } else {
            resetDisplayButton?.isEnabled = false
            forgetDisplayButton?.isEnabled = false
        }
    }
}
