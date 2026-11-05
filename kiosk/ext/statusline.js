// v7.8: a one-line status at the bottom of the box's own app: "Slot A  |  192.168.1.20  |  v7.4.2". It does not
// cover the app: the page is made as much shorter as the line is high (html gets that much less height, and a
// transform on it makes it the containing block of the page's position:fixed parts, so a bottom bar or a
// toast of the app sits above the line, not under it). The line lives in a closed shadow root and is styled
// through the CSSOM, like the menu button, so the app cannot touch it and it cannot touch the app.
// No line on a small screen (an SPI panel is 320 px high: every pixel is the app's).
(function () {
  "use strict";
  if (window.top !== window) return;
  if (document.getElementById("alnasl-kiosk-status")) return;
  var H = 22, MIN_SCREEN_H = 400, REFRESH_MS = 30000;
  if (Math.min(screen.height, screen.width) < MIN_SCREEN_H) return;

  var host = document.createElement("div");
  host.id = "alnasl-kiosk-status";
  host.style.cssText = "all:initial;position:fixed;left:0;right:0;bottom:0;height:" + H + "px;z-index:2147483646;display:block;pointer-events:none";
  var root = host.attachShadow({ mode: "closed" });
  var line = document.createElement("div");
  line.style.cssText = "box-sizing:border-box;height:" + H + "px;width:100%;display:flex;align-items:center;justify-content:flex-end;gap:14px;" +
    "padding:0 14px;background:#0f1419;border-top:1px solid #2b3745;color:#9fb0c3;" +
    "font:500 13px/1 'DejaVu Sans',system-ui,sans-serif;white-space:nowrap;overflow:hidden";
  root.appendChild(line);

  function put(parts) {
    line.replaceChildren();
    parts.forEach(function (t, i) {
      if (i) { var d = document.createElement("span"); d.textContent = "|"; d.style.opacity = ".4"; line.appendChild(d); }
      var s = document.createElement("span"); s.textContent = t; line.appendChild(s);
    });
  }
  put(["Alnasl"]);

  function refresh() {
    try {
      chrome.runtime.sendMessage({ type: "statusline" }, function (s) {
        if (chrome.runtime.lastError || !s) return;
        var p = [];
        if (s.slot) p.push("Slot " + s.slot);
        p.push(s.ip || "no network");
        if (s.version) p.push("v" + s.version);
        put(p);
      });
    } catch (e) { /* the extension was reloaded; the next page load starts a fresh line */ }
  }

  // Make room: the page ends where the line begins.
  try {
    var sheet = new CSSStyleSheet();
    sheet.replaceSync("html { height: calc(100vh - " + H + "px) !important; overflow: auto !important; transform: translateZ(0); }");
    document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
  } catch (_) { return; }   // no constructed stylesheets: no line, rather than a line over the app

  function mount() { if (!host.isConnected) document.documentElement.appendChild(host); }
  mount();
  refresh();
  setInterval(refresh, REFRESH_MS);
})();
