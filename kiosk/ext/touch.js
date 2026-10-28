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
})();
