// On-screen keyboard for every text field of Alnasl (and its LiveView pages) on the hall box.
// Same layout as the box's setup pages (BE AZERTY by default, following Settings > Keyboard), EN/NL labels.
//
// How it types: for each key it dispatches keydown, inserts the text with document.execCommand("insertText")
// (the browser itself fires beforeinput + input, exactly as for a physical key, so LiveView's phx-change /
// phx-keyup / phx-debounce see a normal edit), then keyup. Enter dispatches keydown/keyup Enter and submits
// the form (requestSubmit, so phx-submit fires). It lives in a closed shadow root; the keys never take focus.
(function () {
  "use strict";
  if (window.top !== window) return;               // one keyboard per tab, not per frame
  if (document.getElementById("alnasl-kiosk-osk")) return;

  var LABELS = {
    en: { space: "space", enter: "Enter", hide: "Hide keyboard", done: "Done", show: "Show", mask: "Hide", empty: "(empty)", sym: "123/#", abc: "ABC", acc: "é à", shift: "Shift" },
    nl: { space: "spatie", enter: "Enter", hide: "Toetsenbord verbergen", done: "Klaar", show: "Toon", mask: "Verberg", empty: "(leeg)", sym: "123/#", abc: "ABC", acc: "é à", shift: "Shift" }
  };
  var ROWS = {
    azerty: ["azertyuiop", "qsdfghjklm", "wxcvbn"],
    qwertz: ["qwertzuiop", "asdfghjkl", "yxcvbnm"],
    qwerty: ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
  };
  var SYM = ["1234567890", "-/:;()&@\"€", ".,?!'_#%+="];
  var ACC = ["àâäçéèêë", "îïôöùûüñ", "ßæœøåõ¿¡"];

  var cfg = { lang: "en", layout: "be" }, cfgAt = 0;
  var target = null, shift = false, page = "abc"; // page: abc | sym | acc
  var physical = false;                            // a real keyboard was used: stay out of the way
  var reveal = false, peekTimer = null, lastLen = 0;   // password shown in clear / last typed dot still readable
  var shown = false, repeatTimer = null, repeatDelay = null;

  /* ------------------------------------------------------------ which fields ----- */
  var TEXT_TYPES = { "": 1, text: 1, search: 1, email: 1, url: 1, tel: 1, password: 1, number: 1 };
  function isField(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.disabled || el.readOnly) return false;
    var tag = el.tagName;
    if (tag === "TEXTAREA") return true;
    if (tag === "INPUT") return !!TEXT_TYPES[(el.getAttribute("type") || "").toLowerCase()];
    return el.isContentEditable && el.getAttribute("contenteditable") !== "false";
  }
  function fieldOf(el) {
    while (el && el.nodeType === 1) { if (isField(el)) return el; el = el.parentElement; }
    return null;
  }

  /* ------------------------------------------------------------------- UI -------- */
  var host = document.createElement("div");
  host.id = "alnasl-kiosk-osk";
  host.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:2147483646;display:none";
  var root = host.attachShadow({ mode: "closed" });
  var style = document.createElement("style");
  style.textContent =
    ":host{all:initial}" +
    ".kb{background:#0b1015f5;border-top:1px solid #2b3745;padding:8px 8px 10px;font:20px/1 'DejaVu Sans',system-ui,sans-serif;" +
    "user-select:none;-webkit-user-select:none;touch-action:none;box-sizing:border-box}" +
    ".r{display:flex;gap:6px;margin-bottom:6px;justify-content:center}" +
    ".k{flex:1;max-width:96px;height:clamp(44px,7.4vh,64px);border-radius:9px;border:1px solid #2b3745;background:#202a35;color:#eaf0f6;" +
    "display:flex;align-items:center;justify-content:center;font-size:22px;cursor:pointer;box-sizing:border-box}" +
    ".k:active,.k.p{background:#2b78c9}" +
    ".k.w{max-width:150px;flex:1.6;font-size:17px}.k.on{background:#2b78c9}" +
    ".pre{display:flex;align-items:center;gap:8px;margin-bottom:8px;padding:0 4px 0 10px;min-height:46px;border:1px solid #2b3745;border-radius:9px;background:#05080b;color:#eaf0f6}" +
    ".pre .l{color:#8da0b3;font-size:14px;white-space:nowrap;max-width:30%;overflow:hidden;text-overflow:ellipsis}" +
    ".pre .v{flex:1;min-width:0;font:20px/1.2 'DejaVu Sans Mono',monospace;white-space:pre;overflow:hidden}" +
    ".pre .v::after{content:'';display:inline-block;width:2px;height:1.1em;margin-left:1px;vertical-align:-3px;background:#2b78c9;animation:c 1s steps(1) infinite}" +
    ".pre .v.e{color:#8da0b3}.pre .b{flex:0 0 auto;min-width:64px;height:36px;padding:0 12px;border-radius:8px;border:1px solid #2b3745;background:#202a35;color:#eaf0f6;font-size:15px;display:flex;align-items:center;justify-content:center;cursor:pointer}" +
    ".pre .b.d{background:#2b78c9}@keyframes c{50%{opacity:0}}@media (prefers-reduced-motion:reduce){.pre .v::after{animation:none}}" +
    ".k.sp{max-width:460px;flex:6;font-size:17px}.k.en{background:#2b78c9;max-width:150px;flex:1.6;font-size:20px}";
  var kb = document.createElement("div");
  kb.className = "kb";
  root.appendChild(style);
  root.appendChild(kb);
  document.documentElement.appendChild(host);

  var spacer = document.createElement("div");      // room below the page so a field can scroll above the keyboard
  spacer.style.cssText = "height:0;pointer-events:none";
  document.documentElement.appendChild(spacer);

  function L() { return LABELS[cfg.lang] || LABELS.en; }
  function kind() {
    var id = cfg.layout;
    return id === "be" || id === "fr" ? "azerty" : id === "de" ? "qwertz" : "qwerty";
  }

  function key(label, cls, fn, repeat) {
    var b = document.createElement("div");
    b.className = "k" + (cls ? " " + cls : "");
    b.textContent = label;
    function down(e) {
      e.preventDefault(); e.stopPropagation();     // never take focus from the field
      b.classList.add("p");
      fn();
      if (repeat) {
        repeatDelay = setTimeout(function () { repeatTimer = setInterval(fn, 70); }, 420);
      }
    }
    function up() { b.classList.remove("p"); clearTimeout(repeatDelay); clearInterval(repeatTimer); }
    b.addEventListener("pointerdown", down);
    b.addEventListener("mousedown", function (e) { e.preventDefault(); });
    b.addEventListener("pointerup", up);
    b.addEventListener("pointercancel", up);
    b.addEventListener("pointerleave", up);
    return b;
  }
  function row() { var r = document.createElement("div"); r.className = "r"; return r; }
  function letter(c) {
    var up = shift && page !== "sym";
    var ch = up ? c.toUpperCase() : c;
    return key(ch, "", function () { typeChar(ch); if (shift) { shift = false; draw(); } });
  }

  /* ---------------------------------------- echo line: what is being typed ------ */
  var preV = null;
  function labelOf(el) {
    var t = el.getAttribute("aria-label") || "";
    if (!t && el.id) { var l = document.querySelector('label[for="' + CSS.escape(el.id) + '"]'); if (l) t = l.textContent; }
    if (!t) { var p = el.closest && el.closest("label"); if (p) t = p.textContent; }
    return (t || el.getAttribute("name") || "").replace(/\s+/g, " ").trim().slice(0, 40);
  }
  function secret() { return !!target && target.tagName === "INPUT" && (target.getAttribute("type") || "").toLowerCase() === "password"; }
  function valueOf() {
    if (!target) return "";
    return target.isContentEditable ? target.textContent : (target.value || "");
  }
  // A password shows dots, the last key typed stays readable for a moment (as phones do), unless Show is on.
  function preview(typed) {
    if (!preV || !target) return;
    var v = valueOf(), t = L();
    if (secret() && !reveal) {
      clearTimeout(peekTimer);
      var keep = typed && v.length > lastLen ? v.slice(-1) : "";
      v = "•".repeat(Math.max(0, v.length - (keep ? 1 : 0))) + keep;
      if (keep) peekTimer = setTimeout(function () { preview(false); }, 1200);
    }
    lastLen = valueOf().length;
    var multi = target.tagName === "TEXTAREA" || target.isContentEditable;
    preV.className = "v" + (v ? "" : " e");
    preV.textContent = v ? (multi ? v.split("\n").join(" ↵ ") : v) : (target.placeholder || t.empty);
    preV.scrollLeft = preV.scrollWidth;            // a long value shows its end, where the typing is
  }
  function pbtn(label, cls, fn) {
    var b = document.createElement("div");
    b.className = "b" + (cls ? " " + cls : ""); b.textContent = label;
    b.addEventListener("pointerdown", function (e) { e.preventDefault(); e.stopPropagation(); fn(); });
    b.addEventListener("mousedown", function (e) { e.preventDefault(); });
    return b;
  }
  function preBox() {
    var t = L(), box = document.createElement("div"), lab = target ? labelOf(target) : "";
    box.className = "pre";
    if (lab) { var l = document.createElement("span"); l.className = "l"; l.textContent = lab; box.appendChild(l); }
    preV = document.createElement("span"); preV.className = "v";
    box.appendChild(preV);
    if (secret()) box.appendChild(pbtn(reveal ? t.mask : t.show, "", function () { reveal = !reveal; draw(); }));
    box.appendChild(pbtn(t.done, "d", function () { hide(true); }));
    preview(false);
    return box;
  }

  function draw() {
    var t = L(), r0, rows;
    kb.replaceChildren();
    kb.appendChild(preBox());
    if (page === "sym") rows = SYM; else if (page === "acc") rows = ACC; else rows = ROWS[kind()];
    if (page === "abc") {
      r0 = row(); "1234567890".split("").forEach(function (c) { r0.appendChild(letter(c)); }); kb.appendChild(r0);
    }
    rows.forEach(function (str, i) {
      var r = row();
      if (i === 2 && page !== "sym") r.appendChild(key(t.shift, "w" + (shift ? " on" : ""), function () { shift = !shift; draw(); }));
      Array.from(str).forEach(function (c) { r.appendChild(letter(c)); });
      if (i === 2) r.appendChild(key("⌫", "w", backspace, true));
      kb.appendChild(r);
    });
    var last = row();
    last.appendChild(key(page === "abc" ? t.sym : t.abc, "w", function () { page = page === "abc" ? "sym" : "abc"; draw(); }));
    last.appendChild(key(t.acc, "w" + (page === "acc" ? " on" : ""), function () { page = page === "acc" ? "abc" : "acc"; draw(); }));
    ["@", ".", "-", "_"].forEach(function (c) { last.appendChild(key(c, "", function () { typeChar(c); })); });
    last.appendChild(key(t.space, "sp", function () { typeChar(" "); }));
    last.appendChild(key("↵", "en", enter));
    last.appendChild(key("▾", "w", function () { hide(true); }));
    kb.appendChild(last);
  }

  /* ------------------------------------------------------------------ typing ----- */
  function refocus() {
    if (target && document.activeElement !== target) { try { target.focus({ preventScroll: true }); } catch (e) { /* gone */ } }
    return !!target && target.isConnected;
  }
  function keyEv(type, k, extra) {
    var o = { key: k, bubbles: true, cancelable: true, composed: true };
    for (var p in extra || {}) o[p] = extra[p];
    return new KeyboardEvent(type, o);
  }
  function insert(text) {
    if (document.execCommand("insertText", false, text)) return;
    // Fallback: native setter + a real-looking InputEvent (a framework that tracks the value still notices).
    var el = target;
    if (el.isContentEditable) { el.textContent += text; }
    else {
      var proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      var set = Object.getOwnPropertyDescriptor(proto, "value").set;
      set.call(el, el.value + text);
    }
    el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
  }
  function typeChar(c) {
    if (!refocus()) return;
    var down = keyEv("keydown", c);
    target.dispatchEvent(down);
    if (!down.defaultPrevented) insert(c);
    target.dispatchEvent(keyEv("keyup", c));
    preview(true);
  }
  function backspace() {
    if (!refocus()) return;
    var down = keyEv("keydown", "Backspace", { keyCode: 8, code: "Backspace" });
    target.dispatchEvent(down);
    if (!down.defaultPrevented) document.execCommand("delete", false);
    target.dispatchEvent(keyEv("keyup", "Backspace", { keyCode: 8, code: "Backspace" }));
    preview(false);
  }
  function enter() {
    if (!refocus()) return;
    var el = target;
    var down = keyEv("keydown", "Enter", { keyCode: 13, code: "Enter" });
    el.dispatchEvent(down);
    if (el.tagName === "TEXTAREA" || el.isContentEditable) {
      if (!down.defaultPrevented) document.execCommand(el.isContentEditable ? "insertParagraph" : "insertText", false, "\n");
      el.dispatchEvent(keyEv("keyup", "Enter", { keyCode: 13, code: "Enter" }));
      return;
    }
    el.dispatchEvent(keyEv("keyup", "Enter", { keyCode: 13, code: "Enter" }));
    if (!down.defaultPrevented && el.form) {
      try { el.form.requestSubmit(); } catch (e) { el.form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })); }
    }
    hide(false);
    try { el.blur(); } catch (e) { /* ignore */ }
  }

  /* -------------------------------------------------------------- show / hide ----- */
  function loadCfg(done) {
    if (Date.now() - cfgAt < 30000) return done();
    try {
      chrome.runtime.sendMessage({ type: "osk-config" }, function (r) {
        if (!chrome.runtime.lastError && r) { cfg = r; cfgAt = Date.now(); }
        done();
      });
    } catch (e) { done(); }
  }
  function room() {
    var h = host.offsetHeight || 0;
    spacer.style.height = shown ? h + "px" : "0";
    if (!shown || !target || !target.isConnected) return;
    var r = target.getBoundingClientRect(), limit = window.innerHeight - h - 12;
    if (r.bottom > limit || r.top < 0) {
      window.scrollBy({ top: r.bottom - limit + 12, behavior: "auto" });
      r = target.getBoundingClientRect();
      if (r.bottom > limit) try { target.scrollIntoView({ block: "center" }); } catch (e) { /* ignore */ }
    }
  }
  function show(el) {
    target = el;
    if (physical) return;
    loadCfg(function () {
      if (target !== el) return;
      shift = false; page = "abc"; reveal = false;
      draw();
      host.style.display = "block";
      shown = true;
      setTimeout(room, 30);
      setTimeout(room, 250);
    });
  }
  function hide(userAction) {
    host.style.display = "none"; shown = false; spacer.style.height = "0";
    clearTimeout(repeatDelay); clearInterval(repeatTimer);
    if (userAction && target) { try { target.blur(); } catch (e) { /* ignore */ } }
    if (userAction) target = null;
  }

  document.addEventListener("focusin", function (e) {
    var f = fieldOf(e.target);
    if (f) show(f);
  }, true);
  // Tapping a field that is already focused (after "hide") brings the keyboard back.
  document.addEventListener("input", function (e) {   // LiveView patches, paste, anything that is not our keys
    if (shown && target && (e.target === target || target.contains(e.target))) preview(false);
  }, true);
  document.addEventListener("click", function (e) {
    var f = fieldOf(e.target);
    if (f && !shown) { physical = false; show(f); }
  }, true);
  document.addEventListener("focusout", function () {
    setTimeout(function () {
      if (!fieldOf(document.activeElement)) { if (shown) hide(false); target = null; }
    }, 150);
  }, true);
  // A real keyboard is in use: stop showing ours until the next touch.
  document.addEventListener("keydown", function (e) { if (e.isTrusted && fieldOf(e.target)) { physical = true; if (shown) hide(false); } }, true);
  document.addEventListener("pointerdown", function (e) { if (e.isTrusted && e.pointerType === "touch") physical = false; }, true);
  window.addEventListener("resize", function () { if (shown) room(); });
  // LiveView can remove the field under us; also keep the room right after layout changes.
  setInterval(function () {
    if (!shown) return;
    if (!target || !target.isConnected || !fieldOf(document.activeElement)) { hide(false); return; }
    var h = host.offsetHeight || 0;
    if (parseInt(spacer.style.height || "0", 10) !== h) spacer.style.height = h + "px";
  }, 1000);

  // Already focused when the script arrived (a page that autofocuses a field).
  if (fieldOf(document.activeElement)) show(fieldOf(document.activeElement));
})();
