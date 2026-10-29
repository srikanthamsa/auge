# Peek 1.0.5 — live observation

Observed on 29 Oct 2026 by opening the installed Peek app and asking the user to hold Fn. The app itself displays “Hold Fn to Peek.” The overlay appeared while Fn was held and disappeared after the user released it.

## What was visible

- Peek dims the whole desktop and places a tall, narrow, dark surface in the center.
- The surface showed a live X “For you” feed, including posts and video, in a real website view. The left navigation rail and feed tabs belonged to X inside that view; they were not Peek widget controls.
- This is substantially different from See’s first static card dashboard. Peek’s strong visual structure is the dimmed full-screen layer plus a focused live page.
- A hidden Peek preferences window was directly captured. Its General page showed:
  - Peek layout: **Freeform**
  - Trigger mode: **Single tap**
  - Sync widgets across displays: off
  - Pause media when hidden: on
  - Launch at login: on
  - Hide menu bar icon: off

The “Single tap” value and the observed Fn hold appear inconsistent; the exact meaning of that trigger-mode selector needs a follow-up UI check. The Advanced page and widget editing flow were not inspected.

## Design implications for See

- Build the immersive layer first: full-screen backdrop/dimming with a carefully sized content surface, not a dense dashboard of equal cards.
- Treat a website as a first-class live surface. Keep page controls and content inside its frame; support full real webpages, not just a small embedded preview.
- Make layouts freeform and provide an explicit trigger mode.
- Add display syncing, pause-when-hidden, launch-at-login, and menu-bar visibility as settings only after the base interaction and visuals are solid.
- Rework the first See dashboard before adding more sample cards. Keep sample data clearly separated from working features.

## Limits

The overlay was observed once with X open. No widget editing, multiple-widget layout, Advanced preferences, permission prompt, or other website was exercised. The overlay disappeared on key release, so further hands-on inspection requires another Fn hold.
