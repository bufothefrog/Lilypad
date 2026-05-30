//
//  SnappingManagerGridTests.swift
//  RectangleTests / Lilypad
//
//  M5/M6 verification: the PURE grid-mode engagement decision
//  `SnappingManager.gridModeEngaged(modifierFlags:gridModeEnabled:
//  activationModifierRawValue:spanModifierRawValue:)`. Grid mode engages during a
//  drag when the master flag is on AND the held device-independent modifiers, with
//  the span modifier bits removed, equal the activation modifier — the sole gate
//  that chooses the grid path over the classic edge-snap path. These tests cover
//  the flag-on/off × modifier-held/not matrix, INCLUDING the M6 span-coexistence
//  cases (Shift, Shift+span both engage; Shift+other does not; span alone does
//  not), so a regression that leaks grid mode into the classic path (or vice
//  versa), or that breaks span coexistence, fails here.
//

import XCTest
import Cocoa
@testable import Rectangle

class SnappingManagerGridTests: XCTestCase {

    private let shift = Int(NSEvent.ModifierFlags.shift.rawValue)
    private let option = Int(NSEvent.ModifierFlags.option.rawValue)
    private let command = Int(NSEvent.ModifierFlags.command.rawValue)

    // Default config: Shift activates, Option spans (matching Defaults).
    private func engaged(_ flags: NSEvent.ModifierFlags, enabled: Bool, modifier: Int, span: Int? = nil) -> Bool {
        SnappingManager.gridModeEngaged(modifierFlags: flags,
                                        gridModeEnabled: enabled,
                                        activationModifierRawValue: modifier,
                                        spanModifierRawValue: span ?? option)
    }

    private func spanHeld(_ flags: NSEvent.ModifierFlags, span: Int) -> Bool {
        SnappingManager.spanModifierHeld(modifierFlags: flags, spanModifierRawValue: span)
    }

    // MARK: - Flag OFF: never engaged, regardless of modifier

    func testFlagOffModifierHeld() {
        XCTAssertFalse(engaged(.shift, enabled: false, modifier: shift))
    }

    func testFlagOffModifierNotHeld() {
        XCTAssertFalse(engaged([], enabled: false, modifier: shift))
    }

    // MARK: - Flag ON: engaged iff the activation modifier is held (span tolerated)

    func testFlagOnModifierHeld() {
        XCTAssertTrue(engaged(.shift, enabled: true, modifier: shift))
    }

    func testFlagOnModifierNotHeld() {
        XCTAssertFalse(engaged([], enabled: true, modifier: shift))
    }

    func testFlagOnWrongModifierHeld() {
        // Command held, but Shift is the activation modifier → not engaged.
        XCTAssertFalse(engaged(.command, enabled: true, modifier: shift))
    }

    func testFlagOnIgnoresNonDeviceIndependentBits() {
        // Caps-lock / numeric-pad style bits outside deviceIndependentFlagsMask
        // must be masked off before comparison, so Shift still matches.
        var flags: NSEvent.ModifierFlags = .shift
        flags.insert(NSEvent.ModifierFlags(rawValue: 1 << 0)) // a low, non-device-independent bit
        XCTAssertTrue(engaged(flags, enabled: true, modifier: shift))
    }

    // MARK: - M6 span coexistence (Shift activates, Option spans)

    func testActivationPlusSpanStillEngages() {
        // Shift + Option (span) held: the span bits are stripped, leaving Shift,
        // which equals the activation modifier → STILL engaged (this is the whole
        // point of M6 — span must not disengage grid mode).
        XCTAssertTrue(engaged([.shift, .option], enabled: true, modifier: shift))
    }

    func testSpanAloneDoesNotEngage() {
        // Option (span) alone, no Shift: stripping span leaves nothing, which is
        // not the activation modifier → NOT engaged.
        XCTAssertFalse(engaged(.option, enabled: true, modifier: shift))
    }

    func testActivationPlusSpanPlusOtherDoesNotEngage() {
        // Shift + Option (span) + Command: stripping span leaves Shift+Command,
        // which is not the activation modifier → NOT engaged.
        XCTAssertFalse(engaged([.shift, .option, .command], enabled: true, modifier: shift))
    }

    func testActivationPlusNonSpanExtraDoesNotEngage() {
        // Shift + Command (Command is NOT the span modifier): nothing is stripped,
        // so Shift+Command ≠ Shift → NOT engaged.
        XCTAssertFalse(engaged([.shift, .command], enabled: true, modifier: shift))
    }

    func testSpanEqualsActivationCollapsesToExactMatch() {
        // If the span modifier equals the activation modifier, we must NOT strip
        // the activation bits, so this collapses to M5 exact-match behavior:
        // Shift engages, Shift+Option does not.
        XCTAssertTrue(engaged(.shift, enabled: true, modifier: shift, span: shift))
        XCTAssertFalse(engaged([.shift, .option], enabled: true, modifier: shift, span: shift))
    }

    // MARK: - spanModifierHeld helper

    func testSpanModifierHeld() {
        XCTAssertTrue(spanHeld([.shift, .option], span: option))
        XCTAssertTrue(spanHeld(.option, span: option))
        XCTAssertFalse(spanHeld(.shift, span: option))
        XCTAssertFalse(spanHeld([], span: option))
        // A zero span modifier is never "held".
        XCTAssertFalse(spanHeld(.option, span: 0))
    }

    // MARK: - Zero activation modifier means "flag alone engages"

    func testZeroModifierEngagesOnFlagAlone() {
        XCTAssertTrue(engaged([], enabled: true, modifier: 0))
        XCTAssertTrue(engaged(.shift, enabled: true, modifier: 0))
        // Even with the span modifier held, a zero activation engages on the flag.
        XCTAssertTrue(engaged(.option, enabled: true, modifier: 0))
        XCTAssertFalse(engaged([], enabled: false, modifier: 0))
    }
}
