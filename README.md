# Lilypad

[![Build](https://github.com/bufothefrog/Lilypad/actions/workflows/build.yml/badge.svg)](https://github.com/bufothefrog/Lilypad/actions/workflows/build.yml)

Lilypad is a per-monitor **grid** window manager for macOS, written in Swift. It is a fork of [Rectangle](https://github.com/rxhanson/Rectangle) by Ryan Hanson (MIT-licensed), which is itself based on Spectacle. Lilypad replaces Rectangle's edge snap areas with named, per-monitor zone layouts (FancyZones-style): a split/merge layout editor, drag-to-grid snapping, and keyboard grid navigation.

<img width="962" height="886" alt="image" src="https://github.com/user-attachments/assets/e8d88e5f-7d4f-43bc-a82e-146c42f92d68" />

## System Requirements

Lilypad supports macOS 13 (Ventura) and later.

## Installation

Download the latest build from the [Releases page](https://github.com/bufothefrog/Lilypad/releases), or build from source (see *Running the app in Xcode* below).

## How to use it

Lilypad has two ways to place windows: a **per-monitor grid** (its headline feature) and Rectangle's classic **edge snapping**, which still works alongside it.

### Grid

Each monitor has one or more named **layouts** — a set of rectangular **zones** you design in the layout editor (Settings → Layouts → Edit). The editor is a FancyZones-style canvas: click a zone to split it (Space rotates the split axis), drag across zones to merge them, and drag the lines between zones to resize.

- **Drag to a zone:** hold **Shift** while dragging a window. The active layout lights up on the monitor under the cursor and the window snaps to the zone you release over.
- **Span multiple zones:** also hold **Option** (configurable) while dragging to extend the selection from the anchor zone across several zones.
- **Keyboard:** the `gridMove` shortcuts move the focused window to the adjacent zone, `gridSpan` grows it by one zone toward an arrow, and layout-activation shortcuts switch a monitor's active layout.

### Classic edge snapping

Drag a window to the edge of the screen. When the mouse cursor reaches the edge of the screen, you'll see a footprint that Lilypad will attempt to resize and move the window to when the click is released. (This can be turned off independently of the grid.)

| Snap Area                                              | Resulting Action                       |
|--------------------------------------------------------|----------------------------------------|
| Left or right edge                                     | Left or right half                     |
| Top                                                    | Maximize                               |
| Corners                                                | Quarter in respective corner           |
| Left or right edge, just above or below a corner       | Top or bottom half                     |
| Bottom left, center, or right third                    | Respective third                       |
| Bottom left or right third, then drag to bottom center | First or last two thirds, respectively |

### Ignore an app

Ignoring an app means that when the app is frontmost, keyboard shortcuts are un-registered from macOS. When the app is no longer frontmost, keyboard shortcuts are re-registered with macOS. This is useful for apps that have the same shortcuts like Lilypad and you do not want to change them.

1. Focus the app that you want to ignore (make a window from that app frontmost).
1. Open the Lilypad menu and select "Ignore app"

To un-ignore an app that you have selected to ignore, simply bring that app frontmost again, open the Lilypad menu, and deselect "Ignore".

## Execute an action by URL

Open the URL `lilypad://execute-action?name=[name]`. Do not activate Lilypad if possible.

Available values for `[name]`: `left-half`, `right-half`, `center-half`, `top-half`, `bottom-half`, `top-left`, `top-right`, `bottom-left`, `bottom-right`, `first-third`, `center-third`, `last-third`, `first-two-thirds`, `last-two-thirds`, `maximize`, `almost-maximize`, `maximize-height`, `smaller`, `larger`, `center`, `center-prominently`, `restore`, `next-display`, `previous-display`, `move-left`, `move-right`, `move-up`, `move-down`, `first-fourth`, `second-fourth`, `third-fourth`, `last-fourth`, `first-three-fourths`, `last-three-fourths`, `top-left-sixth`, `top-center-sixth`, `top-right-sixth`, `bottom-left-sixth`, `bottom-center-sixth`, `bottom-right-sixth`, `specified`, `reverse-all`, `top-left-ninth`, `top-center-ninth`, `top-right-ninth`, `middle-left-ninth`, `middle-center-ninth`, `middle-right-ninth`, `bottom-left-ninth`, `bottom-center-ninth`, `bottom-right-ninth`, `top-left-third`, `top-right-third`, `bottom-left-third`, `bottom-right-third`, `top-left-eighth`, `top-center-left-eighth`, `top-center-right-eighth`, `top-right-eighth`, `bottom-left-eighth`, `bottom-center-left-eighth`, `bottom-center-right-eighth`, `bottom-right-eighth`, `tile-all`, `cascade-all`, `cascade-active-app`

Example, from a shell: `open -g "lilypad://execute-action?name=left-half"`

URLs can also be used to ignore/unignore apps. 

```
lilypad://execute-task?name=ignore-app
lilypad://execute-task?name=unignore-app
```
A bundle identifier can also be specified, for example:
```
lilypad://execute-task?name=ignore-app&app-bundle-id=com.apple.Safari
```

## Terminal Commands for Hidden Preferences

See [TerminalCommands.md](TerminalCommands.md)

## Differences with Spectacle

* Lilypad uses [MASShortcut](https://github.com/rxhanson/MASShortcut) for keyboard shortcut recording. Spectacle used its own shortcut recorder.
* Lilypad has additional window actions: move windows to each edge without resizing, maximize only the height of a window, almost maximizing a window.
* Next/prev screen thirds is replaced with explicitly first third, first two thirds, center third, last two thirds, and last third. Screen orientation is taken into account, as in first third will be left third on landscape and top third on portrait.
  * You can however emulate Spectacle's third cycling using first and last third actions. So, if you repeatedly execute first third, it will cycle through thirds (first, center, last) and vice-versa with the last third.
* There's an option to have windows traverse across displays on subsequent left or right executions.
* Windows will snap when dragged to edges/corners of the screen. This can be disabled.

## Common Known Issues

### Lilypad doesn't have the ability to move to other desktops/spaces

Apple never released a public API for doing this. Rectangle Pro has next/prev Space actions, but there are no plans to add those into Lilypad at this time.

### Window resizing is off slightly for iTerm2

By default iTerm2 will only resize in increments of character widths. There might be a setting inside iTerm2 to disable this, but you can change it with the following command.

```bash
defaults write com.googlecode.iterm2 DisableWindowSizeSnap -integer 1
```

### Lilypad appears to cause Notification Center to freeze

This appears to affect only a small amount of users. To prevent this from happening, uncheck the box for "Snap windows by dragging".
See upstream Rectangle issue [317](https://github.com/rxhanson/Rectangle/issues/317).

### Troubleshooting

If windows aren't resizing or moving as you expect, here's some initial steps to get to the bottom of it. Most issues of this type have been caused by other apps.

**Quick fixes (try these first):**

1. **Lock and unlock your Mac** – This simple step resolves many issues, especially after system updates.
1. Make sure macOS is up to date.
1. Restart your Mac (this often fixes things right after a macOS update).

**Diagnose the issue:**

4. **Enable debug logging** (see instructions in the following section) – This helps identify whether Lilypad is working correctly.
1. The logs are straightforward. If your calculated rect and your resulting rect are identical, chances are that there is another application causing issues.

**Check for conflicts:**

6. Make sure there are no other window manager applications running.
1. Make sure that the app whose windows are not behaving properly does not have any conflicting keyboard shortcuts.
1. Try using the menu items to execute a window action or changing the keyboard shortcut to something different so we can tell if it's a keyboard shortcut issue or not.

**Advanced troubleshooting:**

9. If you suspect there may be another application causing issues, try creating and logging in as a new macOS user.
1. Save your logs to attach to an issue if you need to create one.

#### Try resetting the macOS accessibility permissions for Lilypad:

```bash
tccutil reset All com.lilypad.Lilypad
```

Or, this can be done with the following steps instead of the tccutil terminal command.
1. Close Lilypad if it's running
2. In System Settings -> Privacy & Security -> Accessibility, first disable Lilypad, then remove it with the minus button. (it's important to do both of those steps in that order)
3. Restart your mac.
4. Launch Lilypad and enable settings for it as prompted.

## View Debug Logging

1. Hold down the alt (option) key with the Lilypad menu open.
1. Select the "View Logging..." menu item, which is in place of the "About" menu item.
1. Logging will appear in the window as you perform Lilypad commands.

## Import & export JSON config

There are buttons for importing and exporting the config as a JSON file in the settings tab of the preferences window. 

Upon launch, Lilypad will load a config file at `~/Library/Application Support/LilypadConfig.json` if it is present and will rename that file with a time/date stamp so that it isn't read on subsequent launches.

## Preferences Storage

The configuration for Lilypad is stored using NSUserDefaults, meaning it is stored in the following location:
`~/Library/Preferences/com.lilypad.Lilypad.plist`

That file can be backed up or transferred to other machines.

You can also use the import/export button in the Settings pane to share your preferences and keyboard shortcuts across machines using a JSON file.

## Uninstallation

Lilypad can be uninstalled by quitting the app and moving it to the trash. You can remove the Lilypad defaults from your machine with the following terminal command:

```bash
defaults delete com.lilypad.Lilypad
```

---

## Contributing

Lilypad is a community fork of [Rectangle](https://github.com/rxhanson/Rectangle). Pull requests and localizations are welcome. If you'd like to support the project Lilypad is built on, consider supporting upstream Rectangle (and its commercial siblings Multitouch and Rectangle Pro) as well.

### Contributing additional sizes and positions

Lilypad's UI is intentionally simple. If you want to add a size and position that's not in the Shortcuts tab, then you can now add them into the "Extra Shortcuts" section accessed via the ellipsis button at the bottom of the General tab.

### Localization

If you would like to contribute to localization, all of the translations are held in the Main.strings.

Pull requests for new localizations or improvements on existing localizations are welcome.

### Running the app in Xcode (for developers)

Lilypad uses [Swift Package Manager](https://www.swift.org/package-manager/) to install Sparkle and MASShortcut.

The original repository for MASShortcut was archived, so Lilypad (like Rectangle) depends on rxhanson's maintained [fork](https://github.com/rxhanson/MASShortcut).

Due to the addition of the Liquid Glass icon with a fallback for older versions of macOS, there will be a build failure on macOS versions < 26. You can delete the "Asset Catalog Other Flags" to build locally on versions < 26 (but don't check that change in if you create a pull request).

## Credits

Lilypad is a fork of [Rectangle](https://github.com/rxhanson/Rectangle) by Ryan Hanson. Like Rectangle, it uses a forked version of [MASShortcut](https://github.com/rxhanson/MASShortcut) and [Sparkle](https://sparkle-project.org) for updates.

The Lilypad app icon is original artwork created for this fork. (The upstream Rectangle app icons were created by Giovanni Maria Cusaro (@gmcusaro) and [Alexander Käßner](https://www.alexkaessner.de) (@alexkaessner).)

And of course, there's been a lot of community contributions over the years :)
