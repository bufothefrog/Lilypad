//
//  GridDataLossReproTests.swift
//  RectangleTests
//
//  Regression tests for the "relaunch drops grid layouts" data-loss bug.
//
//  Root cause: JSONDefault.typedValue is a load-once in-memory cache; every
//  GridModel write used `typedValue ?? [:]` as its base, so a write clobbered all
//  other displays whenever the cache was smaller than disk (another/earlier process
//  wrote after this one loaded) or nil (one schema-drifted entry nils the whole dict
//  via try?). The fix: GridModel reads FRESH from UserDefaults (lenient, per-entry)
//  as the writeback base, and ensureActiveLayout returns a COMPUTED default without
//  persisting.
//

import XCTest
@testable import Rectangle

final class GridDataLossReproTests: XCTestCase {

    private let key = "gridLayoutsByDisplay"
    private var savedJSON: String?

    private let a = "AAAA1111-0000-0000-0000-000000000001"
    private let b = "BBBB2222-0000-0000-0000-000000000002"
    private let c = "CCCC3333-0000-0000-0000-000000000003"

    override func setUp() {
        super.setUp()
        savedJSON = UserDefaults.standard.string(forKey: key)
    }

    override func tearDown() {
        // Restore whatever was there before so we never pollute real prefs / other tests.
        if let savedJSON {
            UserDefaults.standard.set(savedJSON, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        Defaults.gridLayoutsByDisplay.typedValue =
            UserDefaults.standard.string(forKey: key)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: PerDisplayLayouts].self, from: $0) }
        super.tearDown()
    }

    private func three() -> [String: PerDisplayLayouts] {
        [
            a: PerDisplayLayouts(layouts: [ZoneLayout.uniform(cols: 3, rows: 2, id: "la", name: "3 × 2")], activeLayoutId: "la"),
            b: PerDisplayLayouts(layouts: [ZoneLayout.uniform(cols: 4, rows: 2, id: "lb", name: "4 × 2")], activeLayoutId: "lb"),
            c: PerDisplayLayouts(layouts: [ZoneLayout.grid2x2(id: "lc", name: "2 × 2")], activeLayoutId: "lc"),
        ]
    }

    /// Write the dict straight to disk, bypassing the JSONDefault cache, so the
    /// in-memory cache is STALE relative to disk (the cross-process / earlier-session
    /// condition that triggered the clobber).
    private func writeDiskBypassingCache(_ dict: [String: PerDisplayLayouts]) {
        let data = try! JSONEncoder().encode(dict)
        UserDefaults.standard.set(String(data: data, encoding: .utf8)!, forKey: key)
    }

    private func diskCount() -> Int {
        guard let json = UserDefaults.standard.string(forKey: key),
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: PerDisplayLayouts].self, from: data)
        else { return -1 }
        return dict.count
    }

    // THE REGRESSION: with 3 displays on disk but a STALE cache, adding a layout for
    // a NEW display must keep all 3 + the new one. Before the fix this collapsed to a
    // 1-entry dict.
    func testAddLayoutWithStaleCacheDoesNotClobberOtherDisplays() {
        // Make the cache stale-and-small, then put the real 3 on disk underneath it.
        Defaults.gridLayoutsByDisplay.typedValue = [a: PerDisplayLayouts(layouts: [], activeLayoutId: nil)]
        writeDiskBypassingCache(three())

        GridModel.instance.addLayout(ZoneLayout.grid2x2(id: "new", name: "new"), forDisplay: "DDDD4444-0000-0000-0000-000000000004")

        XCTAssertEqual(diskCount(), 4, "addLayout clobbered other displays from a stale cache")
    }

    // removeLayout on one display must not drop the others, even from a stale cache.
    func testRemoveLayoutWithStaleCacheKeepsOtherDisplays() {
        Defaults.gridLayoutsByDisplay.typedValue = [:]
        writeDiskBypassingCache(three())

        GridModel.instance.removeLayout(id: "la", forDisplay: a)

        XCTAssertEqual(diskCount(), 3, "removeLayout dropped unrelated displays")
        XCTAssertTrue(GridModel.instance.layouts(forDisplay: a).layouts.isEmpty)
        XCTAssertEqual(GridModel.instance.layouts(forDisplay: b).layouts.count, 1)
    }

    // A single schema-drifted entry must not nil the whole dict: lenient per-entry
    // decode keeps the good ones; a write preserves them.
    func testDriftedEntryDoesNotWipeGoodDisplays() {
        // B's layout is missing required `cellZones` — strict decode of the whole dict fails.
        let drifted = """
        {"\(a)":{"activeLayoutId":"la","layouts":[{"name":"3 × 2","rowBoundaries":[0,0.5,1],"colBoundaries":[0,0.5,1],"cellZones":[0,1,2,3],"id":"la"}]},"\(b)":{"activeLayoutId":"lb","layouts":[{"name":"4 × 2","rowBoundaries":[0,0.5,1],"colBoundaries":[0,0.25,0.5,0.75,1],"id":"lb"}]}}
        """
        UserDefaults.standard.set(drifted, forKey: key)
        Defaults.gridLayoutsByDisplay.typedValue = nil

        // A write for a new display must keep A (the good entry), not collapse to 1.
        GridModel.instance.addLayout(ZoneLayout.grid2x2(id: "z", name: "z"), forDisplay: c)

        XCTAssertNotNil(GridModel.instance.layouts(forDisplay: a).activeLayout, "good display A was wiped by a drifted sibling")
        XCTAssertEqual(GridModel.instance.layouts(forDisplay: c).layouts.count, 1)
    }

    // ensureActiveLayout returns a usable computed default for an unconfigured
    // display WITHOUT persisting anything (no write surface for the clobber).
    func testEnsureActiveLayoutComputesDefaultWithoutWriting() {
        // Empty state for `a` (note: typedValue = [:] writes "{}" to disk, so we
        // assert the stored string is UNCHANGED by ensureActiveLayout, not nil).
        Defaults.gridLayoutsByDisplay.typedValue = [:]
        let before = UserDefaults.standard.string(forKey: key)

        let layout = GridModel.instance.ensureActiveLayout(forDisplay: a)

        XCTAssertNotNil(layout)
        XCTAssertEqual(layout?.cols, 2)
        XCTAssertEqual(layout?.rows, 2)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), before, "ensureActiveLayout persisted a layout — it must not write")
    }
}
