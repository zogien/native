# Window controls

A Windows fixture for page-drawn title bars. Three chromeless windows draw Minimize, Maximize/Restore, and Close buttons in their WebViews; each button invokes an app command that calls `Runtime.minimizeWindow`, `maximizeWindow`, `unmaximizeWindow`, or `requestCloseWindow`.

- **main** is resizable and lists which window the user closed last.
- **palette** uses `close_policy = "hide"`: its Close hides it and keeps its page, and main's Show palette brings it back.
- **quitter** is not resizable, so its Maximize reports `WindowNotResizable`, and its Close really closes it.

Each page shows `Maximized: true|false` from the window list and the `window:state` event, so the button follows caption double-clicks and keyboard shortcuts as well as its own clicks.

On Windows a chromeless window hands its top frame to the page, so the harness also checks that the window still resizes from the top edge and both top corners, above the page's buttons too, and that a top-edge double-click maximizes it vertically.

Build it, then drive it with real input:

```bash
zig build
powershell -ExecutionPolicy Bypass -File ../../scripts/test-window-controls-windows.ps1
```
