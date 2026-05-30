//
//  GridOverlayWindow.swift
//  Rectangle / Lilypad
//
//  M4 — the render-only grid overlay. A borderless, click-through window that
//  COVERS a target screen and draws a `ZoneLayout`'s zones (one stroked border
//  per zone, with an optional filled highlight) so the overlay-to-screen
//  coordinate integration can be verified visually before any drag/keyboard
//  path is wired on top of it (M5+).
//
//  This file is purely additive: nothing here is invoked by real drag or
//  keyboard handling yet. The only caller in M4 is the temporary
//  "Debug: Show Grid Overlay" status-menu item.
//
//  COORDINATE INTEGRATION (the whole point of M4 — see LILYPAD_PLAN.md
//  "Stage 3" overlay finding):
//  - `GridCalculation` produces zone rects in Cocoa BOTTOM-LEFT coordinates,
//    inside the screen's `adjustedVisibleFrame()` (the visible area, excluding
//    menu bar / notch / Stage strip).
//  - The overlay WINDOW is positioned with `setFrame` to the full SCREEN frame,
//    in the same Cocoa bottom-left space `FootprintWindow` uses.
//  - Each zone rect (screen Cocoa coords) is converted to the overlay view's
//    LOCAL coordinates by subtracting the window/screen origin. The content view
//    is intentionally NON-FLIPPED (`isFlipped == false`), so its local y also
//    grows upward — a top-row zone therefore lands at the LARGEST local y, with
//    no vertical mirroring. This conversion is the M4 verification gate and is
//    exercised by `GridOverlayWindowTests` through `overlayZoneFrames(...)`.
//

import Cocoa

/// Click-through overlay window that renders a `ZoneLayout` on one screen.
///
/// Mirrors `FootprintWindow`'s configuration (borderless, `.modalPanel` level,
/// transient, non-opaque, no shadow, clear background, alpha-fade show/hide) and
/// adds `ignoresMouseEvents = true` so the overlay never steals events when it
/// sits under the cursor in later milestones.
class GridOverlayWindow: NSWindow {

    private let gridView = GridOverlayView()
    private var orderOutCanceled = false

    init() {
        let initialRect = NSRect(x: 0, y: 0, width: 0, height: 0)
        super.init(contentRect: initialRect, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .modalPanel
        hasShadow = false
        isReleasedWhenClosed = false
        // Start fully transparent; show(...) fades us in.
        alphaValue = 0

        // Match FootprintWindow's transient behavior so the overlay doesn't get
        // captured by Mission Control / Exposé window cycling. (No .canJoinAllSpaces:
        // the overlay is pinned to one screen on the current Space.)
        collectionBehavior.insert(.transient)

        // The overlay is purely decorative and will sit directly under the
        // cursor in M5/M6 — it must be click-through and never become key,
        // never steal mouse events.
        ignoresMouseEvents = true

        contentView = gridView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Public surface

    /// Show `layout`'s zones on `screen`, filling every zone in `highlightZones`.
    ///
    /// Sets the window frame to the screen's full frame, computes each zone's
    /// rect in the overlay view's local coordinates via `overlayZoneFrames`,
    /// hands them to the view, and fades the window in at the front.
    ///
    /// `highlightZones` is a SET (M6): the single-zone drag path passes a
    /// one-element set; the span sub-mode passes the whole spanned set so every
    /// spanned zone reads as selected. An empty set means no zone is filled
    /// "selected".
    ///
    /// Hardened for RAPID REUSE (M5): a single instance is shown/hidden many
    /// times per drag, sometimes with overlapping animations. We therefore
    /// (a) mark `orderOutCanceled = true` BEFORE starting any fade so a hide()
    /// that began first can't strand us ordered-out, and (b) honor
    /// `footprintFade.userDisabled` exactly like FootprintWindow — when fade is
    /// disabled we set alpha and order in/out instantly, with no animation.
    /// Re-showing with a different layout/highlight re-renders cleanly because
    /// the view is updated every call.
    func show(layout: ZoneLayout, on screen: NSScreen, highlightZones: Set<Int> = []) {
        let screenFrame = screen.frame
        let visibleFrame = screen.adjustedVisibleFrame()

        let frames = GridOverlayWindow.overlayZoneFrames(
            layout: layout,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )

        setFrame(screenFrame, display: false)
        gridView.frame = NSRect(origin: .zero, size: screenFrame.size)
        gridView.update(zoneFrames: frames, highlightZones: highlightZones)

        // Cancel any in-flight hide so its completion handler doesn't order us out.
        orderOutCanceled = true

        let targetAlpha = CGFloat(Defaults.footprintAlpha.value)
        if Defaults.footprintFade.userDisabled {
            // Fade disabled: snap to visible with no animation.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                alphaValue = targetAlpha
            }
            orderFront(nil)
            return
        }

        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = targetAlpha
        }
    }

