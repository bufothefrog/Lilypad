//
//  GridModel.swift
//  Lilypad
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

    /// The active layout for `displayUUID`, or a COMPUTED default when the display
    /// has none yet. Mirrors `SnapAreaModel`'s computed-default model: the runtime
    /// grid path (drag / chord / keyboard) gets a usable layout WITHOUT writing
    /// anything to storage. This is deliberate — the previous version persisted a
    /// seed on first use, and that per-display write is exactly what exposed the
    /// shared layouts dict to the stale-cache clobber that wiped other displays. A
    /// display only gets a STORED layout once the user explicitly creates one in the
    /// Layouts pane; until then the grid just uses `computedDefaultLayout`.
    func ensureActiveLayout(forDisplay displayUUID: String) -> ZoneLayout? {
        if let layout = activeLayout(forDisplay: displayUUID) {
            return layout
        }
        return GridModel.computedDefaultLayout()
    }

    /// The in-memory default layout used when a display has no stored layouts. A
    /// STABLE id (not a fresh UUID) so repeat / last-action detection on the runtime
    /// commit paths stays consistent across frames and drags.
    static func computedDefaultLayout() -> ZoneLayout {
        ZoneLayout.grid2x2(id: "lilypad.default.2x2", name: "2 × 2")
    }

    // MARK: - Persistence (mirrors SnapAreaModel's per-display model)

    /// Per-display layouts, read/written through the `JSONDefault` cache exactly like
    /// `SnapAreaModel` accesses `snapAreasByDisplay` — the per-monitor mechanism that
    /// has worked reliably since the original fork. Every mutation reads the whole
    /// cache, changes one display, and writes the whole cache back, so the in-memory
    /// cache (loaded once at launch) stays the source of truth and any single write
    /// preserves every other monitor's layouts. The previous relaunch data loss came
    /// from the GRID-SPECIFIC extra writes (seeding on launch + on every drag), not
    /// this access pattern — those are gone (see `ensureActiveLayout` / AppDelegate),
    /// so writes are now as rare as snap-area overrides.
    private func currentByDisplay() -> [String: PerDisplayLayouts] {
        Defaults.gridLayoutsByDisplay.typedValue ?? [:]
    }

    private func writeByDisplay(_ byDisplay: [String: PerDisplayLayouts]) {
        Defaults.gridLayoutsByDisplay.typedValue = byDisplay
    }

    // MARK: - Mutations (copy-mutate-writeback)

    /// Appends `layout` to `displayUUID`'s layouts. If the display had no
    /// layouts before, the new one becomes active.
    func addLayout(_ layout: ZoneLayout, forDisplay displayUUID: String) {
        var byDisplay = currentByDisplay()
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
        writeByDisplay(byDisplay)
    }

    /// Renames the layout with `id` on `displayUUID`. No-op if not found.
    func renameLayout(id: String, to newName: String, forDisplay displayUUID: String) {
        var byDisplay = currentByDisplay()
        guard var perDisplay = byDisplay[displayUUID],
              let index = perDisplay.layouts.firstIndex(where: { $0.id == id })
        else { return }
        perDisplay.layouts[index].name = newName
        byDisplay[displayUUID] = perDisplay
        writeByDisplay(byDisplay)
    }

    /// Removes the layout with `id` from `displayUUID`. If the removed layout was
    /// active, `activeLayoutId` is repointed to the first remaining layout (or
    /// cleared when none remain).
    func removeLayout(id: String, forDisplay displayUUID: String) {
        var byDisplay = currentByDisplay()
        guard var perDisplay = byDisplay[displayUUID],
              perDisplay.layouts.contains(where: { $0.id == id })
        else { return }
        perDisplay.layouts.removeAll { $0.id == id }
        if perDisplay.activeLayoutId == id {
            perDisplay.activeLayoutId = perDisplay.layouts.first?.id
        }
        byDisplay[displayUUID] = perDisplay
        writeByDisplay(byDisplay)
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
        var byDisplay = currentByDisplay()
        guard var perDisplay = byDisplay[displayUUID],
              let index = perDisplay.layouts.firstIndex(where: { $0.id == id })
        else { return }
        // Mutate geometry in place; id / name (and the surrounding activeLayoutId)
        // are untouched, so the active marker and slot ordering are preserved.
        perDisplay.layouts[index].colBoundaries = colBoundaries
        perDisplay.layouts[index].rowBoundaries = rowBoundaries
        perDisplay.layouts[index].cellZones = cellZones
        byDisplay[displayUUID] = perDisplay
        writeByDisplay(byDisplay)
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
        var byDisplay = currentByDisplay()
        guard var perDisplay = byDisplay[displayUUID],
              perDisplay.layouts.contains(where: { $0.id == id })
        else { return }
        perDisplay.activeLayoutId = id
        byDisplay[displayUUID] = perDisplay
        writeByDisplay(byDisplay)
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
        var byDisplay = currentByDisplay()
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
            writeByDisplay(byDisplay)
        }
        return seeded
    }

    /// The default starter set for a freshly-seeded display: a single 2×2 grid
    /// (active), built with the M2 quick-starter generators. Kept to ONE starter
    /// so a fresh monitor has a working drag-snap layout out of the box without
    /// pre-populating the list with extras the user didn't choose — they add the
    /// rest themselves via the Layouts pane.
    static func starterLayouts() -> PerDisplayLayouts {
        // Fresh unique id per seeded display (the human label stays in `name`),
        // so the id is safe for the add/rename/remove UI.
        let grid2x2 = ZoneLayout.grid2x2(id: UUID().uuidString)
        return PerDisplayLayouts(layouts: [grid2x2], activeLayoutId: grid2x2.id)
    }
}
