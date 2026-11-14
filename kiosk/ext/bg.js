// Service worker.
// 1. The only place that may read the box's settings server (127.0.0.1:4041 sends no CORS headers, so a page
//    script cannot). The on-screen keyboard and the Back bar ask it for the language and the keyboard layout
//    chosen in the box's settings; screen-watch.js asks it what the box is doing (v6 boot screen states).
// 2. A web page that cannot be loaded at all (no internet, DNS) shows Chromium's own error page, which no content
//    script can reach and which has no way back on a touch-only screen. After a few seconds the tab goes back to Alnasl.
// 3. v6: Alnasl itself not answering (restarting, updating) shows the boot screen, which waits for it and
//    comes back, instead of Chromium's error page. v7: the same for the box's own app, whichever it is
//    (Alnasl 4040, Arkab 4050, Polis 4061, Nunki 4062); "home" is the menu server's /, which sends the
//    screen to that app.
var ALNASL = "http://localhost:4041/";
var APP_RE = /^http:\/\/(localhost|127\.0\.0\.1):(4040|4050|4061|4062)(\/|$)/;
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

// v7.5: the screen wizard's "Identify screens" (identify.js asks; the menu server knows where each window is).
chrome.runtime.onMessage.addListener(function (msg, _sender, reply) {
  if (!msg || msg.type !== "identify") return false;
  fetch("http://localhost:4041/api/displays/identify", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(function (s) { reply(s); })
    .catch(function () { reply(null); });
  return true; // async reply
});

// v7.5: a nunki broadcast window (Nunki's /hall?screen=hdmi1) that loses Nunki waits on the boot screen and comes
// back to the same broadcast, not to the control page: the boot screen is told where to return (to=hall1).
function screenFor(u) {
  var m = /^http:\/\/(localhost|127\.0\.0\.1):4062\/hall\b.*[?&]screen=hdmi([12])\b/.exec(u || "");
  return m ? SCREEN + "?to=hall" + m[2] + "&where=hdmi" : SCREEN;
}

function isBoxUrl(u) { return /^http:\/\/(localhost|127\.0\.0\.1)(:|\/|$)/.test(u || ""); }

if (chrome.webNavigation && chrome.webNavigation.onErrorOccurred) {
  chrome.webNavigation.onErrorOccurred.addListener(function (d) {
    if (d.frameId !== 0 || d.error === "net::ERR_ABORTED") return;
    if (APP_RE.test(d.url || "")) {
      chrome.tabs.update(d.tabId, { url: screenFor(d.url) });
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

// v7.8: the status line at the bottom of the screen (statusline.js) asks for slot, address and version.
// /api/sysinfo: net.eth0 / net.wlan0 are lists of "ip/prefix" (the hotspot's own address is left out),
// image_release.slot is A or B and image_release.version the image's version.
chrome.runtime.onMessage.addListener(function (msg, _sender, reply) {
  if (!msg || msg.type !== "statusline") return false;
  fetch("http://localhost:4041/api/sysinfo", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(function (s) {
      var net = s.net || {}, ip = "";
      ["eth0", "wlan0"].forEach(function (i) { if (!ip && net[i] && net[i].length) ip = String(net[i][0]).split("/")[0]; });
      var rel = s.image_release || {};
      reply({ slot: rel.slot || "", ip: ip, version: rel.version || "" });
    })
    .catch(function () { reply(null); });
  return true; // async reply
});
