//
//  ZoneSplitTests.swift
//  LilypadTests
//
//  Verification for the FancyZones-style single-zone split op
//  `ZoneLayout.splittingZone(_:axis:at:)` (ZoneLayoutEditor.swift). The op
//  divides ONLY the named zone into two; every OTHER zone stays exactly as it was
//  (in particular a merged neighbor crossed by a freshly-inserted gridline stays
//  one rectangle). Rows are measured FROM THE TOP — the new BOTTOM half is the
//  larger-y / later-row part, never a vertical mirror.
//
//  Every result is asserted `isValid` (rectangular zones, ascending boundaries in
//  0...1, correct cellZones length).
//

import XCTest
@testable import Lilypad

class ZoneSplitTests: XCTestCase {

    private let eps = 1e-9

    // MARK: - Fixtures

    /// A single full-screen cell (1×1, one zone, id 0).
    private func single() -> ZoneLayout {
        ZoneLayout.uniform(cols: 1, rows: 1, id: "s", name: "s")
    }

    /// 2×2 identity grid: zones 0 1 / 2 3 (row-major, row 0 on top).
    private func grid2x2() -> ZoneLayout {
        ZoneLayout.uniform(cols: 2, rows: 2, id: "g", name: "g")
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

    /// The zone id occupying cell (col,row) — row 0 is the TOP.
    private func zoneAt(_ layout: ZoneLayout, col: Int, row: Int) -> Int {
        layout.cellZones[row * layout.cols + col]
    }

    // MARK: - 1×1 vertical split -> two side-by-side zones

    func testVerticalSplitOf1x1MakesTwoSideBySideZones() {
        let result = single().splittingZone(0, axis: .vertical, at: 0.5)
        XCTAssertNotNil(result)
        let layout = result!
        assertValid(layout)
        XCTAssertEqual(layout.cols, 2)
        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(layout.colBoundaries[1], 0.5, accuracy: eps)
        // Two distinct zones, side by side.
        XCTAssertEqual(Set(layout.cellZones).count, 2)
        let left = zoneAt(layout, col: 0, row: 0)
        let right = zoneAt(layout, col: 1, row: 0)
        XCTAssertNotEqual(left, right)
        // The LEFT half keeps the original id; the RIGHT half is the fresh id.
        XCTAssertEqual(left, 0, "near (left) side keeps the original id")
        XCTAssertGreaterThan(right, 0, "far (right) side is a fresh id")
    }

    // MARK: - 1×1 horizontal split -> new zone is BELOW (no vertical mirroring)

    func testHorizontalSplitOf1x1PutsNewZoneBelowTopKeepsRow0() {
        // Cut at 0.25 from the TOP: the TOP quarter is the original zone, the BOTTOM
        // three-quarters is the fresh zone. Asserting the new boundary is at 0.25
        // (top fraction) and the original id sits in row 0 (the top) proves there is
        // no vertical mirroring.
        let result = single().splittingZone(0, axis: .horizontal, at: 0.25)
        XCTAssertNotNil(result)
        let layout = result!
        assertValid(layout)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.cols, 1)
        // rowBoundaries measured from the TOP: the cut sits at 0.25.
        XCTAssertEqual(layout.rowBoundaries[1], 0.25, accuracy: eps)
        // Row 0 (TOP) keeps the original id; row 1 (BOTTOM) is the fresh id.
        let top = zoneAt(layout, col: 0, row: 0)
        let bottom = zoneAt(layout, col: 0, row: 1)
        XCTAssertEqual(top, 0, "the TOP half keeps the original id (row 0 stays the top)")
        XCTAssertGreaterThan(bottom, 0, "the BOTTOM half is the fresh id")
        XCTAssertNotEqual(top, bottom)
    }

    func testHorizontalSplitTopHalfIsShorterWhenCutNearTop() {
        // The cut is near the top (0.2): the top track must be the SMALL one (the
        // top fraction). If the math were mirrored, the small track would land at the
        // bottom — this asserts top<bottom directly via the boundary value.
        let layout = single().splittingZone(0, axis: .horizontal, at: 0.2)!
        assertValid(layout)
        let topHeight = layout.rowBoundaries[1] - layout.rowBoundaries[0]      // 0.2
        let bottomHeight = layout.rowBoundaries[2] - layout.rowBoundaries[1]   // 0.8
        XCTAssertLessThan(topHeight, bottomHeight)
        XCTAssertEqual(topHeight, 0.2, accuracy: eps)
    }

    // MARK: - Splitting one zone in a 2×2 leaves the other three untouched

