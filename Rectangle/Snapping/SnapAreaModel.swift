//
//  SnapAreaModel.swift
//  Rectangle
//
//  Created by Ryan Hanson on 8/19/22.
//  Copyright © 2022 Ryan Hanson. All rights reserved.
//

import AppKit

class SnapAreaModel {
    static let instance = SnapAreaModel()

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.recordCurrentDisplays() }
        recordCurrentDisplays()
    }
    
    static let defaultLandscape: [Directional:SnapAreaConfig] = [
        .tl: SnapAreaConfig(action: .topLeft),
        .t: SnapAreaConfig(action: .maximize),
        .tr: SnapAreaConfig(action: .topRight),
        .l: SnapAreaConfig(compound: .leftTopBottomHalf),
        .r: SnapAreaConfig(compound: .rightTopBottomHalf),
        .bl: SnapAreaConfig(action: .bottomLeft),
        .b: SnapAreaConfig(compound: .thirds),
        .br: SnapAreaConfig(action: .bottomRight)
    ]
    
    static let defaultPortrait: [Directional:SnapAreaConfig] = [
        .tl: SnapAreaConfig(action: .topLeft),
        .t: SnapAreaConfig(action: .maximize),
        .tr: SnapAreaConfig(action: .topRight),
        .l: SnapAreaConfig(compound: .portraitThirdsSide),
        .r: SnapAreaConfig(compound: .portraitThirdsSide),
        .bl: SnapAreaConfig(action: .bottomLeft),
        .b: SnapAreaConfig(compound: .halves),
        .br: SnapAreaConfig(action: .bottomRight)
    ]
    
    var landscape: [Directional:SnapAreaConfig] {
        Defaults.landscapeSnapAreas.typedValue ?? SnapAreaModel.defaultLandscape
    }
    var portrait: [Directional:SnapAreaConfig] {
        Defaults.portraitSnapAreas.typedValue ?? SnapAreaModel.defaultPortrait
    }

    var isTopConfigured: Bool {
        if let landscapeTop = landscape[.t] {
            if landscapeTop.action != nil || landscapeTop.compound != nil {
                return true
            }
        }
        if NSScreen.portraitDisplayConnected, let portraitTop = portrait[.t] {
            if portraitTop.action != nil || portraitTop.compound != nil {
                return true
            }
        }
        return false
    }

    /// Returns the snap area dictionary that should apply to a given display.
    /// If `displayUUID` has a per-display override for `orientation`, returns that;
    /// otherwise falls back to the global landscape/portrait config.
    func snapAreas(for orientation: DisplayOrientation, displayUUID: String?) -> [Directional:SnapAreaConfig] {
        if let uuid = displayUUID,
           let perDisplay = Defaults.snapAreasByDisplay.typedValue?[uuid],
           let override = perDisplay.config(for: orientation) {
            return override
        }
        return orientation == .landscape ? landscape : portrait
    }

    /// True if the given display has any per-display override stored.
    func hasOverride(displayUUID: String) -> Bool {
        guard let perDisplay = Defaults.snapAreasByDisplay.typedValue?[displayUUID] else { return false }
        return perDisplay.landscape != nil || perDisplay.portrait != nil
    }

    /// Removes any per-display override for the given display.
    func clearOverride(displayUUID: String) {
        var byDisplay = Defaults.snapAreasByDisplay.typedValue ?? [:]
        byDisplay.removeValue(forKey: displayUUID)
        Defaults.snapAreasByDisplay.typedValue = byDisplay
    }

    // MARK: - Known displays registry

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
            if let existing = registry[uuid], existing.name == name {
                registry[uuid] = KnownDisplay(name: name, lastSeen: now)
            } else {
                registry[uuid] = KnownDisplay(name: name, lastSeen: now)
            }
            changed = true
        }
        if changed {
            Defaults.knownDisplays.typedValue = registry
        }
    }

    /// All displays Rectangle knows about — currently connected ones first
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

    /// Removes a previously-seen display from the registry and any per-display
    /// override that referenced it. Useful for cleaning up monitors the user
    /// no longer has.
    func forgetDisplay(uuid: String) {
        var registry = Defaults.knownDisplays.typedValue ?? [:]
        registry.removeValue(forKey: uuid)
        Defaults.knownDisplays.typedValue = registry
        clearOverride(displayUUID: uuid)
    }

    func setConfig(type: DisplayOrientation, directional: Directional, snapAreaConfig: SnapAreaConfig?) {
        setConfig(type: type, directional: directional, snapAreaConfig: snapAreaConfig, displayUUID: nil)
    }

    /// Sets a single directional config. If `displayUUID` is nil, mutates the
    /// global landscape/portrait config (legacy path). Otherwise mutates the
    /// per-display override for that display, seeding it from the current
    /// effective config so unset directions inherit from the global default.
    func setConfig(type: DisplayOrientation, directional: Directional, snapAreaConfig: SnapAreaConfig?, displayUUID: String?) {
        guard let uuid = displayUUID else {
            switch type {
            case .landscape: setLandscape(directional: directional, snapAreaConfig: snapAreaConfig)
            case .portrait: setPortrait(directional: directional, snapAreaConfig: snapAreaConfig)
            }
            return
        }

        var byDisplay = Defaults.snapAreasByDisplay.typedValue ?? [:]
        var perDisplay = byDisplay[uuid] ?? PerDisplaySnapAreas()
        var dict = perDisplay.config(for: type) ?? (type == .landscape ? landscape : portrait)
        dict[directional] = snapAreaConfig
        perDisplay.set(dict, for: type)
        byDisplay[uuid] = perDisplay
        Defaults.snapAreasByDisplay.typedValue = byDisplay
    }

    func setLandscape(directional: Directional, snapAreaConfig: SnapAreaConfig?) {
        var newConfig = landscape
        newConfig[directional] = snapAreaConfig
        Defaults.landscapeSnapAreas.typedValue = newConfig
    }

    func setPortrait(directional: Directional, snapAreaConfig: SnapAreaConfig?) {
        var newConfig = portrait
        newConfig[directional] = snapAreaConfig
        Defaults.portraitSnapAreas.typedValue = newConfig
    }
    
    func migrate() {
        if Defaults.sixthsSnapArea.userEnabled {
            setLandscape(directional: .t, snapAreaConfig: SnapAreaConfig(compound: .topSixths))
            setLandscape(directional: .b, snapAreaConfig: SnapAreaConfig(compound: .bottomSixths))
        }

        let ignoredSnapAreas = SnapAreaOption(rawValue: Defaults.ignoredSnapAreas.value)
        guard ignoredSnapAreas.rawValue > 0 else { return }
        
        let directionalToSnapAreaOption: [Directional: SnapAreaOption] = [
            .tl: .topLeft,
            .t: .top,
            .tr: .topRight,
            .l: .left,
            .r: .right,
            .bl: .bottomLeft,
            .b: .bottom,
            .br: .bottomRight
        ]
        
        for directional in Directional.cases {
            if let option = directionalToSnapAreaOption[directional] {
                if ignoredSnapAreas.contains(option) {
                    setLandscape(directional: directional, snapAreaConfig: nil)
                    setPortrait(directional: directional, snapAreaConfig: nil)
                }
            }
        }
        
        if ignoredSnapAreas.contains(.bottomLeftShort) && ignoredSnapAreas.contains(.topLeftShort) {
            setLandscape(directional: .l, snapAreaConfig: SnapAreaConfig(action: .leftHalf))
        }
        
        if ignoredSnapAreas.contains(.bottomRightShort) && ignoredSnapAreas.contains(.topRightShort) {
            setLandscape(directional: .r, snapAreaConfig: SnapAreaConfig(action: .rightHalf))
        }
    }
}

