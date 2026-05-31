//
//  LayoutsViewController.swift
//  Rectangle / Lilypad
//
//  M14 (Stage 9a). The AppKit host for the Lilypad "Layouts" preferences pane.
//  It embeds an `NSHostingController(rootView: LayoutsRootView())` whose view is
//  the document of an `NSScrollView` pinned edge-to-edge, so the actual UI is
//  SwiftUI. This is the first SwiftUI in the project; the base
//  `NSHostingController` / SwiftUI are available at the project's 10.15
//  deployment target.
//
//  Built fully programmatically (no IB scene) because the tab is added
//  programmatically by `PrefsTabViewController`.
//
//  SIZING. The prefs window is an `NSTabViewController` with `tabStyle =
//  .toolbar`, which resizes the window to fit each selected tab's content view.
//  The three IB scenes (Shortcuts / General / Snap Areas) are all 850pt wide and
//  bounded in height, so this container:
//    - pins its WIDTH at 850 so the window never jumps horizontally on tab switch
//      (the SwiftUI 500pt column stays centered via
//      `.frame(maxWidth: .infinity, alignment: .center)`); and
//    - lets its HEIGHT be driven by the SwiftUI hosting view's intrinsic content
//      size so, in the common case, the toolbar window GROWS to fit the full
//      Layouts content with NO scroll bar (the SwiftUI body does not wrap its
//      content in a ScrollView — Bug A's fix).
//
//  ESCAPE HATCH (the tall-content edge case). Unlike the bounded IB tabs, the
//  Layouts content is UNBOUNDED: the layouts list grows one row per layout. On a
//  short display, or with many layouts, an intrinsic-height-only window could grow
//  taller than the screen and push the bottom controls (the Gaps slider) off the
//  visible frame with no way to reach them. So the hosting view is the document of
//  an `NSScrollView`, and the scroll view height is capped to the active screen's
//  visible height (minus room for the window's title bar + toolbar). While the
//  content fits under that cap the document exactly fills the clip view, no
//  scroller appears, and the window sizes to the content as desired; only once the
//  content would exceed the screen does a vertical scroller appear so the bottom
//  control stays reachable. The cap is recomputed whenever the pane appears or
//  moves to another screen.
//

import Cocoa
import SwiftUI

class LayoutsViewController: NSViewController {

    /// Width shared with the IB tabs; pinning it keeps the toolbar window from
    /// jumping horizontally on tab switch.
    private static let fixedWidth: CGFloat = 850

    /// Headroom reserved below the screen's visible height for the window's title
    /// bar + toolbar (and a little breathing room) when capping the pane height,
    /// so the capped window still fits fully on screen.
    private static let windowChromeAllowance: CGFloat = 80

    private let hosting = NSHostingController(rootView: LayoutsRootView())
    private let scrollView = NSScrollView()

    /// The cap that keeps the pane (and thus the window) from growing past the
    /// active screen. Updated when the screen is known / changes; until then it is
    /// effectively unbounded so the common case is untouched.
    private var maxHeightConstraint: NSLayoutConstraint!

    override func loadView() {
        // A plain container the scroll view is pinned inside, sized to the shared
        // 850pt width. The initial frame height is just a placeholder until the
        // hosting view's fitting size is established.
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: 620))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hosting)

        // Scroll view that only shows a scroller when the content exceeds the cap.
        // Borderless and transparent so when nothing scrolls it is visually
        // indistinguishable from hosting the SwiftUI view directly.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = hosting.view
        view.addSubview(scrollView)

        let document = hosting.view
        document.translatesAutoresizingMaskIntoConstraints = false

        // The document's intrinsic content height (and the fixed width) flow up: in
        // the common case the scroll view, container, and window all size to it with
        // no scroller. The width is pinned to 850 so the window never jumps
        // horizontally across tabs.
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.fixedWidth),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Standard auto-layout scrollable-document wiring: the document is
            // pinned to the clip view's top/leading and its WIDTH is locked to the
            // clip view, but its HEIGHT is left to the SwiftUI content's intrinsic
            // size (no bottom-edge equality, which would force the document to match
            // the clip height and never scroll). So the document is exactly as tall
            // as the content: when that is <= the cap the clip view (and window)
            // size to it and `autohidesScrollers` hides the scroller; when it is
            // greater the document overflows the clip view and the vertical scroller
            // appears, keeping the bottom controls reachable.
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        // Make the window GROW to fit the content in the common case: pull the
        // clip view's height up to the document's intrinsic height. This is
        // required-but-breakable — it is satisfied (window sizes to content) until
        // it collides with the hard `maxHeightConstraint` cap, at which point the
        // cap wins, the clip view stops at the screen height, and the document
        // scrolls. A priority just below required lets the cap override it cleanly
        // without an unsatisfiable-constraints log.
        let growToContent = scrollView.contentView.heightAnchor.constraint(equalTo: document.heightAnchor)
        growToContent.priority = .defaultHigh
        growToContent.isActive = true

        // The cap that keeps the window on screen. Starts very large (effectively
        // unbounded) so the common case is identical to a plain hosting view; it is
        // tightened once the active screen is known (`viewWillAppear`).
        maxHeightConstraint = view.heightAnchor.constraint(lessThanOrEqualToConstant: 100_000)
        maxHeightConstraint.isActive = true
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateHeightCap()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Re-cap on layout passes too: the window may have moved to a different
        // screen (e.g. dragged to a shorter display) since the pane appeared.
        updateHeightCap()
    }

    /// Cap the pane height to the active screen's visible height minus window
    /// chrome, so the toolbar window can never grow taller than the screen and the
    /// bottom Gaps control is always reachable (via the scroller once content
    /// exceeds the screen). When the content fits under the cap this is inert and
    /// the window sizes to the content with no scroll bar.
    private func updateHeightCap() {
        guard maxHeightConstraint != nil else { return }
        let screen = view.window?.screen ?? NSScreen.main
        guard let visibleHeight = screen?.visibleFrame.height else { return }
        maxHeightConstraint.constant = max(200, visibleHeight - Self.windowChromeAllowance)
    }
}
