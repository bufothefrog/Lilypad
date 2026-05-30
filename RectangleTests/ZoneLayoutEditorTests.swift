//
//  ZoneLayoutEditorTests.swift
//  RectangleTests / Lilypad
//
//  M15 verification — the PURE FancyZones edit operations on `ZoneLayout`
//  (ZoneLayoutEditor.swift) and `GridModel.updateLayout`. Each test asserts the
//  RESULT keeps every runtime invariant: boundaries ascending in 0...1,
//  `cellZones.count == cols * rows`, and every zone's cells forming a rectangle
//  (checked via `isValid`). Covers split, remove, move-clamp, snapping,
//  canMerge true/false, merge/unmerge round-trip, and the model write-back.
//

import XCTest
@testable import Rectangle

class ZoneLayoutEditorTests: XCTestCase {

    private let eps = 1e-9

    // MARK: - Fixtures

    /// A single full-screen cell (1×1, one zone).
    private func single() -> ZoneLayout {
        ZoneLayout.uniform(cols: 1, rows: 1, id: "s", name: "s")
    }

    /// 2×2 identity grid: zones 0 1 / 2 3 (row-major, row 0 on top).
    private func grid2x2() -> ZoneLayout {
        ZoneLayout.uniform(cols: 2, rows: 2, id: "g", name: "g")
    }

    /// 3×2 with the two TOP cells merged into one zone (id 0). Mirrors the
    /// existing GridLayoutModelTests sample.
    private func merged3x2() -> ZoneLayout {
        ZoneLayout(
            id: "m", name: "m",
            colBoundaries: [0, 1.0 / 3, 2.0 / 3, 1],
            rowBoundaries: [0, 0.5, 1],
            cellZones: [0, 0, 1,
                        2, 3, 4]
        )
    }

    private func assertValid(_ layout: ZoneLayout, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(layout.isValid, "expected a valid layout: \(layout.colBoundaries) \(layout.rowBoundaries) \(layout.cellZones)", file: file, line: line)
        XCTAssertEqual(layout.cellZones.count, layout.cols * layout.rows, "cellZones length", file: file, line: line)
        // boundaries strictly ascending, bracketed by 0 and 1
        for arr in [layout.colBoundaries, layout.rowBoundaries] {
            XCTAssertEqual(arr.first!, 0, accuracy: eps, file: file, line: line)
            XCTAssertEqual(arr.last!, 1, accuracy: eps, file: file, line: line)
            for i in 1..<arr.count { XCTAssertGreaterThan(arr[i], arr[i - 1], file: file, line: line) }
        }
    }

    // MARK: - Snapping

    func testSnapWithinThresholdJumpsToCandidate() {
        // Near 1/2.
        XCTAssertEqual(ZoneLayout.snapFraction(0.49), 0.5, accuracy: eps)
        // Near 1/4.
        XCTAssertEqual(ZoneLayout.snapFraction(0.26), 0.25, accuracy: eps)
        // Near 1/8.
        XCTAssertEqual(ZoneLayout.snapFraction(0.13), 0.125, accuracy: eps)
        // Near 1/6.
        XCTAssertEqual(ZoneLayout.snapFraction(0.17), 1.0 / 6, accuracy: eps)
    }

    func testSnapOutsideThresholdReturnsInput() {
        // 0.40 is >0.03 from every candidate (3/8=0.375 is 0.025 away => actually snaps).
        // Use a value clearly between candidates: 0.45 is 0.05 from 0.5 and 0.075 from 0.375.
        XCTAssertEqual(ZoneLayout.snapFraction(0.45), 0.45, accuracy: eps)
    }

    func testSnapPicksNearestCandidate() {
        // 0.255 is closer to 0.25 than to anything else.
        XCTAssertEqual(ZoneLayout.snapFraction(0.255), 0.25, accuracy: eps)
    }

    // MARK: - Add column boundary (split)

    func testSplit1x1IntoTwoColumns() {
        let result = single().addingColumnBoundary(at: 0.5)
        XCTAssertNotNil(result)
        let layout = result!
        assertValid(layout)
        XCTAssertEqual(layout.cols, 2)
        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(layout.colBoundaries, [0, 0.5, 1])
        // Two cells, two distinct new zone ids.
        XCTAssertEqual(layout.cellZones.count, 2)
        XCTAssertEqual(Set(layout.cellZones).count, 2)
    }

