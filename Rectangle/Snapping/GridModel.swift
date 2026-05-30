//
//  GridModel.swift
//  Rectangle / Lilypad
//
//  The runtime model for per-monitor named grid layouts, analogous to
//  `SnapAreaModel.instance`. Backed by `Defaults.gridLayoutsByDisplay`
//  (`[displayUUID -> PerDisplayLayouts]`) and enumerating displays through
//  `DisplayRegistry`.
//
//  All mutations use the copy-mutate-writeback idiom (copy the typed dictionary
//  or an empty one, mutate the per-UUID `PerDisplayLayouts`, assign it back so
//  the `JSONDefault` re-serializes), mirroring `SnapAreaModel.setConfig`.
//

import Foundation

class GridModel {
    static let instance = GridModel()

    private init() {}

    // MARK: - Read

    /// The layouts configured for `displayUUID`, or an empty set if the display
    /// has no entry yet (unknown displays return empty rather than nil).
    func layouts(forDisplay displayUUID: String) -> PerDisplayLayouts {
        Defaults.gridLayoutsByDisplay.typedValue?[displayUUID] ?? PerDisplayLayouts()
    }

    /// The active `ZoneLayout` for `displayUUID`, if any (falls back to the first
    /// layout when no `activeLayoutId` is explicitly set; nil when there are none).
    func activeLayout(forDisplay displayUUID: String) -> ZoneLayout? {
        layouts(forDisplay: displayUUID).activeLayout
    }

    /// The active layout for `displayUUID`, seeding the display with the default
    /// starter set on first use if it has no layouts yet. This is the on-demand
    /// seeding the runtime grid path relies on: the one-shot launch migration can
    /// miss displays that aren't named/connected yet at launch (and never re-runs
    /// once lastVersion advances), so the drag/chord/keyboard paths seed lazily
    /// instead. Seeds at most once per display (subsequent calls return the active
    /// layout directly, so there is no per-frame write).
    func ensureActiveLayout(forDisplay displayUUID: String) -> ZoneLayout? {
        if let layout = activeLayout(forDisplay: displayUUID) {
            return layout
        }
        seedDefaultLayouts(forDisplays: [displayUUID])
        return activeLayout(forDisplay: displayUUID)
    }

    // MARK: - Mutations (copy-mutate-writeback)

    /// Appends `layout` to `displayUUID`'s layouts. If the display had no
    /// layouts before, the new one becomes active.
    func addLayout(_ layout: ZoneLayout, forDisplay displayUUID: String) {
        var byDisplay = Defaults.gridLayoutsByDisplay.typedValue ?? [:]
        var perDisplay = byDisplay[displayUUID] ?? PerDisplayLayouts()
        var newLayout = layout
        // Ids must be unique within a display — rename/remove/setActive all key on
        // id, so a collision (e.g. two quick-starters sharing a generator default
        // id) would target the wrong layout. Reassign a fresh id on collision.
        if perDisplay.layouts.contains(where: { $0.id == newLayout.id }) {
            newLayout.id = UUID().uuidString
        }
        perDisplay.layouts.append(newLayout)
        if perDisplay.activeLayoutId == nil {
            perDisplay.activeLayoutId = newLayout.id
        }
        byDisplay[displayUUID] = perDisplay
        Defaults.gridLayoutsByDisplay.typedValue = byDisplay
    }

    /// Renames the layout with `id` on `displayUUID`. No-op if not found.
    func renameLayout(id: String, to newName: String, forDisplay displayUUID: String) {
        var byDisplay = Defaults.gridLayoutsByDisplay.typedValue ?? [:]
        guard var perDisplay = byDisplay[displayUUID],
              let index = perDisplay.layouts.firstIndex(where: { $0.id == id })
        else { return }
        perDisplay.layouts[index].name = newName
        byDisplay[displayUUID] = perDisplay
        Defaults.gridLayoutsByDisplay.typedValue = byDisplay
    }

    /// Removes the layout with `id` from `displayUUID`. If the removed layout was
    /// active, `activeLayoutId` is repointed to the first remaining layout (or
    /// cleared when none remain).
    func removeLayout(id: String, forDisplay displayUUID: String) {
        var byDisplay = Defaults.gridLayoutsByDisplay.typedValue ?? [:]
        guard var perDisplay = byDisplay[displayUUID],
              perDisplay.layouts.contains(where: { $0.id == id })
        else { return }
        perDisplay.layouts.removeAll { $0.id == id }
        if perDisplay.activeLayoutId == id {
            perDisplay.activeLayoutId = perDisplay.layouts.first?.id
        }
        byDisplay[displayUUID] = perDisplay
        Defaults.gridLayoutsByDisplay.typedValue = byDisplay
    }