    func testVerticalSplitInGrid2x2LeavesOtherThreeZonesUntouched() {
        // Split only zone 0 (top-left) vertically at x = 0.25.
        let base = grid2x2()
        let layout = base.splittingZone(0, axis: .vertical, at: 0.25)!
        assertValid(layout)
        // A new column line was inserted -> 3 cols, 2 rows.
        XCTAssertEqual(layout.cols, 3)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.colBoundaries, [0, 0.25, 0.5, 1])

        // The OTHER three zones (1 top-right, 2 bottom-left, 3 bottom-right) each
        // stay a single rectangle with the same id. In particular zone 1 (top-right)
        // — whose column was duplicated by the new line — must stay MERGED across it.
        for other in [1, 2, 3] {
            XCTAssertTrue(layout.canMerge([other]), "zone \(other) must still be one rectangle")
            XCTAssertGreaterThan(layout.cellZones.filter { $0 == other }.count, 0)
        }
        // Columns after the cut: col0=[0,0.25], col1=[0.25,0.5], col2=[0.5,1].
        // Zone 0 spanned [0,0.5] = col0+col1; cutting at 0.25 keeps id 0 on col0 and
        // a fresh id on col1. Zone 1 (top-right) spanned [0.5,1] = col2 ONLY — its
        // own column was NOT duplicated by this cut (the cut fell inside zone 0), so
        // zone 1 is a single cell at col2, row0 and stays one rectangle.
        XCTAssertEqual(zoneAt(layout, col: 2, row: 0), 1)
        // Zone 0 was split: left part (col 0, row 0) keeps id 0; right part (col 1,
        // row 0) is the fresh id, distinct from everything else.
        XCTAssertEqual(zoneAt(layout, col: 0, row: 0), 0)
        let fresh = zoneAt(layout, col: 1, row: 0)
        XCTAssertNotEqual(fresh, 0)
        XCTAssertNotEqual(fresh, 1)
        // The fresh right-half is its own single-cell rectangle.
        XCTAssertTrue(layout.canMerge([fresh]))
        // Bottom row is unchanged in topology: zone 2 spanned [0,0.5] = col0+col1
        // (its column was NOT cut, but the new line still passes through it, so it
        // must stay merged across cols 0 and 1); zone 3 at col2.
        XCTAssertEqual(zoneAt(layout, col: 0, row: 1), 2)
        XCTAssertEqual(zoneAt(layout, col: 1, row: 1), 2)
        XCTAssertEqual(zoneAt(layout, col: 2, row: 1), 3)
        // 5 zones total now (0 split into 2, plus 1,2,3).
        XCTAssertEqual(layout.zoneIds.count, 5)
    }

    func testHorizontalSplitInGrid2x2LeavesOtherThreeZonesUntouched() {
        let base = grid2x2()
        // Split zone 3 (bottom-right) horizontally at y = 0.75 from the top.
        let layout = base.splittingZone(3, axis: .horizontal, at: 0.75)!
        assertValid(layout)
        XCTAssertEqual(layout.rows, 3)
        XCTAssertEqual(layout.cols, 2)
        XCTAssertEqual(layout.rowBoundaries, [0, 0.5, 0.75, 1])
        for other in [0, 1, 2] {
            XCTAssertTrue(layout.canMerge([other]), "zone \(other) must still be one rectangle")
        }
        // Zone 2 (bottom-left) had its row duplicated by the new line -> it now spans
        // rows 1 and 2 in col 0; stays one merged rectangle.
        XCTAssertEqual(zoneAt(layout, col: 0, row: 1), 2)
        XCTAssertEqual(zoneAt(layout, col: 0, row: 2), 2)
        // Zone 3 split: top part (row 1, col 1) keeps id 3; bottom part (row 2) fresh.
        XCTAssertEqual(zoneAt(layout, col: 1, row: 1), 3)
        let fresh = zoneAt(layout, col: 1, row: 2)
        XCTAssertNotEqual(fresh, 3)
        XCTAssertEqual(layout.zoneIds.count, 5)
    }

    // MARK: - Off-bounds / non-interior fraction returns nil

    func testSplitRejectsNonInteriorFraction() {
        // Whole-grid edges.
        XCTAssertNil(single().splittingZone(0, axis: .vertical, at: 0))
        XCTAssertNil(single().splittingZone(0, axis: .vertical, at: 1))
        XCTAssertNil(single().splittingZone(0, axis: .vertical, at: -0.2))
        XCTAssertNil(single().splittingZone(0, axis: .vertical, at: 1.5))
        XCTAssertNil(single().splittingZone(0, axis: .horizontal, at: 0))
        XCTAssertNil(single().splittingZone(0, axis: .horizontal, at: 1))
    }

    func testSplitRejectsFractionOutsideTheTargetZonesExtent() {
        // In a 2×2, zone 0 (top-left) only spans x in [0, 0.5]. A vertical cut at
        // 0.75 is interior to the GRID but OUTSIDE zone 0's extent -> nil.
        XCTAssertNil(grid2x2().splittingZone(0, axis: .vertical, at: 0.75))
        // Zone 0 also only spans y in [0, 0.5]; a horizontal cut at 0.75 is outside.
        XCTAssertNil(grid2x2().splittingZone(0, axis: .horizontal, at: 0.75))
        // Cutting AT zone 0's own outer boundary (0.5) is non-interior -> nil.
        XCTAssertNil(grid2x2().splittingZone(0, axis: .vertical, at: 0.5))
    }

    func testSplitRejectsUnknownZone() {
        XCTAssertNil(single().splittingZone(999, axis: .vertical, at: 0.5))
        XCTAssertNil(grid2x2().splittingZone(42, axis: .horizontal, at: 0.5))
    }

    // MARK: - Splitting a MERGED multi-cell zone divides only it

    func testVerticalSplitOnExistingInteriorBoundaryReassignsFarSideOnly() {
        // 2×1 grid with both cells MERGED into zone 0 (spans the existing boundary
        // at 0.5). A vertical split AT 0.5 needs NO new gridline — it just reassigns
        // the right cell to a fresh id. cols stays 2.
        let merged = ZoneLayout(
            id: "m", name: "m",
            colBoundaries: [0, 0.5, 1],
            rowBoundaries: [0, 1],
            cellZones: [0, 0]
        )
        XCTAssertTrue(merged.isValid)
        let layout = merged.splittingZone(0, axis: .vertical, at: 0.5)!
        assertValid(layout)
        XCTAssertEqual(layout.cols, 2, "no new gridline needed — split landed on an existing interior boundary")
        XCTAssertEqual(layout.colBoundaries, [0, 0.5, 1])
        // Left cell keeps id 0; right cell is the fresh id.
        XCTAssertEqual(zoneAt(layout, col: 0, row: 0), 0)
        XCTAssertNotEqual(zoneAt(layout, col: 1, row: 0), 0)
        XCTAssertEqual(layout.zoneIds.count, 2)
    }

    func testVerticalSplitMergedZoneWithNewLineDividesOnlyIt() {
        // 3×2 with the two TOP cells merged into zone 0 (spans cols 0..1 on row 0).
        // Bottom row cells are 2,3,4. A vertical cut at 0.25 cuts INSIDE the merged
        // zone's first column (the merged zone spans x in [0, 2/3]). A NEW gridline
        // is inserted; only the merged zone's right-of-cut cells become fresh.
        let merged = ZoneLayout(
            id: "m", name: "m",
            colBoundaries: [0, 1.0 / 3, 2.0 / 3, 1],
            rowBoundaries: [0, 0.5, 1],
            cellZones: [0, 0, 1,
                        2, 3, 4]
        )
        XCTAssertTrue(merged.isValid)
        let layout = merged.splittingZone(0, axis: .vertical, at: 0.25)!
        assertValid(layout)
        XCTAssertEqual(layout.cols, 4, "a new column line was inserted at 0.25")
        // The bottom-row zones (2,3,4) are untouched and each still a rectangle;
        // zone 2 (bottom-left) had its column duplicated by the line -> stays merged.
        for other in [1, 2, 3, 4] {
            XCTAssertTrue(layout.canMerge([other]), "zone \(other) stays one rectangle")
        }
        // The original merged zone 0 split into: left part (still id 0) and a fresh
        // right part, both rectangles.
        XCTAssertTrue(layout.canMerge([0]))
        let freshIds = Set(layout.cellZones).subtracting([0, 1, 2, 3, 4])
        XCTAssertEqual(freshIds.count, 1, "exactly one fresh zone id introduced")
        XCTAssertTrue(layout.canMerge([freshIds.first!]))
        // Top row count: merged-left (id 0) + merged-right (fresh) + zone 1, all on
        // the top row, still 6 top-row cells across 4 columns? No — top row has 4
        // cells across 4 cols; left two are id 0/fresh split, right two are zone 1.
        XCTAssertEqual(zoneAt(layout, col: 3, row: 0), 1)
    }

    func testHorizontalSplitMergedColumnZoneDividesOnlyIt() {
        // 2×2 with the LEFT column merged into zone 0 (cells (0,0) and (0,1)).
        // Right column cells are 1 (top) and 3 (bottom). A horizontal cut at 0.25
        // (inside zone 0's top cell) inserts a new row line; only zone 0's
        // below-cut cells become fresh; the right column stays merged across the line.
        let merged = ZoneLayout(
            id: "m", name: "m",
            colBoundaries: [0, 0.5, 1],
            rowBoundaries: [0, 0.5, 1],
            cellZones: [0, 1,
                        0, 3]
        )
        XCTAssertTrue(merged.isValid)
        let layout = merged.splittingZone(0, axis: .horizontal, at: 0.25)!
        assertValid(layout)
        XCTAssertEqual(layout.rows, 3, "a new row line was inserted at 0.25")
        // Right-column zones stay rectangles; zone 1 (top-right) got its row
        // duplicated by the line -> spans rows 0 and 1 in col 1, still one rectangle.
        XCTAssertTrue(layout.canMerge([1]))
        XCTAssertTrue(layout.canMerge([3]))
        XCTAssertEqual(zoneAt(layout, col: 1, row: 0), 1)
        XCTAssertEqual(zoneAt(layout, col: 1, row: 1), 1)
        // Zone 0 split: TOP part (row 0, col 0) keeps id 0; the rows below the cut in
        // col 0 are the fresh id. No mirroring: the original id stays at the TOP.
        XCTAssertEqual(zoneAt(layout, col: 0, row: 0), 0)
        let fresh = zoneAt(layout, col: 0, row: 1)
        XCTAssertNotEqual(fresh, 0)
        XCTAssertEqual(zoneAt(layout, col: 0, row: 2), fresh, "the whole below-cut part is one fresh zone")
        XCTAssertTrue(layout.canMerge([fresh]))
    }

    // MARK: - Both halves are rectangles + total area conserved

    func testSplitHalvesTileTheZoneExactly() {
        // After a vertical split of zone 0 in a 2×2 at 0.25, the union of the two
        // resulting halves equals the original zone's rect (no gap / overlap).
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let base = grid2x2()
        let originalRect = GridCalculation.zoneRect(layout: base, zoneId: 0, in: area)
        let layout = base.splittingZone(0, axis: .vertical, at: 0.25)!
        let leftId = layout.cellZones[0]
        let freshId = layout.cellZones[1]
        let leftRect = GridCalculation.zoneRect(layout: layout, zoneId: leftId, in: area)
        let rightRect = GridCalculation.zoneRect(layout: layout, zoneId: freshId, in: area)
        XCTAssertEqual(leftRect.union(rightRect), originalRect)
        // And they don't overlap: combined area equals the original area.
        XCTAssertEqual(leftRect.width * leftRect.height + rightRect.width * rightRect.height,
                       originalRect.width * originalRect.height, accuracy: 1e-6)
    }

    func testHorizontalSplitNewZoneIsGeometricallyBelow() {
        // Geometry-level mirroring guard: in Cocoa BOTTOM-LEFT space, the fresh
        // (bottom) half must have a SMALLER minY than the original (top) half.
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let layout = single().splittingZone(0, axis: .horizontal, at: 0.25)!
        let topId = zoneAt(layout, col: 0, row: 0)
        let bottomId = zoneAt(layout, col: 0, row: 1)
        let topRect = GridCalculation.zoneRect(layout: layout, zoneId: topId, in: area)
        let bottomRect = GridCalculation.zoneRect(layout: layout, zoneId: bottomId, in: area)
        // Cocoa y grows up: the TOP half sits HIGHER (larger maxY), the BOTTOM half
        // lower (smaller minY). This is the explicit no-mirror assertion.
        XCTAssertGreaterThan(topRect.maxY, bottomRect.maxY)
        XCTAssertEqual(topRect.maxY, area.maxY, accuracy: eps, "the TOP half touches the top of the area")
        XCTAssertEqual(bottomRect.minY, area.minY, accuracy: eps, "the BOTTOM half touches the bottom of the area")
        // The TOP half is the shorter one (cut at 0.25 from the top).
        XCTAssertLessThan(topRect.height, bottomRect.height)
    }

    // MARK: - Degenerate split near a boundary is rejected

    func testSplitTooCloseToZoneEdgeIsRejected() {
        // A fraction within boundaryEpsilon of the zone's own edge is non-interior.
        XCTAssertNil(single().splittingZone(0, axis: .vertical, at: ZoneLayout.boundaryEpsilon / 2))
        XCTAssertNil(single().splittingZone(0, axis: .vertical, at: 1 - ZoneLayout.boundaryEpsilon / 2))
        XCTAssertNil(single().splittingZone(0, axis: .horizontal, at: ZoneLayout.boundaryEpsilon / 2))
    }
}
