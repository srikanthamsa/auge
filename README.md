# See

Native macOS prototype for a glanceable personal information layer.

## Build

Requires macOS 14+ and a Swift toolchain with the macOS SDK. From this directory:

```sh
swift build
swift run See
```

The app launches into a full-screen dimmed workspace with a quick fade. Website surfaces show the page without browser chrome. Use **Add** to open a URL or add a Clock, Calendar, or Quick Note. Hover near the bottom center to reveal the move bar; hover at the bottom-right corner to reveal the rounded resize grip. Drag on empty space to open the Add picker for the rectangle you drew. Right-click the empty workspace for **Customize Background…** (ten palettes plus glow and dim sliders), Tidy Layout, Settings, or Remove All. Press Escape to close the topmost thing first — the picker, a menu, the background panel, or the website picker — and Escape again to dismiss See; click its menu bar eye to reopen it.

## Widget configuration

Right-click any website widget for **Configure Widget…**:

- **Auto Refresh** — Off, 15s, 30s, 1m, 5m, 15m per widget
- **Remember Scroll Position** — restores the page's scroll offset on reload and relaunch
- **User Agent** — Chrome (macOS), Safari (macOS), iPhone, iPad (device layouts)
- **Hide page elements** — *Select on page…* turns the page into a picker: click any element to hide it and keep going for the next one, with a selector list, per-item remove, and Clear all. Hiding and restoring both apply immediately, no reload.
- **Dark mode (experimental)** — asks the page for a dark color scheme and, for pages that hard-code white, inverts the body while keeping images and video true to color

The same menu can reload the page, open it in your browser, or remove the widget.

## Persistent workspace

Websites, native widgets, their positions, sizes, background style, scroll offsets, and every per-widget setting are stored in
`~/Library/Application Support/See/workspace.json` and restored on launch.

See `PRODUCT.md` for the product direction and MVP milestones.

## Apps

Adding an app from *Add → Apps* opens that app in its own window and puts See
away, because a live mirror of another app inside the peek was more confusing
than useful: menus, sheets and keyboard focus never behaved like the real app.
Websites and native widgets are the surfaces that live inside the workspace.

