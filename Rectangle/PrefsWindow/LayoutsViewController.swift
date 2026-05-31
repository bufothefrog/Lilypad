//
//  LayoutsViewController.swift
//  Rectangle / Lilypad
//
//  M14 (Stage 9a). The AppKit host for the Lilypad "Layouts" preferences pane.
//  It embeds an `NSHostingController(rootView: LayoutsRootView())` as a child
//  view controller pinned edge-to-edge, so the actual UI is SwiftUI. This is the
//  first SwiftUI in the project; the base `NSHostingController` / SwiftUI are
//  available at the project's 10.15 deployment target.
//
//  Built fully programmatically (no IB scene) because the tab is added
//  programmatically by `PrefsTabViewController`.
//

import Cocoa
import SwiftUI

class LayoutsViewController: NSViewController {

    override func loadView() {
        // A plain container the hosting view is pinned inside. The prefs window is
        // an NSTabViewController with `tabStyle = .toolbar`, which resizes the
        // window to fit each selected tab's content view. The three IB scenes
        // (Shortcuts / General / Snap Areas) are all 850pt wide, so this container
        // must match that width or the toolbar window visibly shrinks and
        // re-expands when switching to and from the Layouts tab. The SwiftUI
        // content keeps its 500pt column centered inside this 850pt view via
        // `.frame(maxWidth: .infinity, alignment: .center)` — the same way the
        // AppKit panes center their 500pt stack inside the 850pt scene. The height
        // sits within the other scenes' range (567–686pt) so the window doesn't
        // jump vertically either; the SwiftUI pane scrolls if it needs more.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 850, height: 620))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let hosting = NSHostingController(rootView: LayoutsRootView())
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