    /// Fade the overlay out and order it off-screen.
    ///
    /// Cancels any in-flight fade-in (by clearing `orderOutCanceled`) so the
    /// window can't be left visible after rapid show→hide. When fade is disabled
    /// we order out instantly.
    func hide() {
        orderOutCanceled = false

        if Defaults.footprintFade.userDisabled {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                alphaValue = 0
            }
            orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            if !self.orderOutCanceled {
                self.orderOut(nil)
            }
        }
    }

    // MARK: - Geometry (PURE, unit-testable — the M4 verification gate)

    /// The local-coordinate rect of every zone in `layout`, for an overlay view
    /// that fills `screenFrame` and is NON-FLIPPED (origin bottom-left, y up).
    ///
    /// Each zone is computed by `GridCalculation.zoneRect` inside `visibleFrame`
    /// (Cocoa bottom-left, the screen's adjusted visible area), then offset into
    /// the overlay view's local space by subtracting `screenFrame.origin`.
    ///
    /// Because the view is non-flipped, no vertical flip is applied: a top-row
    /// zone (largest screen y) keeps the largest local y, and every returned rect
    /// lies within `(0, 0, screenFrame.width, screenFrame.height)` as long as
    /// `visibleFrame` is contained in `screenFrame`.
    ///
    /// - Parameters:
    ///   - layout: the zone layout to render.
    ///   - screenFrame: the target screen's full frame (Cocoa bottom-left). The
    ///     overlay window/view share this size; its origin is the conversion base.
    ///   - visibleFrame: the screen's `adjustedVisibleFrame()` (Cocoa bottom-left)
    ///     — the area zones are laid out within.
    /// - Returns: `[zoneId: localRect]`. Zones with a null rect are skipped.
    static func overlayZoneFrames(layout: ZoneLayout, screenFrame: CGRect, visibleFrame: CGRect) -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        let origin = screenFrame.origin
        for zoneId in layout.zoneIds {
            let zoneRect = GridCalculation.zoneRect(layout: layout, zoneId: zoneId, in: visibleFrame)
            guard !zoneRect.isNull else { continue }
            // Screen Cocoa coords -> overlay-view-local coords: subtract the
            // window/screen origin. No flip: the view is non-flipped, so y is
            // preserved (top stays at the top).
            result[zoneId] = CGRect(
                x: zoneRect.minX - origin.x,
                y: zoneRect.minY - origin.y,
                width: zoneRect.width,
                height: zoneRect.height
            )
        }
        return result
    }
}

/// The content view that draws each zone as a footprint-style rounded tile.
///
/// Intentionally NON-FLIPPED (`isFlipped == false`) so its local y grows upward,
/// matching the Cocoa bottom-left rects produced by `overlayZoneFrames`. Each zone
/// is painted like Rectangle's drag footprint — an opaque fill with a light-gray
/// rounded border — while the window's `footprintAlpha` supplies the translucency.
/// The selected (highlighted) zones use the prominent dark fill; unselected zones a
/// lighter one. Fills are user-configurable (`gridSelectedZoneColor` /
/// `gridUnselectedZoneColor`, with `gridUseAccentForSelected` for the system accent).
private class GridOverlayView: NSView {

    private var zoneFrames: [Int: CGRect] = [:]
    private var highlightZones: Set<Int> = []

    override var isFlipped: Bool { false }

    func update(zoneFrames: [Int: CGRect], highlightZones: Set<Int>) {
        self.zoneFrames = zoneFrames
        self.highlightZones = highlightZones
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Each zone is drawn like Rectangle's drag footprint: an opaque fill with a
        // light-gray rounded border; the window's footprintAlpha supplies the
        // translucency (no pre-multiplied alpha). The selected (highlighted) zones are
        // the prominent dark fill; unselected zones a lighter one. Fills are
        // user-configurable, with these as defaults.
        let selectedColor: NSColor = Defaults.gridUseAccentForSelected.userEnabled
            ? .controlAccentColor
            : (Defaults.gridSelectedZoneColor.typedValue?.nsColor ?? GridOverlayView.defaultSelectedColor)
        let unselectedColor = Defaults.gridUnselectedZoneColor.typedValue?.nsColor ?? GridOverlayView.defaultUnselectedColor
        let borderWidth = CGFloat(Defaults.footprintBorderWidth.value)
        let radius = GridOverlayView.cornerRadius
        // A small gap so adjacent zones read as separate rounded footprints rather
        // than one continuous fill.
        let gap = max(borderWidth, 4)

        // No geometry is computed here — rects come from the unit-tested
        // `overlayZoneFrames`; draw(_:) only paints.
        for (zoneId, rect) in zoneFrames {
            let tile = rect.insetBy(dx: gap, dy: gap)
            guard tile.width > 0, tile.height > 0 else { continue }
            let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

            (highlightZones.contains(zoneId) ? selectedColor : unselectedColor).setFill()
            path.fill()

            NSColor.lightGray.setStroke()
            path.lineWidth = borderWidth
            path.stroke()
        }
    }

    /// Default selected-zone fill: the footprint dark grey (matches the drag preview).
    static let defaultSelectedColor = NSColor.black
    /// Default unselected-zone fill: a lighter grey.
    static let defaultUnselectedColor = NSColor(white: 0.6, alpha: 1)

    /// Footprint corner radius, matching FootprintWindow across macOS versions.
    private static var cornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 16 }
        if #available(macOS 11.0, *) { return 10 }
        return 5
    }
}
