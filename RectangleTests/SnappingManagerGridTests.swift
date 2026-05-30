//
//  SnappingManagerGridTests.swift
//  RectangleTests / Lilypad
//
//  M5 verification: the PURE grid-mode engagement decision
//  `SnappingManager.gridModeEngaged(modifierFlags:gridModeEnabled:
//  activationModifierRawValue:)`. Grid mode engages during a drag ONLY when the
//  master flag is on AND the configured activation modifier is held — the sole
//  gate that chooses the grid path over the classic edge-snap path. These tests
//  cover the flag-on/off × modifier-held/not matrix so a regression that leaks
//  grid mode into the classic path (or vice versa) fails here.
//

import XCTest
import Cocoa
@testable import Rectangle

class SnappingManagerGridTests: XCTestCase {

    private let shift = Int(NSEvent.ModifierFlags.shift.rawValue)
    private let option = Int(NSEvent.ModifierFlags.option.rawValue)

    private func engaged(_ flags: NSEvent.ModifierFlags, enabled: Bool, modifier: Int) -> Bool {
        SnappingManager.gridModeEngaged(modifierFlags: flags,
                                        gridModeEnabled: enabled,
                                        activationModifierRawValue: modifier)
    }

    // MARK: - Flag OFF: never engaged, regardless of modifier

    func testFlagOffModifierHeld() {
        XCTAssertFalse(engaged(.shift, enabled: false, modifier: shift))
    }

    func testFlagOffModifierNotHeld() {
        XCTAssertFalse(engaged([], enabled: false, modifier: shift))
    }

    // MARK: - Flag ON: engaged iff the activation modifier is held

    func testFlagOnModifierHeld() {
        XCTAssertTrue(engaged(.shift, enabled: true, modifier: shift))
    }

    func testFlagOnModifierNotHeld() {
        XCTAssertFalse(engaged([], enabled: true, modifier: shift))
    }

    func testFlagOnWrongModifierHeld() {
        // Option held, but Shift is the activation modifier → not engaged.
        XCTAssertFalse(engaged(.option, enabled: true, modifier: shift))
    }

    func testFlagOnExtraModifierHeld() {
        // Shift + Option held, but only Shift is the activation modifier. Exact
        // match (like snapModifiers) means an extra modifier does NOT engage.
        XCTAssertFalse(engaged([.shift, .option], enabled: true, modifier: shift))
    }

    func testFlagOnIgnoresNonDeviceIndependentBits() {
        // Caps-lock / numeric-pad style bits outside deviceIndependentFlagsMask
        // must be masked off before comparison, so Shift still matches.
        var flags: NSEvent.ModifierFlags = .shift
        flags.insert(NSEvent.ModifierFlags(rawValue: 1 << 0)) // a low, non-device-independent bit
        XCTAssertTrue(engaged(flags, enabled: true, modifier: shift))
    }

    // MARK: - Zero activation modifier means "flag alone engages"

    func testZeroModifierEngagesOnFlagAlone() {
        XCTAssertTrue(engaged([], enabled: true, modifier: 0))
        XCTAssertTrue(engaged(.shift, enabled: true, modifier: 0))
        XCTAssertFalse(engaged([], enabled: false, modifier: 0))
    }
}
