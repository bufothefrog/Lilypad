//
//  SnappingManager.swift
//  Rectangle
//
//  Created by Ryan Hanson on 9/4/19.
//  Copyright © 2019 Ryan Hanson. All rights reserved.
//

import Cocoa

class SnappingManager {
    
    private let fullIgnoreIds: [String] = Defaults.fullIgnoreBundleIds.typedValue ?? ["com.install4j", 
                                                                                      "com.mathworks.matlab",
                                                                                      "com.live2d.cubism.CECubismEditorApp",
                                                                                      "com.aquafold.datastudio.DataStudio",
                                                                                      "com.adobe.illustrator",
                                                                                      "com.adobe.AfterEffects"]
    
    var eventMonitor: EventMonitor?
    var windowElement: AccessibilityElement?
    var windowId: CGWindowID?
    var windowIdAttempt: Int = 0
    var lastWindowIdAttempt: TimeInterval?
    var windowMoving: Bool = false
    var isFullScreen: Bool = false
    var allowListening: Bool = true
    var initialWindowRect: CGRect?
    var dragPrevY: Double?
    var dragRestrictionExpirationTimestamp: UInt64 = 0
    var dragRestrictionExpired: Bool { DispatchTime.now().uptimeMilliseconds > dragRestrictionExpirationTimestamp }

    // MARK: - Lilypad grid-drag state (M5)
    // A single reusable overlay (built on FootprintWindow's window recipe) and the
    // zone/screen currently previewed by the grid path. These are only ever touched
    // when grid mode is engaged; when it is NOT engaged the overlay is hidden and
    // these are nil, and the drag is just a plain window move (no snapping).
    lazy var gridOverlay: GridOverlayWindow = GridOverlayWindow()
    var currentGridScreen: NSScreen?
    var currentGridLayout: ZoneLayout?
    var currentGridZone: Int?

    // MARK: - Lilypad span sub-mode state (M6)
    // The anchor zone a span extends FROM. Set when the span modifier transitions
    // down (to the zone under the cursor at that moment), cleared when it goes up
    // or any grid preview is cleared. nil ⇒ single-zone behavior. Only touched on
    // the grid path (the only drag-snap path).
    var gridSpanAnchorZone: Int?

    // MARK: - Lilypad proximity-span state (optional drag mode, default OFF)
    // The set of zones the proximity drag mode is currently highlighting (every
    // zone within `gridProximitySpanRadius` of the cursor). nil ⇒ proximity is not
    // the active sub-mode this frame. Tracked so the commit can snap to the
    // bounding box of exactly the set that was last previewed, and so the overlay
    // is only re-rendered when this set changes. Only ever set on the grid path
    // when proximity is enabled AND the span modifier is NOT held; cleared by
    // clearGridPreview so nothing carries over.
    var currentGridProximityZones: Set<Int>?

    let screenDetection = ScreenDetection()

    init() {
        // Force lazy init of DisplayRegistry so the known-displays registry
        // observer (didChangeScreenParametersNotification) is installed at
        // launch, not on the first drag.
        _ = DisplayRegistry.instance

        if Defaults.windowSnapping.enabled != false {
            enableSnapping()
        }

        registerWorkspaceChangeNote()
        
        Notification.Name.windowSnapping.onPost { notification in
            if let enabled = notification.object as? Bool {
                self.allowListening = enabled
            }
            self.toggleListening()
        }
        Notification.Name.missionControlDragging.onPost { notification in
            self.stopEventMonitor()
            self.startEventMonitor()
        }
        Notification.Name.frontAppChanged.onPost(using: frontAppChanged)
    }
    
    func frontAppChanged(notification: Notification) {
        if ApplicationToggle.shortcutsDisabled {
            DispatchQueue.main.async {
                if !Defaults.ignoreDragSnapToo.userDisabled {
                    self.allowListening = false
                    self.toggleListening()
                } else {
                    for id in self.fullIgnoreIds {
                        if ApplicationToggle.frontAppId?.starts(with: id) == true {
                            self.allowListening = false
                            self.toggleListening()
                            break
                        }
                    }
                }
            }
        } else {
            allowListening = true
            checkFullScreen()
        }
    }
    
    func toggleListening() {
        if allowListening, !isFullScreen, !Defaults.windowSnapping.userDisabled {
            enableSnapping()
        } else {
            disableSnapping()
        }
    }
    
