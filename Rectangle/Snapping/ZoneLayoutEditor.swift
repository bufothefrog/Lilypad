//
//  ZoneLayoutEditor.swift
//  Rectangle / Lilypad
//
//  M15 (Stage 9b). The PURE edit operations behind the FancyZones-style canvas
//  editor. Every operation takes a `ZoneLayout` and returns a NEW valid
//  `ZoneLayout` (or `nil` when the edit is invalid), never mutating in place,
//  so the editor can run them on a working copy and the runtime keeps consuming
//  whatever was last Saved.
//
//  INVARIANTS every returned layout must keep (the same ones `GridCalculation`
//  assumes — see GridLayoutModel.swift / GridCalculation.swift):
//   - `colBoundaries` / `rowBoundaries` are ASCENDING fractions in 0...1, the
//     first is 0 and the last is 1.
//   - `cellZones.count == cols * rows`.
//   - every zone's set of cells forms an axis-aligned RECTANGLE (no L-shapes).
//
//  GEOMETRY: these operations are about the cell->zone topology and the boundary
//  arrays only. Anything that turns a (col,row) or a zone into a rect is reused
//  from `GridCalculation` — this file never duplicates rect math.
//

import Foundation
import CoreGraphics

extension ZoneLayout {

    /// Fractions within this distance are treated as the same cut line (used to
    /// dedupe an inserted boundary and to detect snap targets). 0.5% of the span.
    static let boundaryEpsilon: Double = 0.005

    /// The default divider snap targets (fractions of the full canvas): the
    /// halves, quarters, sixths and eighths the spec calls out.
    static let defaultSnapCandidates: [Double] = [
        1.0 / 8, 2.0 / 8, 3.0 / 8, 4.0 / 8, 5.0 / 8, 6.0 / 8, 7.0 / 8,
        1.0 / 6, 2.0 / 6, 4.0 / 6, 5.0 / 6,
        1.0 / 4, 3.0 / 4,
        1.0 / 2,
    ]

    // MARK: - Identity helpers

    /// The smallest zone id not currently used, so freshly-split / unmerged cells
    /// get stable, collision-free ids. (Ids only need to be unique within the
    /// layout; `GridCalculation` keys everything off `cellZones`.)
    private func nextFreshZoneId() -> Int {
        (cellZones.max() ?? -1) + 1
    }

    // MARK: - Snapping (divider drag)

    /// The snap target nearest `fraction` within `threshold`, else `fraction`
    /// unchanged. Pure; used live during a divider drag so the dragged boundary
    /// jumps to 1/2 · 1/4 · 1/6 · 1/8 when the cursor gets close.
    static func snapFraction(_ fraction: Double,
                             candidates: [Double] = ZoneLayout.defaultSnapCandidates,
                             threshold: Double = 0.03) -> Double {
        var best = fraction
        var bestDist = threshold
        for candidate in candidates {
            let dist = abs(candidate - fraction)
            if dist <= bestDist {
                bestDist = dist
                best = candidate
            }
        }
        return best
    }

    // MARK: - Add a boundary (split)

