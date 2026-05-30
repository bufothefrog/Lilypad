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
        XCTAssertTrue(keys.contains("gridActivationModifier"))
        XCTAssertTrue(keys.contains("gridSpanModifier"))
        XCTAssertTrue(keys.contains("gridSelectedZoneColor"))
        XCTAssertTrue(keys.contains("gridUnselectedZoneColor"))
        XCTAssertTrue(keys.contains("gridUseAccentForSelected"))
        XCTAssertTrue(keys.contains("gridProximitySpanEnabled"))
        XCTAssertTrue(keys.contains("gridProximitySpanRadius"))
        XCTAssertTrue(keys.contains("gridWallActionUp"))
        XCTAssertTrue(keys.contains("gridWallActionDown"))
        XCTAssertTrue(keys.contains("gridWallActionLeft"))
        XCTAssertTrue(keys.contains("gridWallActionRight"))
        XCTAssertTrue(keys.contains("shortcutTargetMode"))
    }
}

// MARK: - M9: monitor-relative layout-activation slot resolution

/// Unit tests for the PURE slot resolution backing `activateLayoutSlot*`:
/// `GridLayoutManager.layoutId(forSlot:in:)` maps a 1-based slot to a layout id,
/// returning nil for any out-of-range slot (including an empty layout list).
class GridLayoutSlotTests: XCTestCase {

    private func layout(_ id: String) -> ZoneLayout {
        ZoneLayout(id: id, name: id, colBoundaries: [0, 0.5, 1], rowBoundaries: [0, 1], cellZones: [0, 1])
    }

    private func threeLayouts() -> PerDisplayLayouts {
        PerDisplayLayouts(layouts: [layout("a"), layout("b"), layout("c")], activeLayoutId: "a")
    }

    func testInRangeSlotsResolveToTheLayoutAtThatPosition() {
        let perDisplay = threeLayouts()
        XCTAssertEqual(GridLayoutManager.layoutId(forSlot: 1, in: perDisplay), "a")
        XCTAssertEqual(GridLayoutManager.layoutId(forSlot: 2, in: perDisplay), "b")
        XCTAssertEqual(GridLayoutManager.layoutId(forSlot: 3, in: perDisplay), "c")
    }

    func testOutOfRangeSlotReturnsNil() {
        let perDisplay = threeLayouts()
        // Slot beyond the layout count.
        XCTAssertNil(GridLayoutManager.layoutId(forSlot: 4, in: perDisplay))
        // Slot below the 1-based range (defensive — actions only emit 1...9).
        XCTAssertNil(GridLayoutManager.layoutId(forSlot: 0, in: perDisplay))
        XCTAssertNil(GridLayoutManager.layoutId(forSlot: -1, in: perDisplay))
    }

    func testEmptyLayoutListReturnsNilForEverySlot() {
        let empty = PerDisplayLayouts()
        XCTAssertNil(GridLayoutManager.layoutId(forSlot: 1, in: empty))
        XCTAssertNil(GridLayoutManager.layoutId(forSlot: 9, in: empty))
    }

    // MARK: ShortcutTargetMode raw values stable (persisted)

    func testShortcutTargetModeRawValuesStable() {
        XCTAssertEqual(ShortcutTargetMode.frontWindow.rawValue, 1)
        XCTAssertEqual(ShortcutTargetMode.cursor.rawValue, 2)
        // 0 must not decode to any case, so a never-set key falls through to defaultValue.
        XCTAssertNil(ShortcutTargetMode(rawValue: 0))
    }
}

// MARK: - Per-edge wall action decision logic (M8b)

/// Unit tests for the PURE decision helpers in `GridLayoutManager` that back the
/// repeat-at-wall edge actions: the direction -> EdgeAction mapping, the
/// fire-vs-prime decision, and the EdgeAction -> WindowAction reuse mapping.
class GridWallActionTests: XCTestCase {

    // MARK: shouldFireWallAction (fire-vs-prime)

    func testFiresOnlyOnConsecutiveWallRepeat() {
        // At the wall + previous action was the same grid move => FIRE.
        XCTAssertTrue(GridLayoutManager.shouldFireWallAction(edgeAction: .maximize, atWall: true, lastActionWasSameMove: true))
        // First press at the wall (no matching prior action) => PRIME, don't fire.
        XCTAssertFalse(GridLayoutManager.shouldFireWallAction(edgeAction: .maximize, atWall: true, lastActionWasSameMove: false))
        // Not at the wall => never a wall action.
        XCTAssertFalse(GridLayoutManager.shouldFireWallAction(edgeAction: .maximize, atWall: false, lastActionWasSameMove: true))
    }

    func testNeverFiresWhenEdgeActionIsNone() {
        XCTAssertFalse(GridLayoutManager.shouldFireWallAction(edgeAction: .none, atWall: true, lastActionWasSameMove: true))
        XCTAssertFalse(GridLayoutManager.shouldFireWallAction(edgeAction: .none, atWall: false, lastActionWasSameMove: false))
    }

    // MARK: wallAction(for:) — per-edge defaults

