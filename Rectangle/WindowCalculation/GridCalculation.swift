//
//  GridCalculation.swift
//  Rectangle / Lilypad
//
//  The geometry keystone for the Lilypad grid system. Given a `ZoneLayout`
//  (non-uniform fractional boundaries + a cell->zone merge map) and an `area`
//  (the screen's `adjustedVisibleFrame()`), this produces rects for zones,
//  resolves a cursor or a window rect back to a zone, builds selection-span
//  bounding boxes, and walks the zone neighbor graph for keyboard navigation.
//
//  COORDINATE SPACE (critical — see LILYPAD_PLAN.md "The keystone"):
//  All math here lives in Cocoa BOTTOM-LEFT coordinates, the same space as
//  `NSEvent.mouseLocation`, `NSScreen.frame`, and `NSScreen.adjustedVisibleFrame()`.
//  GridCalculation does NOT flip to top-left — the existing WindowManager commit
//  step does that via `.screenFlipped`. The rects returned here are in `area`'s
//  space directly.
//
//  ROW / COLUMN CONVENTION (the #1 bug risk — vertical mirroring):
//  - `col` index 0 is the LEFT edge of the screen; the last col is the RIGHT.
//    `colBoundaries` is ascending in 0...1 measured left->right, so col 0 has the
//    smallest minX.
//  - `row` index 0 is the TOP of the screen; the last row is the BOTTOM.
//    `rowBoundaries` is ascending in 0...1 measured FROM THE TOP. Because Cocoa y
//    grows upward, row 0 (top) maps to the LARGEST y in `area`, so we invert the
//    row fraction when computing y. This is asserted explicitly in the tests.
//
//  All zones are assumed rectangular (the layout editor enforces this): every
//  zone's set of cells forms an axis-aligned rectangle, so a zone's rect is the
//  bounding box of its cells.
//

import Foundation
import CoreGraphics

enum GridCalculation {

    /// A direction for neighbor lookups and keyboard navigation.
    enum Direction {
        case left, right, up, down
    }

    // MARK: - Cell geometry

    /// The Cocoa-space rect of a single grid cell `(col, row)` within `area`.
    ///
    /// `area` is the screen's `adjustedVisibleFrame()` (bottom-left origin).
    /// `row` 0 is the TOP of the screen (largest y); `col` 0 is the LEFT.
    /// Returns `.null` for out-of-range indices.
    static func cellRect(layout: ZoneLayout, col: Int, row: Int, in area: CGRect) -> CGRect {
        guard col >= 0, col < layout.cols, row >= 0, row < layout.rows else { return .null }

        let xs = layout.colBoundaries
        let ys = layout.rowBoundaries

        let minX = area.minX + CGFloat(xs[col]) * area.width
        let maxX = area.minX + CGFloat(xs[col + 1]) * area.width

        // rowBoundaries are measured from the TOP. Row `row` spans the top
        // fraction ys[row] (nearer the top) to ys[row+1] (nearer the bottom).
        // In Cocoa coords (y up), "top fraction f" sits at y = area.maxY - f*height.
        let topY = area.maxY - CGFloat(ys[row]) * area.height
        let bottomY = area.maxY - CGFloat(ys[row + 1]) * area.height

        return CGRect(x: minX, y: bottomY, width: maxX - minX, height: topY - bottomY)
    }

    // MARK: - Zone geometry

    /// The Cocoa-space bounding box of every cell mapped to `zoneId` in `layout`.
    ///
    /// Because zones are rectangular, this bounding box is exactly the zone. Returns
    /// `.null` if no cell carries `zoneId`.
    static func zoneRect(layout: ZoneLayout, zoneId: Int, in area: CGRect) -> CGRect {
        var union: CGRect = .null
        for (col, row) in cells(of: zoneId, in: layout) {
            union = union.union(cellRect(layout: layout, col: col, row: row, in: area))
        }
        return union
    }

    // MARK: - Hit testing: cursor -> zone

    /// The zone id whose cells contain `point`, or `nil` if `point` is outside `area`.
    ///
    /// `point` is in Cocoa bottom-left coords (e.g. `NSEvent.mouseLocation`). The cell
    /// is located by binary search on the boundary arrays, then mapped through `cellZones`.
    /// A point exactly on an interior boundary resolves deterministically to the cell on
    /// the higher-index side (right / bottom), matching the half-open interval [start, end).
    static func zone(at point: CGPoint, in area: CGRect, layout: ZoneLayout) -> Int? {
        guard layout.cols > 0, layout.rows > 0 else { return nil }
        guard area.width > 0, area.height > 0 else { return nil }
        guard point.x >= area.minX, point.x <= area.maxX,
              point.y >= area.minY, point.y <= area.maxY else { return nil }

        // Horizontal: fraction from the LEFT, ascending.
        let fx = Double((point.x - area.minX) / area.width)
        let col = cellIndex(for: fx, in: layout.colBoundaries, count: layout.cols)

        // Vertical: rowBoundaries are measured from the TOP, so convert the
        // bottom-left y into a top fraction before searching.
        let fyFromTop = Double((area.maxY - point.y) / area.height)
        let row = cellIndex(for: fyFromTop, in: layout.rowBoundaries, count: layout.rows)

        return zoneId(layout: layout, col: col, row: row)
    }

