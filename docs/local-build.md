# Building and running Hop locally

How to build this fork, run it as your everyday Hop, and use the screenshot
changes on the `screenshot-frozen-frame` branch.

## 1. One-time setup: the toolchain

Hop needs a full Xcode, not just the Command Line Tools. Without it the build
fails early with *"Unknown error parsing property list"* or
*"plugin for module 'SwiftUIMacros' not found"*.

```bash
xcode-select -p
# should print /Applications/Xcode.app/Contents/Developer

# if it prints /Library/Developer/CommandLineTools:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
rm -rf .build
```

To try Xcode for one command without switching:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`.

If the default build system still fails, use the older one:
`swift build --build-system native`.

## 2. Build and install

```bash
git switch screenshot-frozen-frame     # or main, once merged
./scripts/build-app.sh --install --dev
```

This makes a quick debug build, installs it as **`/Applications/Hop Dev.app`**
and launches it. Hop Dev has its own bundle id, settings and permissions, so an
official Hop install is left alone. Without a Developer ID certificate it is
signed ad hoc, which is fine on your own Mac.

Hop lives in the **menu bar**, not the Dock. If it did not start:

```bash
open "/Applications/Hop Dev.app"
```

## 3. First launch: permissions

The first screenshot asks for **Screen Recording**. Allow Hop Dev in
System Settings → Privacy & Security → Screen Recording, then quit and reopen
it. Because the build is signed ad hoc, macOS may ask again after a rebuild.

## 4. Make it your default Hop

1. Quit the official Hop if it is running.
2. In Hop Dev's settings, turn on **launch at login**.
3. Optionally remove the official `Hop.app` from System Settings → General →
   Login Items.

Hop Dev never auto-updates, so a release cannot overwrite your changes.

Replacing `/Applications/Hop.app` itself is possible, but not recommended:
`HOP_ALLOW_PROD=1 ./scripts/build-app.sh --install --prod` runs a ~25-minute
universal release build, and you must turn auto-update off first
(`defaults write com.antonshakirov.minimo autoUpdateEnabled -bool false`) or
the next official release replaces it.

## 5. Updating after a change

```bash
git pull                               # or edit / switch branches
./scripts/build-app.sh --install --dev
```

The script quits the running Hop Dev, installs the new build and relaunches it.

## 6. Using the screenshot module

**Taking a shot**

| How | What it does |
| --- | --- |
| ⌃⌥S, or *area* in the panel | Freezes every screen, then you drag the area |
| *window* in the panel | Captures the window under the pointer |
| *screen* in the panel | Captures the whole display |

Window, screen and "repeat last area" have no hotkey by default; set them in
Hop's hotkeys settings.

**While framing an area** the screen is frozen, so menus, tooltips and hover
states that vanish on a click are still in the picture:

- drag to choose the area
- **space**: the window under the pointer
- **r**: the last rectangle again
- **esc**: cancel

The delay setting (3, 5, 10 s) counts down *before* the screen freezes, so you
can open a menu first.

**After the shot**

- The picture is **already on the clipboard**, so you can paste it right away.
- The editor opens for marking up: arrows, text, blur, crop and so on.
- **⌘C** or the copy button copies the marked-up picture and closes the
  window. While typing in the file name or a caption, ⌘C copies the text.
- **Save** writes the file to the Desktop (or the folder set in settings) and
  closes the window.
- **Esc** closes the window. If it has marks you have not copied or saved, it
  asks first. While choosing a crop, esc cancels the crop.
