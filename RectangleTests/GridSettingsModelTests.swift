//
//  GridSettingsModelTests.swift
//  RectangleTests / Lilypad
//
//  M14 verification: the SwiftUI Layouts pane's `GridSettingsModel` round-trips
//  its add / rename / remove / make-active operations through `GridModel` (and
//  thus `Defaults.gridLayoutsByDisplay`) for a test display UUID, and reflects the
//  result in its published `layouts` / `activeLayoutId` mirror.
//
//  Like `GridModelTests`, these mutate the shared `Defaults.gridLayoutsByDisplay`,
//  so they use a unique per-display UUID key and reset that default in tearDown.
//

import XCTest
@testable import Rectangle

class GridSettingsModelTests: XCTestCase {

    // Unique key so a stray persisted value can't collide with real displays.
    private let uuid = "test-gridsettings-uuid-\(UUID().uuidString)"

    private var model: GridSettingsModel!

    override func setUp() {
        super.setUp()
        Defaults.gridLayoutsByDisplay.typedValue = [:]
        model = GridSettingsModel()
        // Point the pane at the isolated test display.
        model.selectedDisplayUUID = uuid
    }

    override func tearDown() {
        model = nil
        Defaults.gridLayoutsByDisplay.typedValue = nil
        UserDefaults.standard.removeObject(forKey: "gridLayoutsByDisplay")
        super.tearDown()
    }

    func testAddQuickStarterRoundTripsThroughGridModel() {
        XCTAssertTrue(model.layouts.isEmpty)

        model.addLayout(.grid2x2)
        // Reflected in the published mirror...
        XCTAssertEqual(model.layouts.count, 1)
        XCTAssertEqual(model.layouts.first?.cols, 2)
        XCTAssertEqual(model.layouts.first?.rows, 2)
        // ...and persisted through GridModel / Defaults.
        XCTAssertEqual(GridModel.instance.layouts(forDisplay: uuid).layouts.count, 1)
        // First added layout is active.
        XCTAssertEqual(model.activeLayoutId, model.layouts.first?.id)

        model.addLayout(.thirds)
        XCTAssertEqual(model.layouts.count, 2)
        XCTAssertEqual(model.layouts[1].cols, 3)
        XCTAssertEqual(model.layouts[1].rows, 1)
        // Adding a second layout must not steal active from the first.
        XCTAssertEqual(model.activeLayoutId, model.layouts.first?.id)
        // Quick-starters get fresh unique ids (no collision).
        XCTAssertNotEqual(model.layouts[0].id, model.layouts[1].id)
    }

    func testRenameRoundTrips() {
        model.addLayout(.grid2x2)
        let id = model.layouts[0].id
        model.renameLayout(id: id, to: "Work")
        XCTAssertEqual(model.layouts.first?.name, "Work")
        XCTAssertEqual(GridModel.instance.layouts(forDisplay: uuid).layouts.first?.name, "Work")
    }

    func testBlankRenameIsIgnored() {
        model.addLayout(.grid2x2)
        let original = model.layouts[0].name
        model.renameLayout(id: model.layouts[0].id, to: "   ")
        XCTAssertEqual(model.layouts.first?.name, original)
    }

    func testMakeActiveRoundTrips() {
        model.addLayout(.grid2x2)
        model.addLayout(.grid3x2)
        let secondId = model.layouts[1].id
        model.makeActive(id: secondId)
        XCTAssertEqual(model.activeLayoutId, secondId)
        XCTAssertEqual(GridModel.instance.activeLayout(forDisplay: uuid)?.id, secondId)
    }

    func testRemoveRoundTripsAndRepointsActive() {
        model.addLayout(.grid2x2)
        model.addLayout(.grid3x2)
        let firstId = model.layouts[0].id
        let secondId = model.layouts[1].id
        // first is active; removing it must repoint active to the remaining one.
        model.removeLayout(id: firstId)
        XCTAssertEqual(model.layouts.map { $0.id }, [secondId])
        XCTAssertEqual(model.activeLayoutId, secondId)
        XCTAssertEqual(GridModel.instance.layouts(forDisplay: uuid).layouts.map { $0.id }, [secondId])
    }

    func testRemoveLastClearsList() {
        model.addLayout(.halves)
        model.removeLayout(id: model.layouts[0].id)
        XCTAssertTrue(model.layouts.isEmpty)
        XCTAssertNil(model.activeLayoutId)
    }

    // MARK: - Settings write-through

    func testModifierChoiceMappingRoundTrips() {
        // None maps to raw 0; the single modifiers map to NSEvent.ModifierFlags raw values.
        XCTAssertEqual(GridModifierChoice.none.modifierRawValue, 0)
        XCTAssertEqual(GridModifierChoice.shift.modifierRawValue, Int(NSEvent.ModifierFlags.shift.rawValue))
        XCTAssertEqual(GridModifierChoice.from(rawValue: Int(NSEvent.ModifierFlags.option.rawValue)), .option)
        XCTAssertEqual(GridModifierChoice.from(rawValue: 999999), .none)
    }
}
