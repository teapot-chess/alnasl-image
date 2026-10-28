// A small translucent button in the bottom-right corner of Alnasl on the kiosk
// screen. A tap opens the box's menu (served on 127.0.0.1:4041). It lives in a
// closed shadow root so Alnasl's own styles cannot touch it and it cannot touch
// Alnasl. With only a keyboard: F10 opens the menu from anywhere in Alnasl, and Tab reaches the
// button too (last on the page), with a ring you can actually see.
(function () {
  if (document.getElementById("alnasl-kiosk-menu")) return;
  var host = document.createElement("div");
  host.id = "alnasl-kiosk-menu";
  host.style.cssText = "position:fixed;right:10px;bottom:10px;z-index:2147483647;width:0;height:0";
  var root = host.attachShadow({ mode: "closed" });
  var b = document.createElement("button");
  b.setAttribute("aria-label", "Menu");
  b.textContent = "☰";
  b.style.cssText = "position:absolute;right:0;bottom:0;width:52px;height:52px;border-radius:26px;border:1px solid #ffffff55;" +
    "background:#0f1419b0;color:#fff;font:26px/1 sans-serif;opacity:.45;cursor:pointer;padding:0;touch-action:manipulation";
  b.addEventListener("pointerenter", function () { b.style.opacity = "1"; });
  b.addEventListener("pointerleave", function () { b.style.opacity = ".45"; });
  b.addEventListener("focus", function () { b.style.opacity = "1"; b.style.outline = "3px solid #4aa3ff"; b.style.outlineOffset = "3px"; });
  b.addEventListener("blur", function () { b.style.opacity = ".45"; b.style.outline = "none"; });
  function open() { location.href = "http://localhost:4041/menu"; }
  b.addEventListener("click", open);
  window.addEventListener("keydown", function (e) {
    if (e.key === "F10" && !e.ctrlKey && !e.altKey && !e.metaKey) { e.preventDefault(); open(); }
  }, true);
  root.appendChild(b);
  document.documentElement.appendChild(host);
})();
