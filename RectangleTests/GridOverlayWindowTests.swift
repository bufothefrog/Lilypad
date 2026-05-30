//
//  GridOverlayWindowTests.swift
//  RectangleTests / Lilypad
//
//  M4 verification — the overlay-to-screen coordinate integration, exercised
//  through the pure `GridOverlayWindow.overlayZoneFrames(layout:screenFrame:
//  visibleFrame:)`. This is the M4 gate: it asserts that zone rects computed by
//  `GridCalculation` inside the screen's adjusted visible frame land in the
//  overlay view's LOCAL coordinates with
//    - the correct count (uniform / merged / non-uniform layouts),
//    - the right origin offset (screenFrame has a non-zero origin),
//    - and NO vertical flip (the content view is non-flipped, so a top-row zone
//      keeps the largest local y and a bottom-row zone the smallest).
//
//  A `visibleFrame` inset on the top (and the other edges) of a `screenFrame`
//  with a non-zero origin means a missed origin-offset or a mirrored y both
//  surface as failures here, before any pixels are drawn.
//

import XCTest
import CoreGraphics
@testable import Rectangle

class GridOverlayWindowTests: XCTestCase {

    private let eps: CGFloat = 1e-6

    // A screen with a NON-ZERO origin (e.g. a secondary display to the right of
    // the main one). If `overlayZoneFrames` forgets to subtract the origin, every
    // rect lands ~3000pt off and the in-bounds assertions fail.
    private let screenFrame = CGRect(x: 3000, y: -200, width: 1600, height: 1000)

    // The adjusted visible frame, inset asymmetrically: a big TOP inset (menu bar
    // / notch), small bottom, and unequal left/right. The asymmetric top inset is
    // what makes a vertical flip detectable — top-row zones must hug the top.
    //   visibleFrame origin   = (3000 + 40, -200 + 30) = (3040, -170)
    //   visibleFrame size     = (1600 - 40 - 20, 1000 - 30 - 80) = (1540, 890)
    private let visibleFrame = CGRect(x: 3040, y: -170, width: 1540, height: 890)

    // 3 cols × 2 rows uniform → 6 zones (rows: top = 0 1 2, bottom = 3 4 5).
    private func uniform3x2() -> ZoneLayout {
        ZoneLayout.uniform(cols: 3, rows: 2, id: "u", name: "u")
    }

    // 2×2 with the top two cells merged into one wide zone:
    //   cells:  zone 0  zone 0
    //           zone 1  zone 2
    // → 3 distinct zones.
    private func merged2x2() -> ZoneLayout {
        ZoneLayout(
            id: "m", name: "m",
            colBoundaries: [0, 0.5, 1],
            rowBoundaries: [0, 0.5, 1],
            cellZones: [0, 0, 1, 2]
        )
    }

    // Non-uniform 2×2: a wide-left column and a short top row, no merges → 4 zones.
    //   col split at 0.7, row split at 0.25 (measured from the TOP).
    private func nonUniform2x2() -> ZoneLayout {
        ZoneLayout(
            id: "n", name: "n",
            colBoundaries: [0, 0.7, 1],
            rowBoundaries: [0, 0.25, 1],
            cellZones: [0, 1, 2, 3]
        )
    }

    // MARK: - Zone count

    func testZoneCountUniform() {
        let frames = GridOverlayWindow.overlayZoneFrames(
            layout: uniform3x2(), screenFrame: screenFrame, visibleFrame: visibleFrame)
        XCTAssertEqual(frames.count, 6)
        XCTAssertEqual(Set(frames.keys), Set(0...5))
    }

    func testZoneCountMerged() {
        let frames = GridOverlayWindow.overlayZoneFrames(
            layout: merged2x2(), screenFrame: screenFrame, visibleFrame: visibleFrame)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(Set(frames.keys), Set([0, 1, 2]))
    }

    func testZoneCountNonUniform() {
        let frames = GridOverlayWindow.overlayZoneFrames(
            layout: nonUniform2x2(), screenFrame: screenFrame, visibleFrame: visibleFrame)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(Set(frames.keys), Set([0, 1, 2, 3]))
    }

    // MARK: - The conversion: no flip, correct origin offset

