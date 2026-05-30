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
