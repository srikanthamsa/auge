# Auge — product brief

Auge is a fast, personal information layer for macOS. A press-and-hold shortcut should show a calm, configurable workspace over the current task; releasing the shortcut or pressing Escape returns to the previous app.

## Product principles

- Useful in a glance; no sprawling dashboard by default.
- Private by default: local-first data and explicit permission requests.
- Cards are modular, reorderable, and individually refreshable.
- Keyboard-first, with a visible menu bar fallback.
- Auge adds actions and capture to Peek’s glanceable information model.

## v1 direction: Better Peek

Initial direction: an immersive overlay with multiple live website surfaces that users can freely move and resize. The current implementation includes those website surfaces; calendar, reminders, quick capture, and local file widgets remain later work. The initial website uses a public demo page.

## Proposed differentiators

1. **Context stacks:** save different card arrangements for Focus, Planning, and Personal contexts.
2. **Quick Capture:** jot a note or save the current link from the overlay, then find it later.
3. **Actions in cards:** complete a reminder, open a link/file, or copy an item without leaving the overlay.
4. **Privacy controls:** per-card data sources, refresh intervals, and permission status.
5. **Responsive layouts:** compact glance and expanded workspace, with keyboard navigation.

## MVP acceptance

- Launching See opens a full-screen dimmed workspace.
- A menu bar entry can reopen the workspace after dismissal.
- Escape and the close control dismiss it.
- Users can add, move, resize, navigate, reload, and close live website surfaces.
- Website URLs and freeform positions currently reset when See restarts.

## Follow-up milestones

- Add configurable press-and-hold shortcut and conflict handling.
- Add persisted card layout, context stacks, and capture storage.
- Add opt-in EventKit calendar/reminder access and local PDF/file cards.
- Add web cards with navigation restrictions and per-card refresh.
- Validate overlay behavior, accessibility, and permission-denied states.

## Reverse-engineering basis

See’s starting point is informed by static inspection of Peek 1.0.5. Findings and limitations are in `../Agents/agent-cab0ba77-a256-43af-b802-d0ddd645dc3e/peek-reverse-engineering.md`. That inspection did not establish Peek’s exact shortcut, overlay behavior, storage, or enabled widget inventory; See’s details above are design decisions, not claims about Peek internals.

Live behavior observed after the prototype was started is recorded in `PEEK-LIVE-OBSERVATIONS.md`. It confirms the dimmed desktop, centered live website surface, Freeform layout setting, and the displayed preference values. The selected “Single tap” trigger-mode label remains unexplained alongside the observed Fn hold.