    /// Overwrites the GEOMETRY (boundaries + cell->zone map) of the layout with
    /// `id` on `displayUUID`, preserving its id / name / active status. This is
    /// the FancyZones editor's Save path (M15): the editor builds a working copy
    /// with the pure `ZoneLayout` edit operations, then writes the result back
    /// here. No-op if no layout with that id exists for the display.
    func updateLayout(id: String,
                      colBoundaries: [Double],
                      rowBoundaries: [Double],
                      cellZones: [Int],
                      forDisplay displayUUID: String) {
        var byDisplay = Defaults.gridLayoutsByDisplay.typedValue ?? [:]
        guard var perDisplay = byDisplay[displayUUID],
              let index = perDisplay.layouts.firstIndex(where: { $0.id == id })
        else { return }
        // Mutate geometry in place; id / name (and the surrounding activeLayoutId)
        // are untouched, so the active marker and slot ordering are preserved.
        perDisplay.layouts[index].colBoundaries = colBoundaries
        perDisplay.layouts[index].rowBoundaries = rowBoundaries
        perDisplay.layouts[index].cellZones = cellZones
        byDisplay[displayUUID] = perDisplay
        Defaults.gridLayoutsByDisplay.typedValue = byDisplay
    }

    /// Convenience overload taking an already-built `ZoneLayout` (matched by its
    /// `id`); writes back only its geometry, preserving the stored name.
    func updateLayout(_ layout: ZoneLayout, forDisplay displayUUID: String) {
        updateLayout(id: layout.id,
                     colBoundaries: layout.colBoundaries,
                     rowBoundaries: layout.rowBoundaries,
                     cellZones: layout.cellZones,
                     forDisplay: displayUUID)
    }

    /// Marks the layout with `id` as active on `displayUUID`. No-op if no layout
    /// with that id exists for the display.
    func setActiveLayout(id: String, forDisplay displayUUID: String) {
        var byDisplay = Defaults.gridLayoutsByDisplay.typedValue ?? [:]
        guard var perDisplay = byDisplay[displayUUID],
              perDisplay.layouts.contains(where: { $0.id == id })
        else { return }
        perDisplay.activeLayoutId = id
        byDisplay[displayUUID] = perDisplay
        Defaults.gridLayoutsByDisplay.typedValue = byDisplay
    }

    // MARK: - Seeding

    /// Seeds a sensible starter set of layouts for each UUID in `displays` that
    /// has no existing `PerDisplayLayouts`. Idempotent: a display that already
    /// has an entry is never overwritten, so this is safe to call on every
    /// launch / migration. Returns the UUIDs that were actually seeded.
    ///
    /// Pure and testable — takes the UUID list as a parameter rather than reading
    /// from `DisplayRegistry`, so callers control which displays to seed.
    @discardableResult
    func seedDefaultLayouts(forDisplays displays: [String]) -> [String] {
        var byDisplay = Defaults.gridLayoutsByDisplay.typedValue ?? [:]
        var seeded: [String] = []
        for uuid in displays {
            // An existing entry — even an empty one (e.g. the user removed a
            // display's last layout) — counts as "already configured" and is left
            // untouched; only displays with no entry at all are seeded.
            guard byDisplay[uuid] == nil else { continue }
            byDisplay[uuid] = GridModel.starterLayouts()
            seeded.append(uuid)
        }
        if !seeded.isEmpty {
            Defaults.gridLayoutsByDisplay.typedValue = byDisplay
        }
        return seeded
    }

    /// The default starter set for a freshly-seeded display: a 2×2 grid (active)
    /// plus a 3×2 grid, built with the M2 quick-starter generators.
    static func starterLayouts() -> PerDisplayLayouts {
        // Fresh unique ids per seeded display (the human label stays in `name`),
        // so ids are safe for the add/rename/remove UI in later milestones.
        let grid2x2 = ZoneLayout.grid2x2(id: UUID().uuidString)
        let grid3x2 = ZoneLayout.grid3x2(id: UUID().uuidString)
        return PerDisplayLayouts(layouts: [grid2x2, grid3x2], activeLayoutId: grid2x2.id)
    }
}
