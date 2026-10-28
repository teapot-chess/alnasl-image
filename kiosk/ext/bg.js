// Service worker.
// 1. The only place that may read the box's settings server (127.0.0.1:4041 sends no CORS headers, so a page
//    script cannot). The on-screen keyboard and the Back bar ask it for the language and the keyboard layout
//    chosen in the box's settings; screen-watch.js asks it what the box is doing (v6 boot screen states).
// 2. A web page that cannot be loaded at all (no internet, DNS) shows Chromium's own error page, which no content
//    script can reach and which has no way back on a touch-only screen. After a few seconds the tab goes back to Alnasl.
// 3. v6: Alnasl itself not answering (restarting, updating) shows the boot screen, which waits for it and
//    comes back, instead of Chromium's error page.
var ALNASL = "http://localhost:4040/";
var SCREEN = "http://localhost:4041/screen";

chrome.runtime.onMessage.addListener(function (msg, _sender, reply) {
  if (!msg || msg.type !== "bootscreen") return false;
  fetch("http://localhost:4041/api/bootscreen", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(function (s) { reply({ state: s.state || "" }); })
    .catch(function () { reply(null); });
  return true; // async reply
});

chrome.runtime.onMessage.addListener(function (msg, _sender, reply) {
  if (!msg || msg.type !== "osk-config") return false;
  fetch("http://localhost:4041/api/state", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(function (s) {
      reply({ lang: s.lang === "nl" ? "nl" : "en", layout: (s.keyboard && s.keyboard.KBD_ID) || "be" });
    })
    .catch(function () { reply({ lang: "en", layout: "be" }); });
  return true; // async reply
});

function isBoxUrl(u) { return /^http:\/\/(localhost|127\.0\.0\.1)(:|\/|$)/.test(u || ""); }

if (chrome.webNavigation && chrome.webNavigation.onErrorOccurred) {
  chrome.webNavigation.onErrorOccurred.addListener(function (d) {
    if (d.frameId !== 0 || d.error === "net::ERR_ABORTED") return;
    if (/^http:\/\/(localhost|127\.0\.0\.1):4040(\/|$)/.test(d.url || "")) {
      chrome.tabs.update(d.tabId, { url: SCREEN });
      return;
    }
    if (isBoxUrl(d.url)) return;
    var tabId = d.tabId;
    setTimeout(function () {
      chrome.tabs.get(tabId, function (tab) {
        if (chrome.runtime.lastError || !tab) return;
        // Only if the tab is still on that page (the visitor may have gone to Alnasl or the menu meanwhile).
        if (!isBoxUrl(tab.url)) chrome.tabs.update(tabId, { url: ALNASL });
      });
    }, 6000);
  });
}