    func testSplit1x1IntoTwoRows() {
        let result = single().addingRowBoundary(at: 0.5)
        XCTAssertNotNil(result)
        let layout = result!
        assertValid(layout)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.cols, 1)
        XCTAssertEqual(layout.rowBoundaries, [0, 0.5, 1])
        XCTAssertEqual(Set(layout.cellZones).count, 2)
    }

    func testAddColumnRejectsNonInteriorFraction() {
        XCTAssertNil(single().addingColumnBoundary(at: 0))
        XCTAssertNil(single().addingColumnBoundary(at: 1))
        XCTAssertNil(single().addingColumnBoundary(at: -0.2))
        XCTAssertNil(single().addingColumnBoundary(at: 1.5))
    }

    func testAddColumnRejectsDuplicateBoundary() {
        // 2×2 already has a boundary at 0.5.
        XCTAssertNil(grid2x2().addingColumnBoundary(at: 0.5))
        XCTAssertNil(grid2x2().addingColumnBoundary(at: 0.5 + ZoneLayout.boundaryEpsilon / 2))
    }

    func testSplitColumnThroughAMergedZoneKeepsMergeOneRectangle() {
        // merged3x2: top row is one merged zone (id 0) spanning cols 0..1.
        // Adding a column line at 1/6 cuts THROUGH the merged zone's first column.
        let result = merged3x2().addingColumnBoundary(at: 1.0 / 6)
        XCTAssertNotNil(result)
        let layout = result!
        assertValid(layout)
        XCTAssertEqual(layout.cols, 4)
        // The merged zone must still be ONE rectangular zone (it absorbed the new cell).
        let mergedCells = layout.cellZones.enumerated().filter { $0.element == 0 }
        // It originally covered 2 cells in the top row; after splitting one of those
        // columns it now covers 3 top-row cells, still a single id and a rectangle.
        XCTAssertEqual(mergedCells.count, 3)
        XCTAssertTrue(layout.canMerge([0]))
    }

    func testSplitColumnIncrementsCellCountByRows() {
        let layout = grid2x2().addingColumnBoundary(at: 0.25)!
        assertValid(layout)
        // 2×2 -> 3×2 => 6 cells.
        XCTAssertEqual(layout.cellZones.count, 6)
        XCTAssertEqual(layout.cols, 3)
        // No merges in a fresh grid: every standalone cell split into two zones,
        // so there are 6 distinct zone ids.
        XCTAssertEqual(Set(layout.cellZones).count, 6)
    }

    // MARK: - Remove boundary (collapse)

    func testRemoveColumnBoundaryCollapsesTwoColumns() {
        let layout = grid2x2().removingColumnBoundary(at: 1)!
        assertValid(layout)
        XCTAssertEqual(layout.cols, 1)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.colBoundaries, [0, 1])
        XCTAssertEqual(layout.cellZones.count, 2)
    }

    func testRemoveRowBoundaryCollapsesTwoRows() {
        let layout = grid2x2().removingRowBoundary(at: 1)!
        assertValid(layout)
        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(layout.cols, 2)
        XCTAssertEqual(layout.rowBoundaries, [0, 1])
    }

    func testRemoveEdgeBoundaryIsRejected() {
        XCTAssertNil(grid2x2().removingColumnBoundary(at: 0))  // left edge
        XCTAssertNil(grid2x2().removingColumnBoundary(at: 2))  // right edge
        XCTAssertNil(grid2x2().removingRowBoundary(at: 0))
        XCTAssertNil(grid2x2().removingRowBoundary(at: 2))
    }

    func testRemoveColumnBoundaryThroughMergeKeepsRectangle() {
        // merged3x2: removing the interior column boundary at index 1 collapses
        // cols 0 and 1; the merged top zone (id 0 spanning both) stays one zone.
        let layout = merged3x2().removingColumnBoundary(at: 1)!
        assertValid(layout)
        XCTAssertEqual(layout.cols, 2)
        XCTAssertTrue(layout.canMerge([0]))
    }

    func testRemoveColumnBoundaryThroughStraddlingMergeReturnsNil() {
        // 3×2: zone 1 is a 2×2 block over cols 1-2 (both rows); zones 0 and 3 are
        // the standalone left-column cells. Removing the boundary at index 1 (cols
        // 0 and 1) would have to repoint zone 1 to BOTH survivor 0 (row 0) and
        // survivor 3 (row 1) — impossible with one id, so the collapse would tear
        // zone 1 into an L. The op must reject it (return nil), not return an
        // invalid layout. (Repro from review finding CASE-G.)
        let layout = ZoneLayout(
            id: "g", name: "g",
            colBoundaries: [0, 1.0 / 3, 2.0 / 3, 1],
            rowBoundaries: [0, 0.5, 1],
            cellZones: [0, 1, 1,
                        3, 1, 1]
        )
        XCTAssertTrue(layout.isValid, "fixture should start valid")
        XCTAssertNil(layout.removingColumnBoundary(at: 1))
    }

    func testRemoveRowBoundaryThroughStraddlingMergeReturnsNil() {
        // Symmetric to the column case: 2×3, zone 8 is a 2×2 block over rows 1-2
        // (both cols); zones 0 and 1 are the standalone top-row cells. Removing the
        // boundary at index 1 (rows 0 and 1) would tear zone 8 into an L. Reject.
        let layout = ZoneLayout(
            id: "g", name: "g",
            colBoundaries: [0, 0.5, 1],
            rowBoundaries: [0, 1.0 / 3, 2.0 / 3, 1],
            cellZones: [0, 1,
                        8, 8,
                        8, 8]
        )
        XCTAssertTrue(layout.isValid, "fixture should start valid")
        XCTAssertNil(layout.removingRowBoundary(at: 1))
    }

    func testRemoveColumnBoundaryThroughStraddlingMergeWiderGridReturnsNil() {
        // 4×3 with zone 7 a 2×2 block over cols 1-2, rows 0-1 (the review's other
        // repro). Removing boundary at index 1 tears zone 7 into an L. Reject.
        let layout = ZoneLayout(
            id: "g", name: "g",
            colBoundaries: [0, 0.25, 0.5, 0.75, 1],
            rowBoundaries: [0, 1.0 / 3, 2.0 / 3, 1],
            cellZones: [0, 7, 7, 3,
                        1, 7, 7, 8,
                        4, 2, 9, 6]
        )
        XCTAssertTrue(layout.isValid, "fixture should start valid")
        XCTAssertNil(layout.removingColumnBoundary(at: 1))
    }

    func testRemoveRowBoundaryThroughMergeConfinedToCollapsedRowsKeepsRectangle() {
        // POSITIVE case: a merge that straddles the removed line but is confined to
        // exactly the two collapsed tracks (and shares the same per-column survivor)
        // stays one rectangle. 2×2 with the LEFT column (rows 0+1) merged into one
        // zone (id 0): removing the row boundary collapses the two rows; zone 0
        // stays a single 1×1 cell, zone 1 and zone 3 collapse into their column.
        let layout = ZoneLayout(
            id: "g", name: "g",
            colBoundaries: [0, 0.5, 1],
            rowBoundaries: [0, 0.5, 1],
            cellZones: [0, 1,
                        0, 3]
        )
        XCTAssertTrue(layout.isValid)
        let collapsed = layout.removingRowBoundary(at: 1)!
        assertValid(collapsed)
        XCTAssertEqual(collapsed.rows, 1)
        XCTAssertEqual(collapsed.cols, 2)
    }

    // MARK: - Move boundary (clamp, geometry only)

    func testMoveColumnBoundaryClampsBetweenNeighbors() {
        let base = ZoneLayout.uniform(cols: 3, rows: 1, id: "u", name: "u") // boundaries 0, 1/3, 2/3, 1
        // Move boundary index 1 (1/3) far past its right neighbor (2/3) — clamps just under it.
        let moved = base.movingColumnBoundary(at: 1, to: 0.95)!
        assertValid(moved)
        XCTAssertLessThan(moved.colBoundaries[1], moved.colBoundaries[2])
        XCTAssertEqual(moved.colBoundaries[1], 2.0 / 3 - ZoneLayout.boundaryEpsilon, accuracy: 1e-6)
        // cellZones unchanged (geometry only).
        XCTAssertEqual(moved.cellZones, base.cellZones)
    }

    func testMoveColumnBoundaryClampsAtLowerNeighbor() {
        let base = ZoneLayout.uniform(cols: 3, rows: 1, id: "u", name: "u")
        let moved = base.movingColumnBoundary(at: 2, to: 0.0)!
        XCTAssertGreaterThan(moved.colBoundaries[2], moved.colBoundaries[1])
        XCTAssertEqual(moved.colBoundaries[2], 1.0 / 3 + ZoneLayout.boundaryEpsilon, accuracy: 1e-6)
    }

    func testMoveEdgeBoundaryIsRejected() {
        let base = grid2x2()
        XCTAssertNil(base.movingColumnBoundary(at: 0, to: 0.1))
        XCTAssertNil(base.movingColumnBoundary(at: 2, to: 0.9))
        XCTAssertNil(base.movingRowBoundary(at: 0, to: 0.1))
        XCTAssertNil(base.movingRowBoundary(at: 2, to: 0.9))
    }

    func testMoveRowBoundaryWithinRangeIsUnclamped() {
        let base = grid2x2() // row boundary at 0.5, neighbors 0 and 1
        // 0.9 is below the upper clamp (1 - eps), so it lands exactly there.
        let moved = base.movingRowBoundary(at: 1, to: 0.9)!
        assertValid(moved)
        XCTAssertEqual(moved.rowBoundaries[1], 0.9, accuracy: 1e-6)
    }

    func testMoveRowBoundaryClampsAtUpperNeighbor() {
        let base = grid2x2() // row boundary at 0.5, upper neighbor is the edge (1).
        // Asking for 1.5 (past the bottom edge) clamps just under 1.
        let moved = base.movingRowBoundary(at: 1, to: 1.5)!
        assertValid(moved)
        XCTAssertEqual(moved.rowBoundaries[1], 1.0 - ZoneLayout.boundaryEpsilon, accuracy: 1e-6)
    }

    // MARK: - canMerge

    func testCanMergeTrueForRectangle() {
        // 2×2: merging the two TOP zones (0 and 1) forms a 2×1 rectangle.
        XCTAssertTrue(grid2x2().canMerge([0, 1]))
        // The two LEFT zones (0 and 2) form a 1×2 rectangle.
        XCTAssertTrue(grid2x2().canMerge([0, 2]))
        // All four zones -> the whole rectangle.
        XCTAssertTrue(grid2x2().canMerge([0, 1, 2, 3]))
        // A single zone is trivially a rectangle.
        XCTAssertTrue(grid2x2().canMerge([0]))
    }

    func testCanMergeFalseForLShape() {
        // 2×2: zones 0 (top-left), 1 (top-right), 2 (bottom-left) form an L —
        // the bottom-right cell (zone 3) is missing from the bounding box.
        XCTAssertFalse(grid2x2().canMerge([0, 1, 2]))
        // Diagonal pair (0 top-left, 3 bottom-right) is not solid.
        XCTAssertFalse(grid2x2().canMerge([0, 3]))
    }

    func testCanMergeFalseForEmptySelection() {
        XCTAssertFalse(grid2x2().canMerge([]))
    }

    // MARK: - merge / unmerge round trip

    func testMergeRejectsNonRectangle() {
        XCTAssertNil(grid2x2().merging([0, 1, 2])) // L-shape
        XCTAssertNil(grid2x2().merging([0, 3]))    // diagonal
    }

    func testMergeThenUnmergeRoundTrips() {
        let base = grid2x2()
        // Merge the top row (0,1) into one zone.
        let merged = base.merging([0, 1])!
        assertValid(merged)
        // The merged zone now spans 2 cells.
        let survivorId = merged.cellZones[0] // top-left after merge
        XCTAssertEqual(merged.cellZones.filter { $0 == survivorId }.count, 2)
        // 3 distinct zones now (merged-top, bottom-left, bottom-right).
        XCTAssertEqual(merged.zoneIds.count, 3)

        // Unmerge it back into individual cells.
        let unmerged = merged.unmerging(survivorId)!
        assertValid(unmerged)
        // Back to 4 distinct zones, each a single cell.
        XCTAssertEqual(unmerged.zoneIds.count, 4)
        for z in unmerged.zoneIds {
            XCTAssertEqual(unmerged.cellZones.filter { $0 == z }.count, 1)
        }
        // Geometry is unchanged by merge/unmerge (only ids moved).
        XCTAssertEqual(unmerged.colBoundaries, base.colBoundaries)
        XCTAssertEqual(unmerged.rowBoundaries, base.rowBoundaries)
    }

    func testMergePicksDeterministicSurvivorId() {
        // The smallest id in the selection wins.
        let merged = grid2x2().merging([3, 2])! // bottom row, ids 2 and 3
        assertValid(merged)
        XCTAssertEqual(merged.cellZones[2], 2) // bottom-left keeps id 2 (the min)
        XCTAssertEqual(merged.cellZones[3], 2)
    }

    func testUnmergeSingleCellIsNoOp() {
        let base = grid2x2()
        let result = base.unmerging(0)! // zone 0 is a single cell
        XCTAssertEqual(result, base)
    }

    func testUnmergeUnknownZoneReturnsNil() {
        XCTAssertNil(grid2x2().unmerging(999))
    }

    // MARK: - isValid catches a hand-built bad layout

    func testIsValidRejectsNonRectangularZone() {
        // Hand-build an L-shaped zone (id 0 in top-left, top-right, bottom-left).
        let bad = ZoneLayout(
            id: "bad", name: "bad",
            colBoundaries: [0, 0.5, 1],
            rowBoundaries: [0, 0.5, 1],
            cellZones: [0, 0,
                        0, 1]
        )
        XCTAssertFalse(bad.isValid)
    }

    func testIsValidRejectsWrongCellCount() {
        let bad = ZoneLayout(
            id: "bad", name: "bad",
            colBoundaries: [0, 0.5, 1],
            rowBoundaries: [0, 1],
            cellZones: [0] // should be length 2
        )
        XCTAssertFalse(bad.isValid)
    }

    func testIsValidRejectsNonAscendingBoundaries() {
        let bad = ZoneLayout(
            id: "bad", name: "bad",
            colBoundaries: [0, 0.5, 0.5, 1],
            rowBoundaries: [0, 1],
            cellZones: [0, 1, 2]
        )
        XCTAssertFalse(bad.isValid)
    }
}

