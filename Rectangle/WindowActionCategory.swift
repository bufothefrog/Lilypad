//
//  WindowActionCategory.swift
//  Rectangle
//
//  Created by Ryan Hanson on 10/3/20.
//  Copyright © 2020 Ryan Hanson. All rights reserved.
//

import Foundation

enum WindowActionCategory {

    case halves, corners, thirds, max, size, display, move, other, fourths

    var menuOrder: Int {
        switch self {
        case .size: return 0
        case .move: return 1
        case .thirds: return 2
        case .fourths: return 3
        default: return 99
        }
    }

    var displayName: String {
        switch self {
        case .halves:
            return NSLocalizedString("Halves", tableName: "Main", value: "", comment: "")
        case .corners:
            return NSLocalizedString("Corners", tableName: "Main", value: "", comment: "")
        case .thirds:
            return NSLocalizedString("Thirds", tableName: "Main", value: "", comment: "")
        case .max:
            return NSLocalizedString("Maximize", tableName: "Main", value: "", comment: "")
        case .size:
            return NSLocalizedString("Size", tableName: "Main", value: "", comment: "")
        case .display:
            return NSLocalizedString("Display", tableName: "Main", value: "", comment: "")
        case .other:
            return NSLocalizedString("Other", tableName: "Main", value: "", comment: "")
        case .move:
            return NSLocalizedString("Move to Edge", tableName: "Main", value: "", comment: "")
        case .fourths:
            return NSLocalizedString("Fourths", tableName: "Main", value: "", comment: "")
        }
    }
}