enum DisplayOrientation {
    case landscape, portrait
}

struct SnapAreaConfig: Codable {
    let compound: CompoundSnapArea?
    let action: WindowAction?

    init(compound: CompoundSnapArea? = nil, action: WindowAction? = nil) {
        self.compound = compound
        self.action = action
    }
}

/// Persistent record of a display Rectangle has seen at least once,
/// keyed by display UUID in `Defaults.knownDisplays`. Lets the Snap Areas
/// settings UI offer disconnected displays for configuration.
struct KnownDisplay: Codable {
    var name: String
    var lastSeen: Date
}

/// One row in the per-display settings dropdown.
struct DisplayChoice {
    let uuid: String
    let name: String
    let isConnected: Bool
}

/// Per-display override of snap area config for one physical monitor,
/// keyed by display UUID in `Defaults.snapAreasByDisplay`. Either side
/// may be nil, in which case the global landscape/portrait config applies.
struct PerDisplaySnapAreas: Codable {
    var landscape: [Directional:SnapAreaConfig]?
    var portrait: [Directional:SnapAreaConfig]?

    init(landscape: [Directional:SnapAreaConfig]? = nil, portrait: [Directional:SnapAreaConfig]? = nil) {
        self.landscape = landscape
        self.portrait = portrait
    }

    func config(for orientation: DisplayOrientation) -> [Directional:SnapAreaConfig]? {
        switch orientation {
        case .landscape: return landscape
        case .portrait: return portrait
        }
    }

    mutating func set(_ config: [Directional:SnapAreaConfig]?, for orientation: DisplayOrientation) {
        switch orientation {
        case .landscape: landscape = config
        case .portrait: portrait = config
        }
    }
}

enum Directional: Int, Codable {
    case tl = 1,
         t = 2,
         tr = 3,
         l = 4,
         r = 5,
         bl = 6,
         b = 7,
         br = 8,
         c = 9
    
    static var cases = [tl, t, tr, l, r, bl, b, br]
}

struct SnapAreaOption: OptionSet, Hashable {
    let rawValue: Int
    
    static let top = SnapAreaOption(rawValue: 1 << 0)
    static let bottom = SnapAreaOption(rawValue: 1 << 1)
    static let left = SnapAreaOption(rawValue: 1 << 2)
    static let right = SnapAreaOption(rawValue: 1 << 3)
    static let topLeft = SnapAreaOption(rawValue: 1 << 4)
    static let topRight = SnapAreaOption(rawValue: 1 << 5)
    static let bottomLeft = SnapAreaOption(rawValue: 1 << 6)
    static let bottomRight = SnapAreaOption(rawValue: 1 << 7)
    static let topLeftShort = SnapAreaOption(rawValue: 1 << 8)
    static let topRightShort = SnapAreaOption(rawValue: 1 << 9)
    static let bottomLeftShort = SnapAreaOption(rawValue: 1 << 10)
    static let bottomRightShort = SnapAreaOption(rawValue: 1 << 11)
    
    static let all: SnapAreaOption = [.top, .bottom, .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight, .topLeftShort, .topRightShort, .bottomLeftShort, .bottomRightShort]
    static let none: SnapAreaOption = []
}
