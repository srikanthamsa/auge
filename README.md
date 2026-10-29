# See

Native macOS prototype for a glanceable personal information layer.

## Build

Requires macOS 14+ and a Swift toolchain with the macOS SDK. From this directory:

```sh
swift build
swift run See
```

The app launches into a full-screen dimmed workspace with a soft fade. Website surfaces show the page without browser chrome. Use **Add** to open a URL or add a Clock, Calendar, or Quick Note. Hover near the bottom center to reveal the move bar; hover at the bottom-right corner to reveal the rounded resize grip. Press Escape to dismiss See, and click its menu bar eye to reopen it.

## Widget configuration

Right-click any website widget for **Configure Widget…**:

- **Auto Refresh** — Off, 15s, 30s, 1m, 5m, 15m per widget
- **Remember Scroll Position** — restores the page's scroll offset on reload and relaunch
- **User Agent** — Chrome (macOS), Safari (macOS), iPhone, iPad (device layouts)
- **Hide page elements** — *Select on page…* turns the page into a picker: click any element to hide it, with a selector list, per-item remove, and Clear all
- **Dark mode (experimental)** — forces a dark color scheme on the page

The same menu can reload the page, open it in your browser, or remove the widget.

## Persistent workspace

Websites, native widgets, their positions, sizes, background style, scroll offsets, and every per-widget setting are stored in
`~/Library/Application Support/See/workspace.json` and restored on launch.

See `PRODUCT.md` for the product direction and MVP milestones.