    /// The default per-edge actions match the user's example: up=maximize,
    /// down=minimize, left/right=none. Reads through Defaults, so guard against a
    /// previously-persisted value polluting the test run by writing the defaults first.
    func testPerEdgeDefaults() {
        let prevUp = Defaults.gridWallActionUp.value
        let prevDown = Defaults.gridWallActionDown.value
        let prevLeft = Defaults.gridWallActionLeft.value
        let prevRight = Defaults.gridWallActionRight.value
        defer {
            Defaults.gridWallActionUp.value = prevUp
            Defaults.gridWallActionDown.value = prevDown
            Defaults.gridWallActionLeft.value = prevLeft
            Defaults.gridWallActionRight.value = prevRight
        }

        Defaults.gridWallActionUp.value = .maximize
        Defaults.gridWallActionDown.value = .minimize
        Defaults.gridWallActionLeft.value = .none
        Defaults.gridWallActionRight.value = .none

        XCTAssertEqual(GridLayoutManager.wallAction(for: .up), .maximize)
        XCTAssertEqual(GridLayoutManager.wallAction(for: .down), .minimize)
        XCTAssertEqual(GridLayoutManager.wallAction(for: .left), .none)
        XCTAssertEqual(GridLayoutManager.wallAction(for: .right), .none)
    }

    // MARK: windowAction(for:direction:) — EdgeAction -> WindowAction reuse

    func testHalfMapsTowardEdge() {
        XCTAssertEqual(GridLayoutManager.windowAction(for: .half, direction: .left), .leftHalf)
        XCTAssertEqual(GridLayoutManager.windowAction(for: .half, direction: .right), .rightHalf)
        XCTAssertEqual(GridLayoutManager.windowAction(for: .half, direction: .up), .topHalf)
        XCTAssertEqual(GridLayoutManager.windowAction(for: .half, direction: .down), .bottomHalf)
    }

    func testMaximizeMapsToMaximizeForEveryEdge() {
        for dir in [GridCalculation.Direction.left, .right, .up, .down] {
            XCTAssertEqual(GridLayoutManager.windowAction(for: .maximize, direction: dir), .maximize)
        }
    }

    func testNextDisplayMapping() {
        XCTAssertEqual(GridLayoutManager.windowAction(for: .nextDisplay, direction: .left), .previousDisplay)
        XCTAssertEqual(GridLayoutManager.windowAction(for: .nextDisplay, direction: .up), .previousDisplay)
        XCTAssertEqual(GridLayoutManager.windowAction(for: .nextDisplay, direction: .right), .nextDisplay)
        XCTAssertEqual(GridLayoutManager.windowAction(for: .nextDisplay, direction: .down), .nextDisplay)
    }

    func testNoneAndMinimizeHaveNoWindowAction() {
        for dir in [GridCalculation.Direction.left, .right, .up, .down] {
            XCTAssertNil(GridLayoutManager.windowAction(for: .none, direction: dir))
            // minimize is handled by the AX minimize path, not a WindowAction.
            XCTAssertNil(GridLayoutManager.windowAction(for: .minimize, direction: dir))
        }
    }

    // MARK: EdgeAction raw values are stable (persisted)

    /// Raw values start at 1 by the shared `IntEnumDefault` convention: `0` is the
    /// reserved "unset" sentinel so `IntEnumDefault.init` falls through to its
    /// `defaultValue` on a fresh install (see `testFreshUnsetDefaultsFallThrough`).
    func testEdgeActionRawValuesStable() {
        XCTAssertEqual(EdgeAction.none.rawValue, 1)
        XCTAssertEqual(EdgeAction.maximize.rawValue, 2)
        XCTAssertEqual(EdgeAction.minimize.rawValue, 3)
        XCTAssertEqual(EdgeAction.half.rawValue, 4)
        XCTAssertEqual(EdgeAction.nextDisplay.rawValue, 5)
        // 0 must NOT decode to any case, so a never-set UserDefaults key (which reads
        // back as 0) falls through to the IntEnumDefault `defaultValue`.
        XCTAssertNil(EdgeAction(rawValue: 0))
    }

    /// On a FRESH install (UserDefaults key never written) `IntEnumDefault.init` reads
    /// `integer(forKey:) == 0`, then `E(rawValue: 0) ?? defaultValue`. Because `0` is not
    /// a valid `EdgeAction`, this MUST fall through to the documented per-edge defaults
    /// (up -> .maximize, down -> .minimize) rather than silently resolving to `.none`.
    /// This exercises the path the always-write `testPerEdgeDefaults` masks.
    func testFreshUnsetDefaultsFallThrough() {
        let keys = ["gridWallActionUp", "gridWallActionDown", "gridWallActionLeft", "gridWallActionRight"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value = value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        for key in keys { UserDefaults.standard.removeObject(forKey: key) }

        // Re-init the IntEnumDefaults against the now-cleared keys (fresh-install path).
        XCTAssertEqual(IntEnumDefault<EdgeAction>(key: "gridWallActionUp", defaultValue: .maximize).value, .maximize)
        XCTAssertEqual(IntEnumDefault<EdgeAction>(key: "gridWallActionDown", defaultValue: .minimize).value, .minimize)
        XCTAssertEqual(IntEnumDefault<EdgeAction>(key: "gridWallActionLeft", defaultValue: .none).value, .none)
        XCTAssertEqual(IntEnumDefault<EdgeAction>(key: "gridWallActionRight", defaultValue: .none).value, .none)
    }
}
