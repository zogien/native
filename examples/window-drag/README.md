# Window drag contract example

A standalone SDK integration fixture using the lower-level Zig/WebView shell.

```sh
zig build run
```

Run from this directory. The main and secondary windows enable `window_drag_regions`; the upper child WebView opts in separately; the lower child keeps the default disabled setting. No application JavaScript Bridge is required.

Check real pointer movement on the header, content handle and child header; double-click behavior and platform preferences; buttons and text selection inside exclusions; dynamic mount/removal; reload; maximize then drag; secondary-window ownership; mixed-DPI and negative-coordinate monitors. Repeat with the system engine on Windows, macOS and Linux (X11/Wayland), and with `-Dweb-engine=chromium` on macOS.

Native drag regions reserve their pointer behavior for the window manager. Put interactive content in `data-native-window-drag-exclude` subtrees. Automated DOM tests and a successful build do not replace this platform acceptance matrix.

## Windows acceptance

From the repository root, build the fixture and run its native input harness:

```powershell
Push-Location examples/window-drag
zig build
Pop-Location
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-window-drag-windows.ps1
```

The harness temporarily foregrounds only its own fixture, sends real mouse input, checks native window geometry and accessible control state, stops further clicks/motion if foreground ownership changes, and releases its own outstanding press. It keeps each attempt under `.zig-cache/window-drag-windows/runs/`, copies a successful run to `.zig-cache/window-drag-windows/results.json`, and cleans up its process.

On 2026-10-16, Windows 10 Enterprise build 19045 passed all 12 assertions: main header drag, child ownership, native double-click maximize, excluded button activation, excluded input drag, ordinary content staying stationary, child opt-in isolation, dynamic mount/removal, reload, maximized drag restore, and the owning window's native system menu. The main page uses strict self-only script/style CSP and no `js_bridge` capability. This run used a 100% scale display; mixed-DPI/negative-coordinate monitor configurations remain unverified.

The Windows host link, 23 focused Zig regressions, 11 JavaScript regressions, and documentation check also pass. The broad repository fast gate was attempted on Windows and remains red. The unchanged base commit `edd5e027e728f05d1e6695c3df07e28b617bf2c1` reproduces 56 runtime-core crashes and one UI-shell crash from stack overflow. Other broad-gate failures include Windows path-separator assertions and unavailable optional toolchains. No gate or policy baseline was weakened. Per the requested scope, macOS and Linux runtime acceptance are deferred.

## Review hardening

The WKWebView/WebKitGTK adapter now answers DOM hit tests from a native press location instead of comparing timestamps from unrelated clocks. Only the native host retains the original event, with a one-use sequence and a 250ms monotonic expiry. Release/cancellation, navigation, ownership loss, geometry and zoom changes reject late replies. These backend source changes still await macOS/Linux acceptance.

Repository text uses LF through `.gitattributes` and `.editorconfig`; the vendored WebView2 header preserves upstream bytes. Five focused regressions exercise the production Windows input functions, including focus loss before a press and during a drag.

The hardening rerun passes 23 Zig tests, 11 adapter tests and five input-ownership cases on Windows. A fresh real-input run could not acquire foreground ownership and aborted before sending mouse input; the earlier 12-case success record remains separate. macOS/Linux execution remains deferred.