    /// Insert a new COLUMN boundary at `fraction` (a vertical cut line), splitting
    /// every column of cells the line crosses into two. Returns `nil` if the
    /// fraction isn't strictly interior (0 < f < 1) or coincides with an existing
    /// boundary within `boundaryEpsilon`.
    ///
    /// Remapping rule: each existing column becomes two columns. A cell that was
    /// its own zone is split into two NEW standalone zones (left part / right
    /// part). A cell that belonged to a MERGED zone keeps that zone's id on both
    /// halves, so the merge survives the cut and the zone stays a rectangle.
    func addingColumnBoundary(at fraction: Double) -> ZoneLayout? {
        guard fraction > Self.boundaryEpsilon, fraction < 1 - Self.boundaryEpsilon else { return nil }
        guard !colBoundaries.contains(where: { abs($0 - fraction) < Self.boundaryEpsilon }) else { return nil }

        // Where does the new line fall among the existing columns?
        let insertAt = colBoundaries.firstIndex(where: { $0 > fraction }) ?? colBoundaries.count
        var newCols = colBoundaries
        newCols.insert(fraction, at: insertAt)
        // The split column index (0-based among the OLD columns) is insertAt - 1.
        let splitCol = insertAt - 1

        let oldCols = cols
        let newColCount = oldCols + 1
        var fresh = nextFreshZoneId()
        // Reserve a fresh id per OLD standalone cell that gets split, so both new
        // halves of a standalone cell become two distinct zones.
        var splitIdForZone: [Int: Int] = [:] // old zone id (only for standalone) -> new right-half id
        // Precompute which zone ids are "standalone" (exactly one cell).
        let cellCounts = zoneCellCounts()

        var newCellZones: [Int] = []
        newCellZones.reserveCapacity(newColCount * rows)
        for row in 0..<rows {
            for col in 0..<newColCount {
                if col <= splitCol {
                    // Left of (and including) the split column maps to the same old column.
                    newCellZones.append(cellZones[row * oldCols + col])
                } else if col == splitCol + 1 {
                    // The RIGHT half of the split column.
                    let oldZone = cellZones[row * oldCols + splitCol]
                    if (cellCounts[oldZone] ?? 0) > 1 {
                        // Part of a merge: keep the merged id (the cut runs through
                        // the merge, which stays one rectangular zone).
                        newCellZones.append(oldZone)
                    } else {
                        // Standalone cell -> a brand new id for the right half.
                        if let id = splitIdForZone[oldZone] {
                            newCellZones.append(id)
                        } else {
                            let id = fresh
                            fresh += 1
                            splitIdForZone[oldZone] = id
                            newCellZones.append(id)
                        }
                    }
                } else {
                    // Right of the split: shift one column over.
                    newCellZones.append(cellZones[row * oldCols + (col - 1)])
                }
            }
        }

        return ZoneLayout(id: id, name: name, colBoundaries: newCols, rowBoundaries: rowBoundaries, cellZones: newCellZones)
    }

    /// Insert a new ROW boundary at `fraction` (a horizontal cut line measured
    /// from the TOP), splitting every row of cells the line crosses into two.
    /// Same remapping rule as `addingColumnBoundary`. Returns `nil` for a
    /// non-interior or duplicate fraction.
    func addingRowBoundary(at fraction: Double) -> ZoneLayout? {
        guard fraction > Self.boundaryEpsilon, fraction < 1 - Self.boundaryEpsilon else { return nil }
        guard !rowBoundaries.contains(where: { abs($0 - fraction) < Self.boundaryEpsilon }) else { return nil }

        let insertAt = rowBoundaries.firstIndex(where: { $0 > fraction }) ?? rowBoundaries.count
        var newRows = rowBoundaries
        newRows.insert(fraction, at: insertAt)
        let splitRow = insertAt - 1

        let colCount = cols
        var fresh = nextFreshZoneId()
        var splitIdForZone: [Int: Int] = [:]
        let cellCounts = zoneCellCounts()

        var newCellZones: [Int] = []
        let newRowCount = rows + 1
        newCellZones.reserveCapacity(colCount * newRowCount)
        for row in 0..<newRowCount {
            for col in 0..<colCount {
                if row <= splitRow {
                    newCellZones.append(cellZones[row * colCount + col])
                } else if row == splitRow + 1 {
                    let oldZone = cellZones[splitRow * colCount + col]
                    if (cellCounts[oldZone] ?? 0) > 1 {
                        newCellZones.append(oldZone)
                    } else if let id = splitIdForZone[oldZone] {
                        newCellZones.append(id)
                    } else {
                        let id = fresh
                        fresh += 1
                        splitIdForZone[oldZone] = id
                        newCellZones.append(id)
                    }
                } else {
                    newCellZones.append(cellZones[(row - 1) * colCount + col])
                }
            }
        }

        return ZoneLayout(id: id, name: name, colBoundaries: colBoundaries, rowBoundaries: newRows, cellZones: newCellZones)
    }

