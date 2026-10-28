// A fixed, clean bar at the top of every web page that is NOT Alnasl or the box's own pages (for example the
// GitHub release notes opened from Alnasl's Updates page). On a touch-only screen there is no address bar and
// no back button, so without this such a page is a dead end. "Back to Alnasl" returns to the page the visitor
// came from when that was Alnasl (history.back(), keeps its state), else loads http://localhost:4040/.
// "Menu" opens the box menu. The bar lives in a closed shadow root and is styled through the CSSOM only
// (a page's Content-Security-Policy cannot block that), so the page cannot touch it and it cannot touch the page.
(function () {
  "use strict";
  if (window.top !== window) return;
  var h = location.hostname;
  if (h === "localhost" || h === "127.0.0.1" || h === "[::1]" || h === "::1") return;   // Alnasl, the box's pages
  if (document.getElementById("alnasl-kiosk-bar")) return;

  var ALNASL = "http://localhost:4040/", MENU = "http://localhost:4041/menu", BAR = 56;
  var TEXT = {
    en: { back: "← Back to Alnasl", menu: "Menu" },
    nl: { back: "← Terug naar Alnasl", menu: "Menu" }
  };
  var lang = "en", moved = false;

  // A page that changes its own address (single-page sites) or loads a second page has left the entry Alnasl linked to.
  try {
    if (window.navigation && navigation.addEventListener) {
      navigation.addEventListener("navigate", function (e) { if (e.navigationType !== "reload") moved = true; });
    }
  } catch (_) { /* optional */ }

  function goBack() {
    var cameFromAlnasl = (document.referrer || "").indexOf("http://localhost:4040") === 0;
    if (cameFromAlnasl && !moved && history.length > 1) {
      history.back();
      // If that went nowhere (no entry to go back to), load Alnasl directly.
      setTimeout(function () { location.href = ALNASL; }, 1200);
    } else {
      location.href = ALNASL;
    }
  }

  var host = document.createElement("div");
  host.id = "alnasl-kiosk-bar";
  host.style.cssText = "all:initial;position:fixed;top:0;left:0;right:0;height:" + BAR + "px;z-index:2147483647;display:block";
  var root = host.attachShadow({ mode: "closed" });
  var bar = document.createElement("div");
  bar.style.cssText = "box-sizing:border-box;height:" + BAR + "px;width:100%;display:flex;align-items:center;gap:12px;padding:0 12px;" +
    "background:#0f1419;border-bottom:1px solid #2b3745;font:600 20px/1 'DejaVu Sans',system-ui,sans-serif;color:#eaf0f6";
  function button(primary) {
    var b = document.createElement("button");
    b.type = "button";
    b.style.cssText = "box-sizing:border-box;height:42px;padding:0 20px;border-radius:10px;border:1px solid " + (primary ? "#4aa3ff" : "#2b3745") +
      ";background:" + (primary ? "#2b78c9" : "#202a35") + ";color:#eaf0f6;font:inherit;cursor:pointer;touch-action:manipulation;margin:0";
    return b;
  }
  var back = button(true), menu = button(false), sp = document.createElement("div");
  sp.style.cssText = "flex:1";
  back.addEventListener("click", goBack);
  menu.addEventListener("click", function () { location.href = MENU; });
  bar.appendChild(back); bar.appendChild(sp); bar.appendChild(menu);
  root.appendChild(bar);

  function labels() { var t = TEXT[lang] || TEXT.en; back.textContent = t.back; menu.textContent = t.menu; }
  labels();
  try {
    chrome.runtime.sendMessage({ type: "osk-config" }, function (c) {
      if (chrome.runtime.lastError || !c) return;
      lang = c.lang === "nl" ? "nl" : "en";
      labels();
    });
  } catch (_) { /* the labels stay English */ }

  function attach() {
    var de = document.documentElement;
    if (!de) return;
    if (!host.isConnected) de.appendChild(host);
    // Make room: the page starts below the bar.
    de.style.setProperty("margin-top", BAR + "px", "important");
  }
  attach();
  // Sites that rebuild the whole document tree would otherwise drop the bar.
  new MutationObserver(function () { if (!host.isConnected) attach(); }).observe(document, { childList: true, subtree: true });
})();
