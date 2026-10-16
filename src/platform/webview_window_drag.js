/* Native SDK declaration adapter. Native hosts initiate each input probe. */
(function (nativeRegions) {
  "use strict";
  if (window.top !== window) return;
  const drag = "data-native-window-drag";
  const exclude = "data-native-window-drag-exclude";
  if (nativeRegions) {
    // Constructed sheets are script-owned, so strict style-src does not block
    // the SDK declaration adapter or require unsafe-inline in application CSP.
    const style = new CSSStyleSheet();
    style.replaceSync(`[${drag}] { app-region: drag; -webkit-app-region: drag; user-select: none; -webkit-user-select: none; }
[${exclude}], [${exclude}] *, [${drag}] iframe { app-region: no-drag; -webkit-app-region: no-drag; }`);
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, style];
    return;
  }
  // Only a host holding the original native press can initiate window movement.
  // DOM hit-testing answers the declaration question, never grants an input token.
  let active = true;
  function targetIsDrag(path) {
    let found = false;
    for (const node of path) {
      if (!(node instanceof Element)) continue;
      if (node.hasAttribute(exclude) || node.tagName === "IFRAME") return false;
      if (node.hasAttribute(drag)) found = true;
    }
    return found;
  }
  const probe = (x, y) => {
    if (!active || ![x, y].every(Number.isFinite) || x < 0 || y < 0) return false;
    const path = [];
    for (let node = document.elementFromPoint(x, y); node; node = node.parentElement) path.push(node);
    return targetIsDrag(path);
  };
  Object.defineProperty(window, "__nativeSdkWindowDragProbe", {value: probe});
  document.addEventListener("mousedown", event => {
    if (active && event.isTrusted && event.button === 0 && targetIsDrag(event.composedPath())) event.preventDefault();
  }, true);
  window.addEventListener("pagehide", () => { active = false; });
  window.addEventListener("pageshow", () => { active = true; });
})
