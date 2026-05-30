//
//  SnappingManager.swift
//  Rectangle
//
//  Created by Ryan Hanson on 9/4/19.
//  Copyright © 2019 Ryan Hanson. All rights reserved.
//

import Cocoa

struct SnapArea: Equatable {
    let screen: NSScreen
    let directional: Directional
    let action: WindowAction
}

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
    var currentSnapArea: SnapArea?
    var dragPrevY: Double?
    var dragRestrictionExpirationTimestamp: UInt64 = 0
    var dragRestrictionExpired: Bool { DispatchTime.now().uptimeMilliseconds > dragRestrictionExpirationTimestamp }

    var box: FootprintWindow?

    // MARK: - Lilypad grid-drag state (M5)
    // A single reusable overlay (mirrors the FootprintWindow `box` pattern) and
    // the zone/screen currently previewed by the grid path. These are only ever
    // touched when grid mode is engaged; when it is NOT engaged the overlay is
    // hidden and these are nil, so the classic edge-snap path is untouched.
    lazy var gridOverlay: GridOverlayWindow = GridOverlayWindow()
    var currentGridScreen: NSScreen?
    var currentGridLayout: ZoneLayout?
    var currentGridZone: Int?

    let screenDetection = ScreenDetection()
    
    private let marginTop = Defaults.snapEdgeMarginTop.cgFloat
    private let marginBottom = Defaults.snapEdgeMarginBottom.cgFloat
    private let marginLeft = Defaults.snapEdgeMarginLeft.cgFloat
    private let marginRight = Defaults.snapEdgeMarginRight.cgFloat
    
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
        if box == nil {
            box = FootprintWindow()
        }
        if eventMonitor == nil {
            startEventMonitor()
        }
    }
    
    private func disableSnapping() {
        box = nil
        // Hide the grid overlay too, so it can't strand visible if snapping is
        // turned off mid grid-drag (app ignored / fullscreen). No-op when grid mode
        // was never used (the overlay is lazy and stays uninstantiated).
        clearGridPreview()
        stopEventMonitor()
    }
    
    private func startEventMonitor() {
        // `.flagsChanged` (M5) lets pressing/releasing the grid-activation modifier
        // mid-drag enter/leave grid mode without any cursor movement. It is a no-op
        // for the classic edge-snap path (handled explicitly in `handle`).
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
    /// Grid mode engages during a drag when BOTH the master flag is on AND the
    /// grid-activation modifier is currently held. This is the SOLE gate that
    /// chooses between the grid path and the classic edge-snap path — when it
    /// returns false the existing behavior must be byte-for-byte unchanged.
    ///
    /// Factored out as a PURE function (no instance state) so it is unit-testable
    /// across the flag-on/off × modifier-held/not matrix.
    static func gridModeEngaged(modifierFlags: NSEvent.ModifierFlags,
                                gridModeEnabled: Bool,
                                activationModifierRawValue: Int) -> Bool {
        guard gridModeEnabled else { return false }
        // A 0 activation modifier means "no modifier required": engage on the
        // flag alone. Otherwise the held flags must match exactly, using the same
        // deviceIndependentFlagsMask idiom canSnap uses for snapModifiers.
        guard activationModifierRawValue > 0 else { return true }
        return modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue == UInt(activationModifierRawValue)
    }

    /// Instance convenience reading current Defaults.
    func gridModeEngaged(_ event: NSEvent) -> Bool {
        SnappingManager.gridModeEngaged(modifierFlags: event.modifierFlags,
                                        gridModeEnabled: Defaults.gridModeEnabled.enabled,
                                        activationModifierRawValue: Defaults.gridActivationModifier.value)
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
            // previewed zone if eligible, otherwise do nothing — it never falls
            // through to a classic edge snap (so releasing over a non-zone, or when
            // ineligible, doesn't trigger a surprise edge snap). Gated on
            // canSnap(event) exactly like the edge path's postSnap, since Stage /
            // modifier state can change between the last dragged event and mouseUp.
            if gridModeEngaged(event) {
                if canSnap(event),
                   let zone = currentGridZone,
                   let screen = currentGridScreen,
                   let layout = currentGridLayout,
                   let windowElement = windowElement,
                   let windowId = windowId {
                    commitGridSnap(zone: zone, screen: screen, layout: layout,
                                   windowElement: windowElement, windowId: windowId)
                    windowElement.bringToFront()
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
            // Not grid mode: ensure no grid overlay lingers, then run the classic
            // edge-snap commit unchanged.
            clearGridPreview()

            if let currentSnapArea = self.currentSnapArea {
                box?.orderOut(nil)
                currentSnapArea.action.postSnap(windowElement: windowElement, windowId: windowId, screen: currentSnapArea.screen)
                self.currentSnapArea = nil
            } else {
                // it's possible that the window has moved, but the mouse dragged events are not getting the updated window position
                // this typically only happens if the user is dragging and dropping windows really quickly
                // in this scenario, the footprint doesn't display but the snap will still occur, as long as the window position is updated as of mouse up.
                if let currentRect = windowElement?.frame,
                   let windowId = windowId,
                   currentRect.size == initialWindowRect?.size,
                   currentRect.origin != initialWindowRect?.origin {
  
                    unsnapRestore(windowId: windowId, currentRect: currentRect, cursorLoc: event.cgEvent?.location)
                    
                    if let snapArea = snapAreaContainingCursor(priorSnapArea: currentSnapArea)  {
                        box?.orderOut(nil)
                        if canSnap(event) {
                            snapArea.action.postSnap(windowElement: windowElement, windowId: windowId, screen: snapArea.screen)
                        }
                        self.currentSnapArea = nil
                    }
                }
            }
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
                    if currentSnapArea != nil {
                        box?.orderOut(nil)
                        currentSnapArea = nil
                    }
                    clearGridPreview()
                    return
                }

                // Lilypad grid path (M5): gated on gridModeEngaged. When NOT
                // engaged we fall through to the EXISTING edge-snap path below,
                // unchanged, and make sure the grid overlay is hidden.
                if gridModeEngaged(event) {
                    // Edge snap state must not coexist with grid mode.
                    if currentSnapArea != nil {
                        box?.orderOut(nil)
                        currentSnapArea = nil
                    }
                    updateGridPreview(windowId: windowId, currentRect: currentRect)
                    return
                }
                clearGridPreview()

                if let snapArea = snapAreaContainingCursor(priorSnapArea: currentSnapArea) {
                    if snapArea == currentSnapArea {
                        return
                    }
                    
                    if Defaults.hapticFeedbackOnSnap.userEnabled {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    
                    let currentWindow = Window(id: windowId, rect: currentRect)
                    
                    if let newBoxRect = getBoxRect(hotSpot: snapArea, currentWindow: currentWindow) {
                        if box == nil {
                            box = FootprintWindow()
                        }
                        if Defaults.footprintAnimationDurationMultiplier.value > 0 {
                            if !box!.realIsVisible, let origin = getFootprintAnimationOrigin(snapArea, newBoxRect) {
                                let frame = CGRect(origin: origin, size: .zero)
                                box!.setFrame(frame, display: false)
                            }
                        } else {
                            box!.setFrame(newBoxRect, display: true)
                        }
                        box!.orderFront(nil)
                        if Defaults.footprintAnimationDurationMultiplier.value > 0 {
                            NSAnimationContext.runAnimationGroup { changes in
                                changes.duration = getFootprintAnimationDuration(box!, newBoxRect)
                                box!.animator().setFrame(newBoxRect, display: true)
                            }
                        }
                    }
                    
                    currentSnapArea = snapArea
                } else {
                    if currentSnapArea != nil {
                        box?.orderOut(nil)
                        currentSnapArea = nil
                    }
                }
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
                if currentSnapArea != nil {
                    box?.orderOut(nil)
                    currentSnapArea = nil
                }
                updateGridPreview(windowId: windowId, currentRect: currentRect)
            } else {
                // Left grid mode: hide the overlay. We deliberately do NOT
                // re-render the edge-snap footprint here (no cursor info this
                // event); the next .leftMouseDragged restores edge snapping.
                clearGridPreview()
            }
        default:
            return
        }
    }

    // MARK: - Lilypad grid drag path (M5)

    /// Re-evaluate the zone under the cursor and show/update the overlay. Called
    /// from the dragged + flagsChanged handlers while grid mode is engaged. Only
    /// re-renders the overlay when the screen or zone actually changes.
    private func updateGridPreview(windowId: CGWindowID, currentRect: CGRect) {
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

        // Only re-render when the screen, layout, or highlighted zone changes.
        let screenChanged = currentGridScreen != screen
        let zoneChanged = currentGridZone != zone
        let layoutChanged = currentGridLayout?.id != layout.id

        currentGridScreen = screen
        currentGridLayout = layout
        currentGridZone = zone

        if screenChanged || zoneChanged || layoutChanged {
            if Defaults.hapticFeedbackOnSnap.userEnabled, zone != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            gridOverlay.show(layout: layout, on: screen, highlightZone: zone)
        }
    }

    /// Hide the grid overlay and clear the previewed zone/screen/layout. Safe to
    /// call when no preview is showing.
    private func clearGridPreview() {
        if currentGridScreen != nil || currentGridZone != nil || currentGridLayout != nil {
            gridOverlay.hide()
        }
        currentGridScreen = nil
        currentGridLayout = nil
        currentGridZone = nil
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
    
    func getFootprintAnimationDuration(_ box: FootprintWindow, _ boxRect: CGRect) -> Double {
        return box.animationResizeTime(boxRect) * Double(Defaults.footprintAnimationDurationMultiplier.value)
    }
    
    func getFootprintAnimationOrigin(_ snapArea: SnapArea, _ boxRect: CGRect) -> CGPoint? {
        switch snapArea.directional {
        case .tl:
            return CGPoint(x: boxRect.minX, y: boxRect.maxY)
        case .t:
            return CGPoint(x: boxRect.midX, y: boxRect.maxY)
        case .tr:
            return CGPoint(x: boxRect.maxX, y: boxRect.maxY)
        case .l:
            return CGPoint(x: boxRect.minX, y: boxRect.midY)
        case .r:
            return CGPoint(x: boxRect.maxX, y: boxRect.midY)
        case .bl:
            return CGPoint(x: boxRect.minX, y: boxRect.minY)
        case .b:
            return CGPoint(x: boxRect.midX, y: boxRect.minY)
        case .br:
            return CGPoint(x: boxRect.maxX, y: boxRect.minY)
        default:
            return nil
        }
    }
    
    func getBoxRect(hotSpot: SnapArea, currentWindow: Window) -> CGRect? {
        if let calculation = WindowCalculationFactory.calculationsByAction[hotSpot.action] {
            
            let ignoreTodo = TodoManager.isTodoWindow(currentWindow.id)
            let rectCalcParams = RectCalculationParameters(window: currentWindow, visibleFrameOfScreen: hotSpot.screen.adjustedVisibleFrame(ignoreTodo), action: hotSpot.action, lastAction: nil)
            let rectResult = calculation.calculateRect(rectCalcParams)
            
            let gapsApplicable = hotSpot.action.gapsApplicable
            
            if Defaults.gapSize.value > 0, gapsApplicable != .none {
                let gapSharedEdges = rectResult.subAction?.gapSharedEdge ?? hotSpot.action.gapSharedEdge

                return GapCalculation.applyGaps(rectResult.rect, dimension: gapsApplicable, sharedEdges: gapSharedEdges, gapSize: Defaults.gapSize.value)
            }
            
            return rectResult.rect
        }
        return nil
    }
    
    func snapAreaContainingCursor(priorSnapArea: SnapArea?) -> SnapArea? {
        let loc = NSEvent.mouseLocation
        
        for screen in NSScreen.screens {
            guard let directional = directionalLocationOfCursor(loc: loc, screen: screen)
            else { continue }
            
            if let windowId = windowId, Defaults.todo.userEnabled && Defaults.todoMode.enabled && TodoManager.isTodoWindow(windowId) {
                if Defaults.todoSidebarSide.value == .left && directional == .l {
                    return SnapArea(screen: screen, directional: directional, action: .leftTodo)
                }
                if Defaults.todoSidebarSide.value == .right && directional == .r {
                    return SnapArea(screen: screen, directional: directional, action: .rightTodo)
                }
            }
            
            let orientation: DisplayOrientation = screen.frame.isLandscape ? .landscape : .portrait
            let config = SnapAreaModel.instance.snapAreas(for: orientation, displayUUID: screen.displayUUIDString)[directional]
            
            if let action = config?.action {
                return SnapArea(screen: screen, directional: directional, action: action)
            }
            if let compound = config?.compound {
                return compound.calculation.snapArea(cursorLocation: loc, screen: screen, directional: directional, priorSnapArea: priorSnapArea)
            }
        }
        
        return nil
    }
    
    func directionalLocationOfCursor(loc: NSPoint, screen: NSScreen) -> Directional? {
        let frame = screen.frame
        let cornerSize = Defaults.cornerSnapAreaSize.cgFloat
        
        /// cgrect contains doesn't include max edges, so manually compare
        guard loc.x >= frame.minX,
              loc.x <= frame.maxX,
              loc.y >= frame.minY,
              loc.y <= frame.maxY
        else { return nil }
        
        if loc.x < frame.minX + marginLeft + cornerSize {
            if loc.y >= frame.maxY - marginTop - cornerSize {
                return .tl
            }
            if loc.y <= frame.minY + marginBottom + cornerSize {
                return .bl
            }
            if loc.x < frame.minX + marginLeft {
                return .l
            }
        }
        
        if loc.x > frame.maxX - marginRight - cornerSize {
            if loc.y >= frame.maxY - marginTop - cornerSize {
                return .tr
            }
            if loc.y <= frame.minY + marginBottom + cornerSize {
                return .br
            }
            if loc.x > frame.maxX - marginRight {
                return .r
            }
        }
        
        if loc.y > frame.maxY - marginTop {
            return .t
        }
        if loc.y < frame.minY + marginBottom {
            return .b
        }
        
        return nil
    }
}
