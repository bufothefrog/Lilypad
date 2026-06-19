//
//  DisplayRegistry.swift
//  Lilypad
//
//  The display registry, extracted from `SnapAreaModel` so it survives the
//  later deletion of the snap-area code. It owns:
//  - `Defaults.knownDisplays` persistence (every display Lilypad has seen),
//  - `recordCurrentDisplays()` plus the `didChangeScreenParametersNotification`
//    observer that keeps it up to date (with the unnamed-display skip guard that
//    avoids phantom entries during docking handshakes),
//  - `allKnownDisplays()` returning a `DisplayChoice` array for settings UIs,
//  - `forgetDisplay(uuid:)` for cleaning up monitors the user no longer has.
//
//  Both the existing Snap Areas pane (via `SnapAreaModel` thin wrappers) and the
//  Lilypad grid system (`GridModel`) enumerate displays through this one registry.
//

import AppKit

class DisplayRegistry {
    static let instance = DisplayRegistry()

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.recordCurrentDisplays() }
        recordCurrentDisplays()
    }

    /// Records every currently-connected display in `Defaults.knownDisplays`
    /// so disconnected displays can still be configured later. Called at init
    /// and on every screen-parameters change.
    func recordCurrentDisplays() {
        var registry = Defaults.knownDisplays.typedValue ?? [:]
        let now = Date()
        var changed = false
        for screen in NSScreen.screens {
            guard let uuid = screen.displayUUIDString else { continue }
            let name = screen.localizedName
            // Skip displays whose name hasn't resolved yet. macOS briefly
            // enumerates displays mid-handshake (e.g. while docking) before
            // their EDID name is available; recording those would leave
            // permanent unnamed "phantom" entries in the registry.
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            registry[uuid] = KnownDisplay(name: name, lastSeen: now)
            changed = true
        }
        if changed {
            Defaults.knownDisplays.typedValue = registry
        }
    }

    /// All displays Lilypad knows about — currently connected ones first
    /// (in `NSScreen.screens` order), then any previously-seen displays that
    /// aren't currently connected. Names are disambiguated when duplicated.
    func allKnownDisplays() -> [DisplayChoice] {
        var seen: Set<String> = []
        var rawChoices: [(uuid: String, name: String, isConnected: Bool)] = []
        for screen in NSScreen.screens {
            guard let uuid = screen.displayUUIDString else { continue }
            rawChoices.append((uuid, screen.localizedName, true))
            seen.insert(uuid)
        }
        let registry = Defaults.knownDisplays.typedValue ?? [:]
        let disconnected = registry
            .filter { !seen.contains($0.key) }
            .sorted { $0.value.lastSeen > $1.value.lastSeen }
        for (uuid, info) in disconnected {
            rawChoices.append((uuid, info.name, false))
        }

        var nameCounts: [String: Int] = [:]
        for c in rawChoices { nameCounts[c.name, default: 0] += 1 }
        var nameSeen: [String: Int] = [:]
        return rawChoices.map { c in
            let displayName: String
            if (nameCounts[c.name] ?? 0) > 1 {
                nameSeen[c.name, default: 0] += 1
                displayName = "\(c.name) (\(nameSeen[c.name]!))"
            } else {
                displayName = c.name
            }
            return DisplayChoice(uuid: c.uuid, name: displayName, isConnected: c.isConnected)
        }
    }

    /// The UUIDs of every display the registry knows about (connected or not),
    /// for callers (e.g. grid seeding) that only need the keys.
    func knownDisplayUUIDs() -> [String] {
        allKnownDisplays().map { $0.uuid }
    }

    /// Removes a previously-seen display from the registry. Useful for cleaning
    /// up monitors the user no longer has. Snap-area / grid per-display data
    /// keyed by this UUID is the caller's responsibility to clear.
    func forgetDisplay(uuid: String) {
        var registry = Defaults.knownDisplays.typedValue ?? [:]
        registry.removeValue(forKey: uuid)
        Defaults.knownDisplays.typedValue = registry
    }
}

/// Persistent record of a display Lilypad has seen at least once,
/// keyed by display UUID in `Defaults.knownDisplays`. Lets settings UIs
/// offer disconnected displays for configuration.
struct KnownDisplay: Codable {
    var name: String
    var lastSeen: Date
}

/// One row in a per-display settings dropdown.
struct DisplayChoice {
    let uuid: String
    let name: String
    let isConnected: Bool
}
