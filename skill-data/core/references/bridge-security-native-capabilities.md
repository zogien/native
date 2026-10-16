# Bridge, Security, and Native Capabilities

Use this when adding JavaScript-to-Zig calls, builtin commands, permissions, windows, child WebViews, dialogs, navigation policies, or external links.

## Bridge architecture

JavaScript calls native Zig through:

```javascript
const result = await window.zero.invoke("native.ping", { source: "webview" });
```

The runtime:

1. Parses the JSON request.
2. Enforces message size limits.
3. Checks origin and permissions.
4. Looks up a registered handler.
5. Runs the handler and returns a JSON response.

Bridge commands are default-deny. A command must be registered in Zig and allowed by policy.

## Handler pattern

```zig
fn ping(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self: *App = @ptrCast(@alignCast(context));
    self.ping_count += 1;
    return std.fmt.bufPrint(output, "{{\"message\":\"pong\",\"count\":{d}}}", .{self.ping_count});
}
```

Dispatcher pattern:

```zig
fn bridge(self: *App) native_sdk.BridgeDispatcher {
    self.handlers = .{.{ .name = "native.ping", .context = self, .invoke_fn = ping }};
    return .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &self.handlers },
    };
}
```

When returning user-controlled strings, escape them:

```zig
return native_sdk.bridge.writeJsonStringValue(output, user_name);
```

## Size limits

- Request message: 16 KiB.
- Response: 16 KiB.
- Handler result: 12 KiB.
- Request ID: 64 bytes.
- Command name: 128 bytes.

For large data, do not force everything through one bridge response. Use native files/resources or chunking patterns.

## Security policy

Core defaults:

- No permissions granted unless listed.
- Bridge commands denied unless policy allows them.
- Navigation blocked unless origin is allowlisted.
- External links denied unless configured.
- Dialog builtin commands always denied unless explicitly listed in `builtin_bridge`.

Manifest examples:

```zig
.permissions = .{ "window" },
.capabilities = .{ "webview", "js_bridge" },
.bridge = .{
    .commands = .{
        .{ .name = "native.ping", .origins = .{ "zero://app" } },
    },
},
.security = .{
    .navigation = .{
        .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
        .external_links = .{ .action = "deny" },
    },
},
```

Prefer exact origins over `"*"`. Use `"*"` only for commands that expose no native state and only when the project already accepts that risk.

## Builtin commands

The Native SDK includes builtin bridge commands for windows, layered WebViews, and dialogs. These are controlled separately from app-defined commands via `builtin_bridge`.

Window commands:

- `native-sdk.window.list`
- `native-sdk.window.create`
- `native-sdk.window.focus`
- `native-sdk.window.close`

Layered WebView commands:

- `native-sdk.webview.create`
- `native-sdk.webview.list`
- `native-sdk.webview.setFrame`
- `native-sdk.webview.navigate`
- `native-sdk.webview.setZoom`
- `native-sdk.webview.setLayer`
- `native-sdk.webview.close`

Dialog commands:

- `native-sdk.dialog.openFile`
- `native-sdk.dialog.saveFile`
- `native-sdk.dialog.showMessage`

Enable explicitly:

```zig
const app_permissions = [_][]const u8{native_sdk.security.permission_window};

.security = .{
    .permissions = &app_permissions,
    .navigation = .{ .allowed_origins = &.{ "zero://app" } },
},
.builtin_bridge = .{
    .enabled = true,
    .commands = &.{
        .{ .name = "native-sdk.window.create", .permissions = .{ "window" }, .origins = .{ "zero://app" } },
        .{ .name = "native-sdk.webview.create", .permissions = .{ "window" }, .origins = .{ "zero://app" } },
        .{ .name = "native-sdk.dialog.openFile", .origins = .{ "zero://app" } },
    },
},
```

`js_window_api = true` exposes `window.zero.windows.*` and `window.zero.webviews.*`, but it does not bypass origin or permission checks.

## Windows from JavaScript

```javascript
const win = await window.zero.windows.create({
  label: "tools",
  title: "Tools",
  width: 420,
  height: 320,
});

const all = await window.zero.windows.list();
await window.zero.windows.focus(win.id);
await window.zero.windows.close(win.id);
```

Window state persistence uses stable labels. Use meaningful labels like `main`, `settings`, `tools`, or `preview`.

## Layered WebViews

Child WebViews are native WebViews layered inside a native window:

```javascript
const preview = await window.zero.webviews.create({
  label: "preview",
  url: "https://example.com",
  frame: { x: 24, y: 24, width: 480, height: 320 },
  layer: 10,
  bridge: false,
});

await preview.setZoom(1.25);
await preview.setLayer(20);
await preview.close();
```

Rules:

- WebView URLs must pass navigation policy.
- Commands target only the calling native window.
- `main` is reserved for the startup WebView.
- Child WebViews receive `window.zero` only with `bridge: true`.
- Backend gaps should reject with `invalid_request`.

## Dialogs

Dialogs require explicit `builtin_bridge` policy.

```javascript
const files = await window.zero.invoke("native-sdk.dialog.openFile", {
  title: "Select a file",
  defaultPath: "/home",
  allowMultiple: true,
  allowDirectories: false,
});

const path = await window.zero.invoke("native-sdk.dialog.saveFile", {
  title: "Save as",
  defaultName: "untitled.txt",
});

const result = await window.zero.invoke("native-sdk.dialog.showMessage", {
  style: "warning",
  title: "Confirm",
  message: "Delete this item?",
  primaryButton: "Delete",
  secondaryButton: "Cancel",
});
```

Use native dialogs for trusted app UI. Do not expose arbitrary filesystem access to remote or untrusted origins.

## Error handling

JavaScript bridge calls reject with `error.code`:

- `invalid_request`: malformed input, unsupported operation, denied navigation URL, missing target, duplicate/reserved label.
- `unknown_command`: no registered handler.
- `permission_denied`: origin or permission failed.
- `handler_failed`: handler returned an error.
- `payload_too_large`: request too large.
- `internal_error`: unexpected runtime failure.

Always handle errors in frontend code:

```javascript
try {
  await window.zero.invoke("native.save", payload);
} catch (error) {
  console.error(error.code, error.message);
}
```


## WebView window dragging

Set `window_drag_regions = true` on a window for its main WebView, or independently on a child `WebViewOptions` / `ViewOptions`. JSON manifests use the same boolean key. Mark regions with `data-native-window-drag` and interactive subtrees with `data-native-window-drag-exclude`. Main shell views use the window declaration; other native view kinds reject the flag. Existing navigation policy still applies, and no application Bridge is required. The SDK owns native input and system window movement; do not pass native handles, synthesize mouse-down events or implement dragging by setting window positions. Regions reserve pointer behavior for the window manager, so do not attach application pointer interactions to their backgrounds. See the windows documentation and `examples/window-drag` for the complete contract and acceptance matrix.
