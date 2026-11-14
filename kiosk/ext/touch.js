// Touch tuning that CSS cannot do.
(function () {
  "use strict";
  function editable(el) {
    return el && el.closest && el.closest('input, textarea, [contenteditable=""], [contenteditable="true"]');
  }
  // Long-press on a touch screen opens Chromium's context menu: not wanted on a kiosk (fields keep theirs).
  document.addEventListener("contextmenu", function (e) { if (!editable(e.target)) e.preventDefault(); }, true);
  // Drags that start on an image or link must scroll the page, not start a drag-and-drop.
  document.addEventListener("dragstart", function (e) { if (!editable(e.target)) e.preventDefault(); }, true);

  // v7.8: no mouse arrow on the screen. It is hidden from the start and stays hidden while nobody uses a mouse;
  // a real mouse moving shows it, and it goes again after IDLE_MS without movement. A finger on a touch screen
  // (pointerType "touch" or "pen", and the compatibility mouse events a tap makes) never shows it, so a hall
  // display with a touch panel never has an arrow in the middle of the picture, and a box someone plugs a mouse
  // into still works. The style is a constructed stylesheet (CSSOM): a page's Content-Security-Policy cannot block it.
  var IDLE_MS = 2500, hideTimer = null, sheet = null;
  function setHidden(hide) {
    try {
      if (!sheet) {
        sheet = new CSSStyleSheet();
        document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
      }
      sheet.replaceSync(hide ? "html, html * { cursor: none !important; }" : "");
    } catch (_) { /* a page without constructed stylesheets keeps its arrow */ }
  }
  setHidden(true);
  window.addEventListener("pointermove", function (e) {
    if (e.pointerType !== "mouse") return;
    setHidden(false);
    clearTimeout(hideTimer);
    hideTimer = setTimeout(function () { setHidden(true); }, IDLE_MS);
  }, true);
  // (a tap on a touch screen also fires mouse-type compatibility events in some builds: they carry no pointermove
  // of type "mouse", so they do not get here.)
  window.addEventListener("pointerdown", function (e) {
    if (e.pointerType === "mouse") return;
    clearTimeout(hideTimer);
    setHidden(true);
  }, true);
})();