    // MARK: - Remove a boundary (collapse two cell tracks)

    /// Drop the INTERIOR column boundary at `boundaryIndex` (1...cols-1),
    /// collapsing the two adjacent columns into one. The merged column's cells
    /// take a deterministic single zone id: for each row the LEFT cell's id wins,
    /// and every cell in either old column that shared an id with the absorbed
    /// (right) cell is repointed to the survivor, so a merged zone that straddled
    /// the removed line stays a single rectangle.
    ///
    /// Returns `nil` for the 0 / last (edge) boundaries, an out-of-range index, OR
    /// when the collapse would tear a zone into a non-rectangle. The latter happens
    /// when a single MERGED zone straddles the removed line across multiple rows
    /// with DIFFERENT left-column survivors: the per-row left-wins rewrite can only
    /// repoint that merged id to one survivor, so its cells in a KEPT column would
    /// split between survivors and form an L. Rather than return an invalid layout
    /// (violating this op's "valid or nil" contract), we validate the result and
    /// return `nil` so the caller can report "that divider can't be removed".
    func removingColumnBoundary(at boundaryIndex: Int) -> ZoneLayout? {
        guard boundaryIndex >= 1, boundaryIndex <= cols - 1 else { return nil }
        // The two columns sharing that boundary are (boundaryIndex - 1) and boundaryIndex.
        let leftCol = boundaryIndex - 1
        let rightCol = boundaryIndex
        let oldCols = cols

        var newBoundaries = colBoundaries
        newBoundaries.remove(at: boundaryIndex)

        // Build the collapsed grid, keeping the LEFT column's id per row and
        // recording right->left id rewrites so straddling merges stay coherent.
        var idRewrite: [Int: Int] = [:]
        var collapsed: [Int] = []
        let newColCount = oldCols - 1
        collapsed.reserveCapacity(newColCount * rows)
        for row in 0..<rows {
            let leftId = cellZones[row * oldCols + leftCol]
            let rightId = cellZones[row * oldCols + rightCol]
            if leftId != rightId {
                idRewrite[rightId] = leftId
            }
            for col in 0..<oldCols where col != rightCol {
                collapsed.append(cellZones[row * oldCols + col])
            }
        }
        // Apply the rewrites (a right-column id everywhere it appears becomes its
        // row's left-column id, so the absorbed cells merge into the survivor).
        let rewritten = collapsed.map { resolveRewrite($0, in: idRewrite) }

        let result = ZoneLayout(id: id, name: name, colBoundaries: newBoundaries, rowBoundaries: rowBoundaries, cellZones: normalizedRectangularZones(rewritten, cols: newColCount, rows: rows))
        // Guard the rectangularity invariant: a straddling multi-row merge can be
        // torn into an L by the single-survivor rewrite. Never return an invalid layout.
        guard result.isValid else { return nil }
        return result
    }

    /// Drop the INTERIOR row boundary at `boundaryIndex` (1...rows-1), collapsing
    /// the two adjacent rows into one (the TOP row's id wins per column). Returns
    /// `nil` for edge / out-of-range boundaries, OR when the collapse would tear a
    /// zone into a non-rectangle (the symmetric case to `removingColumnBoundary`: a
    /// merged zone straddling the removed line across multiple columns with
    /// different top-row survivors). Validates the result and returns `nil` rather
    /// than ever returning an invalid layout.
    func removingRowBoundary(at boundaryIndex: Int) -> ZoneLayout? {
        guard boundaryIndex >= 1, boundaryIndex <= rows - 1 else { return nil }
        let topRow = boundaryIndex - 1
        let bottomRow = boundaryIndex
        let colCount = cols

        var newBoundaries = rowBoundaries
        newBoundaries.remove(at: boundaryIndex)

        var idRewrite: [Int: Int] = [:]
        for col in 0..<colCount {
            let topId = cellZones[topRow * colCount + col]
            let bottomId = cellZones[bottomRow * colCount + col]
            if topId != bottomId {
                idRewrite[bottomId] = topId
            }
        }

        var collapsed: [Int] = []
        let newRowCount = rows - 1
        collapsed.reserveCapacity(colCount * newRowCount)
        for row in 0..<rows where row != bottomRow {
            for col in 0..<colCount {
                collapsed.append(cellZones[row * colCount + col])
            }
        }
        let rewritten = collapsed.map { resolveRewrite($0, in: idRewrite) }

        let result = ZoneLayout(id: id, name: name, colBoundaries: colBoundaries, rowBoundaries: newBoundaries, cellZones: normalizedRectangularZones(rewritten, cols: colCount, rows: newRowCount))
        // Guard the rectangularity invariant (see removingColumnBoundary).
        guard result.isValid else { return nil }
        return result
    }

