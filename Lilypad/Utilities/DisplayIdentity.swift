//
//  DisplayIdentity.swift
//  Lilypad
//
//  Stable identifier for a physical display, used as the storage key for
//  per-monitor snap area profiles. The UUID returned by
//  CGDisplayCreateUUIDFromDisplayID persists across reboots and across
//  reconnects on the same physical display, which CGDirectDisplayID alone
//  does not.
//

import AppKit

extension NSScreen {
    var displayUUIDString: String? {
        guard let num = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuidRef = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuidRef) as String?
    }
}
