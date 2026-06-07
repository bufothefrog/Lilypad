//
//  GridCalculationTests.swift
//  RectangleTests / Lilypad
//
//  M2 verification — the geometry keystone. The single most important assertions
//  here are the anti-mirroring gates: row 0 must map to the TOP of the screen
//  (largest y in Cocoa coords) and col 0 to the LEFT (smallest x). Everything else
//  (non-uniform boundaries, merged-zone bounding boxes, cursor/rect -> zone,
//  neighbor graph, selection union, generator shapes) builds on that convention.
//

import XCTest
import CoreGraphics
@testable import Rectangle

class GridCalculationTests: XCTestCase {

    // A non-square Cocoa-space area with a non-zero origin, so a sign error in
    // either axis (or a forgotten +minX/+minY) shows up as a failure.
    private let area = CGRect(x: 100, y: 200, width: 1600, height: 900)

    private let eps: CGFloat = 1e-6

    // 3 cols × 2 rows, identity zones (no merges):
    //   row 0 (top):    zones 0 1 2
    //   row 1 (bottom): zones 3 4 5
    private func uniform3x2() -> ZoneLayout {
        ZoneLayout.uniform(cols: 3, rows: 2, id: "u", name: "u")
    }

    private func assertRect(_ a: CGRect, _ b: CGRect, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: eps, "minX", file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: eps, "minY", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: eps, "width", file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: eps, "height", file: file, line: line)
    }

    // MARK: - Anti-mirroring gate (the #1 risk)

    /// Row 0 occupies the TOP of the screen, which in Cocoa bottom-left coords is the
    /// LARGEST y. The bottom-most row must have a smaller maxY than the top row.
    func testRow0IsTopOfScreen() {
        let layout = uniform3x2()
        let topRow = GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area)
        let bottomRow = GridCalculation.cellRect(layout: layout, col: 0, row: 1, in: area)

        XCTAssertGreaterThan(topRow.maxY, bottomRow.maxY, "row 0 must sit higher (larger y) than the last row")
        XCTAssertGreaterThan(topRow.minY, bottomRow.minY)
        // Top row's top edge is the screen top; bottom row's bottom edge is the screen bottom.
        XCTAssertEqual(topRow.maxY, area.maxY, accuracy: eps)
        XCTAssertEqual(bottomRow.minY, area.minY, accuracy: eps)
    }

    /// Col 0 occupies the LEFT of the screen (smallest x); the last col is the RIGHT.
    func testCol0IsLeftOfScreen() {
        let layout = uniform3x2()
        let leftCol = GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area)
        let rightCol = GridCalculation.cellRect(layout: layout, col: 2, row: 0, in: area)

        XCTAssertLessThan(leftCol.minX, rightCol.minX, "col 0 must sit further left than the last col")
        XCTAssertEqual(leftCol.minX, area.minX, accuracy: eps)
        XCTAssertEqual(rightCol.maxX, area.maxX, accuracy: eps)
    }

    // MARK: - Cell geometry (uniform)

    func testUniformCellRectExactValues() {
        let layout = uniform3x2()
        // cols of width 1600/3, rows of height 900/2 = 450.
        let w = area.width / 3
        let h = area.height / 2

        // Top-left cell (col 0, row 0): left edge at minX, top edge at maxY.
        assertRect(
            GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area),
            CGRect(x: area.minX, y: area.maxY - h, width: w, height: h)
        )
        // Bottom-right cell (col 2, row 1): right edge at maxX, bottom edge at minY.
        assertRect(
            GridCalculation.cellRect(layout: layout, col: 2, row: 1, in: area),
            CGRect(x: area.maxX - w, y: area.minY, width: w, height: h)
        )
    }

    func testCellRectOutOfRangeIsNull() {
        let layout = uniform3x2()
        XCTAssertTrue(GridCalculation.cellRect(layout: layout, col: -1, row: 0, in: area).isNull)
        XCTAssertTrue(GridCalculation.cellRect(layout: layout, col: 3, row: 0, in: area).isNull)
        XCTAssertTrue(GridCalculation.cellRect(layout: layout, col: 0, row: 2, in: area).isNull)
    }

    // MARK: - Non-uniform boundaries

    func testNonUniformBoundaries() {
        // Columns at 0, 0.25, 1 (a narrow left col, wide right col).
        // Rows at 0, 0.75, 1 measured from the TOP (a tall top row, short bottom row).
        let layout = ZoneLayout(
            id: "nu", name: "nu",
            colBoundaries: [0, 0.25, 1],
            rowBoundaries: [0, 0.75, 1],
            cellZones: [0, 1,
                        2, 3]
        )

        let topLeft = GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area)
        // Narrow left column: width = 0.25 * 1600 = 400.
        XCTAssertEqual(topLeft.width, 0.25 * area.width, accuracy: eps)
        // Tall top row: height = 0.75 * 900 = 675, and it touches the screen top.
        XCTAssertEqual(topLeft.height, 0.75 * area.height, accuracy: eps)
        XCTAssertEqual(topLeft.maxY, area.maxY, accuracy: eps)

        let bottomRight = GridCalculation.cellRect(layout: layout, col: 1, row: 1, in: area)
        XCTAssertEqual(bottomRight.width, 0.75 * area.width, accuracy: eps)
        XCTAssertEqual(bottomRight.height, 0.25 * area.height, accuracy: eps)
        XCTAssertEqual(bottomRight.minY, area.minY, accuracy: eps)
        XCTAssertEqual(bottomRight.maxX, area.maxX, accuracy: eps)
    }

    // MARK: - Merged-zone bounding boxes

    /// 3×2 with the two top cells (col 0,1 of row 0) merged into one wide zone.
    private func mergedTop() -> ZoneLayout {
        ZoneLayout(
            id: "m", name: "m",
            colBoundaries: [0, 1.0 / 3, 2.0 / 3, 1],
            rowBoundaries: [0, 0.5, 1],
            cellZones: [9, 9, 1,   // top: two-thirds-wide merged zone (id 9) + a single cell
                        2, 3, 4]
        )
    }

    func testMergedZoneBoundingBox() {
        let layout = mergedTop()
        let merged = GridCalculation.zoneRect(layout: layout, zoneId: 9, in: area)
        // Spans columns 0 and 1 (the left two-thirds) of the top row.
        XCTAssertEqual(merged.minX, area.minX, accuracy: eps)
        XCTAssertEqual(merged.width, (2.0 / 3) * area.width, accuracy: eps)
        XCTAssertEqual(merged.maxY, area.maxY, accuracy: eps)             // touches screen top
        XCTAssertEqual(merged.height, 0.5 * area.height, accuracy: eps)   // one row tall
    }

    func testZoneRectUnknownZoneIsNull() {
        XCTAssertTrue(GridCalculation.zoneRect(layout: mergedTop(), zoneId: 999, in: area).isNull)
    }

    // MARK: - cursor -> zone

    func testCursorToZoneInteriorPoints() {
        let layout = uniform3x2()
        let w = area.width / 3
        let h = area.height / 2

        // A point in the middle of the top-left cell -> zone 0.
        let topLeftCenter = CGPoint(x: area.minX + w / 2, y: area.maxY - h / 2)
        XCTAssertEqual(GridCalculation.zone(at: topLeftCenter, in: area, layout: layout), 0)

        // Middle of the top-right cell -> zone 2.
        let topRightCenter = CGPoint(x: area.maxX - w / 2, y: area.maxY - h / 2)
        XCTAssertEqual(GridCalculation.zone(at: topRightCenter, in: area, layout: layout), 2)

        // Middle of the bottom-left cell -> zone 3 (row 1).
        let bottomLeftCenter = CGPoint(x: area.minX + w / 2, y: area.minY + h / 2)
        XCTAssertEqual(GridCalculation.zone(at: bottomLeftCenter, in: area, layout: layout), 3)

        // Middle of the bottom-right cell -> zone 5.
        let bottomRightCenter = CGPoint(x: area.maxX - w / 2, y: area.minY + h / 2)
        XCTAssertEqual(GridCalculation.zone(at: bottomRightCenter, in: area, layout: layout), 5)
    }

    func testCursorToZoneOnBoundaries() {
        let layout = uniform3x2()

        // Exactly on the vertical boundary between col 0 and col 1 (x = minX + width/3),
        // at the vertical center of the top row -> resolves to the higher-index cell (col 1) => zone 1.
        let onColBoundary = CGPoint(x: area.minX + area.width / 3, y: area.maxY - area.height / 4)
        XCTAssertEqual(GridCalculation.zone(at: onColBoundary, in: area, layout: layout), 1)

        // Exactly on the horizontal mid boundary (top fraction 0.5), in col 0.
        // In Cocoa coords that's y = area.maxY - 0.5*height = area.midY. Resolves to the
        // lower (bottom) row => zone 3.
        let onRowBoundary = CGPoint(x: area.minX + area.width / 6, y: area.maxY - area.height * 0.5)
        XCTAssertEqual(GridCalculation.zone(at: onRowBoundary, in: area, layout: layout), 3)
    }

    func testCursorToZoneOutsideAreaIsNil() {
        let layout = uniform3x2()
        XCTAssertNil(GridCalculation.zone(at: CGPoint(x: area.minX - 1, y: area.midY), in: area, layout: layout))
        XCTAssertNil(GridCalculation.zone(at: CGPoint(x: area.midX, y: area.maxY + 1), in: area, layout: layout))
    }

    func testCursorToZoneLandsInMergedZone() {
        let layout = mergedTop()
        // A point well inside the merged top zone (left third, top row) -> id 9.
        let p = CGPoint(x: area.minX + area.width / 6, y: area.maxY - area.height / 4)
        XCTAssertEqual(GridCalculation.zone(at: p, in: area, layout: layout), 9)
        // And the second merged cell (center third, top row) -> also id 9.
        let p2 = CGPoint(x: area.minX + area.width / 2, y: area.maxY - area.height / 4)
        XCTAssertEqual(GridCalculation.zone(at: p2, in: area, layout: layout), 9)
    }

    /// cursor -> zone against NON-uniform boundaries. A regression that assumed uniform
    /// cell widths (e.g. col = Int(fx * cols)) would land on the wrong cell here, since the
    /// vertical split is at 0.25 (not 0.5) and the horizontal split is 0.75-from-top.
    func testCursorToZoneNonUniform() {
        let layout = ZoneLayout(
            id: "nu", name: "nu",
            colBoundaries: [0, 0.25, 1],
            rowBoundaries: [0, 0.75, 1],
            cellZones: [0, 1,
                        2, 3]
        )
        // x at 0.20 of width is LEFT of the 0.25 split -> col 0; near the top -> row 0 => zone 0.
        XCTAssertEqual(GridCalculation.zone(at: CGPoint(x: area.minX + 0.20 * area.width, y: area.maxY - 0.10 * area.height), in: area, layout: layout), 0)
        // x at 0.30 is RIGHT of the 0.25 split -> col 1 (would be col 0 if widths were uniform) => zone 1.
        XCTAssertEqual(GridCalculation.zone(at: CGPoint(x: area.minX + 0.30 * area.width, y: area.maxY - 0.10 * area.height), in: area, layout: layout), 1)
        // 0.90 down from the top is in the SHORT bottom row (split at 0.75) -> row 1; left col => zone 2.
        XCTAssertEqual(GridCalculation.zone(at: CGPoint(x: area.minX + 0.20 * area.width, y: area.maxY - 0.90 * area.height), in: area, layout: layout), 2)
        // 0.60 down is still in the TALL top row (split at 0.75) -> row 0; right col => zone 1.
        XCTAssertEqual(GridCalculation.zone(at: CGPoint(x: area.minX + 0.30 * area.width, y: area.maxY - 0.60 * area.height), in: area, layout: layout), 1)
    }

    // MARK: - rect -> zone inference

    func testRectToZoneExactMatch() {
        let layout = uniform3x2()
        let zoneRect = GridCalculation.zoneRect(layout: layout, zoneId: 4, in: area)
        XCTAssertEqual(GridCalculation.zone(matchingWindowRect: zoneRect, in: area, layout: layout), 4)
    }

    func testRectToZoneWithinTolerance() {
        let layout = uniform3x2()
        var zoneRect = GridCalculation.zoneRect(layout: layout, zoneId: 2, in: area)
        // Nudge each edge by less than the tolerance (default 25).
        zoneRect = zoneRect.insetBy(dx: 10, dy: 8).offsetBy(dx: 5, dy: -6)
        XCTAssertEqual(GridCalculation.zone(matchingWindowRect: zoneRect, in: area, layout: layout, tolerance: 25), 2)
    }

    func testRectToZoneOutsideToleranceIsNil() {
        let layout = uniform3x2()
        // A window that fills the whole area matches no single zone within a tight tolerance.
        XCTAssertNil(GridCalculation.zone(matchingWindowRect: area, in: area, layout: layout, tolerance: 5))
    }

    func testRectToZoneMatchesMergedZone() {
        let layout = mergedTop()
        let merged = GridCalculation.zoneRect(layout: layout, zoneId: 9, in: area)
        XCTAssertEqual(GridCalculation.zone(matchingWindowRect: merged, in: area, layout: layout), 9)
    }

    // MARK: - Neighbor graph

    func testNeighborsUniform() {
        let layout = uniform3x2()
        // Layout of zone ids:
        //   row 0: 0 1 2
        //   row 1: 3 4 5
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 0, direction: .right, layout: layout), 1)
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 1, direction: .right, layout: layout), 2)
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 1, direction: .left, layout: layout), 0)
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 0, direction: .down, layout: layout), 3)
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 3, direction: .up, layout: layout), 0)
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 5, direction: .up, layout: layout), 2)
    }

    func testNeighborsAtWallsAreNil() {
        let layout = uniform3x2()
        XCTAssertNil(GridCalculation.neighbor(ofZone: 0, direction: .left, layout: layout))
        XCTAssertNil(GridCalculation.neighbor(ofZone: 2, direction: .right, layout: layout))
        XCTAssertNil(GridCalculation.neighbor(ofZone: 0, direction: .up, layout: layout))   // already top row
        XCTAssertNil(GridCalculation.neighbor(ofZone: 3, direction: .down, layout: layout)) // already bottom row
    }

    func testNeighborHopsAcrossMergedZone() {
        let layout = mergedTop()
        // Layout of zone ids:
        //   row 0: 9 9 1
        //   row 1: 2 3 4
        // Right of the wide merged zone 9 (spans cols 0-1) is col 2 => zone 1.
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 9, direction: .right, layout: layout), 1)
        // Down from merged zone 9 lands on the first differing cell of row 1 => zone 2.
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 9, direction: .down, layout: layout), 2)
        // Left of merged zone 9 is a wall.
        XCTAssertNil(GridCalculation.neighbor(ofZone: 9, direction: .left, layout: layout))
        // Up from zone 3 (bottom center) lands in the merged zone 9.
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 3, direction: .up, layout: layout), 9)
        // Up from zone 4 (bottom right) lands on zone 1 (top right).
        XCTAssertEqual(GridCalculation.neighbor(ofZone: 4, direction: .up, layout: layout), 1)
    }

    // MARK: - Selection union

    func testSelectionRectAdjacentZones() {
        let layout = uniform3x2()
        // Union of the two top-left zones (0 and 1) = left two-thirds of the top row.
        let union = GridCalculation.selectionRect(layout: layout, fromZone: 0, toZone: 1, in: area)
        XCTAssertEqual(union.minX, area.minX, accuracy: eps)
        XCTAssertEqual(union.width, (2.0 / 3) * area.width, accuracy: eps)
        XCTAssertEqual(union.maxY, area.maxY, accuracy: eps)
        XCTAssertEqual(union.height, 0.5 * area.height, accuracy: eps)
    }

    func testSelectionRectVerticalSpan() {
        let layout = uniform3x2()
        // Union of zone 0 (top-left) and zone 3 (bottom-left) = the full left column.
        let union = GridCalculation.selectionRect(layout: layout, fromZone: 0, toZone: 3, in: area)
        XCTAssertEqual(union.minX, area.minX, accuracy: eps)
        XCTAssertEqual(union.width, area.width / 3, accuracy: eps)
        XCTAssertEqual(union.minY, area.minY, accuracy: eps)
        XCTAssertEqual(union.maxY, area.maxY, accuracy: eps)
        XCTAssertEqual(union.height, area.height, accuracy: eps)
    }

    func testSelectionRectSpanningMergedZone() {
        let layout = mergedTop()
        // From the merged top zone (9, left two-thirds of top row) to the bottom-right zone (4).
        // Bounding box = the entire area.
        let union = GridCalculation.selectionRect(layout: layout, fromZone: 9, toZone: 4, in: area)
        assertRect(union, area)
    }

    func testSelectionRectSameZone() {
        let layout = uniform3x2()
        let single = GridCalculation.selectionRect(layout: layout, fromZone: 4, toZone: 4, in: area)
        assertRect(single, GridCalculation.zoneRect(layout: layout, zoneId: 4, in: area))
    }

    /// Pins the single-unknown-zone contract: if exactly one endpoint is unknown, fall back
    /// to the other; only when both are unknown is the result `.null`.
    func testSelectionRectOneUnknownZoneFallsBackToOther() {
        let layout = uniform3x2()
        let known = GridCalculation.zoneRect(layout: layout, zoneId: 4, in: area)
        assertRect(GridCalculation.selectionRect(layout: layout, fromZone: 4, toZone: 999, in: area), known)
        assertRect(GridCalculation.selectionRect(layout: layout, fromZone: 999, toZone: 4, in: area), known)
        XCTAssertTrue(GridCalculation.selectionRect(layout: layout, fromZone: 998, toZone: 999, in: area).isNull)
    }

    // MARK: - zonesInSpan (M6 span sub-mode)

    /// A 2-zone horizontal span on the top row (0 → 1) covers exactly {0, 1}, and
    /// the union of those zones' rects equals the selectionRect.
    func testZonesInSpanHorizontal() {
        let layout = uniform3x2()
        let zones = GridCalculation.zonesInSpan(fromZone: 0, toZone: 1, layout: layout)
        XCTAssertEqual(zones, [0, 1])
        assertUnionMatchesSelection(zones, from: 0, to: 1, layout: layout)
    }

    /// A vertical span down the left column (0 → 3) covers {0, 3}.
    func testZonesInSpanVertical() {
        let layout = uniform3x2()
        let zones = GridCalculation.zonesInSpan(fromZone: 0, toZone: 3, layout: layout)
        XCTAssertEqual(zones, [0, 3])
        assertUnionMatchesSelection(zones, from: 0, to: 3, layout: layout)
    }

    /// A 2×2 block span (top-left 0 → bottom-right-of-block 4 in a 3×2 grid)
    /// covers the full 2×2 corner: {0, 1, 3, 4}.
    func testZonesInSpan2x2Block() {
        let layout = uniform3x2()
        // 3×2 zone ids:  row 0: 0 1 2 ; row 1: 3 4 5.
        // Bounding box of zone 0 (col0,row0) and zone 4 (col1,row1) is cols 0-1,
        // rows 0-1 ⇒ zones 0,1,3,4.
        let zones = GridCalculation.zonesInSpan(fromZone: 0, toZone: 4, layout: layout)
        XCTAssertEqual(zones, [0, 1, 3, 4])
        assertUnionMatchesSelection(zones, from: 0, to: 4, layout: layout)
    }

    /// A single zone spans only itself.
    func testZonesInSpanSingleZoneIsItself() {
        let layout = uniform3x2()
        XCTAssertEqual(GridCalculation.zonesInSpan(fromZone: 4, toZone: 4, layout: layout), [4])
    }

    /// A merged zone is included whole when it fits inside the bounding range. The
    /// mergedTop layout has the wide merged zone 9 (cols 0-1, row 0). Spanning from
    /// it to the bottom-right (4) covers the whole grid ⇒ all zones, and the union
    /// equals the selectionRect.
    func testZonesInSpanWithMergedZone() {
        let layout = mergedTop()
        // ids:  row 0: 9 9 1 ; row 1: 2 3 4.
        let zones = GridCalculation.zonesInSpan(fromZone: 9, toZone: 4, layout: layout)
        XCTAssertEqual(zones, Set(layout.zoneIds))
        assertUnionMatchesSelection(zones, from: 9, to: 4, layout: layout)

        // A narrower span that does NOT fully contain the wide merged zone must
        // exclude it: from zone 1 (col2,row0) to zone 2 (col0,row1) bounds cols
        // 0-2, rows 0-1 → that DOES contain all of zone 9 too, so use a tighter
        // range. From zone 1 (col2,row0) to zone 4 (col2,row1) bounds col 2 only,
        // rows 0-1 ⇒ {1, 4}; zone 9 (cols 0-1) is excluded.
        let narrow = GridCalculation.zonesInSpan(fromZone: 1, toZone: 4, layout: layout)
        XCTAssertEqual(narrow, [1, 4])
        XCTAssertFalse(narrow.contains(9))
    }

    /// Both endpoints unknown ⇒ empty set.
    func testZonesInSpanBothUnknownIsEmpty() {
        XCTAssertTrue(GridCalculation.zonesInSpan(fromZone: 998, toZone: 999, layout: uniform3x2()).isEmpty)
    }

    /// Union of a span's zone rects must equal `selectionRect(from:to:)` so the
    /// highlighted footprint matches the committed rect.
    private func assertUnionMatchesSelection(_ zones: Set<Int>, from: Int, to: Int, layout: ZoneLayout,
                                             file: StaticString = #file, line: UInt = #line) {
        var union: CGRect = .null
        for z in zones {
            union = union.union(GridCalculation.zoneRect(layout: layout, zoneId: z, in: area))
        }
        let selection = GridCalculation.selectionRect(layout: layout, fromZone: from, toZone: to, in: area)
        assertRect(union, selection, file: file, line: line)
    }

    // MARK: - zonesWithinRadius / boundingRect (proximity span)

    /// A uniform 2×2 over `area` (cells 800 wide × 450 tall):
    ///   row 0 (top):    zones 0 1
    ///   row 1 (bottom): zones 2 3
    /// All four meet at the interior corner (x = area.midX, y = area.maxY - h).
    private func uniform2x2() -> ZoneLayout {
        ZoneLayout.uniform(cols: 2, rows: 2, id: "u22", name: "u22")
    }

    /// Deep inside a single zone with a small radius -> just that zone.
    func testZonesWithinRadiusDeepInsideIsSingleZone() {
        let layout = uniform2x2()
        // Center of the top-left cell (zone 0): far from every gridline.
        let cell0 = GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area)
        let center = CGPoint(x: cell0.midX, y: cell0.midY)
        XCTAssertEqual(GridCalculation.zonesWithinRadius(of: center, radius: 20, in: area, layout: layout), [0])
    }

    /// Radius 0 -> only the containing zone (the point's own zone, distance 0).
    func testZonesWithinRadiusZeroRadiusIsContainingZone() {
        let layout = uniform2x2()
        let cell3 = GridCalculation.cellRect(layout: layout, col: 1, row: 1, in: area)
        let p = CGPoint(x: cell3.midX, y: cell3.midY)
        XCTAssertEqual(GridCalculation.zonesWithinRadius(of: p, radius: 0, in: area, layout: layout), [3])
    }

    /// Near a single vertical gridline (between col 0 and col 1 on the top row),
    /// within radius -> the 2 zones across it, and NOT the far (bottom) zones.
    func testZonesWithinRadiusNearGridlineIsTwoZones() {
        let layout = uniform2x2()
        // The vertical split is at x = area.minX + width/2 = area.midX.
        // Sit just LEFT of it (in zone 0), vertically centered in the TOP row so the
        // bottom zones are a full cell-height (450) away.
        let topRowY = GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area).midY
        let p = CGPoint(x: area.midX - 5, y: topRowY)
        // Radius 20: reaches across the gridline to zone 1 (distance 5), but the
        // bottom zones (2,3) are 225pt below -> excluded.
        XCTAssertEqual(GridCalculation.zonesWithinRadius(of: p, radius: 20, in: area, layout: layout), [0, 1])
    }

    /// Near the 4-way corner with a large-enough radius -> all 4 zones.
    func testZonesWithinRadiusNearCornerIsAllFour() {
        let layout = uniform2x2()
        // The interior corner where all four cells meet: x = area.midX,
        // y = area.maxY - h (the row split). Sit a few points into zone 0 (up-left of
        // the corner) so it contains 0, and is within a generous radius of 1,2,3.
        let cornerX = area.midX
        let cornerY = area.maxY - area.height / 2
        let p = CGPoint(x: cornerX - 3, y: cornerY + 3)
        XCTAssertEqual(GridCalculation.zonesWithinRadius(of: p, radius: 40, in: area, layout: layout), [0, 1, 2, 3])
    }

    /// A point OUTSIDE the area, farther than the radius from every zone -> empty.
    func testZonesWithinRadiusOutsideAreaIsEmpty() {
        let layout = uniform2x2()
        // 100pt to the left of the area's left edge; radius 20 reaches nothing.
        let p = CGPoint(x: area.minX - 100, y: area.midY)
        XCTAssertTrue(GridCalculation.zonesWithinRadius(of: p, radius: 20, in: area, layout: layout).isEmpty)
    }

    /// A point just outside the area but WITHIN the radius of the nearest zone still
    /// includes that zone (distance is the gap to the rect, not infinity).
    func testZonesWithinRadiusJustOutsideButWithinRadius() {
        let layout = uniform2x2()
        // 10pt left of the left edge, vertically centered in the top row.
        let topRowY = GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area).midY
        let p = CGPoint(x: area.minX - 10, y: topRowY)
        XCTAssertEqual(GridCalculation.zonesWithinRadius(of: p, radius: 20, in: area, layout: layout), [0])
    }

    /// boundingRect of a 2-zone set = the union of those zones' rects. Top row of
    /// the 2×2 ({0,1}) = the full width, top half.
    func testBoundingRectTwoZoneSet() {
        let layout = uniform2x2()
        let rect = GridCalculation.boundingRect(ofZones: [0, 1], in: area, layout: layout)
        XCTAssertEqual(rect.minX, area.minX, accuracy: eps)
        XCTAssertEqual(rect.maxX, area.maxX, accuracy: eps)   // spans both columns
        XCTAssertEqual(rect.width, area.width, accuracy: eps)
        XCTAssertEqual(rect.maxY, area.maxY, accuracy: eps)   // top row touches screen top
        XCTAssertEqual(rect.height, area.height / 2, accuracy: eps)
    }

    /// boundingRect of the full 4-zone set = the whole area.
    func testBoundingRectFourZoneSet() {
        let layout = uniform2x2()
        let rect = GridCalculation.boundingRect(ofZones: [0, 1, 2, 3], in: area, layout: layout)
        assertRect(rect, area)
    }

    /// boundingRect of a single-zone set equals that zone's rect; an empty / unknown
    /// set is null.
    func testBoundingRectSingleAndEmpty() {
        let layout = uniform2x2()
        assertRect(GridCalculation.boundingRect(ofZones: [3], in: area, layout: layout),
                   GridCalculation.zoneRect(layout: layout, zoneId: 3, in: area))
        XCTAssertTrue(GridCalculation.boundingRect(ofZones: [], in: area, layout: layout).isNull)
        XCTAssertTrue(GridCalculation.boundingRect(ofZones: [999], in: area, layout: layout).isNull)
    }

    /// boundingRectWithGaps insets the union like the other gap-aware helpers; gap 0
    /// is a no-op.
    func testBoundingRectWithGaps() {
        let layout = uniform2x2()
        let plain = GridCalculation.boundingRect(ofZones: [0, 1], in: area, layout: layout)
        let gapped = GridCalculation.boundingRectWithGaps(ofZones: [0, 1], in: area, layout: layout, gapSize: 10)
        XCTAssertLessThan(gapped.width, plain.width)
        XCTAssertLessThan(gapped.height, plain.height)
        assertRect(GridCalculation.boundingRectWithGaps(ofZones: [0, 1], in: area, layout: layout, gapSize: 0), plain)
    }

    // MARK: - targetZone (M7 keyboard nav)

    /// An ALIGNED window (its rect matches a zone) moves to that zone's neighbor.
    func testTargetZoneAlignedWindowMovesToNeighbor() {
        let layout = uniform3x2()
        // ids:  row 0: 0 1 2 ; row 1: 3 4 5.
        // Window exactly fills the center-top zone (1); right -> 2, left -> 0, down -> 4.
        let rect = GridCalculation.zoneRect(layout: layout, zoneId: 1, in: area)
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: rect, in: area, layout: layout, direction: .right), 2)
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: rect, in: area, layout: layout, direction: .left), 0)
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: rect, in: area, layout: layout, direction: .down), 4)
        // The top-center zone has no neighbor above (top row) -> nil.
        XCTAssertNil(GridCalculation.targetZone(forWindowRect: rect, in: area, layout: layout, direction: .up))
    }

    /// An aligned window within tolerance (slightly nudged) is still treated as
    /// occupying its zone and hops to the neighbor.
    func testTargetZoneAlignedWithinToleranceMovesToNeighbor() {
        let layout = uniform3x2()
        var rect = GridCalculation.zoneRect(layout: layout, zoneId: 0, in: area)
        rect = rect.insetBy(dx: 8, dy: 6).offsetBy(dx: 4, dy: -5) // within default tolerance 25
        // Zone 0 (top-left): right -> 1, down -> 3.
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: rect, in: area, layout: layout, direction: .right), 1)
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: rect, in: area, layout: layout, direction: .down), 3)
    }

    /// An aligned window at each wall in the wall direction returns nil (no neighbor).
    func testTargetZoneAlignedAtEachWallIsNil() {
        let layout = uniform3x2()
        // ids:  row 0: 0 1 2 ; row 1: 3 4 5.
        let topLeft = GridCalculation.zoneRect(layout: layout, zoneId: 0, in: area)    // top-left corner
        let topRight = GridCalculation.zoneRect(layout: layout, zoneId: 2, in: area)   // top-right corner
        let bottomLeft = GridCalculation.zoneRect(layout: layout, zoneId: 3, in: area) // bottom-left corner

        // Left wall (zone 0): left -> nil. Top wall (zone 0): up -> nil.
        XCTAssertNil(GridCalculation.targetZone(forWindowRect: topLeft, in: area, layout: layout, direction: .left))
        XCTAssertNil(GridCalculation.targetZone(forWindowRect: topLeft, in: area, layout: layout, direction: .up))
        // Right wall (zone 2): right -> nil.
        XCTAssertNil(GridCalculation.targetZone(forWindowRect: topRight, in: area, layout: layout, direction: .right))
        // Bottom wall (zone 3): down -> nil.
        XCTAssertNil(GridCalculation.targetZone(forWindowRect: bottomLeft, in: area, layout: layout, direction: .down))
    }

    /// An UNALIGNED (free) window captures into the zone under its center and moves
    /// toward the arrow: the first press both snaps into the grid AND nudges.
    func testTargetZoneUnalignedWindowMovesFromCenterZone() {
        let layout = uniform3x2()
        // A small free window whose CENTER sits in the bottom-center cell (zone 4),
        // but which fills no zone (so zone(matchingWindowRect:) returns nil).
        let cell4 = GridCalculation.cellRect(layout: layout, col: 1, row: 1, in: area)
        let center = CGPoint(x: cell4.midX, y: cell4.midY)
        let freeRect = CGRect(x: center.x - 40, y: center.y - 30, width: 80, height: 60)
        // Sanity: this rect must NOT match any zone (otherwise we'd be in the aligned case).
        XCTAssertNil(GridCalculation.zone(matchingWindowRect: freeRect, in: area, layout: layout))

        // Anchor zone is 4 (bottom center). right -> 5, left -> 3, up -> 1.
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .right), 5)
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .left), 3)
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .up), 1)
    }

    /// An unaligned window whose center is in an edge zone, moving toward the wall,
    /// captures into that center zone (neighbor is nil -> fall back to the anchor).
    func testTargetZoneUnalignedAtWallCapturesToCenterZone() {
        let layout = uniform3x2()
        // Free window centered in the top-left cell (zone 0), filling no zone.
        let cell0 = GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area)
        let center = CGPoint(x: cell0.midX, y: cell0.midY)
        let freeRect = CGRect(x: center.x - 30, y: center.y - 20, width: 60, height: 40)
        XCTAssertNil(GridCalculation.zone(matchingWindowRect: freeRect, in: area, layout: layout))

        // Toward the left wall: no neighbor -> capture into the anchor zone 0.
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .left), 0)
        // Toward the top wall: no neighbor -> capture into the anchor zone 0.
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .up), 0)
        // But a non-wall direction still nudges: right -> 1, down -> 3.
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .right), 1)
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .down), 3)
    }

    /// An unaligned window whose center is OUTSIDE the area has no anchor zone -> nil.
    func testTargetZoneUnalignedOutsideAreaIsNil() {
        let layout = uniform3x2()
        // A window entirely to the left of the area (center outside).
        let freeRect = CGRect(x: area.minX - 300, y: area.midY - 50, width: 100, height: 100)
        XCTAssertNil(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .right))
    }

    /// An unaligned window over a merged zone anchors on (and hops across) the merge.
    func testTargetZoneUnalignedOverMergedZone() {
        let layout = mergedTop()
        // ids:  row 0: 9 9 1 ; row 1: 2 3 4. Free window centered in the LEFT cell of
        // the wide merged zone 9 (col 0, row 0), filling no zone.
        let cell = GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area)
        let center = CGPoint(x: cell.midX, y: cell.midY)
        let freeRect = CGRect(x: center.x - 25, y: center.y - 20, width: 50, height: 40)
        XCTAssertNil(GridCalculation.zone(matchingWindowRect: freeRect, in: area, layout: layout))
        // Anchor is the merged zone 9. right hops across the whole merge -> zone 1.
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .right), 1)
        // down from the merged zone -> first differing cell of row 1 -> zone 2.
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .down), 2)
        // left is a wall -> capture into the anchor (zone 9).
        XCTAssertEqual(GridCalculation.targetZone(forWindowRect: freeRect, in: area, layout: layout, direction: .left), 9)
    }

    // MARK: - Cell range inference (M8a span)

    /// A window filling a single zone infers the 1×1 cell range of that zone.
    func testCellRangeSingleZone() {
        let layout = uniform3x2()
        // Zone 1 = (col 1, row 0).
        let rect = GridCalculation.zoneRect(layout: layout, zoneId: 1, in: area)
        let range = GridCalculation.cellRange(matchingWindowRect: rect, in: area, layout: layout)
        XCTAssertEqual(range, GridCalculation.CellRange(colMin: 1, colMax: 1, rowMin: 0, rowMax: 0))
    }

    /// A window already spanning a 2×2 block infers that multi-cell range, not a
    /// single cell. Built directly from the range's bounding rect.
    func testCellRangeMultiCellSpan() {
        let layout = uniform3x2()
        // Cols 0-1, rows 0-1 (the left 2×2 block of the 3×2 grid).
        let block = GridCalculation.CellRange(colMin: 0, colMax: 1, rowMin: 0, rowMax: 1)
        let rect = GridCalculation.rangeRect(block, in: area, layout: layout)
        let inferred = GridCalculation.cellRange(matchingWindowRect: rect, in: area, layout: layout)
        XCTAssertEqual(inferred, block)
    }

    /// A window within tolerance of a single cell still infers that 1×1 range, and
    /// is NOT widened into a larger range whose edges also happen to be near.
    func testCellRangeWithinToleranceStaysSingleCell() {
        let layout = uniform3x2()
        var rect = GridCalculation.zoneRect(layout: layout, zoneId: 4, in: area) // (col1,row1)
        rect = rect.insetBy(dx: 8, dy: 6).offsetBy(dx: 4, dy: -5) // within default tolerance 25
        let range = GridCalculation.cellRange(matchingWindowRect: rect, in: area, layout: layout)
        XCTAssertEqual(range, GridCalculation.CellRange(colMin: 1, colMax: 1, rowMin: 1, rowMax: 1))
    }

    /// A free/unaligned window (matching no range) falls back to the single cell
    /// under its CENTER — and the center cell respects the row=top convention.
    func testCellRangeFreeWindowFallsBackToCenterCell() {
        let layout = uniform3x2()
        // Center sits in the bottom-center cell => (col 1, row 1).
        let cell = GridCalculation.cellRect(layout: layout, col: 1, row: 1, in: area)
        let center = CGPoint(x: cell.midX, y: cell.midY)
        let freeRect = CGRect(x: center.x - 40, y: center.y - 30, width: 80, height: 60)
        XCTAssertNil(GridCalculation.zone(matchingWindowRect: freeRect, in: area, layout: layout))
        let range = GridCalculation.cellRange(matchingWindowRect: freeRect, in: area, layout: layout)
        XCTAssertEqual(range, GridCalculation.CellRange(colMin: 1, colMax: 1, rowMin: 1, rowMax: 1))
    }

    /// A free window centered in the TOP-left cell maps to row 0 (anti-mirroring:
    /// the top of the screen is the largest y but the smallest row index).
    func testCellRangeFreeWindowTopCellIsRow0() {
        let layout = uniform3x2()
        let cell = GridCalculation.cellRect(layout: layout, col: 0, row: 0, in: area)
        let center = CGPoint(x: cell.midX, y: cell.midY)
        let freeRect = CGRect(x: center.x - 20, y: center.y - 15, width: 40, height: 30)
        XCTAssertNil(GridCalculation.zone(matchingWindowRect: freeRect, in: area, layout: layout))
        let range = GridCalculation.cellRange(matchingWindowRect: freeRect, in: area, layout: layout)
        XCTAssertEqual(range, GridCalculation.CellRange(colMin: 0, colMax: 0, rowMin: 0, rowMax: 0))
    }

    /// A window whose center is OUTSIDE the area has no anchor cell -> nil.
    func testCellRangeCenterOutsideAreaIsNil() {
        let layout = uniform3x2()
        let freeRect = CGRect(x: area.minX - 300, y: area.midY - 50, width: 100, height: 100)
        XCTAssertNil(GridCalculation.cellRange(matchingWindowRect: freeRect, in: area, layout: layout))
    }

    // MARK: - grownRange (M8a span, grow-only, directional)

    /// Growing in each direction adjusts the correct edge by one, with the row
    /// convention honored: UP decrements rowMin (toward the top), DOWN increments
    /// rowMax (toward the bottom). The starting range is the interior cell so every
    /// direction has room to grow.
    func testGrownRangeEachDirection() {
        // 3 cols, 3 rows; start at the center cell (col1,row1).
        let start = GridCalculation.CellRange(colMin: 1, colMax: 1, rowMin: 1, rowMax: 1)
        XCTAssertEqual(GridCalculation.grownRange(start, direction: .left, cols: 3, rows: 3),
                       GridCalculation.CellRange(colMin: 0, colMax: 1, rowMin: 1, rowMax: 1))
        XCTAssertEqual(GridCalculation.grownRange(start, direction: .right, cols: 3, rows: 3),
                       GridCalculation.CellRange(colMin: 1, colMax: 2, rowMin: 1, rowMax: 1))
        // UP grows toward the TOP => smaller rowMin.
        XCTAssertEqual(GridCalculation.grownRange(start, direction: .up, cols: 3, rows: 3),
                       GridCalculation.CellRange(colMin: 1, colMax: 1, rowMin: 0, rowMax: 1))
        // DOWN grows toward the BOTTOM => larger rowMax.
        XCTAssertEqual(GridCalculation.grownRange(start, direction: .down, cols: 3, rows: 3),
                       GridCalculation.CellRange(colMin: 1, colMax: 1, rowMin: 1, rowMax: 2))
    }

    /// At each wall, growing in the wall direction returns nil (grow-only no-op).
    func testGrownRangeAtWallsIsNil() {
        // Range pinned to the top-left corner cell of a 3×2 grid.
        let topLeft = GridCalculation.CellRange(colMin: 0, colMax: 0, rowMin: 0, rowMax: 0)
        XCTAssertNil(GridCalculation.grownRange(topLeft, direction: .left, cols: 3, rows: 2))
        XCTAssertNil(GridCalculation.grownRange(topLeft, direction: .up, cols: 3, rows: 2))
        // Range pinned to the bottom-right corner cell.
        let bottomRight = GridCalculation.CellRange(colMin: 2, colMax: 2, rowMin: 1, rowMax: 1)
        XCTAssertNil(GridCalculation.grownRange(bottomRight, direction: .right, cols: 3, rows: 2))
        XCTAssertNil(GridCalculation.grownRange(bottomRight, direction: .down, cols: 3, rows: 2))
    }

    /// A range already spanning to a wall on one edge can still grow on the other
    /// edges; only the edge AT the wall is blocked.
    func testGrownRangeWideRangeGrowsRemainingEdges() {
        // Full top row of a 3×2 grid (cols 0-2, row 0). Up is blocked (row 0), down OK.
        let topRow = GridCalculation.CellRange(colMin: 0, colMax: 2, rowMin: 0, rowMax: 0)
        XCTAssertNil(GridCalculation.grownRange(topRow, direction: .up, cols: 3, rows: 2))
        XCTAssertNil(GridCalculation.grownRange(topRow, direction: .left, cols: 3, rows: 2))
        XCTAssertNil(GridCalculation.grownRange(topRow, direction: .right, cols: 3, rows: 2))
        XCTAssertEqual(GridCalculation.grownRange(topRow, direction: .down, cols: 3, rows: 2),
                       GridCalculation.CellRange(colMin: 0, colMax: 2, rowMin: 0, rowMax: 1))
    }

    // MARK: - rangeRect

    /// A single-cell range's rect equals that cell's rect (uniform layout).
    func testRangeRectSingleCellUniform() {
        let layout = uniform3x2()
        let single = GridCalculation.CellRange(colMin: 2, colMax: 2, rowMin: 1, rowMax: 1)
        assertRect(GridCalculation.rangeRect(single, in: area, layout: layout),
                   GridCalculation.cellRect(layout: layout, col: 2, row: 1, in: area))
    }

    /// A multi-cell range's rect is the bounding union of its corner cells. For the
    /// left 2×2 block of a 3×2 grid that's the left two-thirds, full height.
    func testRangeRectMultiCellUniform() {
        let layout = uniform3x2()
        let block = GridCalculation.CellRange(colMin: 0, colMax: 1, rowMin: 0, rowMax: 1)
        let rect = GridCalculation.rangeRect(block, in: area, layout: layout)
        XCTAssertEqual(rect.minX, area.minX, accuracy: eps)
        XCTAssertEqual(rect.width, (2.0 / 3) * area.width, accuracy: eps)
        XCTAssertEqual(rect.minY, area.minY, accuracy: eps)   // spans both rows => full height
        XCTAssertEqual(rect.maxY, area.maxY, accuracy: eps)
        XCTAssertEqual(rect.height, area.height, accuracy: eps)
    }

    /// rangeRect on a NON-uniform layout uses the actual boundary positions, not
    /// assumed-uniform cell sizes. Columns split at 0.25, rows (from top) at 0.75.
    func testRangeRectNonUniform() {
        let layout = ZoneLayout(
            id: "nu", name: "nu",
            colBoundaries: [0, 0.25, 1],
            rowBoundaries: [0, 0.75, 1],
            cellZones: [0, 1,
                        2, 3]
        )
        // Single top-left cell: narrow (0.25 wide) and tall (0.75), touching top.
        let topLeft = GridCalculation.rangeRect(
            GridCalculation.CellRange(colMin: 0, colMax: 0, rowMin: 0, rowMax: 0), in: area, layout: layout)
        XCTAssertEqual(topLeft.width, 0.25 * area.width, accuracy: eps)
        XCTAssertEqual(topLeft.height, 0.75 * area.height, accuracy: eps)
        XCTAssertEqual(topLeft.maxY, area.maxY, accuracy: eps)

        // Full first column (rows 0-1): still 0.25 wide, but now full height.
        let leftCol = GridCalculation.rangeRect(
            GridCalculation.CellRange(colMin: 0, colMax: 0, rowMin: 0, rowMax: 1), in: area, layout: layout)
        XCTAssertEqual(leftCol.width, 0.25 * area.width, accuracy: eps)
        XCTAssertEqual(leftCol.height, area.height, accuracy: eps)
        XCTAssertEqual(leftCol.minX, area.minX, accuracy: eps)
    }

    /// Anti-mirroring through rangeRect: growing UP from a bottom-row cell must
    /// extend the rect's TOP edge upward (toward larger y), and growing DOWN from a
    /// top-row cell must extend the BOTTOM edge downward (toward smaller y).
    func testRangeRectUpDownMapToTopBottom() {
        let layout = uniform3x2()
        // Start: bottom-left cell (col0,row1). Grow UP -> covers rows 0-1, col 0.
        let bottom = GridCalculation.CellRange(colMin: 0, colMax: 0, rowMin: 1, rowMax: 1)
        let grownUp = GridCalculation.grownRange(bottom, direction: .up, cols: 3, rows: 2)!
        let upRect = GridCalculation.rangeRect(grownUp, in: area, layout: layout)
        let bottomRect = GridCalculation.rangeRect(bottom, in: area, layout: layout)
        // Growing up keeps the bottom edge, raises the top edge to the screen top.
        XCTAssertEqual(upRect.minY, bottomRect.minY, accuracy: eps)
        XCTAssertEqual(upRect.maxY, area.maxY, accuracy: eps)
        XCTAssertGreaterThan(upRect.maxY, bottomRect.maxY)

        // Start: top-left cell (col0,row0). Grow DOWN -> covers rows 0-1, col 0.
        let top = GridCalculation.CellRange(colMin: 0, colMax: 0, rowMin: 0, rowMax: 0)
        let grownDown = GridCalculation.grownRange(top, direction: .down, cols: 3, rows: 2)!
        let downRect = GridCalculation.rangeRect(grownDown, in: area, layout: layout)
        let topRect = GridCalculation.rangeRect(top, in: area, layout: layout)
        // Growing down keeps the top edge, lowers the bottom edge to the screen bottom.
        XCTAssertEqual(downRect.maxY, topRect.maxY, accuracy: eps)
        XCTAssertEqual(downRect.minY, area.minY, accuracy: eps)
        XCTAssertLessThan(downRect.minY, topRect.minY)
    }

    /// rangeRectWithGaps insets the bounding rect like zoneRectWithGaps; gapSize 0
    /// is a no-op.
    func testRangeRectWithGaps() {
        let layout = uniform3x2()
        let range = GridCalculation.CellRange(colMin: 0, colMax: 1, rowMin: 0, rowMax: 0)
        let plain = GridCalculation.rangeRect(range, in: area, layout: layout)
        let gapped = GridCalculation.rangeRectWithGaps(range, in: area, layout: layout, gapSize: 10)
        XCTAssertLessThan(gapped.width, plain.width)
        XCTAssertLessThan(gapped.height, plain.height)
        assertRect(GridCalculation.rangeRectWithGaps(range, in: area, layout: layout, gapSize: 0), plain)
    }

    // MARK: - Gap-aware convenience

    func testZoneRectWithGapsInsetsTheRect() {
        let layout = uniform3x2()
        let plain = GridCalculation.zoneRect(layout: layout, zoneId: 0, in: area)
        let gapped = GridCalculation.zoneRectWithGaps(layout: layout, zoneId: 0, in: area, gapSize: 10)
        // Inset by gapSize on each side => narrower/shorter than the plain rect.
        XCTAssertLessThan(gapped.width, plain.width)
        XCTAssertLessThan(gapped.height, plain.height)
        // gapSize 0 is a no-op.
        assertRect(GridCalculation.zoneRectWithGaps(layout: layout, zoneId: 0, in: area, gapSize: 0), plain)
    }

    // MARK: - Shared-edge gap accounting (standardized on the classic edge-snap model)

    /// `sharedEdges` must classify each edge by whether a neighbour exists, honoring
    /// the Cocoa `.top`(high-y)/`.bottom`(low-y) convention against row 0 = TOP. This
    /// is the anti-mirroring gate for the gap accounting.
    func testSharedEdgesConvention() {
        let layout = ZoneLayout.uniform(cols: 3, rows: 3, id: "u", name: "u")
        // 3x3 identity zones: row 0 (top) 0 1 2 ; row 1 (mid) 3 4 5 ; row 2 (bottom) 6 7 8.
        // Center zone 4 touches no screen edge => all four edges shared.
        XCTAssertEqual(GridCalculation.sharedEdges(ofZone: 4, layout: layout), Edge.all)
        // Top-left zone 0: left + top are screen edges => only right + bottom shared.
        XCTAssertEqual(GridCalculation.sharedEdges(ofZone: 0, layout: layout), [.right, .bottom])
        // Bottom-right zone 8: right + bottom are screen edges => only left + top shared.
        XCTAssertEqual(GridCalculation.sharedEdges(ofZone: 8, layout: layout), [.left, .top])
        // Top-center zone 1: only the top is a screen edge => left + right + bottom shared.
        XCTAssertEqual(GridCalculation.sharedEdges(ofZone: 1, layout: layout), [.left, .right, .bottom])
    }

    /// A zone touching the screen boundary takes a FULL gap on those edges and a HALF
    /// gap on edges shared with a neighbour — the classic edge-snap accounting.
    func testZoneRectWithGapsUsesSharedEdges() {
        let layout = uniform2x2()
        let half: CGFloat = 5, full: CGFloat = 10
        // Zone 0 = top-left: LEFT + TOP on the screen edge (full), RIGHT + BOTTOM shared (half).
        let p0 = GridCalculation.zoneRect(layout: layout, zoneId: 0, in: area)
        let g0 = GridCalculation.zoneRectWithGaps(layout: layout, zoneId: 0, in: area, gapSize: 10)
        XCTAssertEqual(g0.minX, p0.minX + full, accuracy: eps, "left screen edge = full gap")
        XCTAssertEqual(g0.maxY, p0.maxY - full, accuracy: eps, "top screen edge = full gap")
        XCTAssertEqual(g0.maxX, p0.maxX - half, accuracy: eps, "right shared edge = half gap")
        XCTAssertEqual(g0.minY, p0.minY + half, accuracy: eps, "bottom shared edge = half gap")
        // Zone 3 = bottom-right: the mirror — LEFT + TOP shared (half), RIGHT + BOTTOM screen (full).
        let p3 = GridCalculation.zoneRect(layout: layout, zoneId: 3, in: area)
        let g3 = GridCalculation.zoneRectWithGaps(layout: layout, zoneId: 3, in: area, gapSize: 10)
        XCTAssertEqual(g3.minX, p3.minX + half, accuracy: eps, "left shared edge = half gap")
        XCTAssertEqual(g3.maxY, p3.maxY - half, accuracy: eps, "top shared edge = half gap")
        XCTAssertEqual(g3.maxX, p3.maxX - full, accuracy: eps, "right screen edge = full gap")
        XCTAssertEqual(g3.minY, p3.minY + full, accuracy: eps, "bottom screen edge = full gap")
    }

    /// The point of the change: two adjacent zones leave exactly ONE `gapSize`
    /// between their windows (half from each), matching the gap at the screen edge —
    /// not the doubled gap the old `.none`-everywhere inset produced.
    func testAdjacentZonesLeaveSingleGapBetweenThem() {
        let layout = uniform2x2()
        let gap: Float = 10
        let z0 = GridCalculation.zoneRectWithGaps(layout: layout, zoneId: 0, in: area, gapSize: gap) // top-left
        let z1 = GridCalculation.zoneRectWithGaps(layout: layout, zoneId: 1, in: area, gapSize: gap) // top-right
        let z2 = GridCalculation.zoneRectWithGaps(layout: layout, zoneId: 2, in: area, gapSize: gap) // bottom-left
        // Horizontal gap between the top two zones == gapSize.
        XCTAssertEqual(z1.minX - z0.maxX, CGFloat(gap), accuracy: eps)
        // Vertical gap between the left two zones == gapSize (z0 is above z2).
        XCTAssertEqual(z2.maxY - z0.minY, -CGFloat(gap), accuracy: eps, "z0 bottom sits gapSize above z2 top")
        XCTAssertEqual(z0.minY - z2.maxY, CGFloat(gap), accuracy: eps)
        // And each leaves a full gapSize at the screen edge it touches.
        XCTAssertEqual(z0.minX - area.minX, CGFloat(gap), accuracy: eps)
    }

    /// A drag-span / proximity box gaps using the shared edges of its bounding cell
    /// range, and `selectionRectWithGaps` agrees with `boundingRectWithGaps`.
    func testSpanWithGapsUsesSharedEdgesOfBoundingRange() {
        let layout = uniform2x2()
        let half: CGFloat = 5, full: CGFloat = 10
        // Top-row span [0,1]: left/right/top reach the screen (full), bottom shared (half).
        let plain = GridCalculation.boundingRect(ofZones: [0, 1], in: area, layout: layout)
        let gapped = GridCalculation.boundingRectWithGaps(ofZones: [0, 1], in: area, layout: layout, gapSize: 10)
        XCTAssertEqual(gapped.minX, plain.minX + full, accuracy: eps, "left screen edge = full")
        XCTAssertEqual(gapped.maxX, plain.maxX - full, accuracy: eps, "right screen edge = full")
        XCTAssertEqual(gapped.maxY, plain.maxY - full, accuracy: eps, "top screen edge = full")
        XCTAssertEqual(gapped.minY, plain.minY + half, accuracy: eps, "bottom shared = half")
        // selectionRectWithGaps over the same endpoints equals the bounding version.
        let sel = GridCalculation.selectionRectWithGaps(layout: layout, fromZone: 0, toZone: 1, in: area, gapSize: 10)
        assertRect(sel, gapped)
    }

    // MARK: - Quick-starter generators

    func testUniformGeneratorShape() {
        let layout = ZoneLayout.uniform(cols: 4, rows: 2, id: "g", name: "g")
        XCTAssertEqual(layout.cols, 4)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.colBoundaries.count, 5)   // cols + 1
        XCTAssertEqual(layout.rowBoundaries.count, 3)   // rows + 1
        XCTAssertEqual(layout.cellZones.count, 8)       // cols * rows
        // Identity (no-merge) cell->zone map.
        XCTAssertEqual(layout.cellZones, Array(0..<8))
        // Evenly spaced, ascending boundaries 0...1.
        XCTAssertEqual(layout.colBoundaries.first, 0)
        XCTAssertEqual(layout.colBoundaries.last, 1)
        for i in 1..<layout.colBoundaries.count {
            XCTAssertGreaterThan(layout.colBoundaries[i], layout.colBoundaries[i - 1])
        }
        XCTAssertEqual(layout.colBoundaries[1], 0.25, accuracy: eps)
    }

    func testNamedPresets() {
        XCTAssertEqual(ZoneLayout.halves().cols, 2)
        XCTAssertEqual(ZoneLayout.halves().rows, 1)
        XCTAssertEqual(ZoneLayout.thirds().cols, 3)
        XCTAssertEqual(ZoneLayout.thirds().rows, 1)
        XCTAssertEqual(ZoneLayout.grid2x2().cols, 2)
        XCTAssertEqual(ZoneLayout.grid2x2().rows, 2)
        XCTAssertEqual(ZoneLayout.grid3x2().cols, 3)
        XCTAssertEqual(ZoneLayout.grid3x2().rows, 2)
        XCTAssertEqual(ZoneLayout.grid4x2().cols, 4)
        XCTAssertEqual(ZoneLayout.grid4x2().rows, 2)

        // Each preset has a distinct identity zone per cell.
        let g = ZoneLayout.grid3x2()
        XCTAssertEqual(g.zoneIds.count, 6)
        XCTAssertEqual(g.cellZones, Array(0..<6))
    }

    func testUniformGeneratorClampsDegenerateInput() {
        let layout = ZoneLayout.uniform(cols: 0, rows: -3, id: "d", name: "d")
        // Clamped to at least 1×1.
        XCTAssertEqual(layout.cols, 1)
        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(layout.cellZones, [0])
    }
}