    // MARK: - Move a boundary (geometry only)

    /// Move the interior column boundary at `boundaryIndex` (1...cols-1) to
    /// `fraction`, clamped STRICTLY between its neighbors (so boundaries stay
    /// strictly ascending and no column collapses). No `cellZones` change — this
    /// is pure geometry, used live during a divider drag. Returns `nil` for an
    /// edge / out-of-range index.
    func movingColumnBoundary(at boundaryIndex: Int, to fraction: Double) -> ZoneLayout? {
        guard boundaryIndex >= 1, boundaryIndex <= colBoundaries.count - 2 else { return nil }
        let lower = colBoundaries[boundaryIndex - 1] + Self.boundaryEpsilon
        let upper = colBoundaries[boundaryIndex + 1] - Self.boundaryEpsilon
        guard lower < upper else { return nil }
        let clamped = min(max(fraction, lower), upper)
        var newBoundaries = colBoundaries
        newBoundaries[boundaryIndex] = clamped
        return ZoneLayout(id: id, name: name, colBoundaries: newBoundaries, rowBoundaries: rowBoundaries, cellZones: cellZones)
    }

    /// Move the interior row boundary at `boundaryIndex` (1...rows-1) to
    /// `fraction`, clamped strictly between its neighbors. Geometry only. Returns
    /// `nil` for an edge / out-of-range index.
    func movingRowBoundary(at boundaryIndex: Int, to fraction: Double) -> ZoneLayout? {
        guard boundaryIndex >= 1, boundaryIndex <= rowBoundaries.count - 2 else { return nil }
        let lower = rowBoundaries[boundaryIndex - 1] + Self.boundaryEpsilon
        let upper = rowBoundaries[boundaryIndex + 1] - Self.boundaryEpsilon
        guard lower < upper else { return nil }
        let clamped = min(max(fraction, lower), upper)
        var newBoundaries = rowBoundaries
        newBoundaries[boundaryIndex] = clamped
        return ZoneLayout(id: id, name: name, colBoundaries: colBoundaries, rowBoundaries: newBoundaries, cellZones: cellZones)
    }

    // MARK: - Merge / unmerge

    /// True iff the union of every zone in `zoneIds`'s cells forms a SOLID
    /// axis-aligned rectangle — i.e. every cell inside the bounding cell-range of
    /// the selection belongs to the selection. An L-shape / disjoint pick is
    /// false (and `merge` returns nil). A single zone is trivially true.
    func canMerge(_ zoneIds: Set<Int>) -> Bool {
        guard !zoneIds.isEmpty else { return false }
        let selectionCells = cellIndices(forZones: zoneIds)
        guard !selectionCells.isEmpty else { return false }

        let colCount = cols
        let coords = selectionCells.map { (col: $0 % colCount, row: $0 / colCount) }
        let minCol = coords.map { $0.col }.min()!
        let maxCol = coords.map { $0.col }.max()!
        let minRow = coords.map { $0.row }.min()!
        let maxRow = coords.map { $0.row }.max()!

        // Every cell in the bounding range must be in the selection (solid rect),
        // AND no selected zone may have a cell outside the range (it would have
        // expanded the range, but a partially-overlapping merged zone could still
        // poke out — guard explicitly).
        let selected = Set(selectionCells)
        for row in minRow...maxRow {
            for col in minCol...maxCol {
                if !selected.contains(row * colCount + col) { return false }
            }
        }
        return true
    }

