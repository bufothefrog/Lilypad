//
//  PrefsTabViewController.swift
//  Rectangle / Lilypad
//
//  M14 (Stage 9a). The preferences window's tab controller is a stock
//  `NSTabViewController` in `Main.storyboard` whose three IB tabs (Shortcuts /
//  Snap Areas / General) are wired via `tabItems` relationship segues. Rather
//  than add a whole new storyboard scene for the Lilypad "Layouts" tab, the
//  storyboard's `tabViewController` object has its `customClass` set to this
//  subclass (a single attribute edit), and we append the Layouts tab
//  programmatically in `viewDidLoad`.
//
//  This keeps the existing three tabs loading from IB exactly as before — they
//  are still the storyboard's `tabViewItems`/`tabItems` segues; we only ADD a
//  fourth item at the end. The added item hosts a SwiftUI island
//  (`LayoutsViewController` -> `NSHostingController(LayoutsRootView)`), the
//  first SwiftUI in the project.
//

import Cocoa

class PrefsTabViewController: NSTabViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        addLayoutsTab()
    }

    /// Appends the Lilypad "Layouts" tab as the last toolbar item. The three IB
    /// tabs are untouched (they remain the storyboard's relationship segues); this
    /// only adds a new `NSTabViewItem` backed by `LayoutsViewController`.
    private func addLayoutsTab() {
        let layoutsVC = LayoutsViewController()
        let item = NSTabViewItem(viewController: layoutsVC)
        item.label = NSLocalizedString("Layouts", tableName: "Main", value: "Layouts", comment: "Layouts preferences tab title")
        // Reuse an existing template toolbar image so the new tab has an icon
        // consistent with the others. `snapAreaTemplate` already ships in the
        // asset catalog and reads as a "regions on a screen" glyph.
        item.image = NSImage(named: "snapAreaTemplate")
        addTabViewItem(item)
    }
}
