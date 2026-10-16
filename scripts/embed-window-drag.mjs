import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
export function embed(source) {
  return "/* Generated from webview_window_drag.js by scripts/embed-window-drag.mjs. */\n#ifndef NATIVE_SDK_WEBVIEW_WINDOW_DRAG_H\n#define NATIVE_SDK_WEBVIEW_WINDOW_DRAG_H\n#define NATIVE_SDK_WINDOW_DRAG_SOURCE \\\n" + source.trimEnd().split("\n").map(line => JSON.stringify(line + "\n")).join(" \\\n") + "\n#endif\n";
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const source = await readFile(new URL("../src/platform/webview_window_drag.js", import.meta.url), "utf8");
  const header = new URL("../src/platform/webview_window_drag.h", import.meta.url);
  const generated = embed(source);
  if (process.argv.includes("--check")) {
    if (await readFile(header, "utf8") !== generated) throw new Error("stale window-drag header: run node scripts/embed-window-drag.mjs");
  } else await writeFile(header, generated);
}
