//
//  GridModelTests.swift
//  RectangleTests / Lilypad
//
//  M3 verification: `GridModel` per-display CRUD (add / rename / remove /
//  setActive, including repointing the active layout when it is removed),
//  empty results for unknown displays, and idempotent default-layout seeding.
//
//  These tests mutate the shared `Defaults.gridLayoutsByDisplay`, so they use
//  unique per-display UUID keys and reset that default in tearDown to avoid
//  cross-test pollution.
//

import XCTest
@testable import Rectangle

class GridModelTests: XCTestCase {

    private let model = GridModel.instance

    // Unique keys so a stray persisted value can't collide with real displays.
    private let uuidA = "test-grid-uuid-A-\(UUID().uuidString)"
    private let uuidB = "test-grid-uuid-B-\(UUID().uuidString)"

    override func tearDown() {
        Defaults.gridLayoutsByDisplay.typedValue = nil
        UserDefaults.standard.removeObject(forKey: "gridLayoutsByDisplay")
        super.tearDown()
    }

    private func layout(_ id: String, _ name: String) -> ZoneLayout {
        ZoneLayout.uniform(cols: 2, rows: 2, id: id, name: name)
    }

    // MARK: - Unknown display

    func testLayoutsForUnknownDisplayReturnsEmpty() {
        let result = model.layouts(forDisplay: uuidA)
        XCTAssertTrue(result.layouts.isEmpty)
        XCTAssertNil(result.activeLayoutId)
        XCTAssertNil(result.activeLayout)
        XCTAssertNil(model.activeLayout(forDisplay: uuidA))
    }

    // MARK: - Add

    func testAddLayoutSetsFirstAsActive() {
        model.addLayout(layout("l1", "One"), forDisplay: uuidA)
        let result = model.layouts(forDisplay: uuidA)
        XCTAssertEqual(result.layouts.map { $0.id }, ["l1"])
        XCTAssertEqual(result.activeLayoutId, "l1")

        model.addLayout(layout("l2", "Two"), forDisplay: uuidA)
        let result2 = model.layouts(forDisplay: uuidA)
        XCTAssertEqual(result2.layouts.map { $0.id }, ["l1", "l2"])
        // Adding a second layout must not steal active from the first.
        XCTAssertEqual(result2.activeLayoutId, "l1")
    }

    func testAddLayoutIsPerDisplay() {
        model.addLayout(layout("a1", "A1"), forDisplay: uuidA)
        model.addLayout(layout("b1", "B1"), forDisplay: uuidB)
        XCTAssertEqual(model.layouts(forDisplay: uuidA).layouts.map { $0.id }, ["a1"])
        XCTAssertEqual(model.layouts(forDisplay: uuidB).layouts.map { $0.id }, ["b1"])
    }

    // MARK: - Rename

    func testRenameLayout() {
        model.addLayout(layout("l1", "One"), forDisplay: uuidA)
        model.renameLayout(id: "l1", to: "Renamed", forDisplay: uuidA)
        XCTAssertEqual(model.layouts(forDisplay: uuidA).layouts.first?.name, "Renamed")
    }

    func testRenameUnknownLayoutIsNoOp() {
        model.addLayout(layout("l1", "One"), forDisplay: uuidA)
        model.renameLayout(id: "does-not-exist", to: "X", forDisplay: uuidA)
        XCTAssertEqual(model.layouts(forDisplay: uuidA).layouts.first?.name, "One")
    }

    // MARK: - setActive

    func testSetActiveLayout() {
        model.addLayout(layout("l1", "One"), forDisplay: uuidA)
        model.addLayout(layout("l2", "Two"), forDisplay: uuidA)
        model.setActiveLayout(id: "l2", forDisplay: uuidA)
        XCTAssertEqual(model.layouts(forDisplay: uuidA).activeLayoutId, "l2")
        XCTAssertEqual(model.activeLayout(forDisplay: uuidA)?.id, "l2")
    }

    func testSetActiveUnknownLayoutIsNoOp() {
        model.addLayout(layout("l1", "One"), forDisplay: uuidA)
        model.setActiveLayout(id: "nope", forDisplay: uuidA)
        XCTAssertEqual(model.layouts(forDisplay: uuidA).activeLayoutId, "l1")
    }

    // MARK: - Remove

    func testRemoveNonActiveLayoutKeepsActive() {
        model.addLayout(layout("l1", "One"), forDisplay: uuidA)
        model.addLayout(layout("l2", "Two"), forDisplay: uuidA)
        // active is l1; remove l2.
        model.removeLayout(id: "l2", forDisplay: uuidA)
        let result = model.layouts(forDisplay: uuidA)
        XCTAssertEqual(result.layouts.map { $0.id }, ["l1"])
        XCTAssertEqual(result.activeLayoutId, "l1")
    }

