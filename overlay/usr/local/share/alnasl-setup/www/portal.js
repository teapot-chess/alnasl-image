"use strict";
// Alnasl hall box: the setup page a phone sees on the box's setup hotspot (docs/captive-portal.md).
// Plain JS, no libraries, works in the iOS sign-in sheet (no camera there: pasting is enough). Everything
// dynamic goes in through textContent. Same words mechanism as app.js (TX, t, tf); the language is the
// phone's own choice here and stays on the phone, so a visitor does not change the hall screen's language.

const TX = {
  en: {
    title: "Set up this box", intro: "You are connected to the box's own setup Wi-Fi. Nothing here can erase the box, update it or change what it is.",
    box: "This box", role: "What it is", name: "Name", addresses: "Addresses", none_yet: "none yet (no network)",
    reach: "Once it is on the hall's network", reach_url: "Its page: %s", reach_name: "Its name: %s", reach_screen: "Its page is on its own screen; on the network it only dials out.",
    wifi: "Wi-Fi of the hall", scan: "Look for networks", scanning: "Looking...", cached: "The list is from %s s ago: the radio is busy being this hotspot.",
    no_nets: "No networks found. Type the name below.", other: "Other network (type its name)", network_name: "Network name", passphrase: "Password",
    hidden: "Hidden network", country: "Country code", show: "Show", connect: "Connect", saved: "saved", open_net: "open",
    leaving: "The box now leaves this hotspot and tries “%s”. Your phone loses this page in a moment; that is the plan.",
    leaving_ok: "If it works, this hotspot stays off and the box is on “%s”. %s",
    leaving_bad: "If it does not work, the hotspot %s comes back within about a minute: join it again and this page says why.",
    last_bad: "Joining “%s” did not work: %s",
    last_ok: "Joined “%s”.",
    r_wrong_passphrase: "the password was refused.", r_rejected: "the network refused the box.", r_not_found: "the network was not found (check the name, or tick Hidden network).",
    r_no_address: "the box got onto the network but no address from it (the hall's router gave none).", r_supplicant_failed: "the Wi-Fi program on the box did not start.",
    r_failed: "it failed.", r_bad_request: "the name or password was not valid.",
    arkab: "Arkab", pin: "PIN of this box", pin_d: "Every browser elsewhere in the hall types it before it sees anything of this box. It always has one; the box's own screen and alnasl-pin.txt on its SD card show it. Set a new one here: 6 to 64 characters.",
    pin_set: "Set PIN", pin_random: "New random PIN", pin_done: "Done. The app restarts for a few seconds to use it; read the PIN on the box's screen or SD card.",
    pin_short: "At least 6 characters.", pin_long: "64 characters at most.", pin_edges: "No space at the start or the end.", pin_control: "Only plain characters.",
    app_missing: "The app is not installed on this box.", pin_failed: "The box could not change the PIN. Try again.",
    join: "Join link", join_d: "The link the Alnasl server shows under “Add a bridge” (https://server/join/...). Paste it here.",
    join_go: "Join", join_pending: "Kept. The box hands it to Arkab as soon as it has a network (the link is good for 15 minutes).",
    j_joined: "Arkab joined the server.", j_not_a_link: "That is not a join link.", j_used_or_expired: "That link is used up or expired. Ask the server for a new one.",
    j_unreachable: "The server in that link does not answer from here.", j_version: "That server speaks another version of the link. Update one of the two.",
    j_elsewhere: "This bridge is still in another hall on that server. Remove it there first.", j_not_a_server: "That address answered, but not like a server.",
    j_arkab_down: "Arkab is not running yet. Try again in a minute.", j_arkab_refused: "Arkab did not let the setup page in.", j_no_answer: "Arkab gave no answer in time.",
    j_expired: "The link waited too long for a network and expired.", j_last: "Last join link: %s",
    browser: "Open in your browser", browser_d: "This sheet is a small browser. For more room, or to scan a QR code with the camera, open your normal browser while still on this Wi-Fi and go to:",
    not_arkab: "This is not an Arkab box.", not_a_link: "That is not a join link.", box_busy: "The box did not answer. Try again.",
    error: "Something went wrong", retry: "Try again",
  },
  nl: {
    title: "Deze kast instellen", intro: "Je bent verbonden met de eigen installatiewifi van de kast. Niets hier kan de kast wissen, bijwerken of veranderen in iets anders.",
    box: "Deze kast", role: "Wat hij is", name: "Naam", addresses: "Adressen", none_yet: "nog geen (geen netwerk)",
    reach: "Zodra hij op het netwerk van de zaal zit", reach_url: "Zijn pagina: %s", reach_name: "Zijn naam: %s", reach_screen: "Zijn pagina staat op zijn eigen scherm; op het netwerk belt hij alleen naar buiten.",
    wifi: "Wifi van de zaal", scan: "Netwerken zoeken", scanning: "Zoeken...", cached: "De lijst is van %s s geleden: de radio is bezig deze hotspot te zijn.",
    no_nets: "Geen netwerken gevonden. Typ de naam hieronder.", other: "Ander netwerk (typ de naam)", network_name: "Netwerknaam", passphrase: "Wachtwoord",
    hidden: "Verborgen netwerk", country: "Landcode", show: "Tonen", connect: "Verbinden", saved: "opgeslagen", open_net: "open",
    leaving: "De kast verlaat nu deze hotspot en probeert “%s”. Je telefoon verliest deze pagina zo meteen; dat is de bedoeling.",
    leaving_ok: "Lukt het, dan blijft deze hotspot uit en zit de kast op “%s”. %s",
    leaving_bad: "Lukt het niet, dan komt de hotspot %s binnen een minuut terug: maak opnieuw verbinding en deze pagina zegt waarom.",
    last_bad: "Verbinden met “%s” lukte niet: %s",
    last_ok: "Verbonden met “%s”.",
    r_wrong_passphrase: "het wachtwoord werd geweigerd.", r_rejected: "het netwerk weigerde de kast.", r_not_found: "het netwerk is niet gevonden (controleer de naam, of vink Verborgen netwerk aan).",
    r_no_address: "de kast kwam op het netwerk maar kreeg er geen adres (de router van de zaal gaf er geen).", r_supplicant_failed: "het wifi-programma op de kast startte niet.",
    r_failed: "het mislukte.", r_bad_request: "de naam of het wachtwoord was niet geldig.",
    arkab: "Arkab", pin: "Pincode van deze kast", pin_d: "Elke browser elders in de zaal typt hem voor hij iets van deze kast te zien krijgt. Er is er altijd een; het scherm van de kast en alnasl-pin.txt op de SD-kaart tonen hem. Stel hier een nieuwe in: 6 tot 64 tekens.",
    pin_set: "Pincode instellen", pin_random: "Nieuwe willekeurige pincode", pin_done: "Klaar. De app herstart een paar seconden om hem te gebruiken; lees de pincode op het scherm of de SD-kaart van de kast.",
    pin_short: "Minstens 6 tekens.", pin_long: "Hoogstens 64 tekens.", pin_edges: "Geen spatie aan het begin of het eind.", pin_control: "Alleen gewone tekens.",
    app_missing: "De app staat niet op deze kast.", pin_failed: "De kast kon de pincode niet wijzigen. Probeer het opnieuw.",
    join: "Koppellink", join_d: "De link die de Alnasl-server toont onder “Add a bridge” (https://server/join/...). Plak hem hier.",
    join_go: "Koppelen", join_pending: "Bewaard. De kast geeft hem aan Arkab zodra hij een netwerk heeft (de link is 15 minuten geldig).",
    j_joined: "Arkab is gekoppeld aan de server.", j_not_a_link: "Dat is geen koppellink.", j_used_or_expired: "Die link is al gebruikt of verlopen. Vraag de server om een nieuwe.",
    j_unreachable: "De server in die link antwoordt niet vanaf hier.", j_version: "Die server spreekt een andere versie van de link. Werk een van de twee bij.",
    j_elsewhere: "Deze brug zit nog in een andere zaal op die server. Haal hem daar eerst weg.", j_not_a_server: "Dat adres antwoordde, maar niet als een server.",
    j_arkab_down: "Arkab draait nog niet. Probeer het over een minuut opnieuw.", j_arkab_refused: "Arkab liet de installatiepagina niet binnen.", j_no_answer: "Arkab antwoordde niet op tijd.",
    j_expired: "De link wachtte te lang op een netwerk en is verlopen.", j_last: "Laatste koppellink: %s",
    browser: "Openen in je browser", browser_d: "Dit venster is een kleine browser. Voor meer ruimte, of om een QR-code met de camera te scannen, open je gewone browser terwijl je nog op deze wifi zit en ga naar:",
    not_arkab: "Dit is geen Arkab-kast.", not_a_link: "Dat is geen koppellink.", box_busy: "De kast antwoordde niet. Probeer het opnieuw.",
    error: "Er ging iets mis", retry: "Opnieuw proberen",
  },
};
const ROLE_NAME = { alnasl: "Alnasl", arkab: "Arkab", polis: "Polis", nunki: "Nunki" };
let LANG = "en";
try { LANG = localStorage.getItem("alnasl-portal-lang") || ""; } catch (e) { LANG = ""; }
const t = (k) => (TX[LANG] && TX[LANG][k]) || TX.en[k] || k;
const tf = (k, ...a) => { let i = 0; return t(k).replace(/%s/g, () => String(a[i++] ?? "")); };

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === false || v == null) continue;
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "value") el.value = v;
    else if (k === "checked") el.checked = !!v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of kids.flat(Infinity)) if (c != null && c !== false) el.append(c.nodeType ? c : document.createTextNode(String(c)));
  return el;
}
async function api(path, body) {
  const opt = body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json", "X-Alnasl-Setup": "1" }, body: JSON.stringify(body) };
  // A sign-in sheet waits for ever on a request nobody answers; this one gives up and says so.
  const ctl = typeof AbortController === "function" ? new AbortController() : null;
  if (ctl) { opt.signal = ctl.signal; setTimeout(() => ctl.abort(), path === "/api/portal/scan" ? 40000 : 20000); }
  let r;
  try { r = await fetch(path, opt); } catch (e) { throw new Error("box_busy"); }
  let j = {};
  try { j = await r.json(); } catch (e) { /* empty */ }
  if (!r.ok) throw new Error(j.error || "error");
  return j;
}
const msg = (kind, text) => h("div", { class: "msg " + kind }, text);
const busy = (text) => h("p", {}, h("span", { class: "spin" }), text);
const errText = (e) => (TX.en[e.message] ? t(e.message) : t("error"));
function field(label, attrs) {
  const input = h("input", Object.assign({ type: "text", autocomplete: "off", autocapitalize: "off", spellcheck: "false" }, attrs));
  return { el: h("label", { class: "f" }, h("span", {}, label), input), input };
}
function bars(dbm) {
  const n = dbm >= -55 ? 4 : dbm >= -65 ? 3 : dbm >= -75 ? 2 : 1;
  return h("span", { class: "bars" }, [1, 2, 3, 4].map((i) => h("i", { class: i <= n ? "on" : "", style: "height:" + (6 + i * 4) + "px" })));
}

