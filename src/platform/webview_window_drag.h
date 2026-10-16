/* Generated from webview_window_drag.js by scripts/embed-window-drag.mjs. */
#ifndef NATIVE_SDK_WEBVIEW_WINDOW_DRAG_H
#define NATIVE_SDK_WEBVIEW_WINDOW_DRAG_H
#define NATIVE_SDK_WINDOW_DRAG_SOURCE \
"/* Native SDK declaration adapter. Native hosts initiate each input probe. */\n" \
"(function (nativeRegions) {\n" \
"  \"use strict\";\n" \
"  if (window.top !== window) return;\n" \
"  const drag = \"data-native-window-drag\";\n" \
"  const exclude = \"data-native-window-drag-exclude\";\n" \
"  if (nativeRegions) {\n" \
"    // Constructed sheets are script-owned, so strict style-src does not block\n" \
"    // the SDK declaration adapter or require unsafe-inline in application CSP.\n" \
"    const style = new CSSStyleSheet();\n" \
"    style.replaceSync(`[${drag}] { app-region: drag; -webkit-app-region: drag; user-select: none; -webkit-user-select: none; }\n" \
"[${exclude}], [${exclude}] *, [${drag}] iframe { app-region: no-drag; -webkit-app-region: no-drag; }`);\n" \
"    document.adoptedStyleSheets = [...document.adoptedStyleSheets, style];\n" \
"    return;\n" \
"  }\n" \
"  // Only a host holding the original native press can initiate window movement.\n" \
"  // DOM hit-testing answers the declaration question, never grants an input token.\n" \
"  let active = true;\n" \
"  function targetIsDrag(path) {\n" \
"    let found = false;\n" \
"    for (const node of path) {\n" \
"      if (!(node instanceof Element)) continue;\n" \
"      if (node.hasAttribute(exclude) || node.tagName === \"IFRAME\") return false;\n" \
"      if (node.hasAttribute(drag)) found = true;\n" \
"    }\n" \
"    return found;\n" \
"  }\n" \
"  const probe = (x, y) => {\n" \
"    if (!active || ![x, y].every(Number.isFinite) || x < 0 || y < 0) return false;\n" \
"    const path = [];\n" \
"    for (let node = document.elementFromPoint(x, y); node; node = node.parentElement) path.push(node);\n" \
"    return targetIsDrag(path);\n" \
"  };\n" \
"  Object.defineProperty(window, \"__nativeSdkWindowDragProbe\", {value: probe});\n" \
"  document.addEventListener(\"mousedown\", event => {\n" \
"    if (active && event.isTrusted && event.button === 0 && targetIsDrag(event.composedPath())) event.preventDefault();\n" \
"  }, true);\n" \
"  window.addEventListener(\"pagehide\", () => { active = false; });\n" \
"  window.addEventListener(\"pageshow\", () => { active = true; });\n" \
"})\n"
#endif
