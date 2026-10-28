// v6: when the box starts something that takes Alnasl or the screen away (an update, a reset, a
// restart), the page on screen hands over to the boot screen (/screen), which says what is going on
// and comes back by itself. The state comes from the menu server, through the service worker.
(function () {
  if (window.top !== window) return;
  var AWAY = /^(update-|reset-|reboot$|shutdown$)/;
  function check() {
    try {
      chrome.runtime.sendMessage({ type: "bootscreen" }, function (s) {
        if (chrome.runtime.lastError || !s) return;
        if (s.state && AWAY.test(s.state)) location.href = "http://localhost:4041/screen";
      });
    } catch (e) { /* the extension was reloaded; the next page load starts a fresh watcher */ }
  }
  setInterval(check, 4000);
})();
