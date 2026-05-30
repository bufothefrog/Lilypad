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

    private init() {}

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

    // MARK: - Known displays registry (delegated to DisplayRegistry)

    /// All displays Rectangle knows about. Delegates to `DisplayRegistry`; kept
    /// as a thin wrapper so `SnapAreaViewController` is unaffected by the
    /// registry extraction.
    func allKnownDisplays() -> [DisplayChoice] {
        DisplayRegistry.instance.allKnownDisplays()
    }

    /// Forgets a previously-seen display: removes it from the registry AND clears
    /// any per-display snap-area override that referenced it (preserving the
    /// original semantics). Delegates the registry removal to `DisplayRegistry`.
    func forgetDisplay(uuid: String) {
        DisplayRegistry.instance.forgetDisplay(uuid: uuid)
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
