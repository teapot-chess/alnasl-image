// v6 boot screen, last step: the page that follows the boot screen (/boot, /screen on the box's menu
// server) starts on the very picture that screen showed and fades in from it. The boot screen names
// its picture in window.name, which survives the navigation (same site) and nothing else uses here.
(function () {
  var n = window.name || "";
  if (n.indexOf("alnasl-fade:") !== 0) return;
  window.name = "";
  var img = n.slice("alnasl-fade:".length);
  if (!/^\/splash\/[a-z0-9\/._-]+\.png$/.test(img) || img.indexOf("..") >= 0) img = "/splash/alnasl-splash.png";
  var d = document.createElement("div");
  d.id = "alnasl-boot-fade";
  d.style.cssText = "position:fixed;inset:0;z-index:2147483647;pointer-events:none;opacity:1;" +
    "background:#16171a url(http://localhost:4041" + img + ") center/auto 100vh no-repeat;transition:opacity .7s ease";
  document.documentElement.appendChild(d);
  var gone = false;
  function fade() {
    if (gone) return;
    gone = true;
    // Two frames: the page has really painted underneath before the picture lets go of it.
    requestAnimationFrame(function () { requestAnimationFrame(function () {
      d.style.opacity = "0";
      setTimeout(function () { d.remove(); }, 900);
    }); });
  }
  if (document.readyState === "complete") fade(); else window.addEventListener("load", fade, { once: true });
  setTimeout(fade, 15000);  // a page that never finishes loading does not keep the picture up
})();
