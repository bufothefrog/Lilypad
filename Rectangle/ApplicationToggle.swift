//
//  ApplicationToggle.swift
//  Rectangle
//
//  Created by Ryan Hanson on 6/18/19.
//  Copyright © 2019 Ryan Hanson. All rights reserved.
//

import Cocoa

class ApplicationToggle: NSObject {
    
    private var disabledApps = Set<String>()
    public private(set) static var frontAppId: String? = "com.lilypad.Lilypad"
    public private(set) static var frontAppName: String? = "Lilypad"
    public private(set) static var shortcutsDisabled: Bool = false

    private let shortcutManager: ShortcutManager
    
    init(shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        super.init()
        registerFrontAppChangeNote()
        if let disabledApps = getDisabledApps() {
            self.disabledApps = disabledApps
        }
    }
    
    public func reloadFromDefaults() {
        if let disabledApps = getDisabledApps() {
            self.disabledApps = disabledApps
        } else {
            disabledApps.removeAll()
        }
    }
    
    private func saveDisabledApps() {
        let encoder = JSONEncoder()
        if let jsonDisabledApps = try? encoder.encode(disabledApps) {
            if let jsonString = String(data: jsonDisabledApps, encoding: .utf8) {
                Defaults.disabledApps.value = jsonString
            }
        }
    }
    
    private func getDisabledApps() ->  Set<String>? {
        guard let jsonDisabledAppsString = Defaults.disabledApps.value else { return nil }
        
        let decoder = JSONDecoder()
        guard let jsonDisabledApps = jsonDisabledAppsString.data(using: .utf8) else { return nil }
        guard let disabledApps = try? decoder.decode(Set<String>.self, from: jsonDisabledApps) else { return nil }
        
        return disabledApps
    }

    private func disableShortcuts() {
        if !Self.shortcutsDisabled {
            Self.shortcutsDisabled = true
            self.shortcutManager.unbindShortcuts()
            if !Defaults.ignoreDragSnapToo.userDisabled {
                Notification.Name.windowSnapping.post(object: false)
            }
        }
    }
    
    private func enableShortcuts() {
        if Self.shortcutsDisabled {
            Self.shortcutsDisabled = false
            self.shortcutManager.bindShortcuts()
            if !Defaults.ignoreDragSnapToo.userDisabled {
                Notification.Name.windowSnapping.post(object: true)
            }
        }
    }

    public func disableApp(appBundleId: String? = frontAppId) {
        if let appBundleId {
            disabledApps.insert(appBundleId)
            saveDisabledApps()
            disableShortcuts()
            // SnappingManager no longer pauses its event monitor off the
            // `windowSnapping` notification (that now governs only edge snap), so
            // re-post `frontAppChanged` to make it re-evaluate `allowListening` from
            // the app-ignore state when the CURRENT app is toggled from the menu.
            Notification.Name.frontAppChanged.post()
        }
    }

    public func enableApp(appBundleId: String? = frontAppId) {
        if let appBundleId {
            disabledApps.remove(appBundleId)
            saveDisabledApps()
            enableShortcuts()
            Notification.Name.frontAppChanged.post()
        }
    }
    
    public func isDisabled(bundleId: String) -> Bool {
        return disabledApps.contains(bundleId)
    }
    
    private func registerFrontAppChangeNote() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.receiveFrontAppChangeNote(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }
    
    @objc func receiveFrontAppChangeNote(_ notification: Notification) {
        if let application = notification.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication {
            Self.frontAppId = application.bundleIdentifier
            Self.frontAppName = application.localizedName
            if let frontAppId = application.bundleIdentifier {
                if isDisabled(bundleId: frontAppId) {
                    disableShortcuts()
                } else {
                    enableShortcuts()
                }
                Notification.Name.frontAppChanged.post()
            } else {
                enableShortcuts()
            }
            if Defaults.enhancedUI.value == .frontmostDisable {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                    AccessibilityElement.getFrontApplicationElement()?.enhancedUserInterface = false
                }
            }
        }
    }
}

// todo mode
extension ApplicationToggle {
    public func setTodoApp() {
        Defaults.todoApplication.value = Self.frontAppId
    }

    public func todoAppIsActive() -> Bool {
        return Defaults.todoApplication.value == Self.frontAppId
    }
}