    // MARK: - Inference: window rect -> zone

    /// The zone whose rect best matches `rect`, or `nil` if none is within `tolerance`.
    ///
    /// Used for keyboard-nav inference: given the current window frame, find the zone it
    /// is occupying. "Best" = smallest sum of absolute corner deltas (minX, minY, maxX,
    /// maxY). A match is accepted only when each of the four edges is within `tolerance`
    /// points, so a window that fills no zone returns `nil`.
    ///
    /// `rect` and `area` are both in Cocoa bottom-left coords.
    static func zone(matchingWindowRect rect: CGRect, in area: CGRect, layout: ZoneLayout, tolerance: CGFloat = 25) -> Int? {
        var best: Int? = nil
        var bestScore = CGFloat.greatestFiniteMagnitude

        for zoneId in layout.zoneIds {
            let zr = zoneRect(layout: layout, zoneId: zoneId, in: area)
            guard !zr.isNull else { continue }

            let dMinX = abs(zr.minX - rect.minX)
            let dMinY = abs(zr.minY - rect.minY)
            let dMaxX = abs(zr.maxX - rect.maxX)
            let dMaxY = abs(zr.maxY - rect.maxY)

            guard dMinX <= tolerance, dMinY <= tolerance,
                  dMaxX <= tolerance, dMaxY <= tolerance else { continue }

            let score = dMinX + dMinY + dMaxX + dMaxY
            if score < bestScore {
                bestScore = score
                best = zoneId
            }
        }
        return best
    }

    // MARK: - Selection span

    /// The Cocoa-space union bounding box of the cells of `fromZone` and `toZone`.
    ///
    /// Powers drag-span and chord selection: the resulting rect spans both anchor zones
    /// (and, because it is a bounding box, any zones geometrically between them). If exactly
    /// one zone is unknown, falls back to the other zone's rect; returns `.null` only if
    /// both are unknown.
    static func selectionRect(layout: ZoneLayout, fromZone: Int, toZone: Int, in area: CGRect) -> CGRect {
        let a = zoneRect(layout: layout, zoneId: fromZone, in: area)
        let b = zoneRect(layout: layout, zoneId: toZone, in: area)
        if a.isNull { return b }
        if b.isNull { return a }
        return a.union(b)
    }

    // MARK: - Neighbor graph

    /// The zone immediately adjacent to `zoneId` in `direction`, or `nil` at a wall.
    ///
    /// Walks one cell out from the zone's bounding cell range across the shared boundary
    /// in `direction` and returns whichever zone that neighboring cell belongs to (skipping
    /// the starting zone itself, so a hop always lands on a different zone or `nil`). This
    /// correctly hops across merged zones because it steps off the zone's full extent.
    static func neighbor(ofZone zoneId: Int, direction: Direction, layout: ZoneLayout) -> Int? {
        let cells = self.cells(of: zoneId, in: layout)
        guard !cells.isEmpty else { return nil }

        let minCol = cells.map { $0.col }.min()!
        let maxCol = cells.map { $0.col }.max()!
        let minRow = cells.map { $0.row }.min()!
        let maxRow = cells.map { $0.row }.max()!

        switch direction {
        case .left:
            let col = minCol - 1
            guard col >= 0 else { return nil }
            return firstDifferentZone(layout: layout, fromZone: zoneId, col: col, rows: minRow...maxRow)
        case .right:
            let col = maxCol + 1
            guard col < layout.cols else { return nil }
            return firstDifferentZone(layout: layout, fromZone: zoneId, col: col, rows: minRow...maxRow)
        case .up:
            // Up = toward the TOP = toward smaller row index (row 0 is the top).
            let row = minRow - 1
            guard row >= 0 else { return nil }
            return firstDifferentZone(layout: layout, fromZone: zoneId, row: row, cols: minCol...maxCol)
        case .down:
            // Down = toward the BOTTOM = toward larger row index.
            let row = maxRow + 1
            guard row < layout.rows else { return nil }
            return firstDifferentZone(layout: layout, fromZone: zoneId, row: row, cols: minCol...maxCol)
        }
    }

    // MARK: - Gap-aware convenience

    /// `zoneRect` with Rectangle's standard gap inset applied via `GapCalculation`.
    ///
    /// Convenience for callers that already apply gaps to single-window snaps. Shared
    /// edges are left at `.none`, so this is the "no edges shared with neighbors" case —
    /// callers needing exact per-edge gap accounting (matching `SnappingManager.getBoxRect`)
    /// should compute `sharedEdges` themselves. Exact per-edge gap accounting is deferred;
    /// see LILYPAD_PLAN.md "Risk register".
    static func zoneRectWithGaps(layout: ZoneLayout, zoneId: Int, in area: CGRect, gapSize: Float) -> CGRect {
        let rect = zoneRect(layout: layout, zoneId: zoneId, in: area)
        guard !rect.isNull, gapSize > 0 else { return rect }
        return GapCalculation.applyGaps(rect, dimension: .both, sharedEdges: .none, gapSize: gapSize)
    }

