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

    // MARK: - gridCommitDecision (mouseUp commit-branch precedence)
    //
    // PURE decision the `.leftMouseUp` handler uses to pick the commit branch from
    // the previewed state. The regression these guard: a proximity span highlighted
    // over an OFF-AREA cursor (currentGridZone == nil) must still COMMIT — the
    // original `guard let zone = currentGridZone` over-broadly gated the whole
    // commit, so the overlay showed a span the user released on, and nothing snapped.

    private func decide(spanEngaged: Bool = false,
                        anchor: Int? = nil,
                        current: Int? = nil,
                        proximity: Set<Int>? = nil) -> SnappingManager.GridCommit {
        SnappingManager.gridCommitDecision(spanEngaged: spanEngaged,
                                           anchorZone: anchor,
                                           currentZone: current,
                                           proximityZones: proximity)
    }

    /// The core fix: proximity set is non-empty but the cursor is off-area so there
    /// is NO current zone — the commit must still be the proximity branch, NOT .none.
    /// (This is exactly the menu-bar/Dock-strip case: zone(at:) returns nil while
    /// zonesWithinRadius still includes e.g. {0}.)
    func testProximityCommitsEvenWithNoCurrentZone() {
        XCTAssertEqual(decide(current: nil, proximity: [0]), .proximity(zones: [0]))
        XCTAssertEqual(decide(current: nil, proximity: [0, 1, 2, 3]), .proximity(zones: [0, 1, 2, 3]))
    }

    /// Proximity also takes precedence over the single-zone branch when a current
    /// zone DOES exist (cursor inside the area, proximity mode active).
    func testProximityTakesPrecedenceOverSingleZone() {
        XCTAssertEqual(decide(current: 4, proximity: [3, 4]), .proximity(zones: [3, 4]))
    }

    /// An empty or nil proximity set is NOT the proximity branch — fall through to
    /// the single zone (or .none when there is none).
    func testEmptyOrNilProximityFallsThrough() {
        XCTAssertEqual(decide(current: 2, proximity: []), .single(zone: 2))
        XCTAssertEqual(decide(current: 2, proximity: nil), .single(zone: 2))
        XCTAssertEqual(decide(current: nil, proximity: []), .none)
        XCTAssertEqual(decide(current: nil, proximity: nil), .none)
    }

    /// The explicit anchor span (span modifier held + anchor armed + a current zone)
    /// TAKES PRECEDENCE over everything else.
    func testAnchorSpanTakesPrecedence() {
        XCTAssertEqual(decide(spanEngaged: true, anchor: 0, current: 4, proximity: [1, 2]),
                       .anchorSpan(fromZone: 0, toZone: 4))
    }

    /// Span engaged but missing its other endpoint (no current zone) does NOT commit
    /// an anchor span; with no proximity set it is .none (matching the original
    /// behavior where currentGridZone == nil committed nothing for the span path).
    func testSpanEngagedWithoutCurrentZoneDoesNotAnchorSpan() {
        XCTAssertEqual(decide(spanEngaged: true, anchor: 0, current: nil, proximity: nil), .none)
        // Span engaged but no anchor armed yet, with a current zone -> single zone.
        XCTAssertEqual(decide(spanEngaged: true, anchor: nil, current: 3, proximity: nil), .single(zone: 3))
    }

    /// A plain single-zone drag (no span, no proximity) commits the single zone.
    func testPlainSingleZone() {
        XCTAssertEqual(decide(current: 5), .single(zone: 5))
        XCTAssertEqual(decide(current: nil), .none)
    }
}
