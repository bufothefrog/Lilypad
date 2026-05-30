//
//  GridLayoutModel.swift
//  Rectangle / Lilypad
//
//  The persisted data model for the Lilypad grid system. A layout is a
//  FancyZones-style non-uniform grid (cut + merge): arbitrary column/row
//  boundaries plus a cell->zone map. Uniform N×M grids are the special case of
//  evenly spaced boundaries with an identity (no-merge) cell->zone map.
//
//  This file is intentionally pure data (no geometry yet). Span<->rect math,
//  cursor->zone hit-testing, neighbor lookups, and quick-starter generators
//  arrive with GridCalculation in a later milestone.
//

import Foundation

/// One named layout for a monitor.
///
/// Geometry is stored inline as fractional boundaries in `0...1`:
/// `colBoundaries` has `cols + 1` ascending entries (the vertical cut lines,
/// including the 0 and 1 edges), `rowBoundaries` likewise for rows.
///
/// `cellZones` is a row-major array of length `cols * rows`. Each entry is a
/// zone id; cells sharing an id form a single zone, whose cells must always
/// form a rectangle (the editor enforces this — `GridCalculation` assumes it).
/// An identity map (`0, 1, 2, …`) means every cell is its own zone (no merges).
struct ZoneLayout: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var colBoundaries: [Double]
    var rowBoundaries: [Double]
    var cellZones: [Int]

    init(id: String, name: String, colBoundaries: [Double], rowBoundaries: [Double], cellZones: [Int]) {
        self.id = id
        self.name = name
        self.colBoundaries = colBoundaries
        self.rowBoundaries = rowBoundaries
        self.cellZones = cellZones
    }

    /// Number of columns implied by the boundary array.
    var cols: Int { max(colBoundaries.count - 1, 0) }
    /// Number of rows implied by the boundary array.
    var rows: Int { max(rowBoundaries.count - 1, 0) }

    /// Distinct zone ids in stable first-appearance order.
    var zoneIds: [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for z in cellZones where !seen.contains(z) {
            seen.insert(z)
            ordered.append(z)
        }
        return ordered
    }
}

/// The set of named layouts configured for one physical monitor, keyed by
/// display UUID in `Defaults.gridLayoutsByDisplay`. `activeLayoutId` is the
/// layout that grid actions currently target on that monitor.
struct PerDisplayLayouts: Codable, Equatable {
    var layouts: [ZoneLayout]
    var activeLayoutId: String?

    init(layouts: [ZoneLayout] = [], activeLayoutId: String? = nil) {
        self.layouts = layouts
        self.activeLayoutId = activeLayoutId
    }

    /// The active layout, or the first layout if none is explicitly marked.
    var activeLayout: ZoneLayout? {
        if let id = activeLayoutId, let match = layouts.first(where: { $0.id == id }) {
            return match
        }
        return layouts.first
    }
}