    func testRemoveActiveLayoutRepointsActive() {
        model.addLayout(layout("l1", "One"), forDisplay: uuidA)
        model.addLayout(layout("l2", "Two"), forDisplay: uuidA)
        model.setActiveLayout(id: "l1", forDisplay: uuidA)
        // Removing the active layout (l1) must repoint to the first remaining.
        model.removeLayout(id: "l1", forDisplay: uuidA)
        let result = model.layouts(forDisplay: uuidA)
        XCTAssertEqual(result.layouts.map { $0.id }, ["l2"])
        XCTAssertEqual(result.activeLayoutId, "l2")
    }

    func testRemoveLastLayoutClearsActive() {
        model.addLayout(layout("l1", "One"), forDisplay: uuidA)
        model.removeLayout(id: "l1", forDisplay: uuidA)
        let result = model.layouts(forDisplay: uuidA)
        XCTAssertTrue(result.layouts.isEmpty)
        XCTAssertNil(result.activeLayoutId)
    }

    func testRemoveUnknownLayoutIsNoOp() {
        model.addLayout(layout("l1", "One"), forDisplay: uuidA)
        model.removeLayout(id: "nope", forDisplay: uuidA)
        XCTAssertEqual(model.layouts(forDisplay: uuidA).layouts.map { $0.id }, ["l1"])
        XCTAssertEqual(model.layouts(forDisplay: uuidA).activeLayoutId, "l1")
    }

    // MARK: - Seeding

    func testSeedDefaultLayoutsSeedsEmptyDisplays() {
        let seeded = model.seedDefaultLayouts(forDisplays: [uuidA, uuidB])
        XCTAssertEqual(Set(seeded), Set([uuidA, uuidB]))

        let a = model.layouts(forDisplay: uuidA)
        XCTAssertEqual(a.layouts.count, 1)
        // A single 2×2 starter, active.
        XCTAssertEqual(a.layouts[0].cols, 2)
        XCTAssertEqual(a.layouts[0].rows, 2)
        XCTAssertEqual(a.activeLayoutId, a.layouts[0].id)
        XCTAssertEqual(a.activeLayout?.id, a.layouts[0].id)

        // The second display is fully seeded too (not just present in `seeded`).
        let b = model.layouts(forDisplay: uuidB)
        XCTAssertEqual(b.layouts.count, 1)
        XCTAssertEqual(b.activeLayoutId, b.layouts[0].id)
        // Per-display isolation: ids don't collide across displays, and changing
        // one display's active layout doesn't disturb the other.
        XCTAssertTrue(Set(a.layouts.map { $0.id }).isDisjoint(with: Set(b.layouts.map { $0.id })))
        model.setActiveLayout(id: b.layouts[0].id, forDisplay: uuidB)
        XCTAssertEqual(model.layouts(forDisplay: uuidA).activeLayoutId, a.layouts[0].id)
    }

    func testSeedDefaultLayoutsIsIdempotent() {
        _ = model.seedDefaultLayouts(forDisplays: [uuidA])
        let firstCount = model.layouts(forDisplay: uuidA).layouts.count

        // Second seeding must not add or overwrite anything for uuidA.
        let secondPass = model.seedDefaultLayouts(forDisplays: [uuidA])
        XCTAssertTrue(secondPass.isEmpty)
        XCTAssertEqual(model.layouts(forDisplay: uuidA).layouts.count, firstCount)
    }

    func testSeedDefaultLayoutsOnlySeedsDisplaysWithoutLayouts() {
        // uuidA already has a custom layout; uuidB is empty.
        model.addLayout(layout("custom", "Custom"), forDisplay: uuidA)

        let seeded = model.seedDefaultLayouts(forDisplays: [uuidA, uuidB])

        // Only the empty display is seeded.
        XCTAssertEqual(seeded, [uuidB])
        // uuidA is untouched (still just the custom layout).
        XCTAssertEqual(model.layouts(forDisplay: uuidA).layouts.map { $0.id }, ["custom"])
        // uuidB got the starter set.
        XCTAssertEqual(model.layouts(forDisplay: uuidB).layouts.count, 1)
    }

    func testEnsureActiveLayoutComputesDefaultWithoutPersisting() {
        // An unconfigured display returns a usable COMPUTED default (2×2) but stores
        // NOTHING — persisting on the runtime path is what exposed the layouts dict to
        // the stale-cache clobber, so the grid now falls back to a computed default
        // and only persists layouts the user explicitly creates.
        let computed = model.ensureActiveLayout(forDisplay: uuidA)
        XCTAssertNotNil(computed)
        XCTAssertEqual(computed?.cols, 2)
        XCTAssertEqual(computed?.rows, 2)
        XCTAssertTrue(model.layouts(forDisplay: uuidA).layouts.isEmpty, "ensureActiveLayout must not persist a seed")

        // When the display HAS a stored layout, that one is returned (not the default).
        let stored = layout("stored", "Stored")
        model.addLayout(stored, forDisplay: uuidA)
        XCTAssertEqual(model.ensureActiveLayout(forDisplay: uuidA)?.id, "stored")
    }
}
