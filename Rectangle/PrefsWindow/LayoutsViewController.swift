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
        // A plain container the hosting view is pinned inside. Sized to roughly
        // match the other prefs tabs; the tab view resizes it to fit the window.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
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
