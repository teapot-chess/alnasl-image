// v7.5 (docs/nunki-displays.md): "Identify screens" in the screen wizard. For eight seconds every window on the
// HDMI outputs shows a big number and what that output is for, so whoever stands in the hall can tell which
// cable is which. The kiosk writes where each window is (/run/alnasl-kiosk/outputs), the menu server hands that
// over (through the service worker: the menu server sends no CORS headers), and the window that sits at an
// output's position draws that output's number. The touch panel is its own X screen and is not numbered.
(function () {
  if (window.top !== window) return;
  var shown = null;
  function isPanel() {
    try { return localStorage.getItem("alnasl-where") === "panel"; } catch (e) { return false; }
  }
  function draw(label, sub) {
    if (shown) shown.remove();
    var host = document.createElement("div");
    host.style.cssText = "position:fixed;inset:0;z-index:2147483647;pointer-events:none";
    var root = host.attachShadow({ mode: "closed" });
    var box = document.createElement("div");
    box.style.cssText = "position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;" +
      "background:#0f1419d0;color:#fff;font:700 38vh/1 sans-serif;text-shadow:0 0 4vh #4aa3ff";
    box.textContent = label;
    var s = document.createElement("div");
    s.style.cssText = "font:500 5vh/1.3 sans-serif;margin-top:3vh;text-shadow:none";
    s.textContent = sub;
    box.appendChild(s);
    root.appendChild(box);
    document.documentElement.appendChild(host);
    shown = host;
  }
  function check() {
    try {
      chrome.runtime.sendMessage({ type: "identify" }, function (r) {
        if (chrome.runtime.lastError || !r || !r.active || isPanel()) { if (shown) { shown.remove(); shown = null; } return; }
        var x = window.screenX + 2, y = window.screenY + 2, hit = [];
        (r.outputs || []).forEach(function (o) {
          if (x >= o.x && x < o.x + o.w && y >= o.y && y < o.y + o.h) hit.push(o);
          // mirror: both outputs show this one window
          else if (o.job === "mirror") hit.push(o);
        });
        if (!hit.length) hit = [{ n: 1, what: r.single || "" }];
        draw(hit.map(function (o) { return o.n; }).join(" + "), hit.map(function (o) { return o.what; }).filter(Boolean)[0] || "");
      });
    } catch (e) { /* the extension was reloaded; the next page load starts a fresh watcher */ }
  }
  setInterval(check, 1500);
})();
