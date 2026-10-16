import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { embed } from "./embed-window-drag.mjs";
const source = await readFile(new URL("../src/platform/webview_window_drag.js", import.meta.url), "utf8");
function documentHarness(nativeRegions = false, subframe = false) {
  const listeners = new Map();
  const windowListeners = new Map();
  const styles = [];
  let target = null;
  class Element {
    constructor(attrs = [], parentElement = null, tagName = "DIV") {
      this.attrs = new Set(attrs); this.parentElement = parentElement; this.tagName = tagName;
    }
    hasAttribute(name) { return this.attrs.has(name); }
  }
  class CSSStyleSheet { replaceSync(text) { this.textContent = text; } }
  const document = {
    get adoptedStyleSheets() { return styles; },
    set adoptedStyleSheets(value) { styles.splice(0, styles.length, ...value); },
    elementFromPoint(x, y) { return x === 20 && y === 12 ? target : null; },
    addEventListener(name, callback) { listeners.set(name, callback); },
  };
  const window = { addEventListener(name, callback) { windowListeners.set(name, callback); } };
  window.top = subframe ? {} : window;
  vm.runInNewContext(`${source}(${nativeRegions});`, {window, document, Element, CSSStyleSheet});
  return {
    Element, window, styles,
    hit(element) { target = element; },
    event(path, options = {}) {
      let prevented = false;
      listeners.get("mousedown")?.({isTrusted: true, button: 0, composedPath: () => path,
        preventDefault: () => { prevented = true; }, ...options});
      return prevented;
    },
    probe: (x = 20, y = 12) => window.__nativeSdkWindowDragProbe(x, y),
    hide: () => windowListeners.get("pagehide")?.(),
    show: () => windowListeners.get("pageshow")?.(),
  };
}
test("the checked-in native header is generated from the tested LF source", async () => {
  assert.equal(source.includes("\r"), false);
  assert.equal(await readFile(new URL("../src/platform/webview_window_drag.h", import.meta.url), "utf8"), embed(source));
});
test("native-region engines install declarations without a DOM gesture path", () => {
  const h = documentHarness(true);
  assert.equal(h.styles.length, 1);
  assert.equal(h.window.__nativeSdkWindowDragProbe, undefined);
  assert.match(h.styles[0].textContent, /iframe/);
});
test("subframes do not inherit window gesture authority", () => {
  for (const nativeRegions of [false, true]) {
    const h = documentHarness(nativeRegions, true);
    assert.equal(h.styles.length, 0);
    assert.equal(h.window.__nativeSdkWindowDragProbe, undefined);
  }
});
test("a native-location probe resolves declarations through ordinary descendants", () => {
  const h = documentHarness();
  h.hit(new h.Element([], new h.Element(["data-native-window-drag"])));
  assert.equal(h.probe(), true);
});
test("exclusion ancestors dominate even nested drag declarations", () => {
  const h = documentHarness();
  const excluded = new h.Element(["data-native-window-drag-exclude"], new h.Element(["data-native-window-drag"]));
  h.hit(new h.Element(["data-native-window-drag"], excluded));
  assert.equal(h.probe(), false);
});
test("an iframe hit does not acquire the containing drag region's authority", () => {
  const h = documentHarness();
  h.hit(new h.Element([], new h.Element(["data-native-window-drag"]), "IFRAME"));
  assert.equal(h.probe(), false);
});
test("probes need neither DOM event delivery nor a shared clock", () => {
  const h = documentHarness();
  h.hit(new h.Element(["data-native-window-drag"]));
  // No performance/Date clock or DOM press exists in this harness.
  assert.equal(h.probe(), true);
});
test("current hit-testing reflects region removal and newly excluded content", () => {
  const h = documentHarness();
  const target = new h.Element(["data-native-window-drag"]);
  h.hit(target);
  assert.equal(h.probe(), true);
  target.attrs.clear();
  assert.equal(h.probe(), false);
  target.attrs.add("data-native-window-drag");
  target.attrs.add("data-native-window-drag-exclude");
  assert.equal(h.probe(), false);
});
test("only trusted primary DOM presses suppress content default behavior", () => {
  const h = documentHarness();
  const target = new h.Element(["data-native-window-drag"]);
  assert.equal(h.event([target]), true);
  assert.equal(h.event([target], {isTrusted: false}), false);
  assert.equal(h.event([target], {button: 2}), false);
  assert.equal(h.event([new h.Element(["data-native-window-drag-exclude"], target), target]), false);
});
test("probes reject absent, out-of-viewport and nonfinite locations", () => {
  const h = documentHarness();
  assert.equal(h.probe(), false);
  h.hit(new h.Element(["data-native-window-drag"]));
  for (const [x,y] of [[21,12],[-1,12],[20,-1],[NaN,12],[20,Infinity]]) assert.equal(h.probe(x,y), false);
});
test("pagehide revokes queries and pageshow permits back-forward-cache restoration", () => {
  const h = documentHarness();
  h.hit(new h.Element(["data-native-window-drag"]));
  assert.equal(h.probe(), true);
  h.hide(); assert.equal(h.probe(), false);
  h.show(); assert.equal(h.probe(), true);
  h.hide(); assert.equal(h.probe(), false);
});