    private func registerWorkspaceChangeNote() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveWorkspaceNote(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        checkFullScreen()
    }
    
    func checkFullScreen() {
        isFullScreen = AccessibilityElement.getFrontWindowElement()?.isFullScreen == true
        toggleListening()
    }
    
    @objc func receiveWorkspaceNote(_ notification: Notification) {
        checkFullScreen()
    }
        
    public func reloadFromDefaults() {
        if Defaults.windowSnapping.userDisabled {
            if eventMonitor?.running == true {
                disableSnapping()
            }
        } else {
            if eventMonitor?.running == true {
                if Defaults.missionControlDragging.userDisabled != (eventMonitor is ActiveEventMonitor) {
                    stopEventMonitor()
                    startEventMonitor()
                }
            } else {
                enableSnapping()
            }
        }
    }
    
    private func enableSnapping() {
        if eventMonitor == nil {
            startEventMonitor()
        }
    }

    private func disableSnapping() {
        // Hide the grid overlay too, so it can't strand visible if snapping is
        // turned off mid grid-drag (app ignored / fullscreen). No-op when grid mode
        // was never used (the overlay is lazy and stays uninstantiated).
        clearGridPreview()
        stopEventMonitor()
    }
    
    private func startEventMonitor() {
        // `.flagsChanged` (M5) lets pressing/releasing the grid-activation modifier
        // mid-drag enter/leave grid mode without any cursor movement. Outside grid
        // mode it is a no-op (a plain drag just moves the window).
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .flagsChanged]
        eventMonitor = Defaults.missionControlDragging.userDisabled ? ActiveEventMonitor(mask: mask, filterer: filter, handler: handle) : PassiveEventMonitor(mask: mask, handler: handle)
        eventMonitor?.start()
    }
    
    private func stopEventMonitor() {
        eventMonitor?.stop()
        eventMonitor = nil
    }
    
    func filter(event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseUp:
            dragPrevY = nil
        case .leftMouseDragged:
            if let cgEvent = event.cgEvent, let screen = NSScreen.main {
                let minY = screen.frame.screenFlipped.minY
                if cgEvent.location.y == minY && dragPrevY == minY {
                    if event.deltaY < -Defaults.missionControlDraggingAllowedOffscreenDistance.cgFloat {
                        cgEvent.location.y = minY + 1
                        dragRestrictionExpirationTimestamp = DispatchTime.now().uptimeMilliseconds + UInt64(Defaults.missionControlDraggingDisallowedDuration.value)
                    } else if !dragRestrictionExpired {
                        cgEvent.location.y = minY + 1
                    }
                }
                dragPrevY = cgEvent.location.y
            }
        default:
            break
        }
        return false
    }
    
    /// Whether the Lilypad grid drag path should engage right now.
    ///
    /// Grid mode engages during a drag when the grid-activation modifier is
    /// currently held. This is the SOLE gate that chooses whether a drag snaps to
    /// the grid: when it returns false the window just moves freely.
    ///
    /// SPAN COEXISTENCE (M6): the span modifier (default Option) must be allowed
    /// as an EXTRA held modifier so Shift+Option still engages grid mode (to span)
    /// instead of disengaging it. We therefore mask to deviceIndependentFlagsMask,
    /// REMOVE the span modifier bits, then require the remainder to equal the
    /// activation modifier. Result: Shift alone engages, Shift+span engages,
    /// Shift+Command does NOT engage, span alone does NOT engage. When the span
    /// modifier equals the activation modifier (or is 0), this collapses to the M5
    /// exact-match behavior.
    ///
    /// Factored out as a PURE function (no instance state) so it is unit-testable
    /// across the modifier-held/not matrix.
    static func gridModeEngaged(modifierFlags: NSEvent.ModifierFlags,
                                activationModifierRawValue: Int,
                                spanModifierRawValue: Int) -> Bool {
        // A 0 activation modifier means "no modifier required": engage on the
        // flag alone, regardless of which extra modifiers (incl. span) are held.
        guard activationModifierRawValue > 0 else { return true }
        // Mask to the device-independent flags, then strip the span bits so the
        // span modifier is tolerated as an allowed extra. The remainder must equal
        // the activation modifier exactly (same idiom canSnap uses for snapModifiers).
        // Never strip the span bits when span == activation, so the activation
        // modifier itself is never accidentally removed.
        let masked = modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        let spanBits = UInt(max(spanModifierRawValue, 0))
        let withoutSpan = (spanModifierRawValue > 0 && spanModifierRawValue != activationModifierRawValue)
            ? (masked & ~spanBits)
            : masked
        return withoutSpan == UInt(activationModifierRawValue)
    }

    /// Whether the SPAN modifier (default Option) is currently held.
    static func spanModifierHeld(modifierFlags: NSEvent.ModifierFlags,
                                 spanModifierRawValue: Int) -> Bool {
        guard spanModifierRawValue > 0 else { return false }
        let masked = modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        return (masked & UInt(spanModifierRawValue)) == UInt(spanModifierRawValue)
    }

    /// Which grid-snap commit the `.leftMouseUp` handler should perform, given the
    /// previewed state. PURE so the precedence is unit-testable without live screen /
    /// cursor state (the source of the proximity preview/commit-mismatch bug).
    enum GridCommit: Equatable {
        case anchorSpan(fromZone: Int, toZone: Int)  // span modifier held + anchor armed + a current zone.
        case proximity(zones: Set<Int>)              // proximity mode active (non-empty tracked set).
        case single(zone: Int)                       // the single current zone (M5).
        case none                                    // nothing eligible to commit.
    }

    /// Decide the commit branch with this PRECEDENCE (mirrors updateGridPreview):
    ///   (a) span modifier held + anchor armed + a current zone ⇒ anchor span.
    ///   (b) else a non-empty proximity set ⇒ proximity span. This does NOT require
    ///       `currentZone`: proximity deliberately highlights zones within the radius
    ///       even when the cursor is just OUTSIDE `area` (over the menu-bar/Dock
    ///       strip), where `zone(at:)` — and therefore `currentZone` — is nil. Gating
    ///       on `currentZone` here would highlight a span but never commit it
    ///       (the preview/commit mismatch this helper exists to prevent).
    ///   (c) else a current zone ⇒ the single zone.
    ///   (d) else nothing.
    static func gridCommitDecision(spanEngaged: Bool,
                                   anchorZone: Int?,
                                   currentZone: Int?,
                                   proximityZones: Set<Int>?) -> GridCommit {
        if spanEngaged, let anchor = anchorZone, let zone = currentZone {
            return .anchorSpan(fromZone: anchor, toZone: zone)
        }
        if let proximityZones = proximityZones, !proximityZones.isEmpty {
            return .proximity(zones: proximityZones)
        }
        if let zone = currentZone {
            return .single(zone: zone)
        }
        return .none
    }

    /// Instance convenience reading current Defaults.
    func gridModeEngaged(_ event: NSEvent) -> Bool {
        SnappingManager.gridModeEngaged(modifierFlags: event.modifierFlags,
                                        activationModifierRawValue: Defaults.gridActivationModifier.value,
                                        spanModifierRawValue: Defaults.gridSpanModifier.value)
    }

    /// Grid mode engaged AND the span modifier currently held (so the drag should
    /// extend a multi-zone span from the anchor zone).
    func spanEngaged(_ event: NSEvent) -> Bool {
        gridModeEngaged(event)
            && SnappingManager.spanModifierHeld(modifierFlags: event.modifierFlags,
                                                spanModifierRawValue: Defaults.gridSpanModifier.value)
    }

    func canSnap(_ event: NSEvent) -> Bool {
        if Defaults.snapModifiers.value > 0 {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue != Defaults.snapModifiers.value {
                return false
            }
        }
        if let windowId = windowId {
            if StageUtil.stageCapable && StageUtil.stageEnabled && StageUtil.getStageStripWindowGroup(windowId) != nil {
                return false
            }
        }
        return true
    }
    
    func handle(event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if !Defaults.obtainWindowOnClick.userDisabled {
                windowElement = AccessibilityElement.getWindowElementUnderCursor()
                windowId = windowElement?.getWindowId()
                initialWindowRect = windowElement?.frame
            }
        case .leftMouseUp:
            // Lilypad grid mode (M5) OWNS the gesture when engaged: snap to the
            // previewed zone if eligible, otherwise do nothing (releasing over a
            // non-zone, or when ineligible, just leaves the window where it was
            // dragged). Re-check canSnap(event) at mouseUp because Stage / modifier
            // state can change between the last dragged event and mouseUp.
            if gridModeEngaged(event) {
                // Only the SHARED eligibility (canSnap + screen/layout/window) is
                // guarded up front. The commit BRANCH is chosen by the pure
                // `gridCommitDecision` (mirrors updateGridPreview's precedence): the
                // proximity branch must NOT require currentGridZone, because proximity
                // deliberately highlights zones within the radius even when the cursor
                // is just OUTSIDE `area` (over the menu-bar/Dock strip), where
                // zone(at:) — and therefore currentGridZone — is nil. Gating the whole
                // commit on currentGridZone (as the original code did) highlighted that
                // span but never snapped to it (preview/commit mismatch).
                if canSnap(event),
                   let screen = currentGridScreen,
                   let layout = currentGridLayout,
                   let windowElement = windowElement,
                   let windowId = windowId {
                    let decision = SnappingManager.gridCommitDecision(
                        spanEngaged: spanEngaged(event),
                        anchorZone: gridSpanAnchorZone,
                        currentZone: currentGridZone,
                        proximityZones: currentGridProximityZones)
                    switch decision {
                    case let .anchorSpan(fromZone, toZone):
                        commitGridSpanSnap(fromZone: fromZone, toZone: toZone, screen: screen, layout: layout,
                                           windowElement: windowElement, windowId: windowId)
                        windowElement.bringToFront()
                    case let .proximity(zones):
                        commitGridProximitySnap(zones: zones, screen: screen, layout: layout,
                                                windowElement: windowElement, windowId: windowId)
                        windowElement.bringToFront()
                    case let .single(zone):
                        commitGridSnap(zone: zone, screen: screen, layout: layout,
                                       windowElement: windowElement, windowId: windowId)
                        windowElement.bringToFront()
                    case .none:
                        break
                    }
                }
                clearGridPreview()
                self.windowElement = nil
                self.windowId = nil
                windowMoving = false
                initialWindowRect = nil
                windowIdAttempt = 0
                lastWindowIdAttempt = nil
                return
            }
            // Not grid mode: the window just moved freely (no snapping). Ensure no
            // grid overlay lingers, then reset the drag state.
            clearGridPreview()
            windowElement = nil
            windowId = nil
            windowMoving = false
            initialWindowRect = nil
            windowIdAttempt = 0
            lastWindowIdAttempt = nil
        case .leftMouseDragged:
            if windowId == nil, windowIdAttempt < 20 {
                if let lastWindowIdAttempt = lastWindowIdAttempt {
                    if event.timestamp - lastWindowIdAttempt < 0.1 {
                        return
                    }
                }
                if windowElement == nil {
                    windowElement = AccessibilityElement.getWindowElementUnderCursor()
                }
                windowId = windowElement?.getWindowId()
                initialWindowRect = windowElement?.frame
                windowIdAttempt += 1
                lastWindowIdAttempt = event.timestamp
            }
            guard let currentRect = windowElement?.frame,
                let windowId = windowId
            else { return }
            
            if !windowMoving {
                if let initialWindowRect, (currentRect.size == initialWindowRect.size || currentRect.numSharedEdges(withRect: initialWindowRect) < 2) {
                    if currentRect.origin != initialWindowRect.origin {
                        windowMoving = true
                        unsnapRestore(windowId: windowId, currentRect: currentRect, cursorLoc: event.cgEvent?.location)
                    }
                }
                else {
                    AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
                }
            }
            if windowMoving {
                if !canSnap(event) {
                    clearGridPreview()
                    return
                }

                // Lilypad grid path: gated on gridModeEngaged. When NOT engaged the
                // window just moves freely with no preview.
                if gridModeEngaged(event) {
                    updateGridPreview(windowId: windowId, currentRect: currentRect, spanEngaged: spanEngaged(event))
                    return
                }
                clearGridPreview()
            }
        case .flagsChanged:
            // Only meaningful mid-drag: pressing/releasing the grid-activation
            // modifier should enter/leave grid mode WITHOUT any cursor movement.
            // Outside a drag (no window moving) this is a no-op, so the classic
            // path is untouched.
            guard windowMoving,
                  let currentRect = windowElement?.frame,
                  let windowId = windowId,
                  canSnap(event)
            else {
                // A modifier change that takes us out of a snappable state should
                // also clear any grid preview that was showing — regardless of
                // windowMoving. In particular, when this guard fails because
                // canSnap(event) became false mid-drag (e.g. the user released a
                // configured snapModifier, or the window joined a Stage Manager
                // strip group), windowMoving is still true; clearing only on
                // !windowMoving would strand the overlay on screen with a zone
                // still armed for commit. clearGridPreview() is a safe no-op when
                // nothing is showing.
                clearGridPreview()
                return
            }

            if gridModeEngaged(event) {
                // Span sub-mode (M6): a .flagsChanged is exactly where the span
                // modifier transitions down/up mid-drag, with no cursor movement.
                // updateGridPreview owns the anchor logic: span engaged + no anchor
                // ⇒ set the anchor to the zone under the cursor right now; span not
                // engaged ⇒ clear the anchor and revert to single-zone preview. We
                // re-render here without any cursor delta so the overlay reflects
                // the new span/single state immediately.
                updateGridPreview(windowId: windowId, currentRect: currentRect, spanEngaged: spanEngaged(event))
            } else {
                // Left grid mode mid-drag: hide the overlay. The drag now just
                // moves the window freely; the next .leftMouseDragged simply
                // continues that free move (there is no snapping outside grid mode).
                clearGridPreview()
            }
        default:
            return
        }
    }

    // MARK: - Lilypad grid drag path (M5)

    /// Re-evaluate the zone under the cursor and show/update the overlay. Called
    /// from the dragged + flagsChanged handlers while grid mode is engaged. Only
    /// re-renders the overlay when the screen, layout, highlighted zone, or span
    /// anchor actually changes.
    ///
    /// Span sub-mode (M6): when `spanEngaged` is true the selection runs from the
    /// span anchor to the current zone and the overlay highlights ALL zones in that
    /// span (`GridCalculation.zonesInSpan`); when false the overlay highlights only
    /// the single current zone. The anchor is owned here:
    /// - span engaged + no anchor yet ⇒ set the anchor to the current zone (this is
    ///   the "modifier pressed" transition, and also the "pressed before a zone
    ///   existed" recovery — the first frame with a non-nil current zone arms it).
    /// - span not engaged ⇒ clear the anchor so a later span re-arms fresh.
    private func updateGridPreview(windowId: CGWindowID, currentRect: CGRect, spanEngaged: Bool) {
        guard let screen = screenDetection.detectScreensAtCursor()?.currentScreen,
              let uuid = screen.displayUUIDString,
              let layout = GridModel.instance.ensureActiveLayout(forDisplay: uuid)
        else {
            // No layout for this display (and seeding produced none): nothing to preview.
            clearGridPreview()
            return
        }

        let ignoreTodo = TodoManager.isTodoWindow(windowId)
        let area = screen.adjustedVisibleFrame(ignoreTodo)
        let zone = GridCalculation.zone(at: NSEvent.mouseLocation, in: area, layout: layout)

        // A span anchor is a zone ID, which is only meaningful WITHIN one screen's
        // active layout. If the cursor crosses to a different screen, or the active
        // layout for the current screen changes, an anchor armed against the old
        // layout would be reinterpreted against the new one — yielding a
        // geometrically wrong highlight and committed span (FINDINGS M6). Detect
        // that here, BEFORE the anchor block, so a screen/layout change is treated
        // exactly like "no anchor yet" and the anchor re-arms to the current zone in
        // the NEW layout it will actually be committed against.
        let screenChanged = currentGridScreen != nil && currentGridScreen != screen
        let layoutChanged = currentGridLayout != nil && currentGridLayout?.id != layout.id
        if screenChanged || layoutChanged {
            gridSpanAnchorZone = nil
        }

        // Anchor management.
        let previousAnchor = gridSpanAnchorZone
        if spanEngaged {
            // Arm the anchor on the span-modifier-down transition (no anchor yet),
            // anchoring to the current zone under the cursor. If span was pressed
            // before any zone existed, this re-tries each frame until a zone is hit.
            // After a screen/layout change cleared the anchor above, this re-arms it
            // against the new layout on the first frame with a zone under the cursor.
            if gridSpanAnchorZone == nil, let zone = zone {
                gridSpanAnchorZone = zone
            }
        } else {
            // Span released (or never engaged): revert to single-zone behavior.
            gridSpanAnchorZone = nil
        }

        // Compute the highlighted zone set with this PRECEDENCE (matching the
        // mouseUp commit):
        //   (a) span modifier engaged + armed ⇒ EXISTING anchor span
        //       (anchor..current). Highest precedence.
        //   (b) else proximity enabled ⇒ every zone within the radius of the cursor
        //       (`zonesWithinRadius`). This is the OPTIONAL proximity sub-mode.
        //   (c) else ⇒ the single current zone (EXISTING behavior).
        // `currentGridProximityZones` is non-nil only while (b) is the active mode,
        // so the commit knows which set to snap to.
        let highlightZones: Set<Int>
        let previousProximityZones = currentGridProximityZones
        var proximityZones: Set<Int>? = nil
        if spanEngaged, let anchor = gridSpanAnchorZone, let zone = zone {
            highlightZones = GridCalculation.zonesInSpan(fromZone: anchor, toZone: zone, layout: layout)
        } else if !spanEngaged, Defaults.gridProximitySpanEnabled.userEnabled {
            // Proximity span: union the zones whose rect is within the radius of the
            // cursor. zonesWithinRadius is never empty while the cursor is inside the
            // area (the containing zone is distance 0); empty only off-area.
            let zones = GridCalculation.zonesWithinRadius(
                of: NSEvent.mouseLocation,
                radius: Defaults.gridProximitySpanRadius.cgFloat,
                in: area,
                layout: layout)
            proximityZones = zones
            highlightZones = zones
        } else if let zone = zone {
            highlightZones = [zone]
        } else {
            highlightZones = []
        }
        currentGridProximityZones = proximityZones

        // Only re-render when something visible changed. (These re-render checks
        // also fire on the FIRST frame — when currentGridScreen/Layout are still nil
        // — so the initial overlay always shows; the anchor-reset checks above
        // deliberately do not, to avoid clearing the anchor on its very first frame.)
        let renderScreenChanged = currentGridScreen != screen
        let zoneChanged = currentGridZone != zone
        let renderLayoutChanged = currentGridLayout?.id != layout.id
        let anchorChanged = previousAnchor != gridSpanAnchorZone
        // In proximity mode the highlighted SET (not the single zone under the
        // cursor) drives the visible state, so re-render whenever that set changes —
        // even when the zone directly under the cursor hasn't.
        let proximityChanged = previousProximityZones != proximityZones

        currentGridScreen = screen
        currentGridLayout = layout
        currentGridZone = zone

        if renderScreenChanged || zoneChanged || renderLayoutChanged || anchorChanged || proximityChanged {
            if Defaults.hapticFeedbackOnSnap.userEnabled, zone != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            gridOverlay.show(layout: layout, on: screen, highlightZones: highlightZones)
        }
    }

    /// Hide the grid overlay and clear the previewed zone/screen/layout AND the
    /// span anchor, so a stale span can't carry over into the next gesture. Safe to
    /// call when no preview is showing.
    private func clearGridPreview() {
        if currentGridScreen != nil || currentGridZone != nil || currentGridLayout != nil {
            gridOverlay.hide()
        }
        currentGridScreen = nil
        currentGridLayout = nil
        currentGridZone = nil
        gridSpanAnchorZone = nil
        currentGridProximityZones = nil
    }

    /// Commit a grid drag-snap: compute the zone rect (with gaps) in the screen's
    /// adjusted visible frame and move/resize the window to it via the shared
    /// window-mover + history path, so unsnap-restore keeps working.
    private func commitGridSnap(zone: Int, screen: NSScreen, layout: ZoneLayout,
                                windowElement: AccessibilityElement, windowId: CGWindowID) {
        let ignoreTodo = TodoManager.isTodoWindow(windowId)
        let area = screen.adjustedVisibleFrame(ignoreTodo)

        let rect = Defaults.gapSize.value > 0
            ? GridCalculation.zoneRectWithGaps(layout: layout, zoneId: zone, in: area, gapSize: Defaults.gapSize.value)
            : GridCalculation.zoneRect(layout: layout, zoneId: zone, in: area)
        guard !rect.isNull else { return }

        // Record the pre-snap restore rect so `restore` can bring the window back,
        // mirroring how the edge-snap drag records it during unsnapRestore. The
        // dragged handler's unsnapRestore already manages restoreRects during the
        // drag; only set it here if nothing recorded it yet.
        if Defaults.unsnapRestore.enabled != false,
           AppDelegate.windowHistory.restoreRects[windowId] == nil {
            AppDelegate.windowHistory.restoreRects[windowId] = initialWindowRect
        }

        // Reuse WindowManager's mover-chain + history recording (fixed-size/cross
        // display handled there) rather than hand-rolling setFrame.
        WindowManager.instance?.applyGridRect(rect, screen: screen, windowElement: windowElement, windowId: windowId)
    }

    /// Commit a grid SPAN drag-snap (M6): the window snaps to the selection rect
    /// spanning `fromZone`..`toZone`. Mirrors `commitGridSnap` exactly (gaps,
    /// restore-rect bookkeeping, the shared WindowManager.applyGridRect path) but
    /// uses `GridCalculation.selectionRect` for the rect instead of a single zone.
    private func commitGridSpanSnap(fromZone: Int, toZone: Int, screen: NSScreen, layout: ZoneLayout,
                                    windowElement: AccessibilityElement, windowId: CGWindowID) {
        let ignoreTodo = TodoManager.isTodoWindow(windowId)
        let area = screen.adjustedVisibleFrame(ignoreTodo)

        var rect = GridCalculation.selectionRect(layout: layout, fromZone: fromZone, toZone: toZone, in: area)
        guard !rect.isNull else { return }
        // Apply gaps the same way the single-zone commit does (inset the whole
        // span by gapSize on every side), keeping span and single-zone snaps
        // visually consistent.
        if Defaults.gapSize.value > 0 {
            rect = GapCalculation.applyGaps(rect, dimension: .both, sharedEdges: .none, gapSize: Defaults.gapSize.value)
            guard !rect.isNull else { return }
        }

        if Defaults.unsnapRestore.enabled != false,
           AppDelegate.windowHistory.restoreRects[windowId] == nil {
            AppDelegate.windowHistory.restoreRects[windowId] = initialWindowRect
        }

        WindowManager.instance?.applyGridRect(rect, screen: screen, windowElement: windowElement, windowId: windowId)
    }

    /// Commit a proximity-span drag-snap (optional mode): the window snaps to the
    /// bounding box of `zones` — the set of zones the cursor was within the radius
    /// of at mouseUp. Mirrors `commitGridSpanSnap` (gaps, restore-rect bookkeeping,
    /// the shared WindowManager.applyGridRect path) but uses
    /// `GridCalculation.boundingRect(ofZones:)` for the rect.
    private func commitGridProximitySnap(zones: Set<Int>, screen: NSScreen, layout: ZoneLayout,
                                         windowElement: AccessibilityElement, windowId: CGWindowID) {
        let ignoreTodo = TodoManager.isTodoWindow(windowId)
        let area = screen.adjustedVisibleFrame(ignoreTodo)

        let rect = Defaults.gapSize.value > 0
            ? GridCalculation.boundingRectWithGaps(ofZones: zones, in: area, layout: layout, gapSize: Defaults.gapSize.value)
            : GridCalculation.boundingRect(ofZones: zones, in: area, layout: layout)
        guard !rect.isNull else { return }

        if Defaults.unsnapRestore.enabled != false,
           AppDelegate.windowHistory.restoreRects[windowId] == nil {
            AppDelegate.windowHistory.restoreRects[windowId] = initialWindowRect
        }

        WindowManager.instance?.applyGridRect(rect, screen: screen, windowElement: windowElement, windowId: windowId)
    }

    func unsnapRestore(windowId: CGWindowID, currentRect: CGRect, cursorLoc: CGPoint?) {
        if Defaults.unsnapRestore.enabled != false {
            // if window was put there by rectangle, restore size
            if let lastRect = AppDelegate.windowHistory.lastRectangleActions[windowId]?.rect,
                lastRect == initialWindowRect,
                let restoreRect = AppDelegate.windowHistory.restoreRects[windowId] {
                
                if let windowElement = windowElement {
                    if #available(macOS 12, *) { // earlier versions of macOS would stutter the reposition when dragging the window
                        var newRect = currentRect
                        newRect.size = restoreRect.size
                        if let cursorLoc = cursorLoc {
                            if !newRect.contains(cursorLoc) { // keep the same maxX if possible
                                newRect.origin = CGPoint(x: currentRect.maxX - newRect.width, y: newRect.minY)
                                
                                if !newRect.contains(cursorLoc) { // still doesn't contain cursor
                                    newRect.origin = CGPoint(x: cursorLoc.x - (newRect.width / 2), y: newRect.minY)
                                }
                            }
                        }
                        windowElement.setFrame(newRect, adjustSizeFirst: false)
                    } else {
                        windowElement.size = restoreRect.size
                    }
                }
                
                AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
            } else {
                AppDelegate.windowHistory.restoreRects[windowId] = initialWindowRect
            }
        }
    }
}