const app = document.getElementById("app");
let P = null;

function reachText(next, role) {
  if (!next) return "";
  return next.url ? tf("reach_url", next.url) : role === "polis" || role === "nunki" ? t("reach_screen") : tf("reach_name", next.mdns);
}

async function draw() {
  app.replaceChildren(topBar(), h("div", { class: "page" }, busy("...")));
  try { P = await api("/api/portal"); } catch (e) { app.replaceChildren(topBar(), h("div", { class: "page" }, msg("bad", t("box_busy")), h("button", { class: "btn", onclick: draw }, t("retry")))); return; }
  if (!LANG) LANG = P.lang === "nl" ? "nl" : (navigator.language || "").toLowerCase().startsWith("nl") ? "nl" : "en";
  const page = h("div", { class: "page" }, h("h1", {}, t("title")), h("p", { class: "dim" }, t("intro")));
  const lj = P.last_join;
  if (lj && lj.ssid) page.append(lj.ok ? msg("ok", tf("last_ok", lj.ssid)) : msg("bad", tf("last_bad", lj.ssid, t("r_" + lj.reason) === "r_" + lj.reason ? t("r_failed") : t("r_" + lj.reason))));
  page.append(boxCard(), wifiCard());
  page.append(pinCard());
  if (P.role === "arkab") page.append(arkabCard());
  page.append(h("div", { class: "card" }, h("h2", {}, t("browser")), h("p", { class: "dim small" }, t("browser_d")),
    h("p", { class: "mono" }, h("a", { href: "http://10.42.0.1/", id: "portal-url" }, "http://10.42.0.1/"))));
  app.replaceChildren(topBar(), page);
}
// Not "top": that name is the browser's own (window.top), and a script that takes it does not run at all.
function topBar() {
  return h("div", { class: "top" }, h("div", { class: "brand" }, "Alnasl"), h("div", { class: "dim" }, P && P.hotspot ? P.hotspot.ssid || "" : ""),
    h("div", { class: "sp" }),
    h("div", { class: "row" }, ["en", "nl"].map((l) => h("button", { class: "btn sm" + (LANG === l ? " primary" : ""), onclick: () => {
      LANG = l; try { localStorage.setItem("alnasl-portal-lang", l); } catch (e) { /* the sheet may not keep it */ } draw();
    } }, l.toUpperCase()))));
}
function boxCard() {
  const addrs = (P.addresses || []).map((a) => a.ip + " (" + (a.iface === "eth0" ? "Ethernet" : "Wi-Fi") + ")").join(", ");
  return h("div", { class: "card", id: "box-card" }, h("h2", {}, t("box")),
    h("dl", { class: "kv" }, h("dt", {}, t("role")), h("dd", {}, ROLE_NAME[P.role] || P.role),
      h("dt", {}, t("name")), h("dd", { class: "mono" }, P.next ? P.next.mdns : P.hostname),
      h("dt", {}, t("addresses")), h("dd", {}, addrs || t("none_yet"))),
    h("p", { class: "small dim", style: "margin-top:10px" }, t("reach") + ": " + reachText(P.next, P.role)));
}
function wifiCard() {
  const results = h("div", {});
  const form = h("div", {});
  const country = field(t("country"), { value: P.country || "BE", maxlength: "2", style: "text-transform:uppercase" });
  async function scan() {
    results.replaceChildren(busy(t("scanning")));
    let r;
    try { r = await api("/api/portal/scan"); } catch (e) { results.replaceChildren(msg("bad", errText(e))); return; }
    const list = h("div", { class: "list" }, (r.networks || []).map((n) => h("button", { class: "item net", onclick: () => connectForm(n.ssid, n.secured, false) },
      bars(n.signal), h("span", { class: "n" }, n.ssid), h("span", { class: "dim small" }, n.saved ? t("saved") : n.secured ? "" : t("open_net")))));
    list.append(h("button", { class: "item", onclick: () => connectForm("", true, true) }, t("other")));
    results.replaceChildren(r.source === "cached" && r.age ? h("p", { class: "dim small" }, tf("cached", r.age)) : "",
      (r.networks || []).length ? "" : msg("warn", t("no_nets")), list);
  }
  function connectForm(ssid, secured, typed) {
    const name = field(t("network_name"), { value: ssid, id: "wifi-ssid" });
    const pw = field(t("passphrase"), { type: "password", id: "wifi-pass", autocomplete: "off" });
    const hid = h("input", { type: "checkbox", id: "wifi-hidden" });
    const out = h("div", {});
    const showBtn = h("button", { class: "btn sm", onclick: () => { pw.input.type = pw.input.type === "password" ? "text" : "password"; } }, t("show"));
    const go = h("button", { class: "btn primary", id: "wifi-connect", onclick: async () => {
      go.disabled = true;
      try {
        const r = await api("/api/portal/join", { ssid: name.input.value, passphrase: pw.input.value, hidden: hid.checked, country: (country.input.value || "BE").toUpperCase() });
        out.replaceChildren(msg("ok", tf("leaving", r.ssid || name.input.value)),
          h("p", { class: "small" }, tf("leaving_ok", r.ssid || name.input.value, reachText(r.next, P.role))),
          h("p", { class: "small dim" }, tf("leaving_bad", r.hotspot || (P.hotspot && P.hotspot.ssid) || "")));
      } catch (e) { out.replaceChildren(msg("bad", errText(e))); go.disabled = false; }
    } }, t("connect"));
    form.replaceChildren(h("div", { class: "card" }, typed ? name.el : h("h2", {}, ssid),
      secured || typed ? h("div", { class: "row" }, h("div", { style: "flex:1;min-width:180px" }, pw.el), showBtn) : "",
      typed ? h("label", { class: "row", style: "margin-bottom:12px" }, hid, t("hidden")) : "",
      country.el, go, h("div", { style: "margin-top:12px" }, out)));
    form.scrollIntoView({ block: "start", behavior: "smooth" });
  }
  setTimeout(scan, 50);
  return h("div", { class: "card", id: "wifi-card" }, h("h2", {}, t("wifi")),
    h("div", { class: "row", style: "margin-bottom:12px" }, h("button", { class: "btn", id: "wifi-scan", onclick: scan }, t("scan"))), results, form);
}
// The box's access PIN, whatever the box is: set here, never shown here (the hotspot is not the box's screen).
function pinCard() {
  const pin = h("input", { type: "password", id: "box-pin", autocomplete: "new-password", maxlength: "64" });
  const pinOut = h("div", {});
  const send = async (body) => {
    try { await api("/api/portal/pin", body); pin.value = ""; pinOut.replaceChildren(msg("ok", t("pin_done"))); }
    catch (e) { pinOut.replaceChildren(msg("bad", errText(e))); }
  };
  return h("div", { class: "card", id: "pin-card" }, h("h2", {}, t("pin")), h("p", { class: "dim small" }, t("pin_d")),
    h("div", { class: "row" }, h("div", { style: "flex:1;min-width:180px" }, pin),
      h("button", { class: "btn sm", onclick: () => { pin.type = pin.type === "password" ? "text" : "password"; } }, t("show")),
      h("button", { class: "btn primary", id: "box-pin-set", onclick: () => send({ pin: pin.value }) }, t("pin_set"))),
    h("div", { class: "row", style: "margin-top:8px" }, h("button", { class: "btn", id: "box-pin-random", onclick: () => send({ new: true }) }, t("pin_random"))),
    pinOut);
}
function arkabCard() {
  const link = h("textarea", { id: "arkab-link", placeholder: "https://server/join/K7Q-4MD", autocapitalize: "off", spellcheck: "false" });
  const joinOut = h("div", {});
  const a = P.arkab || {};
  if (a.pending) joinOut.append(msg("warn", t("join_pending")));
  else if (a.last && a.last.reason) joinOut.append(msg(a.last.ok ? "ok" : "bad", tf("j_last", t("j_" + a.last.reason))));
  return h("div", { class: "card", id: "arkab-card" }, h("h2", {}, t("arkab")),
    h("h2", { class: "small", style: "margin-top:6px" }, t("join")), h("p", { class: "dim small" }, t("join_d")), link,
    h("div", { class: "row", style: "margin-top:10px" }, h("button", { class: "btn primary", id: "arkab-join", onclick: async (ev) => {
      const b = ev.currentTarget; b.disabled = true; joinOut.replaceChildren(busy("..."));
      try {
        const r = await api("/api/portal/arkab-join", { link: link.value.trim() });
        joinOut.replaceChildren(r.pending ? msg("warn", t("join_pending")) : msg(r.ok ? "ok" : "bad", t("j_" + r.reason)));
      } catch (e) { joinOut.replaceChildren(msg("bad", errText(e))); }
      b.disabled = false;
    } }, t("join_go"))), joinOut);
}

draw();