    // MARK: - Internal helpers

    /// All `(col, row)` cells mapped to `zoneId`, in row-major order.
    private static func cells(of zoneId: Int, in layout: ZoneLayout) -> [(col: Int, row: Int)] {
        var result: [(col: Int, row: Int)] = []
        let cols = layout.cols
        guard cols > 0 else { return result }
        for (index, id) in layout.cellZones.enumerated() where id == zoneId {
            result.append((col: index % cols, row: index / cols))
        }
        return result
    }

    /// The zone id at `(col, row)`, or `nil` if out of range or unmapped.
    private static func zoneId(layout: ZoneLayout, col: Int, row: Int) -> Int? {
        guard col >= 0, col < layout.cols, row >= 0, row < layout.rows else { return nil }
        let index = row * layout.cols + col
        guard index >= 0, index < layout.cellZones.count else { return nil }
        return layout.cellZones[index]
    }

    /// Binary-search a value `f` (a fraction in 0...1) into a cell index given an
    /// ascending boundary array of length `count + 1`. Clamps to `[0, count - 1]`.
    /// On an exact interior boundary, resolves to the higher-index cell ([start, end)).
    private static func cellIndex(for f: Double, in boundaries: [Double], count: Int) -> Int {
        guard count > 0 else { return 0 }
        if f <= boundaries.first ?? 0 { return 0 }
        if f >= boundaries.last ?? 1 { return count - 1 }

        // Find the last boundary <= f; that boundary's index is the cell.
        var lo = 0
        var hi = count            // searching boundaries[0...count]
        while lo < hi {
            let mid = (lo + hi) / 2
            if boundaries[mid] <= f {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        // lo is the first boundary index strictly greater than f; cell is lo - 1.
        return max(0, min(count - 1, lo - 1))
    }

    /// Scan a column over a row range; return the first zone id that differs from
    /// `fromZone`, or `nil` if every cell in the range belongs to `fromZone`.
    private static func firstDifferentZone(layout: ZoneLayout, fromZone: Int, col: Int, rows: ClosedRange<Int>) -> Int? {
        for row in rows {
            if let id = zoneId(layout: layout, col: col, row: row), id != fromZone {
                return id
            }
        }
        return nil
    }

    /// Scan a row over a column range; return the first zone id that differs from
    /// `fromZone`, or `nil` if every cell in the range belongs to `fromZone`.
    private static func firstDifferentZone(layout: ZoneLayout, fromZone: Int, row: Int, cols: ClosedRange<Int>) -> Int? {
        for col in cols {
            if let id = zoneId(layout: layout, col: col, row: row), id != fromZone {
                return id
            }
        }
        return nil
    }
}

// MARK: - Quick-starter generators

extension ZoneLayout {

    /// A uniform `cols` × `rows` grid with evenly spaced boundaries and an identity
    /// cell->zone map (every cell is its own zone — no merges).
    ///
    /// `cellZones` is `0, 1, 2, …` in row-major order, so zone ids match cell indices.
    static func uniform(cols: Int, rows: Int, id: String, name: String) -> ZoneLayout {
        let safeCols = max(cols, 1)
        let safeRows = max(rows, 1)

        let colBoundaries = (0...safeCols).map { Double($0) / Double(safeCols) }
        let rowBoundaries = (0...safeRows).map { Double($0) / Double(safeRows) }
        let cellZones = Array(0..<(safeCols * safeRows))

        return ZoneLayout(
            id: id,
            name: name,
            colBoundaries: colBoundaries,
            rowBoundaries: rowBoundaries,
            cellZones: cellZones
        )
    }

    // MARK: Named presets (quick-starters the editor can seed, then cut/merge)

    /// Two columns side by side (left | right).
    static func halves(id: String = "halves", name: String = "Halves") -> ZoneLayout {
        uniform(cols: 2, rows: 1, id: id, name: name)
    }

    /// Three equal columns (left | center | right).
    static func thirds(id: String = "thirds", name: String = "Thirds") -> ZoneLayout {
        uniform(cols: 3, rows: 1, id: id, name: name)
    }

    /// A 2×2 quadrant grid.
    static func grid2x2(id: String = "2x2", name: String = "2 × 2") -> ZoneLayout {
        uniform(cols: 2, rows: 2, id: id, name: name)
    }

    /// A 3×2 grid (three columns, two rows).
    static func grid3x2(id: String = "3x2", name: String = "3 × 2") -> ZoneLayout {
        uniform(cols: 3, rows: 2, id: id, name: name)
    }

    /// A 4×2 grid (four columns, two rows).
    static func grid4x2(id: String = "4x2", name: String = "4 × 2") -> ZoneLayout {
        uniform(cols: 4, rows: 2, id: id, name: name)
    }
}
