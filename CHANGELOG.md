# Changelog

All notable changes to Lilypad are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
semantic versioning.

## [1.0.0] — Unreleased

First public release of Lilypad, a per-monitor grid window manager for macOS,
forked from [Rectangle](https://github.com/rxhanson/Rectangle).

### Added
- **Per-monitor zone layouts** (FancyZones-style) — named layouts per display.
- **Split/merge layout editor** — cut/merge cells, per-track ratio inputs,
  real-edge resize dividers, proximity seam resize cue.
- **Drag-to-grid** snapping with a drag-span sub-mode and proximity span.
- **Keyboard grid navigation** — move/span a window one zone at a time,
  per-edge wall actions, monitor-relative layout-activation shortcuts.
- Classic edge snapping coexists with the grid.

### Changed
- Rebranded from Rectangle to **Lilypad**: original app icon, menu-bar glyph,
  bundle id `com.lilypad.Lilypad`, and `lilypad://` URL scheme.
- Raised the minimum macOS version to **13.0**; removed the launcher target in
  favor of `SMAppService`.

### Notes
- Clean break from Rectangle: settings do not migrate automatically (a
  Rectangle config export can be imported manually — see the README). You will
  re-grant Accessibility and Input Monitoring under the new app identity.

[1.0.0]: https://github.com/bufothefrog/Lilypad/releases/tag/v1.0.0
