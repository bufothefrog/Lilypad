//
//  ZoneLayoutEditorTests.swift
//  LilypadTests
//
//  M15 verification — the PURE FancyZones edit operations on `ZoneLayout`
//  (ZoneLayoutEditor.swift) and `GridModel.updateLayout`. Each test asserts the
//  RESULT keeps every runtime invariant: boundaries ascending in 0...1,
//  `cellZones.count == cols * rows`, and every zone's cells forming a rectangle
//  (checked via `isValid`). Covers split, remove, move-clamp, snapping,
//  canMerge true/false, merge/unmerge round-trip, and the model write-back.
//

import XCTest
@testable import Lilypad

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

// MARK: - Ratio operations (parse + set + read)

class ZoneLayoutRatioTests: XCTestCase {

    private let eps = 1e-9

    private func grid2x2() -> ZoneLayout {
        ZoneLayout.uniform(cols: 2, rows: 2, id: "g", name: "g")
    }

    /// 3×2 with the two TOP cells merged into one zone (id 0).
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
        for arr in [layout.colBoundaries, layout.rowBoundaries] {
            XCTAssertEqual(arr.first!, 0, accuracy: eps, file: file, line: line)
            XCTAssertEqual(arr.last!, 1, accuracy: eps, file: file, line: line)
            for i in 1..<arr.count { XCTAssertGreaterThan(arr[i], arr[i - 1], file: file, line: line) }
        }
    }

    // MARK: parseRatios

    func testParseColonSeparated() {
        XCTAssertEqual(ZoneLayout.parseRatios("1:2:1")!, [1, 2, 1])
        XCTAssertEqual(ZoneLayout.parseRatios("2:3:2")!, [2, 3, 2])
    }

    func testParseAcceptsSpacesAndCommas() {
        XCTAssertEqual(ZoneLayout.parseRatios("1 2 1")!, [1, 2, 1])
        XCTAssertEqual(ZoneLayout.parseRatios("1, 2, 1")!, [1, 2, 1])
        XCTAssertEqual(ZoneLayout.parseRatios(" 1 : 2 : 1 ")!, [1, 2, 1])
        // Mixed / repeated separators don't create phantom parts.
        XCTAssertEqual(ZoneLayout.parseRatios("1::2,,1")!, [1, 2, 1])
    }

    func testParseAcceptsDecimals() {
        XCTAssertEqual(ZoneLayout.parseRatios("1.5:2.5")!, [1.5, 2.5])
    }

    func testParseSinglePartIsValid() {
        XCTAssertEqual(ZoneLayout.parseRatios("3")!, [3])
    }

    func testParseRejectsEmptyAndBlank() {
        XCTAssertNil(ZoneLayout.parseRatios(""))
        XCTAssertNil(ZoneLayout.parseRatios("   "))
        XCTAssertNil(ZoneLayout.parseRatios(":,: "))
    }

    func testParseRejectsNonNumeric() {
        XCTAssertNil(ZoneLayout.parseRatios("1:a:1"))
        XCTAssertNil(ZoneLayout.parseRatios("foo"))
    }

    func testParseRejectsZeroAndNegative() {
        XCTAssertNil(ZoneLayout.parseRatios("1:0:1"))
        XCTAssertNil(ZoneLayout.parseRatios("1:-2:1"))
        XCTAssertNil(ZoneLayout.parseRatios("0"))
    }

    // MARK: cumulativeBoundaries

    func testCumulativeBoundariesSimple() {
        let b = ZoneLayout.cumulativeBoundaries(fromRatios: [1, 2, 1])!
        XCTAssertEqual(b.count, 4)
        XCTAssertEqual(b[0], 0, accuracy: eps)
        XCTAssertEqual(b[1], 0.25, accuracy: eps)
        XCTAssertEqual(b[2], 0.75, accuracy: eps)
        XCTAssertEqual(b[3], 1, accuracy: eps)
    }

    func testCumulativeBoundaries232() {
        let b = ZoneLayout.cumulativeBoundaries(fromRatios: [2, 3, 2])!
        XCTAssertEqual(b[0], 0, accuracy: eps)
        XCTAssertEqual(b[1], 2.0 / 7, accuracy: eps)
        XCTAssertEqual(b[2], 5.0 / 7, accuracy: eps)
        XCTAssertEqual(b[3], 1, accuracy: eps)
    }

    func testCumulativeBoundariesEndsExactlyAtOne() {
        // Floating-point drift must not leave the last boundary != 1.
        let b = ZoneLayout.cumulativeBoundaries(fromRatios: [1, 1, 1])!
        XCTAssertEqual(b.last!, 1.0)  // exact, not approximate
        XCTAssertEqual(b.first!, 0.0)
    }

    // MARK: settingColumnRatios — same count keeps merges

    func testSettingColumnRatiosSameCountKeepsMerges() {
        // merged3x2 has 3 columns; pass 3 ratios -> reposition only, keep merge.
        let result = merged3x2().settingColumnRatios([1, 2, 1])!
        assertValid(result)
        XCTAssertEqual(result.cols, 3)
        // cellZones (the merge) is untouched.
        XCTAssertEqual(result.cellZones, merged3x2().cellZones)
        // New boundaries are the 1:2:1 split.
        XCTAssertEqual(result.colBoundaries[1], 0.25, accuracy: eps)
        XCTAssertEqual(result.colBoundaries[2], 0.75, accuracy: eps)
        // The merged top zone is still one rectangle.
        XCTAssertTrue(result.canMerge([0]))
    }

    func testSettingRowRatiosSameCountKeepsMerges() {
        // merged3x2 has 2 rows; pass 2 ratios -> reposition only, keep merge.
        let result = merged3x2().settingRowRatios([1, 3])!
        assertValid(result)
        XCTAssertEqual(result.rows, 2)
        XCTAssertEqual(result.cellZones, merged3x2().cellZones)
        XCTAssertEqual(result.rowBoundaries[1], 0.25, accuracy: eps)
    }

    // MARK: settingColumnRatios — different count rebuilds identity

    func testSettingColumnRatiosDifferentCountRebuildsIdentity() {
        // merged3x2 has 3 cols; pass 2 ratios -> rebuild to 2 cols, identity.
        let result = merged3x2().settingColumnRatios([1, 1])!
        assertValid(result)
        XCTAssertEqual(result.cols, 2)
        XCTAssertEqual(result.rows, 2)
        // cellZones length = cols*rows.
        XCTAssertEqual(result.cellZones.count, 4)
        // Identity (no merges): every cell its own zone.
        XCTAssertEqual(Set(result.cellZones).count, 4)
        XCTAssertEqual(result.cellZones, [0, 1, 2, 3])
        // Even split.
        XCTAssertEqual(result.colBoundaries, [0, 0.5, 1])
    }

    func testSettingRowRatiosDifferentCountRebuildsIdentity() {
        // merged3x2 has 2 rows; pass 3 ratios -> rebuild to 3 rows, identity.
        let result = merged3x2().settingRowRatios([1, 1, 1])!
        assertValid(result)
        XCTAssertEqual(result.rows, 3)
        XCTAssertEqual(result.cols, 3)
        XCTAssertEqual(result.cellZones.count, 9)
        XCTAssertEqual(Set(result.cellZones).count, 9)
        XCTAssertEqual(result.rowBoundaries[1], 1.0 / 3, accuracy: eps)
        XCTAssertEqual(result.rowBoundaries[2], 2.0 / 3, accuracy: eps)
    }

    func testSettingRatiosRejectsInvalid() {
        // settingColumn/RowRatios take already-parsed ratios; empty -> nil.
        XCTAssertNil(grid2x2().settingColumnRatios([]))
        XCTAssertNil(grid2x2().settingRowRatios([]))
    }

    func testSettingRatiosRejectsExtremeMagnitudeRatios() {
        // Precondition: such ratios DO collapse — the interior boundary rounds to
        // 1.0 in double precision and collides with the forced final 1, so the
        // raw cumulative boundaries are non-ascending ([0, 1, 1]).
        let collapsed = ZoneLayout.cumulativeBoundaries(fromRatios: [1, 1e-16])!
        XCTAssertEqual(collapsed, [0, 1, 1])
        // The setting ops must therefore reject them rather than commit a
        // non-ascending (invalid) layout — "valid or nil" contract.
        XCTAssertNil(grid2x2().settingColumnRatios([1, 1e-16]))
        XCTAssertNil(grid2x2().settingColumnRatios([1e16, 1]))
        XCTAssertNil(grid2x2().settingRowRatios([1, 1e-16]))
        XCTAssertNil(grid2x2().settingRowRatios([1e16, 1]))
    }

    // MARK: current ratios read-back

    func testCurrentColumnRatiosFromGaps() {
        let layout = ZoneLayout(
            id: "x", name: "x",
            colBoundaries: [0, 0.25, 0.75, 1],
            rowBoundaries: [0, 1],
            cellZones: [0, 1, 2]
        )
        let ratios = layout.currentColumnRatios
        XCTAssertEqual(ratios.count, 3)
        XCTAssertEqual(ratios[0], 0.25, accuracy: eps)
        XCTAssertEqual(ratios[1], 0.5, accuracy: eps)
        XCTAssertEqual(ratios[2], 0.25, accuracy: eps)
    }

    func testCurrentColumnRatioStringReducesToSmallIntegers() {
        // A 25/50/25 split reads as "1:2:1".
        let layout = ZoneLayout(
            id: "x", name: "x",
            colBoundaries: [0, 0.25, 0.75, 1],
            rowBoundaries: [0, 1],
            cellZones: [0, 1, 2]
        )
        XCTAssertEqual(layout.currentColumnRatioString, "1:2:1")
    }

    func testCurrentRatioStringForUniformGrid() {
        // Even thirds read as "1:1:1".
        let layout = ZoneLayout.uniform(cols: 3, rows: 1, id: "u", name: "u")
        XCTAssertEqual(layout.currentColumnRatioString, "1:1:1")
    }

    func testRatioStringFor232Split() {
        // 2/7, 3/7, 2/7 should reduce back to "2:3:2".
        let layout = ZoneLayout(
            id: "x", name: "x",
            colBoundaries: [0, 2.0 / 7, 5.0 / 7, 1],
            rowBoundaries: [0, 1],
            cellZones: [0, 1, 2]
        )
        XCTAssertEqual(layout.currentColumnRatioString, "2:3:2")
    }

    // MARK: round-trip current <-> setting

    func testRoundTrip121() {
        let base = ZoneLayout.uniform(cols: 3, rows: 1, id: "u", name: "u")
        let set = base.settingColumnRatios([1, 2, 1])!
        XCTAssertEqual(set.currentColumnRatioString, "1:2:1")
        // Re-applying the read-back string's parsed ratios reproduces the boundaries.
        let parsed = ZoneLayout.parseRatios(set.currentColumnRatioString)!
        let reset = set.settingColumnRatios(parsed)!
        XCTAssertEqual(reset.colBoundaries[1], 0.25, accuracy: eps)
        XCTAssertEqual(reset.colBoundaries[2], 0.75, accuracy: eps)
        assertValid(reset)
    }

    func testRoundTrip232Rows() {
        let base = ZoneLayout.uniform(cols: 1, rows: 3, id: "u", name: "u")
        let set = base.settingRowRatios([2, 3, 2])!
        XCTAssertEqual(set.currentRowRatioString, "2:3:2")
        let parsed = ZoneLayout.parseRatios(set.currentRowRatioString)!
        let reset = set.settingRowRatios(parsed)!
        XCTAssertEqual(reset.rowBoundaries[1], 2.0 / 7, accuracy: eps)
        XCTAssertEqual(reset.rowBoundaries[2], 5.0 / 7, accuracy: eps)
        assertValid(reset)
    }

    // MARK: settingColumnRatio / settingRowRatio (single-track resize)

    func testSettingColumnRatioReplacesOneTrackKeepingOthers() {
        // Uniform 3-col grid: each column's CURRENT proportion is 1/3. Replacing
        // the middle track's weight with the literal 2 gives [1/3, 2, 1/3] (the
        // other tracks keep their 1/3 weight), which normalizes to 1:6:1.
        let base = ZoneLayout.uniform(cols: 3, rows: 1, id: "u", name: "u")
        let result = base.settingColumnRatio(atIndex: 1, to: 2)!
        assertValid(result)
        XCTAssertEqual(result.cols, 3)  // track count unchanged
        XCTAssertEqual(result.currentColumnRatioString, "1:6:1")
    }

    func testSettingColumnRatioKeepsMerges() {
        // merged3x2 has the two TOP cells merged (zone 0). A same-count single-track
        // resize must preserve that merge (settingColumnRatios same-count path).
        let result = merged3x2().settingColumnRatio(atIndex: 0, to: 2)!
        assertValid(result)
        XCTAssertEqual(result.cellZones, merged3x2().cellZones)  // merge untouched
        XCTAssertTrue(result.canMerge([0]))
    }

    func testSettingRowRatioReplacesOneTrackKeepingOthers() {
        // Each row's current proportion is 1/3; replacing the last with literal 2
        // gives [1/3, 1/3, 2] => normalized 1:1:6.
        let base = ZoneLayout.uniform(cols: 1, rows: 3, id: "u", name: "u")
        let result = base.settingRowRatio(atIndex: 2, to: 2)!
        assertValid(result)
        XCTAssertEqual(result.rows, 3)
        XCTAssertEqual(result.currentRowRatioString, "1:1:6")
    }

    func testSettingTrackRatioRejectsNonPositive() {
        let base = ZoneLayout.uniform(cols: 3, rows: 2, id: "u", name: "u")
        XCTAssertNil(base.settingColumnRatio(atIndex: 0, to: 0))
        XCTAssertNil(base.settingColumnRatio(atIndex: 0, to: -1))
        XCTAssertNil(base.settingColumnRatio(atIndex: 0, to: .nan))
        XCTAssertNil(base.settingColumnRatio(atIndex: 0, to: .infinity))
        XCTAssertNil(base.settingRowRatio(atIndex: 0, to: 0))
        XCTAssertNil(base.settingRowRatio(atIndex: 0, to: -2))
    }

    func testSettingTrackRatioRejectsOutOfRangeIndex() {
        let base = ZoneLayout.uniform(cols: 3, rows: 2, id: "u", name: "u")
        XCTAssertNil(base.settingColumnRatio(atIndex: -1, to: 1))
        XCTAssertNil(base.settingColumnRatio(atIndex: 3, to: 1))   // cols == 3 -> valid 0..2
        XCTAssertNil(base.settingRowRatio(atIndex: 2, to: 1))      // rows == 2 -> valid 0..1
    }

    func testSettingTrackRatioRoundTripFromCurrentIsNoOp() {
        // Re-applying a track's CURRENT proportion should leave the layout valid
        // and unchanged in track count, preserving merges.
        let base = merged3x2()
        let current = base.currentColumnRatios[1]
        let result = base.settingColumnRatio(atIndex: 1, to: current)!
        assertValid(result)
        XCTAssertEqual(result.cols, base.cols)
        XCTAssertEqual(result.cellZones, base.cellZones)
        for i in 0..<result.colBoundaries.count {
            XCTAssertEqual(result.colBoundaries[i], base.colBoundaries[i], accuracy: eps)
        }
    }

    func testSettingTrackRatioOnlyMovesNeighborBoundaries() {
        // On a 4-col uniform grid, resizing column 1 should leave the OUTER edges
        // (0 and 1) fixed and keep boundaries ascending; only interior boundaries
        // shift. Verifies it's a proportional re-layout, not a rebuild.
        let base = ZoneLayout.uniform(cols: 4, rows: 1, id: "u", name: "u")
        let result = base.settingColumnRatio(atIndex: 1, to: 3)!
        assertValid(result)
        XCTAssertEqual(result.cols, 4)
        XCTAssertEqual(result.colBoundaries.first!, 0, accuracy: eps)
        XCTAssertEqual(result.colBoundaries.last!, 1, accuracy: eps)
        // current fractional weights [1/4,1/4,1/4,1/4]; replacing index 1 with the
        // literal 3 gives [1/4, 3, 1/4, 1/4] => normalized 1:12:1:1.
        XCTAssertEqual(result.currentColumnRatioString, "1:12:1:1")
    }

    // MARK: cleanIntegerRatio (freeform detection)

    func testCleanIntegerRatioReducesCleanSplit() {
        // 25/50/25 -> reduced [1, 2, 1].
        XCTAssertEqual(ZoneLayout.cleanIntegerRatio(from: [0.25, 0.5, 0.25])!, [1, 2, 1])
        // 2/7, 3/7, 2/7 -> [2, 3, 2].
        XCTAssertEqual(ZoneLayout.cleanIntegerRatio(from: [2.0 / 7, 3.0 / 7, 2.0 / 7])!, [2, 3, 2])
        // Even thirds -> [1, 1, 1].
        XCTAssertEqual(ZoneLayout.cleanIntegerRatio(from: [1.0 / 3, 1.0 / 3, 1.0 / 3])!, [1, 1, 1])
        // Non-normalized input is normalized first: [1, 2, 1] -> [1, 2, 1].
        XCTAssertEqual(ZoneLayout.cleanIntegerRatio(from: [1, 2, 1])!, [1, 2, 1])
    }

    func testCleanIntegerRatioNilForFreeformSplit() {
        // A split with no clean small-integer ratio (denom up to 48, 1% tol) -> nil.
        XCTAssertNil(ZoneLayout.cleanIntegerRatio(from: [0.37, 0.4, 0.23]))
    }

    func testCleanIntegerRatioEmptyAndZeroTotal() {
        XCTAssertNil(ZoneLayout.cleanIntegerRatio(from: []))
        XCTAssertNil(ZoneLayout.cleanIntegerRatio(from: [0, 0]))
    }

    func testRatioStringMatchesCleanIntegerRatio() {
        // ratioString and cleanIntegerRatio must agree for a clean split (single
        // source of truth after the refactor).
        let p = [0.25, 0.5, 0.25]
        let ints = ZoneLayout.cleanIntegerRatio(from: p)!
        XCTAssertEqual(ZoneLayout.ratioString(from: p), ints.map { String($0) }.joined(separator: ":"))
        XCTAssertEqual(ZoneLayout.ratioString(from: p), "1:2:1")
    }

    // MARK: reassemblingColumns / reassemblingRows (type-to-reassemble from freeform)

    func testReassemblingColumnsProducesCleanRatio() {
        // Proportions ~1:1.45:0.62 (a FREEFORM split — no clean small-int ratio);
        // type 2 into track 0 -> factor 2 -> [2, 2.9, 1.24] -> rounds to [2, 3, 1]
        // => "2:3:1" (the spec's 2:3:1 reassembly example).
        let p: [Double] = [1, 1.45, 0.62]
        let base = ZoneLayout(
            id: "x", name: "x",
            colBoundaries: ZoneLayout.cumulativeBoundaries(fromRatios: p)!,
            rowBoundaries: [0, 1],
            cellZones: [0, 1, 2]
        )
        // Precondition: that split is freeform.
        XCTAssertNil(ZoneLayout.cleanIntegerRatio(from: base.currentColumnRatios), "fixture should be freeform")
        // Sanity-check the per-track proportions sum to 1 (gaps of cumulative boundaries).
        XCTAssertEqual(base.currentColumnRatios.reduce(0, +), 1.0, accuracy: eps)

        let result = base.reassemblingColumns(atIndex: 0, to: 2)!
        assertValid(result)
        XCTAssertEqual(result.cols, 3)  // track count unchanged
        XCTAssertEqual(result.currentColumnRatioString, "2:3:1")
    }

    func testReassemblingRowsProducesCleanRatio() {
        // Symmetric row case (rows from the top): ~1:1.45:0.62, type 2 in row 0.
        let p: [Double] = [1, 1.45, 0.62]
        let base = ZoneLayout(
            id: "x", name: "x",
            colBoundaries: [0, 1],
            rowBoundaries: ZoneLayout.cumulativeBoundaries(fromRatios: p)!,
            cellZones: [0, 1, 2]
        )
        XCTAssertNil(ZoneLayout.cleanIntegerRatio(from: base.currentRowRatios), "fixture should be freeform")
        let result = base.reassemblingRows(atIndex: 0, to: 2)!
        assertValid(result)
        XCTAssertEqual(result.rows, 3)
        XCTAssertEqual(result.currentRowRatioString, "2:3:1")
    }

    func testReassemblingKeepsMerges() {
        // reassembling uses the same-count settingColumnRatios path, so merges on a
        // freeform column axis survive. Start from merged3x2 retuned to a freeform
        // column split, then reassemble — the top merge (zone 0) must persist.
        let freeform = merged3x2().settingColumnRatios([1, 1.45, 0.62])!
        XCTAssertNil(ZoneLayout.cleanIntegerRatio(from: freeform.currentColumnRatios), "should be freeform")
        XCTAssertTrue(freeform.canMerge([0]))
        let result = freeform.reassemblingColumns(atIndex: 0, to: 2)!
        assertValid(result)
        XCTAssertEqual(result.cellZones, merged3x2().cellZones)  // merge untouched
        XCTAssertTrue(result.canMerge([0]))
        XCTAssertEqual(result.currentColumnRatioString, "2:3:1")
    }

    func testReassemblingRejectsBadInput() {
        let base = ZoneLayout(
            id: "x", name: "x",
            colBoundaries: ZoneLayout.cumulativeBoundaries(fromRatios: [1, 1.45, 0.62])!,
            rowBoundaries: [0, 1],
            cellZones: [0, 1, 2]
        )
        XCTAssertNil(base.reassemblingColumns(atIndex: -1, to: 2))
        XCTAssertNil(base.reassemblingColumns(atIndex: 3, to: 2))   // 3 cols -> valid 0..2
        XCTAssertNil(base.reassemblingColumns(atIndex: 0, to: 0))
        XCTAssertNil(base.reassemblingColumns(atIndex: 0, to: -1))
        XCTAssertNil(base.reassemblingColumns(atIndex: 0, to: .nan))
        XCTAssertNil(base.reassemblingColumns(atIndex: 0, to: .infinity))
        XCTAssertNil(base.reassemblingRows(atIndex: 1, to: 2))      // 1 row -> valid 0..0
    }

    func testReassemblingAnchorsTypedTrackExactly() {
        // The typed track lands at the integer N (anchored); the others scale.
        // ~1:0.51 is a FREEFORM 2-track split; type 4 into track 0 -> factor 4 ->
        // [4, 2.04] -> rounds to [4, 2] -> reduced "2:1".
        let base = ZoneLayout(
            id: "x", name: "x",
            colBoundaries: ZoneLayout.cumulativeBoundaries(fromRatios: [1, 0.51])!,
            rowBoundaries: [0, 1],
            cellZones: [0, 1]
        )
        XCTAssertNil(ZoneLayout.cleanIntegerRatio(from: base.currentColumnRatios), "fixture should be freeform")
        let result = base.reassemblingColumns(atIndex: 0, to: 4)!
        assertValid(result)
        // [4, 2.04] rounds to [4, 2] -> reduced 2:1.
        XCTAssertEqual(result.currentColumnRatioString, "2:1")
    }

    // MARK: invariants hold for an end-to-end ratio edit on a merged grid

    func testRatioEditPreservesInvariantsAcrossAxes() {
        // Start merged, change columns (same count keeps merge), then change rows
        // to a different count (rebuilds rows to identity). Result must be valid.
        let step1 = merged3x2().settingColumnRatios([3, 1, 3])!
        assertValid(step1)
        XCTAssertTrue(step1.canMerge([0]))  // merge survived same-count col change
        let step2 = step1.settingRowRatios([1, 1, 1])!  // 2 -> 3 rows, identity rebuild
        assertValid(step2)
        XCTAssertEqual(step2.rows, 3)
        XCTAssertEqual(Set(step2.cellZones).count, step2.cellZones.count)  // no merges
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