// MARK: - GridModel.updateLayout

class GridModelUpdateLayoutTests: XCTestCase {

    private let model = GridModel.instance
    private let uuid = "test-update-uuid-\(UUID().uuidString)"

    override func tearDown() {
        Defaults.gridLayoutsByDisplay.typedValue = nil
        UserDefaults.standard.removeObject(forKey: "gridLayoutsByDisplay")
        super.tearDown()
    }

    func testUpdateLayoutOverwritesGeometryPreservingNameAndActive() {
        let original = ZoneLayout.uniform(cols: 2, rows: 1, id: "L", name: "My Layout")
        model.addLayout(original, forDisplay: uuid)
        // Add a second layout and make the first active to prove active is preserved.
        model.addLayout(ZoneLayout.uniform(cols: 2, rows: 2, id: "L2", name: "Other"), forDisplay: uuid)
        model.setActiveLayout(id: "L", forDisplay: uuid)

        // Edit "L" into a 3-column layout.
        let edited = original.addingColumnBoundary(at: 0.25)!
        model.updateLayout(id: "L",
                           colBoundaries: edited.colBoundaries,
                           rowBoundaries: edited.rowBoundaries,
                           cellZones: edited.cellZones,
                           forDisplay: uuid)

        let stored = model.layouts(forDisplay: uuid).layouts.first(where: { $0.id == "L" })!
        XCTAssertEqual(stored.colBoundaries, edited.colBoundaries)
        XCTAssertEqual(stored.cellZones, edited.cellZones)
        // Name + active status preserved.
        XCTAssertEqual(stored.name, "My Layout")
        XCTAssertEqual(model.layouts(forDisplay: uuid).activeLayoutId, "L")
    }

    func testUpdateLayoutConvenienceOverloadMatchesById() {
        let original = ZoneLayout.uniform(cols: 1, rows: 1, id: "Z", name: "Z")
        model.addLayout(original, forDisplay: uuid)
        var edited = original.addingRowBoundary(at: 0.5)!
        // Even if the passed-in name differs, the stored name is preserved.
        edited.name = "ignored-name"
        model.updateLayout(edited, forDisplay: uuid)

        let stored = model.layouts(forDisplay: uuid).layouts.first!
        XCTAssertEqual(stored.rows, 2)
        XCTAssertEqual(stored.name, "Z") // preserved, not overwritten
    }

    func testUpdateUnknownLayoutIsNoOp() {
        model.addLayout(ZoneLayout.uniform(cols: 1, rows: 1, id: "Z", name: "Z"), forDisplay: uuid)
        model.updateLayout(id: "nope", colBoundaries: [0, 1], rowBoundaries: [0, 1], cellZones: [0], forDisplay: uuid)
        // The real layout is untouched.
        XCTAssertEqual(model.layouts(forDisplay: uuid).layouts.map { $0.id }, ["Z"])
    }
}