    /// Merge every zone in `zoneIds` into ONE zone (the smallest id in the
    /// selection wins, for determinism) when `canMerge`; otherwise `nil`.
    func merging(_ zoneIds: Set<Int>) -> ZoneLayout? {
        guard canMerge(zoneIds) else { return nil }
        let survivor = zoneIds.min()!
        let newCellZones = cellZones.map { zoneIds.contains($0) ? survivor : $0 }
        return ZoneLayout(id: id, name: name, colBoundaries: colBoundaries, rowBoundaries: rowBoundaries, cellZones: newCellZones)
    }

    /// Split a merged zone back into its individual cells — each cell of
    /// `zoneId` gets its own fresh unique id (the first cell keeps the original
    /// id so a single-cell zone is a no-op). Returns `nil` if no cell carries
    /// `zoneId`.
    func unmerging(_ zoneId: Int) -> ZoneLayout? {
        let indices = cellIndices(forZones: [zoneId])
        guard !indices.isEmpty else { return nil }
        guard indices.count > 1 else { return self } // already a single cell — no-op

        var fresh = nextFreshZoneId()
        var newCellZones = cellZones
        for (offset, index) in indices.enumerated() {
            if offset == 0 {
                newCellZones[index] = zoneId // keep the first cell's id
            } else {
                newCellZones[index] = fresh
                fresh += 1
            }
        }
        return ZoneLayout(id: id, name: name, colBoundaries: colBoundaries, rowBoundaries: rowBoundaries, cellZones: newCellZones)
    }

    // MARK: - Validation

    /// True iff this layout satisfies every invariant the runtime assumes:
    /// boundaries strictly ascending in 0...1 (first 0, last 1), correct
    /// `cellZones` length, and every zone's cells forming a rectangle.
    var isValid: Bool {
        guard cols >= 1, rows >= 1 else { return false }
        guard cellZones.count == cols * rows else { return false }
        guard Self.boundariesValid(colBoundaries), Self.boundariesValid(rowBoundaries) else { return false }
        // Every zone must be a solid rectangle.
        for zoneId in zoneIds {
            if !canMerge([zoneId]) { return false }
        }
        return true
    }

    private static func boundariesValid(_ b: [Double]) -> Bool {
        guard b.count >= 2 else { return false }
        guard abs(b.first! - 0) < 1e-9, abs(b.last! - 1) < 1e-9 else { return false }
        for i in 1..<b.count where b[i] <= b[i - 1] { return false }
        return true
    }

    // MARK: - Private cell helpers

    /// The flat `cellZones` indices belonging to any zone in `zoneIds`.
    private func cellIndices(forZones zoneIds: Set<Int>) -> [Int] {
        cellZones.enumerated().compactMap { zoneIds.contains($0.element) ? $0.offset : nil }
    }

    /// Map of zone id -> number of cells it covers.
    private func zoneCellCounts() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for z in cellZones { counts[z, default: 0] += 1 }
        return counts
    }

    /// Follow a rewrite chain to its terminal id (rewrites are shallow here, but
    /// chase transitively to be safe against a < b < c collapse sequence).
    private func resolveRewrite(_ id: Int, in rewrite: [Int: Int]) -> Int {
        var current = id
        var guardCounter = 0
        while let next = rewrite[current], next != current, guardCounter < 1024 {
            current = next
            guardCounter += 1
        }
        return current
    }

    /// After a collapse, two previously-distinct rectangles can become adjacent
    /// but keep different ids even though they now form one solid rectangle that
    /// SHOULD stay separate — so we do NOT auto-merge. This helper only guarantees
    /// the array is returned as-is; it exists as the single seam where a future
    /// normalization could hook in, and documents that collapse preserves caller
    /// ids verbatim.
    private func normalizedRectangularZones(_ zones: [Int], cols: Int, rows: Int) -> [Int] {
        zones
    }
}
