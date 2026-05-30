//
//  GridLayoutModelTests.swift
//  RectangleTests / Lilypad
//
//  M1 verification: the zone data model and its grid Defaults round-trip
//  through JSON, and the new Defaults are registered for config export/import.
//

import XCTest
@testable import Rectangle

class GridLayoutModelTests: XCTestCase {

    /// 3 columns × 2 rows, with the two top cells merged into one zone.
    private func sampleLayout() -> ZoneLayout {
        ZoneLayout(
            id: "layout-1",
            name: "Layout 1",
            colBoundaries: [0, 1.0 / 3, 2.0 / 3, 1],
            rowBoundaries: [0, 0.5, 1],
            cellZones: [0, 0, 1,
                        2, 3, 4]
        )
    }

    private func samplePerDisplay() -> [String: PerDisplayLayouts] {
        ["UUID-A": PerDisplayLayouts(layouts: [sampleLayout()], activeLayoutId: "layout-1")]
    }

    // MARK: - Model round-trips

    func testZoneLayoutCodableRoundTrip() throws {
        let layout = sampleLayout()
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(ZoneLayout.self, from: data)
        XCTAssertEqual(layout, decoded)
    }

    func testZoneLayoutDerivedProperties() {
        let layout = sampleLayout()
        XCTAssertEqual(layout.cols, 3)
        XCTAssertEqual(layout.rows, 2)
        // Top two cells merged => 5 distinct zones, in first-appearance order.
        XCTAssertEqual(layout.zoneIds, [0, 1, 2, 3, 4])
    }

    func testPerDisplayLayoutsCodableRoundTrip() throws {
        let value = samplePerDisplay()
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode([String: PerDisplayLayouts].self, from: data)
        XCTAssertEqual(value, decoded)
    }

    func testActiveLayoutFallsBackToFirst() {
        XCTAssertEqual(PerDisplayLayouts(layouts: [sampleLayout()], activeLayoutId: "layout-1").activeLayout?.id, "layout-1")
        XCTAssertEqual(PerDisplayLayouts(layouts: [sampleLayout()], activeLayoutId: nil).activeLayout?.id, "layout-1")
        XCTAssertNil(PerDisplayLayouts().activeLayout)
    }

    // MARK: - Defaults persistence path

    func testGridLayoutsJSONDefaultRoundTrip() {
        let keyA = "test.gridLayoutsByDisplay.a"
        let keyB = "test.gridLayoutsByDisplay.b"
        defer {
            UserDefaults.standard.removeObject(forKey: keyA)
            UserDefaults.standard.removeObject(forKey: keyB)
        }
        let value = samplePerDisplay()
        let d1 = JSONDefault<[String: PerDisplayLayouts]>(key: keyA)
        d1.typedValue = value
        // toCodable() carries the JSON string; load() on a fresh default rehydrates it.
        let codable = d1.toCodable()
        let d2 = JSONDefault<[String: PerDisplayLayouts]>(key: keyB)
        d2.load(from: codable)
        XCTAssertEqual(d2.typedValue, value)
    }

    // MARK: - Defaults.array membership

    /// A setting omitted from Defaults.array silently drops from config export/import
    /// with no compile error — so assert the new keys are present.
    func testGridDefaultsRegisteredInArray() {
        let keys = Defaults.array.map { $0.key }
        XCTAssertTrue(keys.contains("gridModeEnabled"))
        XCTAssertTrue(keys.contains("gridLayoutsByDisplay"))
        XCTAssertTrue(keys.contains("gridSpanModifier"))
    }
}