    /// In the NON-FLIPPED overlay view, the top row must sit at the LARGEST local
    /// y and the bottom row at the smallest. With the inset visible frame the top
    /// zones hug the visible-area top, NOT y == screen height.
    func testTopRowMapsToTopOfWindowLocalSpace() {
        let frames = GridOverlayWindow.overlayZoneFrames(
            layout: uniform3x2(), screenFrame: screenFrame, visibleFrame: visibleFrame)

        guard let topLeft = frames[0], let bottomLeft = frames[3] else {
            return XCTFail("missing zones")
        }

        // Top row higher (larger y) than bottom row → no vertical mirroring.
        XCTAssertGreaterThan(topLeft.minY, bottomLeft.minY, "top row must have a larger local y than the bottom row")
        XCTAssertGreaterThan(topLeft.maxY, bottomLeft.maxY)

        // The top zone's top edge equals the visible-area top in LOCAL coords:
        //   visibleFrame.maxY - screenFrame.minY = (-170 + 890) - (-200) = 920.
        let expectedTopLocalY = visibleFrame.maxY - screenFrame.minY
        XCTAssertEqual(topLeft.maxY, expectedTopLocalY, accuracy: eps)

        // The bottom zone's bottom edge equals the visible-area bottom in LOCAL coords:
        //   visibleFrame.minY - screenFrame.minY = -170 - (-200) = 30.
        let expectedBottomLocalY = visibleFrame.minY - screenFrame.minY
        XCTAssertEqual(bottomLeft.minY, expectedBottomLocalY, accuracy: eps)
    }

    /// Left column hugs the visible-area left edge in local coords; right column
    /// the right edge. Catches a dropped `-screenFrame.minX`.
    func testLeftRightMapCorrectly() {
        let frames = GridOverlayWindow.overlayZoneFrames(
            layout: uniform3x2(), screenFrame: screenFrame, visibleFrame: visibleFrame)

        guard let left = frames[0], let right = frames[2] else {
            return XCTFail("missing zones")
        }

        XCTAssertLessThan(left.minX, right.minX, "col 0 must be further left than the last col")

        // Left edge of col 0 in local coords = visibleFrame.minX - screenFrame.minX.
        let expectedLeftLocalX = visibleFrame.minX - screenFrame.minX
        XCTAssertEqual(left.minX, expectedLeftLocalX, accuracy: eps)

        // Right edge of the last col = visibleFrame.maxX - screenFrame.minX.
        let expectedRightLocalX = visibleFrame.maxX - screenFrame.minX
        XCTAssertEqual(right.maxX, expectedRightLocalX, accuracy: eps)
    }

    /// The non-uniform top row (short, the 0.25 band from the TOP) must still be
    /// the TALLEST-positioned band: its zones sit above the larger bottom band.
    func testNonUniformTopBandIsAtTop() {
        let frames = GridOverlayWindow.overlayZoneFrames(
            layout: nonUniform2x2(), screenFrame: screenFrame, visibleFrame: visibleFrame)

        guard let topZone = frames[0], let bottomZone = frames[2] else {
            return XCTFail("missing zones")
        }
        XCTAssertGreaterThan(topZone.minY, bottomZone.minY)
        // Top band is the short one (0.25 of height); bottom band is the rest (0.75).
        XCTAssertLessThan(topZone.height, bottomZone.height)
        XCTAssertEqual(topZone.maxY, visibleFrame.maxY - screenFrame.minY, accuracy: eps)
    }

    // MARK: - In-bounds

    /// Every returned rect must lie within the window-local bounds
    /// (0, 0, screenFrame.width, screenFrame.height). A missed origin offset or a
    /// flip pushes a rect out of these bounds.
    func testAllFramesWithinWindowLocalBounds() {
        let bounds = CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)
        for layout in [uniform3x2(), merged2x2(), nonUniform2x2()] {
            let frames = GridOverlayWindow.overlayZoneFrames(
                layout: layout, screenFrame: screenFrame, visibleFrame: visibleFrame)
            XCTAssertFalse(frames.isEmpty)
            for (zoneId, rect) in frames {
                XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - eps, "zone \(zoneId) minX out of bounds")
                XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - eps, "zone \(zoneId) minY out of bounds")
                XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + eps, "zone \(zoneId) maxX out of bounds")
                XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + eps, "zone \(zoneId) maxY out of bounds")
            }
        }
    }
}
