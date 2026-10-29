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

## App widgets (live app windows in the workspace)

Adding an app from *Add → Apps* no longer throws you out to the app's own
window. See launches the app, streams its window with ScreenCaptureKit and
draws it as a card inside the workspace:

- **Live** — the card is a real 30 fps mirror of the app window, not a still.
- **Interactive** — clicks, right-clicks, drags and scrolls on the card are
  forwarded to the owning process (`CGEvent.postToPid`), mapped through the
  mirrored window's frame, so you operate the app inside the peek.
- **Double-click** the card to bring the app itself forward.
- Right-click the card for *Refresh Mirror*, *Open App* and *Remove*.
- Drag the title strip to move it, the bottom-right corner to resize; size and
  position persist with the rest of the workspace.

ScreenCaptureKit needs the **Screen Recording** permission. The first time a
mirror starts, macOS asks for it (See also opens the right Settings pane). After
granting it, quit and reopen See — the card switches from *Screen Recording
needed* to the live app.
