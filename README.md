# See

Native macOS prototype for a glanceable personal information layer.

## Build

Requires macOS 14+ and a Swift toolchain with the macOS SDK. From this directory:

```sh
swift build
swift run See
```

The prototype launches into a full-screen dimmed workspace with a soft fade. Website surfaces show the page without browser chrome. Use **Add** to open a URL or add a Clock, Calendar, or Quick Note. Hover near the bottom center to reveal the move bar; hover at the bottom-right corner to reveal the rounded resize grip. Website address entry appears inside the See overlay. Press Escape to dismiss See, and click its menu bar eye to reopen it. The first website loads `https://www.are.na`. Website URLs, notes, and surface positions currently reset when See restarts.

See `PRODUCT.md` for the product direction and MVP milestones.
