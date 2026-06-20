//
//  GridCalculation.swift
//  Lilypad
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

    /// An inclusive rectangular range of grid cells, in the same (col, row)
    /// convention as the rest of GridCalculation: `col` 0 is the LEFT, `row` 0 is
    /// the TOP. A single cell is the degenerate range where min == max on both axes.
    /// Powers the keyboard SPAN actions (M8a), which grow this range one cell-line
    /// in an arrow direction and commit the range's bounding rect.
    struct CellRange: Equatable {
        var colMin: Int
        var colMax: Int
        var rowMin: Int
        var rowMax: Int

        init(colMin: Int, colMax: Int, rowMin: Int, rowMax: Int) {
            self.colMin = colMin
            self.colMax = colMax
            self.rowMin = rowMin
            self.rowMax = rowMax
        }
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

    /// The set of zone ids whose cells lie within the bounding cell-range of
    /// `fromZone` and `toZone` (min..max col, min..max row across both zones'
    /// cells). Powers the drag-span overlay: every zone in the returned set is
    /// highlighted, and for uniform / simple layouts the union of those zones'
    /// rects equals `selectionRect(fromZone:toZone:in:)`.
    ///
    /// A zone is included iff EVERY one of its cells lies inside the bounding
    /// cell-range, so partially-overlapping merged zones that would push the
    /// highlight (and therefore the committed rect) outside the selection box are
    /// excluded — keeping the highlight consistent with `selectionRect`. If either
    /// endpoint is unknown, falls back to the cell-range of the known one; returns
    /// an empty set only when both are unknown.
    static func zonesInSpan(fromZone: Int, toZone: Int, layout: ZoneLayout) -> Set<Int> {
        let fromCells = cells(of: fromZone, in: layout)
        let toCells = cells(of: toZone, in: layout)
        let cellsForBounds = fromCells + toCells
        guard !cellsForBounds.isEmpty else { return [] }

        let minCol = cellsForBounds.map { $0.col }.min()!
        let maxCol = cellsForBounds.map { $0.col }.max()!
        let minRow = cellsForBounds.map { $0.row }.min()!
        let maxRow = cellsForBounds.map { $0.row }.max()!

        // A zone is in the span iff all of its cells fall inside the bounding range.
        var result: Set<Int> = []
        for zoneId in layout.zoneIds {
            let zoneCells = cells(of: zoneId, in: layout)
            guard !zoneCells.isEmpty else { continue }
            let allInside = zoneCells.allSatisfy {
                $0.col >= minCol && $0.col <= maxCol && $0.row >= minRow && $0.row <= maxRow
            }
            if allInside {
                result.insert(zoneId)
            }
        }
        return result
    }

    // MARK: - Proximity span (M-proximity)

    /// The set of zone ids whose rect lies within `radius` (Cocoa points) of
    /// `point`, using point-to-rect distance. Powers the OPTIONAL "span by
    /// proximity" drag mode: position the cursor near where zones meet to span
    /// them without holding the span modifier.
    ///
    /// DISTANCE METRIC (point-to-rect, the standard axis-separated distance):
    ///   dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
    ///   dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
    ///   distance = hypot(dx, dy)
    /// `dx`/`dy` are 0 on the axis the point already overlaps, so a point INSIDE a
    /// rect has distance 0. A zone is included iff `distance <= radius`.
    ///
    /// Behavior with radius:
    /// - deep inside one zone (small radius) -> just that zone (distance 0).
    /// - near a single gridline -> the 2 zones across it (both within radius).
    /// - near a 4-way corner (large enough radius) -> all 4 meeting zones.
    /// - radius 0 -> only the zone(s) containing the point (distance exactly 0).
    /// The zone CONTAINING the point always has distance 0, so when `point` is
    /// inside `area` the result is never empty. A point fully outside `area`
    /// (every zone farther than `radius`) yields an empty set.
    ///
    /// `point` and `area` are both in Cocoa bottom-left coords.
    static func zonesWithinRadius(of point: CGPoint, radius: CGFloat, in area: CGRect, layout: ZoneLayout) -> Set<Int> {
        var result: Set<Int> = []
        let r = max(radius, 0)
        for zoneId in layout.zoneIds {
            let rect = zoneRect(layout: layout, zoneId: zoneId, in: area)
            guard !rect.isNull else { continue }
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            if hypot(dx, dy) <= r {
                result.insert(zoneId)
            }
        }
        return result
    }

    /// The Cocoa-space bounding box (union) of the rects of every zone in
    /// `zones`. Powers the proximity-span commit/preview: the window snaps to the
    /// box enclosing all the zones the cursor was near. Unknown zone ids are
    /// skipped; returns `.null` when `zones` is empty or all-unknown.
    ///
    /// `area` is in Cocoa bottom-left coords.
    static func boundingRect(ofZones zones: Set<Int>, in area: CGRect, layout: ZoneLayout) -> CGRect {
        var union: CGRect = .null
        for zoneId in zones {
            union = union.union(zoneRect(layout: layout, zoneId: zoneId, in: area))
        }
        return union
    }

    /// `boundingRect(ofZones:)` with Rectangle's standard gap inset applied via
    /// `GapCalculation`, matching `zoneRectWithGaps` / `rangeRectWithGaps`. The
    /// shared edges of the span's bounding cell range are computed (`sharedEdges`)
    /// so an edge touching the screen boundary gets a FULL gap while an edge shared
    /// with a neighbouring zone gets a HALF gap — the same accounting the classic
    /// edge-snap path uses (see `sharedEdges` docs). `gapSize` 0 is a no-op.
    static func boundingRectWithGaps(ofZones zones: Set<Int>, in area: CGRect, layout: ZoneLayout, gapSize: Float) -> CGRect {
        gapped(boundingRect(ofZones: zones, in: area, layout: layout),
               sharedEdges: sharedEdges(ofZones: zones, layout: layout), gapSize: gapSize)
    }

    /// `selectionRect(fromZone:toZone:)` with gaps applied using the shared edges of
    /// the selection's bounding cell range, so a drag-span snap insets a FULL gap on
    /// the sides that reach the screen boundary and a HALF gap on the sides shared
    /// with a neighbouring zone — keeping span snaps uniform with single-zone snaps
    /// and with the classic edge path. `gapSize` 0 is a no-op.
    static func selectionRectWithGaps(layout: ZoneLayout, fromZone: Int, toZone: Int, in area: CGRect, gapSize: Float) -> CGRect {
        gapped(selectionRect(layout: layout, fromZone: fromZone, toZone: toZone, in: area),
               sharedEdges: sharedEdges(ofZones: [fromZone, toZone], layout: layout), gapSize: gapSize)
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

    // MARK: - Keyboard navigation: window rect -> target zone

    /// The zone a keyboard "move one zone in `direction`" should land the window in,
    /// or `nil` if there is nowhere to go (the caller no-ops/beeps).
    ///
    /// Two cases, both pure and deterministic:
    ///
    /// 1. **Aligned window** — `rect` matches an existing zone within `tolerance`
    ///    (`zone(matchingWindowRect:)`). The window is "in" that zone, so move to its
    ///    `neighbor` in `direction`. If the matched zone is at the wall in `direction`
    ///    (no neighbor), return `nil` — the window can't move further (per-edge wall
    ///    actions arrive in M8).
    ///
    /// 2. **Unaligned / free window** — `rect` matches no zone. Capture it into the grid
    ///    using the zone under the window's center (`zone(at:)`), then move toward the
    ///    arrow: return that anchor's `neighbor`, falling back to the anchor itself when
    ///    the anchor is already at the wall (so the first press snaps a free window into
    ///    the grid AND nudges it, or captures-to-the-edge-zone when there's no neighbor).
    ///    Returns `nil` only when the center is outside `area` (no anchor zone).
    ///
    /// `rect` and `area` are both in Cocoa bottom-left coords.
    static func targetZone(forWindowRect rect: CGRect, in area: CGRect, layout: ZoneLayout, direction: Direction, tolerance: CGFloat = 25) -> Int? {
        // Case 1: the window already fills a zone — hop to the neighbor (nil at a wall).
        if let currentZone = zone(matchingWindowRect: rect, in: area, layout: layout, tolerance: tolerance) {
            return neighbor(ofZone: currentZone, direction: direction, layout: layout)
        }

        // Case 2: a free window — anchor on the zone under its center, then nudge.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let anchor = zone(at: center, in: area, layout: layout) else { return nil }
        return neighbor(ofZone: anchor, direction: direction, layout: layout) ?? anchor
    }

    // MARK: - Keyboard span: cell range inference + grow

    /// The inclusive cell range a window currently covers, for the keyboard SPAN
    /// actions (M8a — grow the focused window's footprint by one cell-line).
    ///
    /// Two cases, both pure:
    ///
    /// 1. **Aligned window** — `rect`'s bounding box matches some rectangular cell
    ///    range within `tolerance` on all four edges. We try every (colMin..colMax,
    ///    rowMin..rowMax) range, compare its `rangeRect` to `rect`, and return the
    ///    closest match (smallest sum of the four edge deltas), preferring the
    ///    smallest range on ties. This recognizes both a single zone/cell and a
    ///    window the user has already grown across several cells.
    ///
    /// 2. **Unaligned / free window** — no range matches. Fall back to the single
    ///    cell under the window's CENTER (a 1×1 range), so the first SPAN press
    ///    captures the free window onto the grid before growing. Returns `nil` only
    ///    when the center is outside `area` (no cell to anchor on).
    ///
    /// `rect` and `area` are both in Cocoa bottom-left coords. Ranges are in CELL
    /// space (not zone ids), so this composes directly with `grownRange` / `rangeRect`.
    static func cellRange(matchingWindowRect rect: CGRect, in area: CGRect, layout: ZoneLayout, tolerance: CGFloat = 25) -> CellRange? {
        let cols = layout.cols
        let rows = layout.rows
        guard cols > 0, rows > 0 else { return nil }
        guard area.width > 0, area.height > 0 else { return nil }

        // Case 1: best matching cell range within tolerance on every edge.
        var best: CellRange? = nil
        var bestScore = CGFloat.greatestFiniteMagnitude
        for colMin in 0..<cols {
            for colMax in colMin..<cols {
                for rowMin in 0..<rows {
                    for rowMax in rowMin..<rows {
                        let range = CellRange(colMin: colMin, colMax: colMax, rowMin: rowMin, rowMax: rowMax)
                        let rr = rangeRect(range, in: area, layout: layout)
                        guard !rr.isNull else { continue }

                        let dMinX = abs(rr.minX - rect.minX)
                        let dMinY = abs(rr.minY - rect.minY)
                        let dMaxX = abs(rr.maxX - rect.maxX)
                        let dMaxY = abs(rr.maxY - rect.maxY)
                        guard dMinX <= tolerance, dMinY <= tolerance,
                              dMaxX <= tolerance, dMaxY <= tolerance else { continue }

                        let cellCount = (colMax - colMin + 1) * (rowMax - rowMin + 1)
                        // Tie-break on the smaller footprint so an exact single cell
                        // wins over a larger range whose edges also fall within
                        // tolerance, keeping inference tight.
                        let score = dMinX + dMinY + dMaxX + dMaxY + CGFloat(cellCount) * tolerance
                        if score < bestScore {
                            bestScore = score
                            best = range
                        }
                    }
                }
            }
        }
        if let best { return best }

        // Case 2: free window — anchor on the cell under its center (1×1 range).
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard center.x >= area.minX, center.x <= area.maxX,
              center.y >= area.minY, center.y <= area.maxY else { return nil }

        let fx = Double((center.x - area.minX) / area.width)
        let col = cellIndex(for: fx, in: layout.colBoundaries, count: cols)
        let fyFromTop = Double((area.maxY - center.y) / area.height)
        let row = cellIndex(for: fyFromTop, in: layout.rowBoundaries, count: rows)
        return CellRange(colMin: col, colMax: col, rowMin: row, rowMax: row)
    }

    /// Grow a cell range by one cell-line in `direction`, or `nil` if the relevant
    /// edge is already at the grid boundary (GROW-ONLY, M8a).
    ///
    /// - `.left` decrements `colMin` (adds the column to the LEFT); nil at col 0.
    /// - `.right` increments `colMax` (adds the column to the RIGHT); nil at `cols-1`.
    /// - `.up` decrements `rowMin` — row 0 is the TOP, so UP means a SMALLER row
    ///   index; nil when already at row 0.
    /// - `.down` increments `rowMax` (toward the bottom); nil at `rows-1`.
    static func grownRange(_ range: CellRange, direction: Direction, cols: Int, rows: Int) -> CellRange? {
        var grown = range
        switch direction {
        case .left:
            guard range.colMin > 0 else { return nil }
            grown.colMin -= 1
        case .right:
            guard range.colMax < cols - 1 else { return nil }
            grown.colMax += 1
        case .up:
            // Up = toward the TOP = smaller row index (row 0 is the top).
            guard range.rowMin > 0 else { return nil }
            grown.rowMin -= 1
        case .down:
            // Down = toward the BOTTOM = larger row index.
            guard range.rowMax < rows - 1 else { return nil }
            grown.rowMax += 1
        }
        return grown
    }

    /// The Cocoa-space bounding rect of a cell range = the union of its corner
    /// cells `cellRect(colMin, rowMin)` and `cellRect(colMax, rowMax)`.
    ///
    /// Because cells tile the area edge-to-edge, this bounding box covers every cell
    /// in the range exactly (no gaps). Returns `.null` if either corner is out of
    /// range. `area` is the screen's `adjustedVisibleFrame` (bottom-left origin).
    static func rangeRect(_ range: CellRange, in area: CGRect, layout: ZoneLayout) -> CGRect {
        let topLeft = cellRect(layout: layout, col: range.colMin, row: range.rowMin, in: area)
        let bottomRight = cellRect(layout: layout, col: range.colMax, row: range.rowMax, in: area)
        if topLeft.isNull { return bottomRight }
        if bottomRight.isNull { return topLeft }
        return topLeft.union(bottomRight)
    }

    /// `rangeRect` with Lilypad's standard gap inset applied via `GapCalculation`,
    /// matching `zoneRectWithGaps`. The range's shared edges are computed
    /// (`sharedEdges`) so an edge on the screen boundary gets a FULL gap and an edge
    /// shared with a neighbouring cell-line gets a HALF gap, matching the classic
    /// edge-snap accounting. `gapSize` 0 is a no-op.
    static func rangeRectWithGaps(_ range: CellRange, in area: CGRect, layout: ZoneLayout, gapSize: Float) -> CGRect {
        gapped(rangeRect(range, in: area, layout: layout),
               sharedEdges: sharedEdges(colMin: range.colMin, colMax: range.colMax, rowMin: range.rowMin, rowMax: range.rowMax, cols: layout.cols, rows: layout.rows),
               gapSize: gapSize)
    }

    // MARK: - Gap-aware convenience

    /// `zoneRect` with Lilypad's standard gap inset applied via `GapCalculation`.
    ///
    /// The zone's shared edges are computed (`sharedEdges`) so an edge touching the
    /// screen boundary gets a FULL gap and an edge shared with a neighbouring zone a
    /// HALF gap — the same per-edge accounting `SnappingManager.getBoxRect` uses for
    /// the classic edge-snap path. Two adjacent zones therefore leave exactly one
    /// `gapSize` between their windows, matching the gap at the screen edge.
    static func zoneRectWithGaps(layout: ZoneLayout, zoneId: Int, in area: CGRect, gapSize: Float) -> CGRect {
        gapped(zoneRect(layout: layout, zoneId: zoneId, in: area),
               sharedEdges: sharedEdges(ofZone: zoneId, layout: layout), gapSize: gapSize)
    }

    // MARK: - Shared-edge computation (gap accounting)

    /// The edges of a rectangular cell range that are SHARED with a neighbouring
    /// zone (interior to the grid) rather than lying on the screen-`area` boundary.
    ///
    /// Because the grid tiles `area` edge-to-edge with no holes, every edge of a
    /// rectangular region is either on the area boundary — no neighbour, so it takes
    /// a FULL gap — or adjacent to another zone — a neighbour, so it takes a HALF gap
    /// (the two windows together then leave one `gapSize` between them). This is the
    /// grid analogue of `WindowAction.gapSharedEdge`, letting every grid path reuse
    /// the classic edge-snap gap accounting via `GapCalculation.applyGaps`.
    ///
    /// EDGE / ROW CONVENTION (must match `GapCalculation` + `cellRect`): `Edge.top`
    /// is the HIGH-y edge and `Edge.bottom` the LOW-y edge. Row 0 is the TOP of the
    /// screen (largest y), so the range's topmost row is `rowMin` (its `.top` edge)
    /// and its bottommost row is `rowMax` (its `.bottom` edge). A row existing ABOVE
    /// `rowMin` (i.e. `rowMin > 0`) means the top edge is shared; a row BELOW
    /// `rowMax` (`rowMax < rows - 1`) means the bottom edge is shared.
    static func sharedEdges(colMin: Int, colMax: Int, rowMin: Int, rowMax: Int, cols: Int, rows: Int) -> Edge {
        var edges: Edge = .none
        if colMin > 0 { edges.insert(.left) }
        if colMax < cols - 1 { edges.insert(.right) }
        if rowMin > 0 { edges.insert(.top) }
        if rowMax < rows - 1 { edges.insert(.bottom) }
        return edges
    }

    /// The shared edges of a single zone, from its bounding cell range. A merged
    /// zone uses the bounding box of all its cells (zones are rectangular), so the
    /// result is correct for the rect `zoneRect` returns.
    static func sharedEdges(ofZone zoneId: Int, layout: ZoneLayout) -> Edge {
        let zoneCells = cells(of: zoneId, in: layout)
        guard !zoneCells.isEmpty else { return .none }
        let minCol = zoneCells.map { $0.col }.min()!
        let maxCol = zoneCells.map { $0.col }.max()!
        let minRow = zoneCells.map { $0.row }.min()!
        let maxRow = zoneCells.map { $0.row }.max()!
        return sharedEdges(colMin: minCol, colMax: maxCol, rowMin: minRow, rowMax: maxRow, cols: layout.cols, rows: layout.rows)
    }

    /// The shared edges of the bounding cell range of a SET of zones — the same
    /// bounding box `boundingRect` / `selectionRect` produce for that set — so the
    /// gap on each side of a committed span/proximity box is correct. An empty or
    /// all-unknown set has no cells and shares no edges (`.none`).
    static func sharedEdges(ofZones zones: Set<Int>, layout: ZoneLayout) -> Edge {
        var cellsForBounds: [(col: Int, row: Int)] = []
        for zoneId in zones {
            cellsForBounds.append(contentsOf: cells(of: zoneId, in: layout))
        }
        guard !cellsForBounds.isEmpty else { return .none }
        let minCol = cellsForBounds.map { $0.col }.min()!
        let maxCol = cellsForBounds.map { $0.col }.max()!
        let minRow = cellsForBounds.map { $0.row }.min()!
        let maxRow = cellsForBounds.map { $0.row }.max()!
        return sharedEdges(colMin: minCol, colMax: maxCol, rowMin: minRow, rowMax: maxRow, cols: layout.cols, rows: layout.rows)
    }

    /// Apply Lilypad's standard gap inset to a grid rect via `GapCalculation`, in
    /// BOTH dimensions with the given `sharedEdges`. The single home for grid gap
    /// application — `zoneRectWithGaps` / `rangeRectWithGaps` / `boundingRectWithGaps`
    /// / `selectionRectWithGaps` all funnel through here. A null rect or `gapSize <= 0`
    /// is returned unchanged.
    static func gapped(_ rect: CGRect, sharedEdges: Edge, gapSize: Float) -> CGRect {
        guard !rect.isNull, gapSize > 0 else { return rect }
        return GapCalculation.applyGaps(rect, dimension: .both, sharedEdges: sharedEdges, gapSize: gapSize)
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
