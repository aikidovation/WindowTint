# WindowTint

A menu-bar app for Apple silicon Macs. In Dark Mode, stacked windows of different apps look the same. WindowTint draws a colored border on each normal window, in a shade of that app's icon color, so a window in the background is still recognizable.

Each app gets one base color. Each window of that app gets a slightly different lightness and hue, chosen the first time that window is seen, and kept for the rest of the session.

The optional tint is a faint wash of the same color over the window (6% opacity). It is off unless you turn it on.

The border is click-through. It does not change the apps underneath it.

## Requirements

- An Apple silicon Mac
- macOS 14 or later
- Xcode, for `swiftc`, `codesign`, and (only if the icon is missing) `iconutil`

Intel Macs and Rosetta are not supported. The app is not sandboxed. It uses public window-list, Accessibility, AppKit, and ServiceManagement APIs only.

## What it does

The menu-bar icon (two overlapping squares) lets you:

- Turn borders on or off (**Enabled**)
- Pick a **Border Width** of 2, 4, or 6 points (default 4)
- Turn the faint **Tint** on or off (default off)
- **Grant Accessibility…** when WindowTint is not allowed to watch window movement (the item is hidden once it is)
- **Launch at Login**
- Open this project’s page on GitHub (**View on GitHub**)
- Quit

Colors are cached per app. A `defaults` override replaces an app’s base color. Other windows of that app are still lighter or darker variants of it.

## Limits

- Each border stays on the Space where its window lives. It is shown only while that window is on screen. Switching Spaces does not move a border onto the Space you are leaving for.
- Mission Control is best effort. A border is a separate window ordered just above its target, which is the relationship that can show up in a preview. There is no public API to draw inside another app's window, or to attach our window as a child of another process's window, so a preview can omit the border. Stage Manager thumbnails are separate snapshots and are not tinted.
- While you drag or resize a window, its border hides until the frame has stayed still for about 150 ms. A window that just appeared waits the same way, so a Space animation does not flash a border in the wrong place. With Accessibility permission, other updates are coalesced to about 20 per second. Without it, a timer refreshes about twice a second.
- Full-screen apps are tinted only when the window is a normal on-screen window and the border is allowed onto that space. The transition into full screen can lag by one refresh.
- The corner radius is a fixed 12 points. It will not match every window, especially very small ones or windows with a different corner.
- Windows smaller than 100×60 points, fully transparent windows, and this app’s own windows are skipped. Minimized windows are off screen, so they are not tinted until they come back.
- WindowTint does not read window titles, so it does not need Screen Recording permission.

## Permissions

WindowTint asks for Accessibility permission so it can refresh as soon as a window moves, resizes, or opens. If you decline, borders still update on the timer, and the menu shows **Grant Accessibility…**.

That item opens System Settings to Privacy & Security → Accessibility:

`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`

The app is ad-hoc signed, and each rebuild gets a new signature. macOS then treats it as a different app, so you have to allow it in Accessibility again. If the switch is on but events never arrive, remove the old WindowTint row from the Accessibility list and allow the new build.

It does not need Screen Recording, microphone, or other privacy permissions.

## Opening the app the first time

The app `build.sh` produces is ad-hoc signed. It is not notarized, so macOS treats it as coming from an unidentified developer.

1. Try to open `WindowTint.app` (double-click it, or right-click and choose Open). macOS will warn that Apple could not verify it.
2. Open **System Settings**, click **Privacy & Security** in the sidebar, and scroll down to **Security**.
3. Click **Open Anyway**. This button is available for about an hour after you try to open the app. See [Apple’s steps for opening an app from an unidentified developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).
4. Enter your Mac login password if asked, then click **Open** on the warning that appears again.

After that, you can open WindowTint like any other app. It appears only in the menu bar (there is no Dock icon).

More background from Apple: [Safely open apps on your Mac](https://support.apple.com/en-us/102445).

## Launch at Login

WindowTint does not register itself as a login item until you turn on **Launch at Login**. macOS may then ask you to allow it. If approval is still needed, the app opens **System Settings › General › Login Items** so you can allow WindowTint there.

## Build from source

Install Xcode, then in this directory run:

```bash
./build.sh
```

That writes an ad-hoc-signed Apple silicon app to `build/WindowTint.app`. The deployment target is macOS 14. Open it with:

```bash
open build/WindowTint.app
```

`build.sh` does not launch the app.

## Settings

Settings are stored in UserDefaults for `com.aikidovation.WindowTint`. Changes are picked up on the next refresh, within a fraction of a second. You do not need to relaunch.

| Key | Type | Default |
| --- | --- | --- |
| `enabled` | bool | true |
| `borderWidth` | float | 4 (also 2 or 6) |
| `tintEnabled` | bool | false |
| `colorOverrides` | dictionary of bundle id → `#RRGGBB` | empty |
| `excludedBundleIDs` | array of bundle ids | empty |
| `DebugLog` | bool | false |

Give Safari a blue border, and do not tint Finder:

```bash
defaults write com.aikidovation.WindowTint colorOverrides -dict-add com.apple.Safari "#2F6FED"
defaults write com.aikidovation.WindowTint excludedBundleIDs -array com.apple.finder
```

`-dict-add` merges one entry. Replacing the whole override dictionary:

```bash
defaults write com.aikidovation.WindowTint colorOverrides -dict com.apple.Safari "#2F6FED" com.apple.Terminal "#3DDC97"
```

Clear the overrides or the exclusion list:

```bash
defaults delete com.aikidovation.WindowTint colorOverrides
defaults delete com.aikidovation.WindowTint excludedBundleIDs
```

A bundle id is the app’s id, not its name:

```bash
osascript -e 'id of app "Safari"'
```

The hex value is that app’s base color (its first window). Further windows of the same app keep that hue and shift brightness by about 8–12%. Very dark hex values are hard to see as a border.

To log every refresh to `~/Library/Logs/WindowTint.log`:

```bash
defaults write com.aikidovation.WindowTint DebugLog -bool true
```

A line is written when the on-screen windows, frames, colors, or stacking order change. The line includes what triggered that change, how many on-screen windows WindowTint is considering, the back-to-front window ids, and for each window the id, process id, bundle id, Quartz frame, whether the border was created, shown, or hidden, and the border color. Identical timer ticks are not logged. Set the key back to false to stop. You do not need to relaunch.

There is no default override and no default exclusion.

## App icon

The bundle icon is original artwork: overlapping navy, green, and grey rounded rectangles on a dark rounded square. It is not an SF Symbol. `Resources/AppIcon.icns` is not checked in. When that file is missing, `build.sh` runs `tools/make-icon.swift` and `iconutil`, then copies the icns into the app before signing. The menu-bar item itself stays the system `square.on.square` symbol, drawn at runtime.

<img src="Resources/icon-1024.png" width="128" alt="WindowTint app icon">

The picture above is the committed preview, `Resources/icon-1024.png`. To regenerate the icon and that preview on a Mac:

```bash
cd tools
xcrun swift make-icon.swift
iconutil -c icns AppIcon.iconset -o AppIcon.icns
cp AppIcon.icns ../Resources/AppIcon.icns
cp icon-1024.png ../Resources/icon-1024.png
```

`make-icon.swift` writes `AppIcon.iconset` and a 1024 px preview in the current directory. `iconutil` packs that iconset into `AppIcon.icns`. `build.sh` runs those steps for you when `Resources/AppIcon.icns` is absent.

## License

MIT. See [LICENSE](LICENSE).
