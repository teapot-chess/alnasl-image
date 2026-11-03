"use strict";
// Alnasl hall box: menu, settings and first-run wizard. Plain JS, no libraries.
// Everything dynamic goes in through textContent (an SSID is untrusted text).

/* ------------------------------------------------------------ i18n ------ */
const TX = {
  en: {
    welcome: "Welcome to your Alnasl box", welcome_d: "A few quick steps and the box is ready for the hall. You can change everything later from the menu.",
    language: "Language", next: "Next", back: "Back", skip: "Skip", finish: "Finish", save: "Save", cancel: "Cancel", close: "Close",
    keyboard: "Keyboard layout", keyboard_d: "Used by the screen and by a keyboard plugged into the box.", kbd_test: "Try it here",
    kbd_saved: "Saved. The display restarts to apply it.", kbd_saved_w: "Saved.",
    network: "Network", status: "Status", wifi: "Wi-Fi", ip_settings: "IP settings", ethernet: "Ethernet",
    link_up: "connected", link_down: "no cable", hotspot_on: "setup hotspot", not_present: "not present", no_ip: "no address yet",
    address: "Address", gateway: "Gateway", dns: "DNS servers", hostname: "Name of this box",
    hostname_note: "Letters, digits and hyphens. Applies fully after a restart.",
    scan: "Scan for networks", scanning: "Scanning...", hidden_net: "Hidden network",
    network_name: "Network name", passphrase: "Passphrase", country: "Country code", show: "Show", hide: "Hide",
    connect: "Connect", connecting: "Connecting...", connected_to: "Connected to", saved_nets: "Saved networks", forget: "Forget",
    secured: "secured", open_net: "open", saved: "saved", no_wifi: "This box has no Wi-Fi adapter.", no_nets: "No networks found. Scan again.",
    err_wrong: "The passphrase was refused. Check it and try again.", err_rejected: "The network did not accept the connection.",
    err_nf: "The network was not found. Move closer, check the name, or tick Hidden network.",
    dhcp: "Automatic (DHCP)", static_ip: "Fixed address", apply: "Apply", wifi_ok_noip: "Connected; waiting for an address.",
    keep_q: "Keep these network settings?", keep_d: "If you do not confirm, the previous settings come back by themselves in",
    keep: "Keep", revert: "Undo", seconds: "s", eth_fine: "Ethernet is connected, so Wi-Fi is optional.",
    services: "Services on this Pi", services_d: "Choose what runs on this box.",
    s_alnasl: "Alnasl", s_alnasl_d: "Board relay and web page for the hall (port 4040).",
    s_kiosk: "Display", s_kiosk_d: "Shows Alnasl full screen on the HDMI screen.",
    kiosk_warn: "Without the display this screen disappears. Run 'alnasl-setup' on the box, or use the web page, to get back.",
    done_title: "All set", done_d: "%s opens next. The menu button in the corner brings you back here.", open_alnasl: "Open %s",
    menu: "Menu", m_alnasl: "Alnasl", m_alnasl_d: "The boards and pairings", m_settings: "Settings", m_settings_d: "Network, keyboard, services, display",
    m_info: "System info", m_info_d: "Addresses, versions, uptime", m_power: "Restart / Shut down", m_power_d: "Switch the box off safely",
    alnasl_down: "Alnasl is not running on this box. Turn it on in Settings > Services.",
    settings: "Settings", display: "Display", scale: "Size of everything on screen", scale_note: "Raise it for a large TV seen from far away. The display restarts.",
    restart: "Restart", shutdown: "Shut down", power: "Restart or shut down", sure: "Are you sure?", power_wait: "Done. The screen goes dark in a moment.",
    info: "System info", model: "Model", serial: "Serial (last 6)", kernel: "Kernel", os: "System", image: "Image", alnasl_v: "Alnasl",
    uptime: "Uptime", memory: "Memory", disk: "Disk free", temp: "Temperature", disp_path: "Screen", free: "free",
    error: "Something went wrong", retry: "Try again", rerun: "Run the first-time setup again", first_run: "First-time setup",
    reset: "Erase this box", reset_d: "Everything this box has kept goes: Alnasl's data and recordings, the settings, the Wi-Fi networks, the logs and the update results. It then restarts as new, into the first-time setup.",
    reset_keep: "The system and Alnasl itself stay. Diagnostics files saved to the SD card stay too.", reset_hold: "Hold to erase",
    role_title: "What is this box?", role_d: "One box, one job. You can change it later in Settings.",
    role_alnasl_d: "Runs the hall: the boards, the pairings and the hall screen.",
    role_arkab_d: "Only reads DGT boards and passes them to an Alnasl box.",
    role_polis_d: "Prints the pairings and place cards of every round.",
    role_nunki_d: "Reads the pairings aloud and counts down to the round.",
    role_now: "This box is %s.", role_change: "Change what this box is", role_yes: "Change and restart",
    role_q: "Make this box %s?", role_switch_d: "%s stops and %s starts, after a restart. Nothing is erased: switching back loses nothing.",
    done_arkab_d: "The box restarts as Arkab. Its page opens on this screen: join it to an Alnasl box there.",
    done_polis_d: "The box restarts as Polis. Add the printer in Settings > Printers, then join a tournament on Polis's page.",
    done_nunki_d: "The box restarts as Nunki. Pick the speakers in Settings > Sound, then join a tournament on Nunki's page.",
    restart_now: "Restart",
    m_arkab_d: "The board bridge", m_polis_d: "The print station", m_nunki_d: "The announcer",
    role_down: "%s is not running on this box. Diagnostics says why; a restart often helps.",
    st_up: "running", st_down: "not running", st_noaddr: "no address yet",
    printers: "Printers", printers_tile: "Where Polis prints",
    printers_d: "Polis prints through these. A printer that understands PDF works, as most network printers do. There is no search: type the printer's address.",
    printers_none: "No printer yet.", printer_default: "default", printer_make_default: "Make default", printer_remove: "Remove",
    printer_test: "Test page", printer_test_sent: "Sent to the printer.", printer_add: "Add a network printer",
    printer_addr: "Address (IP or name)", printer_name: "Name (optional)", add: "Add", adding: "Adding...",
    printer_usb: "USB printers", printer_usb_scan: "Look for USB printers", printer_usb_none: "No USB printer found.",
    printer_cups_off: "The printing service is not running.",
    bad_printer_address: "That is not a printer address.", bad_printer_name: "Letters, digits, - and _ only, at most 32.",
    printer_not_added: "The printer could not be added. Check the address and that the printer is switched on.",
    printer_test_failed: "The test page could not be sent.",
    sound: "Sound", sound_tile: "Speakers and volume", sound_d: "Where the announcer speaks, and how loud.",
    out_hdmi: "HDMI (the screen's speakers)", out_hdmi2: "HDMI 2", out_jack: "3.5 mm jack", volume: "Volume", sound_test: "Test",
    sound_none: "No sound output found yet. Connect the screen or the speakers and open this page again.",
    sound_saved: "Saved.", sound_testing: "Listen...",
    m_diag: "Diagnostics", m_diag_d: "Is the Wi-Fi working? Network, services, logs", m_console: "Console", m_console_d: "Text console, or stop the screen",
    diag: "Diagnostics", d_wifi_q: "Does the Wi-Fi work at all?", d_loading: "Collecting...", d_refresh: "Refresh", d_test_scan: "Test Wi-Fi scan",
    d_save: "Save diagnostics to the SD card", d_saved: "Saved as %s on the boot partition of the SD card. Put the card in a PC and open the file there.",
    d_wifi: "Wi-Fi hardware and driver", d_network: "Network", d_services: "Services", d_kiosk: "Screen and kiosk", d_updates: "OS and system updates",
    d_logs: "Logs (last 60 lines per service; scroll inside a box)", d_scan_out: "Raw output of the scan test", d_scan_found: "networks found",
    d_back: "Diagnostics",
    m_help: "Get help", m_help_d: "Send this box's report, get a code to read out",
    help_d: "Sends this box's report (passwords and keys are left out) to the people helping you, and gives you a code to read out to them.",
    help_send: "Send the report", help_again: "Send again", help_sending: "Sending the report...", help_code_label: "Help code", help_last: "Your last code",
    help_read: "Read this code to the people helping you. Valid until %s.",
    help_err_no_internet: "The box could not reach the internet. Check the network in Settings > Network and try again.",
    help_err_rate_limited: "Too many requests from this network. Try again in an hour.",
    help_err_support_off: "Support is switched off on that server. Check the address in Settings > Get help.",
    help_err_too_large: "The report is too large to send.", help_err_rejected: "The server did not accept the report.",
    help_err_server_error: "The server gave an unexpected answer. Try again later.",
    help_url: "Where reports are sent", help_url_d: "An https:// address. The default is the one the Alnasl team runs.", help_url_bad: "Only https:// addresses are accepted.",
    help_url_saved: "Saved.", help_default: "Use the default",
    v_ok: "Yes. The Wi-Fi chip, its driver and its firmware work.", v_no_driver: "No. The Wi-Fi driver (brcmfmac) is not loaded.",
    v_no_hardware: "No. The Wi-Fi chip is not found on the SDIO bus.", v_firmware: "No. The firmware of the Wi-Fi chip did not load.",
    v_no_interface: "No. There is no wlan0 interface.", v_link_down: "The interface exists but is switched off. A scan switches it on.",
    v_supplicant: "The hardware works, but the Wi-Fi program (wpa_supplicant) is not answering. A scan restarts it.",
    c_driver: "Driver loaded", c_hardware: "Wi-Fi chip found", c_firmware: "Firmware loaded", c_interface: "Interface wlan0",
    c_link: "Interface switched on", c_supplicant: "wpa_supplicant answers",
    scan_none: "No networks were found.", scan_details: "Details (raw output)", open_diag: "Open Diagnostics", try_again: "Scan again",
    scan_why_no_results: "The Wi-Fi radio is working but saw no networks. Check the country code, the antenna side of the box and the distance, then scan again.",
    scan_why_supplicant: "The Wi-Fi program (wpa_supplicant) would not start. The log below says why.",
    scan_why_rejected: "The Wi-Fi program refused to scan. See the details below.",
    scan_why_nointerface: "There is no Wi-Fi interface (wlan0). The details below show what the kernel says.",
    err_supp: "The Wi-Fi program could not be started. Open Diagnostics for the reason.",
    hs_title: "Set up from a phone", hs_d: "This box has its own setup Wi-Fi on right now. Join it with a phone and its setup page opens by itself.",
    hs_ssid: "Wi-Fi", hs_pw: "Password", hs_handover: "The box leaves its setup hotspot to try this network. If it works the hotspot stays off; if not, it comes back within a minute.",
    console_title: "Console", console_d: "With a keyboard on the box: Ctrl+Alt+F2 or F3 opens a text console (log in as root), Ctrl+Alt+F1 returns to the screen.",
    console_show: "Show the console now", console_back: "Press Ctrl+Alt+F1 on the keyboard to return to this screen.",
    console_stop: "Stop the screen", console_stop_q: "Stop the screen until the next boot?",
    console_stop_note: "The box then shows the text console. To bring the screen back, log in there and type: alnasl-screen start (or restart the box). A touch screen alone cannot bring it back.",
    console_stopped: "Done. The text console appears in a moment.", yes_stop: "Yes, stop the screen",
    res: "Screen resolution", res_auto: "Automatic (the screen's preferred mode)", res_pref: "preferred", res_current: "Now",
    res_note: "Only modes your screen reports are listed. After a change you have a few seconds to confirm; otherwise the previous resolution comes back by itself, even if the screen goes black.",
    res_none: "No screen is connected, so no resolutions are known.", res_apply: "Apply resolution", res_applying: "Switching...",
    res_keep_q: "Keep this resolution?", res_keep_d: "If you do not confirm, the previous resolution comes back by itself in", res_later: "Saved. It is used the next time the screen starts.",
    upd: "System updates", upd_tile: "Version, updates, upgrade",
    upd_this: "This box", upd_slot: "system slot", upd_rule: "New versions of %s install by themselves at night (03:00-05:00), never during a round. Hall data and settings stay.",
    upd_last: "Last update", upd_none_yet: "None yet.", upd_checked: "Last checked", upd_never: "never",
    upd_check: "Check now", upd_checking: "Checking...", upd_uptodate: "This box is up to date.",
    upd_newer: "Version %s is available.", upd_install: "Install now", upd_install_q: "Install version %s now?",
    upd_install_d: "The box downloads it, writes it next to the running system and restarts into it, on its own (a few minutes). If the new version does not start properly, the box goes back to this one by itself.",
    upd_yes_install: "Yes, install now",
    upd_offer: "%s is available", upd_offer_d: "A new release line. It never installs by itself: only Upgrade starts it.",
    upd_upgrade: "Upgrade to %s", upd_upgrade_q: "Upgrade this box to %s?",
    upd_upgrade_d: "The box downloads %s, writes it next to the running system and restarts into it. Hall data and settings stay. If it does not start properly, the box goes back to this version by itself. Afterwards, new versions of %s install by themselves at night.",
    upd_yes_upgrade: "Yes, upgrade to %s", upd_blocked: "%s needs version %s of this line first; that one comes by itself at night.",
    upd_off: "System updates are off on this box.", upd_not_ab: "This card does not have the update layout yet. Flash a v6 image once; after that, no more flashing.",
    upd_trial: "Version %s is being tried out. The box decides within a few minutes whether to keep it.",
    upd_ph_checking: "Checking...", upd_ph_downloading: "Downloading", upd_ph_verifying: "Checking the download",
    upd_ph_installing: "Installing", upd_ph_restarting: "Restarting into the new version", upd_ph_waiting: "Waiting for the network",
    upd_ph_staged: "Ready; it is put in use at night.",
    upd_r_ok: "Updated", upd_r_rolled_back: "Did not work; went back", upd_r_failed: "Failed", upd_r_refused: "Refused",
    upd_r_staged: "Ready for the night", upd_r_nothing: "Nothing newer", upd_r_skipped: "Skipped",
    upd_err_round_in_progress: "A round is in progress, so nothing was changed. Try again after the round.",
    upd_err_busy: "An update is already running.", upd_err_updates_off: "System updates are off on this box.",
    upd_err_not_ab: "This card does not have the update layout.", upd_err_bad_train: "That is not a newer release line.",
    touch: "Touch screen", touch_tile: "Calibrate the stylus",
    touch_d: "The small screen's stylus touch, switched on in alnasl-screen.txt on the SD card (SCREEN=). If taps land beside what you aim at, calibrate: tap the centre of four crosses with the stylus.",
    touch_off: "No stylus touch screen is switched on. alnasl-screen.txt on the SD card does that: SCREEN=waveshare35a or waveshare32b for a small screen on the pins, or TOUCH=xpt2046 for a 3.5-inch HDMI screen whose stylus touch is on the pins.",
    touch_st_ready: "The touch panel works.", touch_st_no_touch: "The touch panel does not answer. Is the screen seated on the pins?",
    touch_st_no_panel: "The screen on the pins did not appear; the picture stays on HDMI. Is it seated on the pins, and is SCREEN= the right model?",
    touch_st_overlay_failed: "The touch panel could not be switched on (device tree). Diagnostics has the details.",
    touch_st_no_overlay_support: "This system cannot switch the touch panel on.", touch_st_not_started: "The touch panel has not been set up yet.",
    touch_now: "Rotation %s degrees, picture %s, calibration: %s.", touch_src_default: "built in", touch_src_file: "from alnasl-screen.txt", touch_src_screen: "made on this screen",
    touch_cal: "Calibrate", touch_reset: "Back to the defaults", touch_reset_done: "Done. The screen restarts with the defaults.",
    touch_tap_n: "Tap the centre of the cross with the stylus (%s of %s)",
    touch_timeout: "Nothing was tapped for 30 seconds, so the calibration stopped.", touch_saving: "Saving...", touch_saved: "Saved. The screen restarts with the new calibration.",
    res_forced: "A small screen is switched on in alnasl-screen.txt on the SD card: it sets the picture (a screen on the pins has one size; a 3.5-inch HDMI screen takes MODE=).",
    upd_url: "Where updates come from", upd_url_d: "An https:// address of a release index. Keep the default unless the Alnasl team tells you otherwise.",
    cmp_menu: "Menu", cmp_qr_setup: "Scan to set up this box", cmp_qr_in: "Scan to reach this box", cmp_qr_url: "Scan for %s",
    cmp_qr_none: "No network yet", cmp_qr_none_d: "Plug in Ethernet, or wait: the setup hotspot comes back when no network works.",
    cmp_qr_wait: "Starting the setup hotspot", cmp_qr_wait_d: "A QR code appears here in a moment. No Wi-Fi adapter? Plug in Ethernet.",
    cmp_status_in: "Status in %s", cmp_status: "Status", cmp_none: "none", cmp_hotspot: "setup hotspot", cmp_running: "running", cmp_stopped: "stopped",
    cmp_wait: "Waiting for the box...", cmp_t_role: "Use", cmp_t_pin: "Remote PIN", cmp_t_qr: "Show the QR code", cmp_pin_done: "Saved.",
  },
  nl: {
    welcome: "Welkom bij je Alnasl-box", welcome_d: "Nog een paar korte stappen en de box is klaar voor de zaal. Je kunt alles later wijzigen via het menu.",
    language: "Taal", next: "Volgende", back: "Terug", skip: "Overslaan", finish: "Klaar", save: "Opslaan", cancel: "Annuleren", close: "Sluiten",
    keyboard: "Toetsenbordindeling", keyboard_d: "Geldt voor het scherm en voor een toetsenbord dat je op de box aansluit.", kbd_test: "Probeer het hier",
    kbd_saved: "Opgeslagen. Het scherm herstart om het toe te passen.", kbd_saved_w: "Opgeslagen.",
    network: "Netwerk", status: "Status", wifi: "Wifi", ip_settings: "IP-instellingen", ethernet: "Ethernet",
    link_up: "verbonden", link_down: "geen kabel", hotspot_on: "installatiehotspot", not_present: "niet aanwezig", no_ip: "nog geen adres",
    address: "Adres", gateway: "Gateway", dns: "DNS-servers", hostname: "Naam van deze box",
    hostname_note: "Letters, cijfers en koppeltekens. Volledig actief na een herstart.",
    scan: "Netwerken zoeken", scanning: "Zoeken...", hidden_net: "Verborgen netwerk",
    network_name: "Netwerknaam", passphrase: "Wachtwoord", country: "Landcode", show: "Tonen", hide: "Verbergen",
    connect: "Verbinden", connecting: "Verbinden...", connected_to: "Verbonden met", saved_nets: "Opgeslagen netwerken", forget: "Vergeten",
    secured: "beveiligd", open_net: "open", saved: "opgeslagen", no_wifi: "Deze box heeft geen wifi-adapter.", no_nets: "Geen netwerken gevonden. Zoek opnieuw.",
    err_wrong: "Het wachtwoord werd geweigerd. Controleer het en probeer opnieuw.", err_rejected: "Het netwerk accepteerde de verbinding niet.",
    err_nf: "Het netwerk is niet gevonden. Ga dichterbij staan, controleer de naam of kies Verborgen netwerk.",
    dhcp: "Automatisch (DHCP)", static_ip: "Vast adres", apply: "Toepassen", wifi_ok_noip: "Verbonden; wacht op een adres.",
    keep_q: "Deze netwerkinstellingen houden?", keep_d: "Als je niet bevestigt, komen de vorige instellingen vanzelf terug over",
    keep: "Houden", revert: "Ongedaan maken", seconds: "s", eth_fine: "Ethernet is verbonden, dus wifi is optioneel.",
    services: "Diensten op deze Pi", services_d: "Kies wat er op deze box draait.",
    s_alnasl: "Alnasl", s_alnasl_d: "Bordenrelay en webpagina voor de zaal (poort 4040).",
    s_kiosk: "Scherm", s_kiosk_d: "Toont Alnasl schermvullend op het HDMI-scherm.",
    kiosk_warn: "Zonder scherm verdwijnt dit scherm. Voer 'alnasl-setup' op de box uit, of gebruik de webpagina, om terug te komen.",
    done_title: "Alles klaar", done_d: "%s opent nu. Met de menuknop in de hoek kom je hier terug.", open_alnasl: "%s openen",
    menu: "Menu", m_alnasl: "Alnasl", m_alnasl_d: "De borden en de indelingen", m_settings: "Instellingen", m_settings_d: "Netwerk, toetsenbord, diensten, scherm",
    m_info: "Systeeminfo", m_info_d: "Adressen, versies, looptijd", m_power: "Herstarten / Afsluiten", m_power_d: "Zet de box veilig uit",
    alnasl_down: "Alnasl draait niet op deze box. Zet het aan via Instellingen > Diensten.",
    settings: "Instellingen", display: "Scherm", scale: "Grootte van alles op het scherm", scale_note: "Verhoog dit voor een grote tv die je van ver bekijkt. Het scherm herstart.",
    restart: "Herstarten", shutdown: "Afsluiten", power: "Herstarten of afsluiten", sure: "Weet je het zeker?", power_wait: "Klaar. Het scherm gaat zo uit.",
    info: "Systeeminfo", model: "Model", serial: "Serienummer (laatste 6)", kernel: "Kernel", os: "Systeem", image: "Image", alnasl_v: "Alnasl",
    uptime: "Looptijd", memory: "Geheugen", disk: "Schijf vrij", temp: "Temperatuur", disp_path: "Scherm", free: "vrij",
    error: "Er ging iets mis", retry: "Opnieuw proberen", rerun: "De eerste installatie opnieuw doen", first_run: "Eerste installatie",
    reset: "Deze box wissen", reset_d: "Alles wat deze box bewaard heeft verdwijnt: de gegevens en opnames van Alnasl, de instellingen, de wifi-netwerken, de logs en de updateresultaten. Daarna start hij opnieuw als nieuw, in de eerste installatie.",
    reset_keep: "Het systeem en Alnasl zelf blijven. Diagnosebestanden op de SD-kaart blijven ook.", reset_hold: "Ingedrukt houden om te wissen",
    role_title: "Wat is deze box?", role_d: "Een box, een taak. Je kunt het later wijzigen in Instellingen.",
    role_alnasl_d: "Beheert de zaal: de borden, de paringen en het zaalscherm.",
    role_arkab_d: "Leest alleen DGT-borden en geeft ze door aan een Alnasl-box.",
    role_polis_d: "Drukt de paringen en tafelkaartjes van elke ronde af.",
    role_nunki_d: "Leest de paringen voor en telt af naar de ronde.",
    role_now: "Deze box is %s.", role_change: "Wijzigen wat deze box is", role_yes: "Wijzigen en herstarten",
    role_q: "Deze box %s maken?", role_switch_d: "%s stopt en %s start, na een herstart. Er wordt niets gewist: terugschakelen verliest niets.",
    done_arkab_d: "De box herstart als Arkab. De pagina opent op dit scherm: koppel hem daar aan een Alnasl-box.",
    done_polis_d: "De box herstart als Polis. Voeg de printer toe in Instellingen > Printers en koppel daarna een toernooi op de pagina van Polis.",
    done_nunki_d: "De box herstart als Nunki. Kies de luidsprekers in Instellingen > Geluid en koppel daarna een toernooi op de pagina van Nunki.",
    restart_now: "Herstarten",
    m_arkab_d: "De bordenbrug", m_polis_d: "Het printstation", m_nunki_d: "De omroeper",
    role_down: "%s draait niet op deze box. Diagnose zegt waarom; herstarten helpt vaak.",
    st_up: "draait", st_down: "draait niet", st_noaddr: "nog geen adres",
    printers: "Printers", printers_tile: "Waar Polis afdrukt",
    printers_d: "Polis drukt hierlangs af. Een printer die PDF begrijpt werkt, zoals de meeste netwerkprinters. Er wordt niet gezocht: typ het adres van de printer.",
    printers_none: "Nog geen printer.", printer_default: "standaard", printer_make_default: "Standaard maken", printer_remove: "Verwijderen",
    printer_test: "Testpagina", printer_test_sent: "Naar de printer gestuurd.", printer_add: "Een netwerkprinter toevoegen",
    printer_addr: "Adres (IP of naam)", printer_name: "Naam (niet verplicht)", add: "Toevoegen", adding: "Toevoegen...",
    printer_usb: "USB-printers", printer_usb_scan: "USB-printers zoeken", printer_usb_none: "Geen USB-printer gevonden.",
    printer_cups_off: "De printdienst draait niet.",
    bad_printer_address: "Dat is geen printeradres.", bad_printer_name: "Alleen letters, cijfers, - en _, hoogstens 32.",
    printer_not_added: "De printer kon niet worden toegevoegd. Controleer het adres en of de printer aan staat.",
    printer_test_failed: "De testpagina kon niet worden verstuurd.",
    sound: "Geluid", sound_tile: "Luidsprekers en volume", sound_d: "Waar de omroeper spreekt, en hoe luid.",
    out_hdmi: "HDMI (de luidsprekers van het scherm)", out_hdmi2: "HDMI 2", out_jack: "3,5 mm-aansluiting", volume: "Volume", sound_test: "Testen",
    sound_none: "Nog geen geluidsuitgang gevonden. Sluit het scherm of de luidsprekers aan en open deze pagina opnieuw.",
    sound_saved: "Opgeslagen.", sound_testing: "Luister...",
    m_diag: "Diagnose", m_diag_d: "Werkt de wifi? Netwerk, diensten, logs", m_console: "Console", m_console_d: "Tekstconsole, of het scherm stoppen",
    diag: "Diagnose", d_wifi_q: "Werkt de wifi wel?", d_loading: "Gegevens verzamelen...", d_refresh: "Vernieuwen", d_test_scan: "Wifi-scan testen",
    d_save: "Diagnose opslaan op de SD-kaart", d_saved: "Opgeslagen als %s op de opstartpartitie van de SD-kaart. Steek de kaart in een pc en open het bestand daar.",
    d_wifi: "Wifi-hardware en driver", d_network: "Netwerk", d_services: "Diensten", d_kiosk: "Scherm en kiosk", d_updates: "OS- en systeemupdates",
    d_logs: "Logs (laatste 60 regels per dienst; scrol binnen een vak)", d_scan_out: "Ruwe uitvoer van de scantest", d_scan_found: "netwerken gevonden",
    d_back: "Diagnose",
    m_help: "Hulp vragen", m_help_d: "Verstuur het rapport van deze box en krijg een code om door te geven",
    help_d: "Stuurt het rapport van deze box (zonder wachtwoorden en sleutels) naar de mensen die je helpen, en geeft je een code om aan hen door te geven.",
    help_send: "Rapport versturen", help_again: "Opnieuw versturen", help_sending: "Rapport wordt verstuurd...", help_code_label: "Hulpcode", help_last: "Je laatste code",
    help_read: "Geef deze code door aan de mensen die je helpen. Geldig tot %s.",
    help_err_no_internet: "De box kreeg geen verbinding met internet. Controleer het netwerk bij Instellingen > Netwerk en probeer opnieuw.",
    help_err_rate_limited: "Te veel aanvragen vanaf dit netwerk. Probeer het over een uur opnieuw.",
    help_err_support_off: "Hulp staat uit op die server. Controleer het adres bij Instellingen > Hulp vragen.",
    help_err_too_large: "Het rapport is te groot om te versturen.", help_err_rejected: "De server heeft het rapport niet aanvaard.",
    help_err_server_error: "De server gaf een onverwacht antwoord. Probeer het later opnieuw.",
    help_url: "Waarheen rapporten gaan", help_url_d: "Een https://-adres. Standaard is dat van het Alnasl-team.", help_url_bad: "Enkel https://-adressen worden aanvaard.",
    help_url_saved: "Opgeslagen.", help_default: "Standaard gebruiken",
    v_ok: "Ja. De wifi-chip, de driver en de firmware werken.", v_no_driver: "Nee. De wifi-driver (brcmfmac) is niet geladen.",
    v_no_hardware: "Nee. De wifi-chip is niet gevonden op de SDIO-bus.", v_firmware: "Nee. De firmware van de wifi-chip is niet geladen.",
    v_no_interface: "Nee. Er is geen wlan0-interface.", v_link_down: "De interface bestaat maar staat uit. Een scan zet hem aan.",
    v_supplicant: "De hardware werkt, maar het wifi-programma (wpa_supplicant) antwoordt niet. Een scan start het opnieuw.",
    c_driver: "Driver geladen", c_hardware: "Wifi-chip gevonden", c_firmware: "Firmware geladen", c_interface: "Interface wlan0",
    c_link: "Interface aan", c_supplicant: "wpa_supplicant antwoordt",
    scan_none: "Er zijn geen netwerken gevonden.", scan_details: "Details (ruwe uitvoer)", open_diag: "Diagnose openen", try_again: "Opnieuw zoeken",
    scan_why_no_results: "De wifi-radio werkt maar zag geen netwerken. Controleer de landcode, de antennekant van de box en de afstand, en zoek opnieuw.",
    scan_why_supplicant: "Het wifi-programma (wpa_supplicant) wilde niet starten. Het log hieronder zegt waarom.",
    scan_why_rejected: "Het wifi-programma weigerde te scannen. Zie de details hieronder.",
    scan_why_nointerface: "Er is geen wifi-interface (wlan0). De details hieronder tonen wat de kernel zegt.",
    err_supp: "Het wifi-programma kon niet gestart worden. Open Diagnose voor de reden.",
    hs_title: "Instellen met je telefoon", hs_d: "Deze kast heeft nu zijn eigen installatiewifi aan. Maak er verbinding mee met je telefoon en de installatiepagina gaat vanzelf open.",
    hs_ssid: "Wifi", hs_pw: "Wachtwoord", hs_handover: "De kast verlaat zijn installatiehotspot om dit netwerk te proberen. Lukt het, dan blijft de hotspot uit; lukt het niet, dan komt hij binnen een minuut terug.",
    console_title: "Console", console_d: "Met een toetsenbord op de box: Ctrl+Alt+F2 of F3 opent een tekstconsole (log in als root), Ctrl+Alt+F1 brengt je terug naar het scherm.",
    console_show: "Console nu tonen", console_back: "Druk op het toetsenbord op Ctrl+Alt+F1 om terug te keren naar dit scherm.",
    console_stop: "Scherm stoppen", console_stop_q: "Het scherm stoppen tot de volgende start?",
    console_stop_note: "De box toont daarna de tekstconsole. Om het scherm terug te krijgen log je daar in en typ je: alnasl-screen start (of herstart de box). Alleen met een aanraakscherm lukt dat niet.",
    console_stopped: "Klaar. De tekstconsole verschijnt zo.", yes_stop: "Ja, stop het scherm",
    res: "Schermresolutie", res_auto: "Automatisch (de voorkeursmodus van het scherm)", res_pref: "voorkeur", res_current: "Nu",
    res_note: "Alleen modi die je scherm opgeeft staan in de lijst. Na een wijziging heb je enkele seconden om te bevestigen; anders komt de vorige resolutie vanzelf terug, ook als het scherm zwart wordt.",
    res_none: "Er is geen scherm aangesloten, dus er zijn geen resoluties bekend.", res_apply: "Resolutie toepassen", res_applying: "Omschakelen...",
    res_keep_q: "Deze resolutie houden?", res_keep_d: "Als je niet bevestigt, komt de vorige resolutie vanzelf terug over", res_later: "Opgeslagen. Wordt gebruikt de volgende keer dat het scherm start.",
    upd: "Systeemupdates", upd_tile: "Versie, updates, upgrade",
    upd_this: "Deze box", upd_slot: "systeemslot", upd_rule: "Nieuwe versies van %s installeren zich 's nachts vanzelf (03:00-05:00), nooit tijdens een ronde. Zaalgegevens en instellingen blijven.",
    upd_last: "Laatste update", upd_none_yet: "Nog geen.", upd_checked: "Laatst gecontroleerd", upd_never: "nooit",
    upd_check: "Nu controleren", upd_checking: "Controleren...", upd_uptodate: "Deze box is up-to-date.",
    upd_newer: "Versie %s is beschikbaar.", upd_install: "Nu installeren", upd_install_q: "Versie %s nu installeren?",
    upd_install_d: "De box downloadt ze, schrijft ze naast het draaiende systeem en herstart erin, helemaal vanzelf (enkele minuten). Start de nieuwe versie niet goed, dan gaat de box vanzelf terug naar deze.",
    upd_yes_install: "Ja, nu installeren",
    upd_offer: "%s is beschikbaar", upd_offer_d: "Een nieuwe releaselijn. Die installeert zich nooit vanzelf: alleen Upgraden start ze.",
    upd_upgrade: "Upgraden naar %s", upd_upgrade_q: "Deze box upgraden naar %s?",
    upd_upgrade_d: "De box downloadt %s, schrijft ze naast het draaiende systeem en herstart erin. Zaalgegevens en instellingen blijven. Start ze niet goed, dan gaat de box vanzelf terug naar deze versie. Daarna installeren nieuwe versies van %s zich 's nachts vanzelf.",
    upd_yes_upgrade: "Ja, upgraden naar %s", upd_blocked: "%s vraagt eerst versie %s van deze lijn; die komt 's nachts vanzelf.",
    upd_off: "Systeemupdates staan uit op deze box.", upd_not_ab: "Deze kaart heeft nog niet de indeling voor updates. Flash eenmalig een v6-image; daarna hoeft dat nooit meer.",
    upd_trial: "Versie %s wordt uitgeprobeerd. De box beslist binnen enkele minuten of hij ze houdt.",
    upd_ph_checking: "Controleren...", upd_ph_downloading: "Downloaden", upd_ph_verifying: "De download controleren",
    upd_ph_installing: "Installeren", upd_ph_restarting: "Herstarten in de nieuwe versie", upd_ph_waiting: "Wachten op het netwerk",
    upd_ph_staged: "Klaar; ze wordt 's nachts in gebruik genomen.",
    upd_r_ok: "Bijgewerkt", upd_r_rolled_back: "Werkte niet; teruggezet", upd_r_failed: "Mislukt", upd_r_refused: "Geweigerd",
    upd_r_staged: "Klaar voor de nacht", upd_r_nothing: "Niets nieuwers", upd_r_skipped: "Overgeslagen",
    upd_err_round_in_progress: "Er loopt een ronde, dus er is niets veranderd. Probeer het na de ronde opnieuw.",
    upd_err_busy: "Er loopt al een update.", upd_err_updates_off: "Systeemupdates staan uit op deze box.",
    upd_err_not_ab: "Deze kaart heeft niet de indeling voor updates.", upd_err_bad_train: "Dat is geen nieuwere releaselijn.",
    touch: "Aanraakscherm", touch_tile: "De stylus kalibreren",
    touch_d: "De stylus-aanraking van het kleine scherm, aangezet in alnasl-screen.txt op de SD-kaart (SCREEN=). Kom je met een tik naast wat je bedoelt, kalibreer dan: tik met de stylus het midden van vier kruisjes aan.",
    touch_off: "Er staat geen stylus-aanraakscherm aan. Dat doe je in alnasl-screen.txt op de SD-kaart: SCREEN=waveshare35a of waveshare32b voor een klein scherm op de pinnen, of TOUCH=xpt2046 voor een 3,5-inch HDMI-scherm met stylus-aanraking op de pinnen.",
    touch_st_ready: "Het aanraakpaneel werkt.", touch_st_no_touch: "Het aanraakpaneel antwoordt niet. Zit het scherm goed op de pinnen?",
    touch_st_no_panel: "Het scherm op de pinnen kwam niet tevoorschijn; het beeld blijft op HDMI. Zit het goed op de pinnen, en klopt het model bij SCREEN=?",
    touch_st_overlay_failed: "Het aanraakpaneel kon niet aangezet worden (device tree). Diagnose toont de details.",
    touch_st_no_overlay_support: "Dit systeem kan het aanraakpaneel niet aanzetten.", touch_st_not_started: "Het aanraakpaneel is nog niet ingesteld.",
    touch_now: "Rotatie %s graden, beeld %s, kalibratie: %s.", touch_src_default: "ingebouwd", touch_src_file: "uit alnasl-screen.txt", touch_src_screen: "op dit scherm gemaakt",
    touch_cal: "Kalibreren", touch_reset: "Terug naar de standaard", touch_reset_done: "Klaar. Het scherm herstart met de standaardwaarden.",
    touch_tap_n: "Tik met de stylus het midden van het kruisje aan (%s van %s)",
    touch_timeout: "Er werd 30 seconden niets aangetikt, dus de kalibratie is gestopt.", touch_saving: "Opslaan...", touch_saved: "Opgeslagen. Het scherm herstart met de nieuwe kalibratie.",
    res_forced: "Er staat een klein scherm aan in alnasl-screen.txt op de SD-kaart: dat bepaalt het beeld (een scherm op de pinnen heeft één formaat; een 3,5-inch HDMI-scherm neemt MODE=).",
    upd_url: "Waar updates vandaan komen", upd_url_d: "Een https://-adres van een release-index. Laat de standaard staan tenzij het Alnasl-team iets anders zegt.",
    cmp_menu: "Menu", cmp_qr_setup: "Scan om deze kast in te stellen", cmp_qr_in: "Scan om deze kast te bereiken", cmp_qr_url: "Scan voor %s",
    cmp_qr_none: "Nog geen netwerk", cmp_qr_none_d: "Steek een netwerkkabel in, of wacht: de installatiehotspot komt terug als geen netwerk werkt.",
    cmp_qr_wait: "De installatiehotspot start", cmp_qr_wait_d: "Zo meteen verschijnt hier een QR-code. Geen wifi-adapter? Steek een netwerkkabel in.",
    cmp_status_in: "Status over %s", cmp_status: "Status", cmp_none: "geen", cmp_hotspot: "installatiehotspot", cmp_running: "draait", cmp_stopped: "gestopt",
    cmp_wait: "Wachten op de kast...", cmp_t_role: "Gebruik", cmp_t_pin: "Pincode op afstand", cmp_t_qr: "Toon de QR-code", cmp_pin_done: "Opgeslagen.",
  },
};
let LANG = "en";
const t = (k) => (TX[LANG] && TX[LANG][k]) || TX.en[k] || k;
const tf = (k, ...a) => { let i = 0; return t(k).replace(/%s/g, () => String(a[i++] ?? "")); };

/* --------------------------------------------------------- helpers ------ */
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
const $ = (s, r = document) => r.querySelector(s);
async function api(path, body) {
  const opt = body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json", "X-Alnasl-Setup": "1" }, body: JSON.stringify(body) };
  const r = await fetch(path, opt);
  let j = {};
  try { j = await r.json(); } catch (e) { /* empty */ }
  if (!r.ok) throw new Error(j.error || t("error"));
  return j;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function bars(dbm) {
  const n = dbm >= -55 ? 4 : dbm >= -65 ? 3 : dbm >= -75 ? 2 : 1;
  return h("span", { class: "bars" }, [1, 2, 3, 4].map((i) => h("i", { class: i <= n ? "on" : "", style: "height:" + (6 + i * 4) + "px" })));
}
const fmtBytes = (b) => (b >= 1e9 ? (b / 1e9).toFixed(1) + " GB" : Math.round(b / 1e6) + " MB");
function fmtUp(s) { const d = Math.floor(s / 86400), hh = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60); return (d ? d + "d " : "") + hh + "h " + m + "m"; }

let S = { layouts: [], keyboard: {}, services: {}, scale: "100", done: false };
let WIZ = false;          // true while the first-run sequence is on screen
const app = $("#app");

function modal(content) { const m = $("#modal"); m.replaceChildren(h("div", { class: "box" }, content)); m.hidden = false; return () => { m.hidden = true; m.replaceChildren(); }; }
function msg(kind, text) { return h("div", { class: "msg " + kind }, text); }
function busy(text) { return h("p", {}, h("span", { class: "spin" }), text); }

function shell(title, body, opts = {}) {
  const top = h("div", { class: "top" },
    h("div", { class: "brand" }, "Alnasl"),
    h("div", { class: "dim" }, title),
    h("div", { class: "sp" }),
    opts.langToggle === false ? null : langToggle(),
    opts.home ? h("button", { class: "btn sm", onclick: () => go(S.compact ? "/compact" : "/menu") }, t("menu")) : null);
  app.replaceChildren(top, h("div", { class: "page" }, body));
  closeOsk();
}
function langToggle() {
  return h("div", { class: "row" }, ["en", "nl"].map((l) =>
    h("button", { class: "btn sm" + (LANG === l ? " primary" : ""), onclick: async () => { LANG = l; await api("/api/lang", { lang: l }).catch(() => 0); route(); } }, l.toUpperCase())));
}

/* ------------------------------------------ on-screen keyboard (touch) -- */
const OSK_ROWS = {
  azerty: ["azertyuiop", "qsdfghjklm", "wxcvbn"],
  qwertz: ["qwertzuiop", "asdfghjkl", "yxcvbnm"],
  qwerty: ["qwertyuiop", "asdfghjkl", "zxcvbnm"],
};
const OSK_SYM = ["1234567890", "-/:;()&@\"", ".,?!'_#%+="];
let oskTarget = null, oskShift = false, oskSym = false;
function oskKind() {
  const id = (S.keyboard && S.keyboard.KBD_ID) || "be";
  return id === "be" || id === "fr" ? "azerty" : id === "de" ? "qwertz" : "qwerty";
}
function oskDraw() {
  const o = $("#osk");
  const rows = oskSym ? OSK_SYM : OSK_ROWS[oskKind()];
  const key = (c) => h("button", { type: "button", onpointerdown: (e) => { e.preventDefault(); oskType(oskShift && !oskSym ? c.toUpperCase() : c); } }, oskShift && !oskSym ? c.toUpperCase() : c);
  const num = oskSym ? null : h("div", { class: "kr" }, [..."1234567890"].map(key));
  o.replaceChildren(
    num,
    ...rows.map((r, i) => h("div", { class: "kr" },
      i === 2 && !oskSym ? h("button", { type: "button", class: "w" + (oskShift ? " on" : ""), onpointerdown: (e) => { e.preventDefault(); oskShift = !oskShift; oskDraw(); } }, "Shift") : null,
      [...r].map(key),
      i === 2 ? h("button", { type: "button", class: "w", onpointerdown: (e) => { e.preventDefault(); oskType("\b"); } }, "⌫") : null)),
    h("div", { class: "kr" },
      h("button", { type: "button", class: "w", onpointerdown: (e) => { e.preventDefault(); oskSym = !oskSym; oskDraw(); } }, oskSym ? "ABC" : "123/#"),
      key("@"), key("."), key("-"), key("_"),
      h("button", { type: "button", class: "spc", onpointerdown: (e) => { e.preventDefault(); oskType(" "); } }, "space"),
      h("button", { type: "button", class: "w", onpointerdown: (e) => { e.preventDefault(); closeOsk(); } }, "▾")));
}
function oskType(c) {
  const el = oskTarget; if (!el) return;
  const s = el.selectionStart ?? el.value.length, e = el.selectionEnd ?? s;
  if (c === "\b") { if (s === e && s > 0) { el.setRangeText("", s - 1, e, "end"); } else { el.setRangeText("", s, e, "end"); } }
  else el.setRangeText(c, s, e, "end");
  el.dispatchEvent(new Event("input", { bubbles: true }));
  if (oskShift) { oskShift = false; oskDraw(); }
}
function closeOsk() { $("#osk").hidden = true; document.body.classList.remove("osk-open"); oskTarget = null; }
function openOsk(el) { oskTarget = el; oskDraw(); $("#osk").hidden = false; document.body.classList.add("osk-open"); setTimeout(() => el.scrollIntoView({ block: "center", behavior: "smooth" }), 50); }
function field(label, attrs) {
  const input = h("input", Object.assign({ type: "text", autocomplete: "off", autocapitalize: "off", spellcheck: "false", inputmode: "none" }, attrs));
  input.addEventListener("focus", () => openOsk(input));
  input.addEventListener("click", () => openOsk(input));
  return { el: h("label", { class: "f" }, h("span", {}, label), input), input };
}

/* ---------------------------------------------------------- routing ----- */
function go(path) { history.pushState({}, "", path); route(); }
window.addEventListener("popstate", route);

// Heartbeat: tells the box which page is open. The kiosk watchdog never restarts
// the browser while this is fresh, and a browser that is restarted anyway
// returns to this page (the server remembers it, including the tab and step).
let FIRST_PING = true, LEAVING = false;
function ping() {
  if (LEAVING) return Promise.resolve();
  const q = "?p=" + encodeURIComponent(location.pathname + location.search) + (FIRST_PING ? "&first=1" : "");
  FIRST_PING = false;
  return api("/api/ping" + q).catch(() => 0);
}
async function leaveToAlnasl() { LEAVING = true; await api("/api/ping?p=").catch(() => 0); }
setInterval(() => { if (location.pathname !== "/") ping(); }, 8000);
// The tab / step live in the address (and sessionStorage), so a reload comes back to the same place.
function qget(k) { return new URLSearchParams(location.search).get(k); }
function qset(obj) {
  const q = new URLSearchParams(location.search);
  for (const [k, v] of Object.entries(obj)) { if (v == null) q.delete(k); else q.set(k, v); }
  const s = q.toString();
  history.replaceState({}, "", location.pathname + (s ? "?" + s : ""));
  ping();
}

async function route() {
  const p = location.pathname;
  try {
    S = Object.assign(S, await api("/api/state"));
    LANG = S.lang || LANG;
  } catch (e) { shell("", [msg("bad", t("error")), h("button", { class: "btn", onclick: route }, t("retry"))], { langToggle: false }); return; }
  ping();
  compactStop();
  if (p === "/compact") return compactPage();
  if (p === "/setup") {
    WIZ = true;
    const st = Number(qget("step") ?? sessionStorage.getItem("wizstep") ?? 0);
    return wizard(st >= 0 && st < STEPS.length ? st : 0);
  }
  WIZ = false;
  if (p === "/settings" || p.startsWith("/settings/")) return settings(p.split("/")[2] || "");
  if (p === "/info") return infoPage();
  if (p === "/diag") return diagPage();
  if (p === "/help") return helpPage();
  return menu();
}

/* ------------------------------------------------- setup hotspot card -- */
// docs/captive-portal.md: while the box has its setup hotspot on, its screen says how to join it.
function hotspotCard() {
  const holder = h("div", { id: "hotspot-card" });
  api("/api/hotspot").then((s) => {
    if (!s.active || !s.ssid || !s.password) return;
    holder.replaceChildren(h("div", { class: "card" }, h("h2", {}, t("hs_title")), h("p", { class: "dim small" }, t("hs_d")),
      h("dl", { class: "kv" }, h("dt", {}, t("hs_ssid")), h("dd", {}, s.ssid), h("dt", {}, t("hs_pw")), h("dd", {}, s.password))));
  }).catch(() => 0);
  return holder;
}

/* ------------------------------------------------------ compact screen -- */
// v7.4 (docs/spi-screens.md): a panel on the pins shows this instead of the menu and the role's page. It has to
// work with nobody touching it: a QR code (always before setup, and for two minutes after every start), then the
// box's status, both refreshed by themselves. The server decides which (AlnaslSetup.Compact); a working stylus
// adds one Menu button, and the menu's tiles lead to the pages that already fit a small screen.
let CMP_TIMER = null, CMP_FORCE_QR = false;
function compactStop() { if (CMP_TIMER) { clearInterval(CMP_TIMER); CMP_TIMER = null; } }
function qrCanvas(rows) {
  const n = rows.length, quiet = 4;
  const W = window.innerWidth, H = window.innerHeight;   // portrait: the code on top, the text below
  const room = H > W ? Math.min(W - 16, Math.floor(H * 0.55)) : Math.min(H - 16, Math.floor(W * 0.58));
  const m = Math.max(1, Math.floor(room / (n + 2 * quiet)));
  const side = m * (n + 2 * quiet);
  const c = h("canvas", { class: "cmp-code", id: "cmp-code", width: side, height: side, "aria-label": "QR" });
  const g = c.getContext("2d");
  g.fillStyle = "#fff"; g.fillRect(0, 0, side, side);
  g.fillStyle = "#000";
  rows.forEach((r, y) => { for (let x = 0; x < n; x++) if (r[x] === "1") g.fillRect((x + quiet) * m, (y + quiet) * m, m, m); });
  return c;
}
const mmss = (s) => Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
function cmpMenuBtn(r) {
  return r.touch ? h("button", { class: "btn cmp-menu", id: "cmp-menu", onclick: () => compactMenu(r) }, t("cmp_menu")) : null;
}
function compactQr(r) {
  const q = r.qr || {};
  let title, lines;
  if (q.kind === "hotspot") {
    title = r.done ? t("cmp_qr_in") : t("cmp_qr_setup");
    lines = [h("p", { class: "cmp-big" }, q.ssid), h("p", { class: "dim" }, t("hs_pw") + ": ", h("b", { class: "cmp-pw" }, q.password))];
  } else if (q.kind === "url") {
    title = tf("cmp_qr_url", ROLE_NAME[canonRole(r.role) || "alnasl"]);
    lines = [h("p", { class: "cmp-big cmp-url" }, q.url.replace(/^http:\/\//, "").replace(/\/$/, ""))];
  } else {
    title = r.done ? t("cmp_qr_none") : t("cmp_qr_wait");
    lines = [h("p", { class: "dim" }, r.done ? t("cmp_qr_none_d") : t("cmp_qr_wait_d"))];
  }
  const foot = r.qr_left > 0 ? h("p", { class: "cmp-count", id: "cmp-count" }, tf("cmp_status_in", mmss(r.qr_left))) :
    CMP_FORCE_QR ? h("button", { class: "btn cmp-menu", id: "cmp-back", onclick: () => { CMP_FORCE_QR = false; compactDraw(); } }, t("cmp_status")) : null;
  return h("div", { class: "cmp cmp-qr", id: "cmp-qr" },
    q.kind === "none" ? h("div", { class: "cmp-code cmp-nocode" }, h("span", { class: "spin" })) : qrCanvas(r.rows || []),
    h("div", { class: "cmp-side" }, h("div", { class: "cmp-brand" }, "Alnasl"), h("h2", {}, title), lines, foot, CMP_FORCE_QR ? null : cmpMenuBtn(r)));
}
function cmpRow(ok, label, value) {
  return h("div", { class: "cmp-row" }, h("i", { class: "dot " + (ok ? "ok" : "bad") }), h("span", { class: "cmp-k" }, label), h("span", { class: "cmp-v" }, value));
}
function compactStats(r) {
  const role = canonRole(r.role) || "alnasl";
  const eth = (r.addrs || []).filter((a) => a.iface === "eth0").map((a) => a.ip);
  const wl = (r.addrs || []).filter((a) => a.iface === "wlan0").map((a) => a.ip);
  return h("div", { class: "cmp cmp-stats", id: "cmp-stats" },
    h("div", { class: "cmp-head" },
      h("div", {}, h("div", { class: "cmp-role" }, ROLE_NAME[role]), h("div", { class: "dim small" }, t("m_" + role + "_d"))),
      h("span", { class: "pill " + (r.role_up ? "ok" : "bad"), id: "cmp-app" }, r.role_up ? t("st_up") : t("st_down"))),
    h("div", { class: "cmp-rows" },
      cmpRow(eth.length > 0, t("ethernet"), eth.join("  ") || t("cmp_none")),
      cmpRow(wl.length > 0, t("wifi"), wl.join("  ") || (r.hotspot && r.hotspot.active ? t("cmp_hotspot") + " " + (r.hotspot.ssid || "") : t("cmp_none"))),
      r.role_port ? cmpRow(r.role_up, ROLE_NAME[role], r.role_up ? t("cmp_running") : t("cmp_stopped")) : null),
    h("div", { class: "cmp-foot" },
      h("span", { class: "dim small" }, (r.hostname || "") + (r.version ? "  |  v" + r.version : "") + (r.debug_ssh ? "  |  DEBUG SSH" : "")),
      cmpMenuBtn(r)));
}
async function compactDraw() {
  let r;
  try { r = await api("/api/compact" + (CMP_FORCE_QR ? "?qr=1" : "")); }
  catch (e) { app.replaceChildren(h("div", { class: "cmp" }, h("p", {}, h("span", { class: "spin" }), t("cmp_wait")))); return; }
  if (location.pathname !== "/compact" || !$("#modal").hidden) return;   // a menu or dialog is open: leave it be
  app.replaceChildren(r.view === "stats" ? compactStats(r) : compactQr(r));
}
function compactPage() {
  compactStop();
  closeOsk();
  compactDraw();
  CMP_TIMER = setInterval(compactDraw, 4000);
}
// The stylus menu: few, big tiles. Everything else (tournaments, updates, logs, a reset) is the phone's, via the QR.
function compactMenu(r) {
  const role = canonRole(r.role) || "alnasl";
  const done = (fn) => () => { close(); fn(); };
  const close = modal([h("div", { class: "cmp-tiles", id: "cmp-tiles" },
    tile(t("cmp_t_role"), ROLE_NAME[role], done(modeDialog)),
    role === "arkab" ? tile(t("cmp_t_pin"), "", done(pinPad)) : null,
    tile(t("wifi"), "", done(() => go("/settings/network?tab=wifi"))),
    tile(t("cmp_t_qr"), "", done(() => { CMP_FORCE_QR = true; compactDraw(); })),
    tile(t("touch"), "", done(() => go("/settings/touch"))),
    tile(t("power"), "", done(powerDialog))),
    h("button", { class: "btn cmp-menu", id: "cmp-close", onclick: () => close() }, t("close"))]);
}
// Arkab's remote PIN, digits only on this pad (the setup page takes any text); the same hand-over as there.
// Five keys wide and three high, so the whole pad fits a 320x240 panel with every key 60 px tall.
function pinPad() {
  let pin = "";
  const show = h("div", { class: "cmp-pin", id: "cmp-pin" }, "");
  const out = h("div", { class: "cmp-pin-out" });
  const draw = () => { show.textContent = pin.replace(/./g, "*") || "----"; ok.disabled = pin.length < 4; };
  const key = (k) => h("button", { class: "btn cmp-key", onclick: () => { if (pin.length < 12) { pin += k; draw(); } } }, k);
  const ok = h("button", { class: "btn primary cmp-key", id: "cmp-pin-ok", onclick: async () => {
    ok.disabled = true;
    try { await api("/api/compact/arkab-pin", { pin }); out.replaceChildren(msg("ok", t("cmp_pin_done"))); setTimeout(() => close(), 2500); }
    catch (e) { out.replaceChildren(msg("bad", errText(e))); draw(); }
  } }, "OK");
  const close = modal([h("div", { class: "cmp-pad", id: "cmp-pad" }, show, [..."1234567890"].map(key),
    h("button", { class: "btn cmp-key", onclick: () => { pin = pin.slice(0, -1); draw(); } }, "⌫"),
    h("button", { class: "btn cmp-key cmp-key-x", onclick: () => close() }, t("cancel")), ok), out]);
  draw();
}

/* -------------------------------------------------------------- menu ---- */
function tile(title, desc, fn) {
  return h("button", { class: "tile", onclick: fn }, h("div", { class: "t" }, title), h("div", { class: "d" }, desc));
}
// v7: the box is one of four things (docs/v7-plan.md). The first tile opens that thing's own page.
const ROLES = ["alnasl", "arkab", "polis", "nunki"];
const ROLE_NAME = { alnasl: "Alnasl", arkab: "Arkab", polis: "Polis", nunki: "Nunki" };
const ROLE_PORT = { alnasl: 4040, arkab: 4050, polis: 4061, nunki: 4062 };
const ALIAS = { master: "alnasl", slave: "arkab" };
const canonRole = (w) => { const r = ALIAS[w] || w; return ROLES.includes(r) ? r : null; };
function roleNow() { return (S.mode && (canonRole(S.mode.running_role) || canonRole(S.mode.running))) || "alnasl"; }
function roleChosen() { return (S.mode && (canonRole(S.mode.role) || canonRole(S.mode.mode))) || roleNow(); }
async function openAlnasl() {
  const r = roleNow();
  if (S.role_up) { await leaveToAlnasl(); location.href = "http://localhost:" + ROLE_PORT[r] + "/"; return; }
  const m = modal([h("p", {}, r === "alnasl" ? t("alnasl_down") : tf("role_down", ROLE_NAME[r])),
    h("button", { class: "btn", onclick: () => m() }, t("close"))]);
}
// An error from the server is a word; the sentence for it, when there is one.
const errText = (e) => (TX.en[e.message] ? t(e.message) : e.message);
// Compact screens (3.5 inch): the status line comes first. Hidden by CSS on big screens.
function statusStrip(r) {
  const addr = h("span", { class: "dim" }, "...");
  api("/api/sysinfo").then((i) => {
    const a = [].concat((i.net && i.net.eth0) || [], (i.net && i.net.wlan0) || []);
    addr.textContent = a.join("  ") || t("st_noaddr");
  }).catch(() => { addr.textContent = "-"; });
  return h("div", { class: "card statusbar", id: "status-strip" },
    h("span", { class: "pill " + (S.role_up ? "ok" : "bad") }, ROLE_NAME[r] + " " + (S.role_up ? t("st_up") : t("st_down"))), addr);
}
function menu() {
  const r = roleNow();
  shell(t("menu"), [statusStrip(r), hotspotCard(), h("div", { class: "grid" },
    tile(ROLE_NAME[r], t(r === "alnasl" ? "m_alnasl_d" : "m_" + r + "_d"), openAlnasl),
    tile(t("m_settings"), t("m_settings_d"), () => go("/settings")),
    tile(t("m_info"), t("m_info_d"), () => go("/info")),
    tile(t("m_help"), t("m_help_d"), () => go("/help")),
    tile(t("m_diag"), t("m_diag_d"), () => go("/diag")),
    tile(t("m_console"), t("m_console_d"), consoleDialog),
    tile(t("m_power"), t("m_power_d"), powerDialog))]);
}
function consoleDialog() {
  const out = h("div", {});
  const close = modal([h("h2", {}, t("console_title")), h("p", { class: "dim" }, t("console_d")),
    h("div", { class: "row" },
      h("button", { class: "btn primary", onclick: async () => { try { await api("/api/console/show", {}); out.replaceChildren(msg("ok", t("console_back"))); } catch (e) { out.replaceChildren(msg("bad", e.message)); } } }, t("console_show")),
      h("button", { class: "btn danger", onclick: stopScreenDialog }, t("console_stop")),
      h("button", { class: "btn", onclick: () => close() }, t("close"))), h("div", { style: "margin-top:14px" }, out)]);
  function stopScreenDialog() {
    out.replaceChildren(h("div", { class: "msg warn" }, h("p", {}, h("b", {}, t("console_stop_q"))), h("p", { class: "small" }, t("console_stop_note")),
      h("div", { class: "row" },
        h("button", { class: "btn danger", onclick: async () => { try { await api("/api/screen/stop", {}); out.replaceChildren(msg("ok", t("console_stopped"))); } catch (e) { out.replaceChildren(msg("bad", e.message)); } } }, t("yes_stop")),
        h("button", { class: "btn", onclick: () => out.replaceChildren() }, t("cancel")))));
  }
}
function powerDialog() {
  const close = modal([h("h2", {}, t("power")), h("p", { class: "dim" }, t("sure")),
    h("div", { class: "row" },
      h("button", { class: "btn primary", onclick: () => doPower("reboot") }, t("restart")),
      h("button", { class: "btn danger", onclick: () => doPower("poweroff") }, t("shutdown")),
      h("button", { class: "btn", onclick: () => close() }, t("cancel")))]);
  // v6: the boot screen says "Restarting" / "Shutting down" from here to the dark (or back).
  async function doPower(a) { await api("/api/power", { action: a }).catch(() => 0); location.href = "/screen"; }
}

/* -------------------------------------------------------- info page ----- */
async function infoPage() {
  shell(t("info"), busy("..."), { home: true });
  const i = await api("/api/sysinfo");
  const rows = [
    [t("hostname"), i.hostname], [t("model"), i.model], [t("serial"), i.serial], [t("os"), i.os], [t("kernel"), i.kernel],
    [t("image"), i.image_release && i.image_release.version ? "v" + i.image_release.version + (i.image_release.slot ? "  (" + t("upd_slot") + " " + i.image_release.slot + ")" : "") : i.image],
    [t("alnasl_v"), i.alnasl], [t("uptime"), fmtUp(i.uptime)],
    [t("memory"), fmtBytes(i.mem_avail) + " " + t("free") + " / " + fmtBytes(i.mem_total)],
    [t("disk"), fmtBytes(i.disk_free) + " / " + fmtBytes(i.disk_total)], [t("temp"), i.temp_c == null ? "-" : i.temp_c + " °C"],
    [t("ethernet"), (i.net.eth0 || []).join(", ") || "-"], [t("wifi"), (i.net.wlan0 || []).join(", ") || "-"], [t("disp_path"), i.display],
  ];
  shell(t("info"), h("div", { class: "card" }, h("dl", { class: "kv" }, rows.map(([k, v]) => [h("dt", {}, k), h("dd", {}, v)]))), { home: true });
}

/* ------------------------------------------------------ settings -------- */
/* ------------------------------------------------------ diagnostics ------- */
async function diagPage() {
  shell(t("diag"), busy(t("d_loading")), { home: true });
  let d;
  try { d = await api("/api/diag"); } catch (e) { shell(t("diag"), msg("bad", e.message), { home: true }); return; }
  const scanOut = h("div", {}), saveOut = h("div", {}), logs = h("div", {}, busy(t("d_loading")));
  const mark = (ok) => h("span", { class: "pill " + (ok === true ? "ok" : ok === false ? "bad" : "") }, ok === true ? "OK" : ok === false ? "FAIL" : "?");
  const verdict = h("div", { class: "card" }, h("h2", {}, t("d_wifi_q")),
    msg(d.verdict === "ok" ? "ok" : "bad", t("v_" + d.verdict)),
    d.checks.map((c) => h("div", { class: "chk" }, mark(c.ok), h("b", {}, t("c_" + c.id)), h("span", { class: "dim small" }, c.detail))));
  const bScan = h("button", { class: "btn primary", onclick: async () => {
    bScan.disabled = true; scanOut.replaceChildren(busy(t("scanning")));
    try {
      const r = await api("/api/diag/scan");
      scanOut.replaceChildren(h("div", { class: "card" }, h("h2", {}, t("d_scan_out")),
        h("p", {}, (r.networks || []).length + " " + t("d_scan_found") + (r.elapsed != null ? " (" + r.elapsed + " s)" : "")),
        h("pre", { class: "raw" }, r.raw || r.detail || "")));
    } catch (e) { scanOut.replaceChildren(msg("bad", e.message)); }
    bScan.disabled = false;
  } }, t("d_test_scan"));
  const bSave = h("button", { class: "btn", onclick: async () => {
    bSave.disabled = true; saveOut.replaceChildren(busy(t("d_loading")));
    try { const r = await api("/api/diag/save", {}); saveOut.replaceChildren(msg("ok", t("d_saved").replace("%s", r.file))); }
    catch (e) { saveOut.replaceChildren(msg("bad", e.message)); }
    bSave.disabled = false;
  } }, t("d_save"));
  const sections = d.sections.map((s) => h("details", { class: "card" }, h("summary", {}, t("d_" + s.id)), h("pre", { class: "raw" }, s.text)));
  shell(t("diag"), [h("div", { class: "row", style: "margin-bottom:16px" }, bScan, bSave, h("button", { class: "btn", onclick: diagPage }, t("d_refresh"))),
    scanOut, saveOut, verdict, sections, h("h2", { style: "margin-top:22px" }, t("d_logs")), logs], { home: true });
  try {
    const j = await api("/api/diag/journals");
    logs.replaceChildren(...j.journals.map((u) => {
      const pre = h("pre", { class: "raw" }, u.text || "(empty)");
      const det = h("details", { class: "card" }, h("summary", {}, u.unit), pre);
      det.addEventListener("toggle", () => { if (det.open) pre.scrollTop = pre.scrollHeight; });
      return det;
    }));
  } catch (e) { logs.replaceChildren(msg("bad", e.message)); }
}

/* ------------------------------------------------------------ get help ---- */
// The report goes out over HTTPS and a six-digit code comes back. Outbound only.
const fmtCode = (c) => String(c).replace(/^(\d{3})(\d{3})$/, "$1 $2");
const fmtWhen = (iso) => { const d = new Date(iso); return isNaN(d) ? iso : d.toLocaleString(LANG === "nl" ? "nl-BE" : "en-GB", { dateStyle: "medium", timeStyle: "short" }); };
function helpCode(r) {
  return h("div", { class: "card center", id: "help-code" },
    h("div", { class: "dim" }, t("help_code_label")),
    h("div", { class: "helpcode", id: "help-code-value" }, fmtCode(r.code)),
    h("p", {}, t("help_read").replace("%s", fmtWhen(r.expires_at))));
}
async function helpPage() {
  shell(t("m_help"), busy("..."), { home: true });
  let st; try { st = await api("/api/help"); } catch (e) { shell(t("m_help"), msg("bad", e.message), { home: true }); return; }
  const out = h("div", {}), last = h("div", {});
  const btn = h("button", { class: "btn primary", id: "help-send", onclick: send }, t("help_send"));
  if (st.last) last.replaceChildren(h("p", { class: "dim" }, t("help_last")), helpCode(st.last));
  async function send() {
    btn.disabled = true; last.replaceChildren(); out.replaceChildren(busy(t("help_sending")));
    try {
      const r = await api("/api/help/send", {});
      if (r.ok) { out.replaceChildren(helpCode(r)); }
      else out.replaceChildren(msg("bad", t("help_err_" + r.error) || t("help_err_server_error")));
    } catch (e) { out.replaceChildren(msg("bad", t("help_err_server_error"))); }
    btn.disabled = false; btn.textContent = t("help_again");
  }
  shell(t("m_help"), [h("div", { class: "card" }, h("p", {}, t("help_d")), h("div", { class: "row" }, btn)), out, last], { home: true });
}
function helpSettings() {
  const f = field(t("help_url"), { value: "", id: "help-url" });
  const out = h("div", {});
  api("/api/help").then((st) => { f.input.value = st.url; }).catch(() => 0);
  async function save(url) {
    try { const st = await api("/api/help/url", { url }); f.input.value = st.url; out.replaceChildren(msg("ok", t("help_url_saved"))); }
    catch (e) { out.replaceChildren(msg("bad", e.message === "bad_url" ? t("help_url_bad") : e.message)); }
  }
  sub(t("m_help"), [h("p", { class: "dim" }, t("help_url_d")), f.el, out,
    h("div", { class: "row" }, h("button", { class: "btn primary", id: "help-url-save", onclick: () => save(f.input.value) }, t("save")),
      h("button", { class: "btn", onclick: () => save("") }, t("help_default")))]);
}

/* ---------------------------------------------------- system updates ---- */
// v6 A/B. The box's own train (v6) updates by itself at night; another train (v7) only through
// "Upgrade to v7" and its confirmation here, or Arkab's page, or alnasl-upgrade.txt on the SD card.
let UPD_TIMER = null;
function updPage() {
  const holder = h("div", { id: "upd" }, busy("..."));
  const urlF = field(t("upd_url"), { value: "", id: "upd-url" });
  const urlOut = h("div", {});
  async function saveUrl(url) {
    try { const st = await api("/api/system/url", { url }); urlF.input.value = st.index_url || ""; urlOut.replaceChildren(msg("ok", t("help_url_saved"))); }
    catch (e) { urlOut.replaceChildren(msg("bad", e.message === "bad_url" ? t("help_url_bad") : e.message)); }
  }
  const urlCard = h("details", { class: "card", id: "upd-url-card" }, h("summary", {}, t("upd_url")), h("p", { class: "dim small" }, t("upd_url_d")), urlF.el, urlOut,
    h("div", { class: "row" }, h("button", { class: "btn primary", id: "upd-url-save", onclick: () => saveUrl(urlF.input.value) }, t("save")),
      h("button", { class: "btn", onclick: () => saveUrl("") }, t("help_default"))));
  sub(t("upd"), [holder, urlCard]);
  let first = true;
  const errText = (e) => t("upd_err_" + e.message) !== "upd_err_" + e.message ? t("upd_err_" + e.message) : e.message;
  async function draw() {
    if (!document.body.contains(holder)) { clearInterval(UPD_TIMER); UPD_TIMER = null; return; }
    let s;
    try { s = await api("/api/system"); } catch (e) { holder.replaceChildren(msg("bad", e.message)); return; }
    if (first) { urlF.input.value = s.index_url || ""; first = false; }
    const cards = [];
    const ver = s.version ? "v" + s.version : "?";
    cards.push(h("div", { class: "card" }, h("dl", { class: "kv" },
      h("dt", {}, t("upd_this")), h("dd", { id: "upd-version" }, ver + "  ", h("span", { class: "pill" }, s.train || "?"), s.slot ? h("span", { class: "dim small" }, "  " + t("upd_slot") + " " + s.slot) : null),
      h("dt", {}, t("upd_checked")), h("dd", {}, s.checked_at || t("upd_never")),
      h("dt", {}, t("upd_last")), h("dd", { id: "upd-last" }, s.last_result
        ? [h("span", { class: "pill " + (s.last_result.outcome === "ok" ? "ok" : s.last_result.outcome === "rolled_back" || s.last_result.outcome === "failed" ? "bad" : "") },
            t("upd_r_" + s.last_result.outcome)), " " + s.last_result.when, h("div", { class: "dim small" }, s.last_result.note)]
        : t("upd_none_yet"))),
      s.ab && s.updates_on ? h("p", { class: "note" }, tf("upd_rule", s.train)) : null));
    if (!s.ab) { cards.push(msg("warn", t("upd_not_ab"))); holder.replaceChildren(...cards); return; }
    if (!s.updates_on) cards.push(msg("warn", t("upd_off") + (s.off_reason ? " (" + s.off_reason + ")" : "")));
    const out = h("div", { id: "upd-out" });
    if (s.request_error) out.replaceChildren(msg("warn", t("upd_err_" + s.request_error)));
    if (s.trial) {
      cards.push(msg("warn", tf("upd_trial", s.trial.version || "?")));
    } else if (s.busy) {
      const ph = t("upd_ph_" + s.phase) !== "upd_ph_" + s.phase ? t("upd_ph_" + s.phase) : s.phase;
      const pct = s.progress != null ? s.progress : null;
      cards.push(h("div", { class: "card", id: "upd-busy" }, h("p", {}, h("span", { class: "spin" }), ph + (pct != null ? " " + pct + "%" : "")),
        pct != null ? h("div", { class: "pbar" }, h("i", { style: "width:" + pct + "%" })) : null));
    } else if (s.updates_on) {
      const chk = h("button", { class: "btn", id: "upd-check", onclick: async () => {
        chk.disabled = true; out.replaceChildren(busy(t("upd_checking")));
        try { await api("/api/system/check", {}); await sleep(2500); } catch (e) { out.replaceChildren(msg("bad", errText(e))); }
        draw();
      } }, t("upd_check"));
      const same = s.available;
      const own = h("div", { class: "card" });
      if (s.phase === "staged") own.append(msg("ok", t("upd_ph_staged")));
      if (same) {
        own.append(h("p", {}, h("b", {}, tf("upd_newer", same.version))), same.notes ? h("p", { class: "dim small" }, same.notes) : "",
          h("div", { class: "row" }, h("button", { class: "btn primary", id: "upd-install", onclick: () => confirmDlg(tf("upd_install_q", same.version), t("upd_install_d"),
            t("upd_yes_install"), () => api("/api/system/install", { confirm: "INSTALL" })) }, t("upd_install")), chk));
      } else own.append(h("p", {}, t("upd_uptodate")), h("div", { class: "row" }, chk));
      cards.push(own);
      if (s.offer) {
        const o = s.offer;
        cards.push(h("div", { class: "card offer", id: "upd-offer" }, h("h2", {}, tf("upd_offer", o.train)), h("p", { class: "dim" }, t("upd_offer_d")),
          o.notes ? h("p", { class: "small" }, o.notes) : null,
          h("button", { class: "btn primary", id: "upd-upgrade", onclick: () => confirmDlg(tf("upd_upgrade_q", o.train), tf("upd_upgrade_d", "v" + o.version, o.train),
            tf("upd_yes_upgrade", o.train), () => api("/api/system/upgrade", { train: o.train, confirm: "UPGRADE" })) }, tf("upd_upgrade", o.train))));
      } else if (s.offer_blocked) {
        cards.push(msg("warn", tf("upd_blocked", "v" + (Number(String(s.train).slice(1)) + 1), s.offer_blocked)));
      }
    }
    cards.push(out);
    holder.replaceChildren(...cards);
    function confirmDlg(q, d, yes, call) {
      const o2 = h("div", {});
      const b = h("button", { class: "btn primary", id: "upd-confirm", onclick: async () => {
        b.disabled = true;
        try { await call(); close(); await sleep(1500); draw(); } catch (e) { o2.replaceChildren(msg("bad", errText(e))); b.disabled = false; }
      } }, yes);
      const close = modal([h("h2", {}, q), h("p", { class: "dim" }, d), h("div", { class: "row" }, b, h("button", { class: "btn", onclick: () => close() }, t("cancel"))), o2]);
    }
  }
  clearInterval(UPD_TIMER);
  UPD_TIMER = setInterval(draw, 3000);
  draw();
}

function settings(sub) {
  const subs = { network: netPage, keyboard: kbdPage, services: svcPage, display: dispPage, help: helpSettings, updates: updPage,
    printers: printersPage, sound: soundPage, touch: touchPage };
  if (!sub || !subs[sub]) {
    return shell(t("settings"), [
      h("div", { class: "grid" },
        tile(t("network"), "", () => go("/settings/network")),
        tile(t("keyboard"), "", () => go("/settings/keyboard")),
        tile(t("services"), "", () => go("/settings/services")),
        tile(t("display"), "", () => go("/settings/display")),
        tile(t("m_help"), "", () => go("/settings/help")),
        tile(t("upd"), t("upd_tile"), () => go("/settings/updates")),
        roleNow() === "polis" ? tile(t("printers"), t("printers_tile"), () => go("/settings/printers")) : null,
        roleNow() === "nunki" ? tile(t("sound"), t("sound_tile"), () => go("/settings/sound")) : null,
        S.touch === "xpt2046" ? tile(t("touch"), t("touch_tile"), () => go("/settings/touch")) : null),
      h("p", { class: "dim", id: "role-now", style: "margin-top:22px" }, tf("role_now", ROLE_NAME[roleNow()])),
      h("div", { class: "row" }, h("button", { class: "btn sm", onclick: rerun }, t("rerun")),
        h("button", { class: "btn sm", id: "mode-open", onclick: modeDialog }, t("role_change")),
        h("button", { class: "btn sm danger", id: "reset-open", onclick: resetDialog }, t("reset")))], { home: true });
  }
  subs[sub](false);
}
// Erase the box back to new (alnasl-reset). No typing on a touch screen: the button is held for 3 s,
// a bar fills while it is; letting go before the end cancels. Then the boot screen shows the steps.
function resetDialog() {
  const HOLD = 3000;
  const out = h("div", {});
  const bar = h("i", {});
  const btn = h("button", { class: "btn danger hold", id: "reset-hold" }, bar, h("span", {}, t("reset_hold")));
  let timer = null;
  const start = (e) => {
    e.preventDefault();
    if (timer || btn.disabled) return;
    bar.style.transition = "width " + HOLD + "ms linear"; bar.style.width = "100%";
    timer = setTimeout(fire, HOLD);
  };
  const stop = () => {
    if (!timer) return;
    clearTimeout(timer); timer = null;
    bar.style.transition = "width .2s ease"; bar.style.width = "0";
  };
  async function fire() {
    timer = null; btn.disabled = true;
    try { await api("/api/reset", { confirm: "RESET" }); location.href = "/screen"; }
    catch (e) { out.replaceChildren(msg("bad", e.message)); btn.disabled = false; bar.style.width = "0"; }
  }
  btn.addEventListener("pointerdown", start);
  ["pointerup", "pointerleave", "pointercancel"].forEach((ev) => btn.addEventListener(ev, stop));
  btn.addEventListener("contextmenu", (e) => e.preventDefault());  // a long touch is not a right click here
  const close = modal([h("h2", {}, t("reset")), h("p", {}, t("reset_d")), h("p", { class: "dim small" }, t("reset_keep")),
    h("div", { class: "row" }, btn, h("button", { class: "btn", onclick: () => close() }, t("cancel"))), out]);
}
// What this box is. The role is a file; the switch is that file and a restart (the boot screen shows it).
function roleItem(id, sel, onpick) {
  return h("button", { class: "item" + (sel ? " sel" : ""), id: "role-" + id, onclick: onpick },
    h("span", { class: "grow", style: "white-space:normal" }, h("strong", {}, ROLE_NAME[id]), h("br"), h("span", { class: "dim" }, t("role_" + id + "_d"))));
}
function modeDialog() {
  const now = roleNow();
  let to = null;
  const out = h("div", {});
  const ask = h("div", {});
  const list = h("div", { class: "list" }, ROLES.map((id) => {
    const it = roleItem(id, id === now, () => {
      [...list.children].forEach((c) => c.classList.remove("sel")); it.classList.add("sel");
      to = id === now ? null : id;
      ask.replaceChildren(...(to ? [h("p", {}, tf("role_switch_d", ROLE_NAME[now], ROLE_NAME[to]))] : []));
      yes.disabled = !to;
    });
    return it;
  }));
  const yes = h("button", { class: "btn primary", id: "mode-yes", disabled: true, onclick: async () => {
    if (!to) return;
    yes.disabled = true;
    try { await api("/api/mode", { mode: to, confirm: "SWITCH", by: "menu" }); location.href = "/screen"; }
    catch (e) { out.replaceChildren(msg("bad", errText(e))); yes.disabled = false; }
  } }, t("role_yes"));
  const close = modal([h("h2", {}, t("role_change")), list, ask,
    h("div", { class: "row" }, yes, h("button", { class: "btn", onclick: () => close() }, t("cancel"))), out]);
}
async function rerun() { await api("/api/reopen", {}); sessionStorage.setItem("wizstep", "0"); sessionStorage.removeItem("wizmode"); WMODE = null; go("/setup"); }
function sub(title, body, back) {
  shell(title, [h("p", {}, h("button", { class: "btn sm", onclick: () => go("/settings") }, "← " + t("settings"))), h("h1", {}, title), body], { home: true });
}

/* ---------------------------------------------------------- keyboard ----- */
function kbdPage(wiz, nav) {
  const cur = (S.keyboard && S.keyboard.KBD_ID) || "be";
  const status = h("div", {});
  const test = field(t("kbd_test"), { value: "" });
  const list = h("div", { class: "list" }, S.layouts.map((l) => {
    const it = h("button", { class: "item" + (l.id === cur ? " sel" : ""), onclick: async () => {
      try {
        await api("/api/keyboard", { layout: l.id, restart_kiosk: !wiz });
        S.keyboard.KBD_ID = l.id;
        [...list.children].forEach((c) => c.classList.remove("sel")); it.classList.add("sel");
        status.replaceChildren(msg("ok", wiz ? t("kbd_saved_w") : t("kbd_saved")));
      } catch (e) { status.replaceChildren(msg("bad", e.message)); }
    } }, h("span", { class: "grow" }, l.label), l.id === "be" ? h("span", { class: "pill" }, LANG === "nl" ? "standaard" : "default") : null);
    return it;
  }));
  const body = [h("p", { class: "dim" }, t("keyboard_d")), list, status, wiz ? null : test.el];
  if (wiz) return body;
  sub(t("keyboard"), body);
}

/* ---------------------------------------------------------- services ----- */
function svcPage(wiz) {
  const sv = S.services;
  // The role's own app is not switched here, except Alnasl (as in v6); the screen is every role's.
  const defs = (wiz ? WMODE : roleNow()) === "alnasl" ? [["alnasl", "s_alnasl", "s_alnasl_d"], ["kiosk", "s_kiosk", "s_kiosk_d"]] : [["kiosk", "s_kiosk", "s_kiosk_d"]];
  const boxes = {};
  const warn = h("div", {});
  const status = h("div", {});
  const rows = defs.map(([id, a, b]) => {
    boxes[id] = h("input", { type: "checkbox", checked: sv[id] && sv[id].enabled, onchange: showWarn });
    return h("label", { class: "sw" }, h("div", { class: "grow" }, h("div", {}, t(a)), h("div", { class: "dim small" }, t(b))), boxes[id]);
  });
  function showWarn() {
    const w = [];
    if (!boxes.kiosk.checked) w.push(msg("warn", t("kiosk_warn")));
    warn.replaceChildren(...w);
  }
  const saveBtn = h("button", { class: "btn primary", onclick: save }, wiz ? t("next") : t("save"));
  async function save() {
    try {
      const body = { kiosk: boxes.kiosk.checked };
      if (boxes.alnasl) body.alnasl = boxes.alnasl.checked;
      S.services = await api("/api/services", body);
      status.replaceChildren(msg("ok", t("kbd_saved_w")));
      return true;
    } catch (e) { status.replaceChildren(msg("bad", e.message)); return false; }
  }
  const body = [h("p", { class: "dim" }, t("services_d")), h("div", { class: "card" }, rows), warn, status, wiz ? null : saveBtn];
  showWarn();
  if (wiz) { body.save = save; return body; }
  sub(t("services"), body);
}

/* ---------------------------------------------------------- printers ----- */
// Polis prints through CUPS; this page is CUPS's printer list, as small as it can be (docs/v7-plan.md).
async function printersPage() {
  const list = h("div", {});
  const status = h("div", {});
  const usb = h("div", {});
  async function draw(r) {
    try { r = r || await api("/api/printers"); } catch (e) { status.replaceChildren(msg("bad", errText(e))); return; }
    const act = (path, name, okText) => async () => {
      try { const j = await api(path, { name }); status.replaceChildren(msg("ok", okText || t("sound_saved"))); if (j.printers) draw(j); }
      catch (e) { status.replaceChildren(msg("bad", errText(e))); }
    };
    list.replaceChildren(
      r.cups ? null : msg("warn", t("printer_cups_off")),
      r.printers.length ? h("div", { class: "list" }, r.printers.map((p) => h("div", { class: "item wrap", id: "printer-" + p.name },
        h("span", { class: "grow" }, h("strong", {}, p.name), " ", p.default ? h("span", { class: "pill" }, t("printer_default")) : null,
          h("br"), h("span", { class: "dim small" }, p.uri)),
        h("span", { class: "row" },
          h("button", { class: "btn sm", onclick: act("/api/printers/test", p.name, t("printer_test_sent")) }, t("printer_test")),
          p.default ? null : h("button", { class: "btn sm", onclick: act("/api/printers/default", p.name) }, t("printer_make_default")),
          h("button", { class: "btn sm danger", onclick: act("/api/printers/remove", p.name) }, t("printer_remove"))))))
        : h("p", { class: "dim" }, t("printers_none")));
  }
  const addr = field(t("printer_addr"), { value: "", id: "printer-addr" });
  const name = field(t("printer_name"), { value: "", id: "printer-name" });
  const addBtn = h("button", { class: "btn primary", id: "printer-add", onclick: async () => {
    addBtn.disabled = true; status.replaceChildren(busy(t("adding")));
    try { const r = await api("/api/printers/add", { address: addr.input.value.trim(), name: name.input.value.trim() }); closeOsk(); status.replaceChildren(msg("ok", t("sound_saved"))); draw(r); }
    catch (e) { status.replaceChildren(msg("bad", errText(e))); }
    addBtn.disabled = false;
  } }, t("add"));
  const usbBtn = h("button", { class: "btn", id: "printer-usb-scan", onclick: async () => {
    usb.replaceChildren(busy(t("printer_usb_scan")));
    try {
      const r = await api("/api/printers/usb");
      usb.replaceChildren(r.usb.length ? h("div", { class: "list" }, r.usb.map((u) => h("button", { class: "item", onclick: async () => {
        status.replaceChildren(busy(t("adding")));
        try { draw(await api("/api/printers/add", { usb: u })); status.replaceChildren(msg("ok", t("sound_saved"))); } catch (e) { status.replaceChildren(msg("bad", errText(e))); }
      } }, h("span", { class: "grow" }, decodeURIComponent(u.slice(6).split("?")[0])), h("span", { class: "pill" }, t("add")))))
        : h("p", { class: "dim" }, t("printer_usb_none")));
    } catch (e) { usb.replaceChildren(msg("bad", errText(e))); }
  } }, t("printer_usb_scan"));
  sub(t("printers"), [h("p", { class: "dim" }, t("printers_d")), list, status,
    h("div", { class: "card" }, h("h2", {}, t("printer_add")), addr.el, name.el, addBtn),
    h("div", { class: "card" }, h("h2", {}, t("printer_usb")), usbBtn, usb)]);
  draw();
}

/* ------------------------------------------------------------- sound ----- */
async function soundPage() {
  const status = h("div", {});
  let r;
  try { r = await api("/api/sound"); } catch (e) { sub(t("sound"), [msg("bad", errText(e))]); return; }
  const outs = r.outputs.length ? r.outputs : [];
  const list = h("div", { class: "list" }, outs.map((o) => {
    const it = h("button", { class: "item" + (o === r.output ? " sel" : ""), id: "out-" + o, onclick: async () => {
      try { r = await api("/api/sound", { output: o }); [...list.children].forEach((c) => c.classList.remove("sel")); it.classList.add("sel"); status.replaceChildren(msg("ok", t("sound_saved"))); }
      catch (e) { status.replaceChildren(msg("bad", errText(e))); }
    } }, h("span", { class: "grow" }, t("out_" + o)));
    return it;
  }));
  const val = h("b", {}, r.volume + "%");
  const vol = h("input", { type: "range", min: "0", max: "100", step: "5", value: String(r.volume), id: "volume", class: "range",
    oninput: () => { val.textContent = vol.value + "%"; },
    onchange: async () => { try { r = await api("/api/sound", { volume: Number(vol.value) }); status.replaceChildren(msg("ok", t("sound_saved"))); } catch (e) { status.replaceChildren(msg("bad", errText(e))); } } });
  const test = h("button", { class: "btn primary", id: "sound-test", onclick: async () => {
    try { await api("/api/sound/test", {}); status.replaceChildren(msg("ok", t("sound_testing"))); } catch (e) { status.replaceChildren(msg("bad", errText(e))); }
  } }, t("sound_test"));
  sub(t("sound"), [h("p", { class: "dim" }, t("sound_d")), outs.length ? list : msg("warn", t("sound_none")),
    h("div", { class: "card" }, h("h2", {}, t("volume")), h("div", { class: "row" }, vol, val)), h("div", { class: "row" }, test), status]);
}

/* ----------------------------------------------------------- display ----- */
function dispPage() {
  const sel = h("select", {}, [75, 100, 125, 150, 200, 250].map((v) => h("option", { value: v, selected: String(v) === String(S.scale) }, v + " %")));
  const st = h("div", {});
  const resCard = h("div", { class: "card", id: "res-card" }, busy("..."));
  sub(t("display"), [h("div", { class: "card" }, h("label", { class: "f" }, h("span", {}, t("scale")), sel), h("p", { class: "note" }, t("scale_note")),
    h("button", { class: "btn primary", onclick: async () => { try { await api("/api/scale", { scale: Number(sel.value) }); S.scale = sel.value; st.replaceChildren(msg("ok", t("kbd_saved"))); } catch (e) { st.replaceChildren(msg("bad", e.message)); } } }, t("save"))), st, resCard]);
  resolutionCard(resCard);
}
// Resolution: the list is what the connected screen reports; a change is live, then confirmed within a
// few seconds or undone by the box itself (the server owns the timer, so a black screen still comes back).
async function resolutionCard(card) {
  let r;
  try { r = await api("/api/resolution"); } catch (e) { card.replaceChildren(msg("bad", e.message)); return; }
  if (r.pending) resKeepDialog(r.seconds_left || r.confirm_seconds, () => resolutionCard(card));
  if (r.forced) { card.replaceChildren(h("h2", {}, t("res")), h("p", { class: "dim", id: "res-forced" }, t("res_forced"))); return; }
  if (!r.modes.length) { card.replaceChildren(h("h2", {}, t("res")), h("p", { class: "dim" }, t("res_none"))); return; }
  const sel = h("select", { id: "res-select" }, [h("option", { value: "auto", selected: r.setting === "auto" }, t("res_auto") + (r.preferred ? " - " + r.preferred : "")),
    ...r.modes.map((m, i) => h("option", { value: m, selected: r.setting === m }, m + (i === 0 ? " (" + t("res_pref") + ")" : "")))]);
  const out = h("div", {});
  const go1 = h("button", { class: "btn primary", id: "res-apply", onclick: async () => {
    go1.disabled = true; out.replaceChildren(busy(t("res_applying")));
    try {
      const j = await api("/api/resolution", { mode: sel.value });
      out.replaceChildren();
      if (j.pending) resKeepDialog(j.confirm_seconds, () => resolutionCard(card)); else out.replaceChildren(msg("ok", t("res_later")));
    } catch (e) { out.replaceChildren(msg("bad", e.message)); }
    go1.disabled = false;
  } }, t("res_apply"));
  card.replaceChildren(h("h2", {}, t("res")), h("label", { class: "f" }, h("span", {}, t("res_current") + ": " + (r.setting === "auto" ? t("res_auto") : r.setting) + (r.connector ? "  (" + r.connector + ")" : "")), sel),
    h("p", { class: "note" }, t("res_note")), go1, out);
}
function resKeepDialog(secs, redraw) {
  let left = secs; const cd = h("b", { id: "res-countdown" }, left + t("seconds"));
  let done = false;
  const finish = (fn) => { if (done) return; done = true; clearInterval(timer); close(); fn && fn(); };
  const timer = setInterval(() => { left -= 1; cd.textContent = Math.max(left, 0) + t("seconds"); if (left <= -3) finish(redraw); }, 1000);
  const close = modal([h("h2", {}, t("res_keep_q")), h("p", { class: "dim" }, t("res_keep_d") + " ", cd),
    h("div", { class: "row" },
      h("button", { class: "btn primary", id: "res-keep", onclick: async () => { await api("/api/resolution/confirm", {}).catch(() => 0); finish(redraw); } }, t("keep")),
      h("button", { class: "btn", id: "res-undo", onclick: async () => { await api("/api/resolution/undo", {}).catch(() => 0); finish(redraw); } }, t("revert")))]);
}

/* ------------------------------------------------------ touch screen ----- */
// v7.3: a small stylus screen, on the pins or a 3.5-inch HDMI one (alnasl-screen.txt). Four crosses, one at a time; where the stylus landed goes to
// the box, which works out the calibration, keeps it on the data partition and restarts the screen with it.
async function touchPage() {
  const card = h("div", { class: "card", id: "touch-card" }, busy("..."));
  sub(t("touch"), card);
  let r;
  try { r = await api("/api/touch"); } catch (e) { card.replaceChildren(msg("bad", e.message)); return; }
  if (r.touch !== "xpt2046") { card.replaceChildren(h("p", { class: "dim" }, t("touch_off"))); return; }
  const out = h("div", { id: "touch-out" });
  const ok = r.status === "ready";
  const reset = r.stored ? h("button", { class: "btn", id: "touch-reset", onclick: async () => {
    try { await api("/api/touch/reset", {}); out.replaceChildren(msg("ok", t("touch_reset_done"))); } catch (e) { out.replaceChildren(msg("bad", e.message)); }
  } }, t("touch_reset")) : null;
  card.replaceChildren(h("p", { class: "dim" }, t("touch_d")),
    msg(ok ? "ok" : "bad", TX.en["touch_st_" + r.status] ? t("touch_st_" + r.status) : r.status),
    h("p", { class: "dim small" }, tf("touch_now", r.rotate, r.mode, t("touch_src_" + (r.source || "default")))),
    h("div", { class: "row" }, ok ? h("button", { class: "btn primary", id: "touch-cal", onclick: () => calibrator(out) }, t("touch_cal")) : null, reset),
    out);
}
function calibrator(out) {
  const TGT = [[0.15, 0.15], [0.85, 0.15], [0.85, 0.85], [0.15, 0.85]];
  const samples = [];
  const cross = h("div", { class: "calib-x" });
  const hint = h("div", { class: "calib-hint" });
  const ov = h("div", { class: "calib", id: "touch-calib" }, cross, hint);
  let timer = 0, last = -1e9;
  const place = () => { const [x, y] = TGT[samples.length]; cross.style.left = (x * 100) + "%"; cross.style.top = (y * 100) + "%"; hint.textContent = tf("touch_tap_n", samples.length + 1, TGT.length); };
  const close = () => { clearTimeout(timer); ov.remove(); };
  const idle = () => { clearTimeout(timer); timer = setTimeout(() => { close(); out.replaceChildren(msg("bad", t("touch_timeout"))); }, 30000); };
  ov.addEventListener("pointerdown", async (e) => {
    e.preventDefault();
    if (e.timeStamp - last < 500) return;   // a resistive panel bounces; one tap is one tap
    last = e.timeStamp;
    const [x, y] = TGT[samples.length];
    samples.push([x, y, e.clientX / window.innerWidth, e.clientY / window.innerHeight]);
    if (samples.length < TGT.length) { place(); idle(); return; }
    close();
    out.replaceChildren(busy(t("touch_saving")));
    try { await api("/api/touch/calibrate", { samples }); out.replaceChildren(msg("ok", t("touch_saved"))); }
    catch (err) { out.replaceChildren(msg("bad", err.message)); }
  });
  document.body.append(ov); place(); idle();
}

/* ----------------------------------------------------------- network ----- */
let NETTAB = null;
function netPage(wiz) {
  const holder = h("div", {});
  const tabs = h("div", { class: "tabs" });
  const defs = [["status", t("status")], ["wifi", t("wifi")], ["ip", t("ip_settings")]];
  if (NETTAB === null) {  // first draw after a (re)load: the address, then sessionStorage, say which tab was open
    let want = qget("tab");
    try { want = want || sessionStorage.getItem("nettab"); } catch (e) { /* storage may be unavailable */ }
    NETTAB = defs.some(([id]) => id === want) ? want : "status";
  }
  async function draw() {
    try { sessionStorage.setItem("nettab", NETTAB); } catch (e) { /* ignore */ }
    qset({ tab: NETTAB });
    tabs.replaceChildren(...defs.map(([id, label]) => h("button", { class: "tab" + (NETTAB === id ? " on" : ""), onclick: () => { NETTAB = id; draw(); } }, label)));
    holder.replaceChildren(busy("..."));
    try {
      holder.replaceChildren(await ({ status: tabStatus, wifi: tabWifi, ip: tabIp })[NETTAB](draw));
    } catch (e) { holder.replaceChildren(msg("bad", e.message)); }
  }
  draw();
  const body = [tabs, holder];
  if (wiz) return body;
  sub(t("network"), body);
}
function ifaceLine(name, d) {
  if (!d.present) return [name, t("not_present")];
  if (d.hotspot) return [name, [h("span", { class: "pill warn" }, t("hotspot_on")), " " + d.hotspot]];
  const parts = [];
  parts.push(h("span", { class: "pill " + (d.link ? "ok" : "bad") }, d.link ? t("link_up") : t("link_down")));
  parts.push(" " + (d.addresses.join(", ") || t("no_ip")));
  if (d.ssid) parts.push("  " + d.ssid + " (" + d.rssi + " dBm)");
  return [name, parts];
}
async function tabStatus(redraw) {
  const n = await api("/api/net");
  const rows = [ifaceLine(t("ethernet"), n.eth0), ifaceLine(t("wifi"), n.wlan0), [t("gateway"), n.eth0.gateway || n.wlan0.gateway || "-"],
    [t("dns"), n.dns.join(", ") || "-"]];
  const hn = field(t("hostname"), { value: n.hostname });
  const hst = h("div", {});
  return h("div", {}, h("div", { class: "card" }, h("dl", { class: "kv" }, rows.map(([k, v]) => [h("dt", {}, k), h("dd", {}, v)]))),
    h("div", { class: "card" }, hn.el, h("p", { class: "note" }, t("hostname_note")),
      h("button", { class: "btn sm primary", onclick: async () => { try { await api("/api/hostname", { hostname: hn.input.value }); hst.replaceChildren(msg("ok", t("kbd_saved_w"))); } catch (e) { hst.replaceChildren(msg("bad", e.message)); } } }, t("save")), hst),
    n.eth0.link && n.eth0.addresses.length && WIZ ? msg("ok", t("eth_fine")) : null);
}
async function tabWifi(redraw) {
  const wrap = h("div", {});
  const saved = await api("/api/wifi/saved");
  const results = h("div", {});
  const form = h("div", {});
  const country = field(t("country"), { value: saved.country, maxlength: "2" });
  function scanProblem(r) {
    const why = { no_interface: "scan_why_nointerface", supplicant_failed: "scan_why_supplicant", scan_rejected: "scan_why_rejected", no_results: "scan_why_no_results" }[r.reason] || "no_nets";
    return h("div", { class: "msg warn" }, h("p", {}, h("b", {}, t("scan_none"))), h("p", { class: "small" }, t(why)),
      r.detail ? h("details", { open: true }, h("summary", {}, t("scan_details")), h("pre", { class: "raw" }, r.detail)) : null,
      h("div", { class: "row" }, h("button", { class: "btn sm primary", onclick: scan }, t("try_again")),
        h("button", { class: "btn sm", onclick: async () => { await leaveToDiag(); } }, t("open_diag"))));
  }
  async function leaveToDiag() { go("/diag"); }
  async function scan() {
    results.replaceChildren(busy(t("scanning")));
    try {
      const r = await api("/api/wifi/scan");
      if (!r.available && !r.reason) { results.replaceChildren(msg("warn", t("no_wifi"))); return; }
      if (!r.networks.length) { results.replaceChildren(scanProblem(r)); return; }
      results.replaceChildren(h("div", { class: "list" }, r.networks.map((n) =>
        h("button", { class: "item", onclick: () => connectForm(n.ssid, n.secured, false) }, bars(n.signal),
          h("span", { class: "grow" }, n.ssid), h("span", { class: "pill" }, n.band + " GHz"),
          n.saved ? h("span", { class: "pill ok" }, t("saved")) : null, h("span", { class: "pill" }, n.secured ? t("secured") : t("open_net"))))));
    } catch (e) { results.replaceChildren(msg("bad", e.message)); }
  }
  function connectForm(ssid, secured, hidden) {
    const name = field(t("network_name"), { value: ssid || "" });
    const pw = field(t("passphrase"), { type: "password" });
    const hid = h("input", { type: "checkbox", checked: hidden });
    const out = h("div", {});
    const go1 = h("button", { class: "btn primary", onclick: async () => {
      go1.disabled = true; out.replaceChildren(busy(t("connecting")));
      try {
        const r = await api("/api/wifi/connect", { ssid: name.input.value, passphrase: secured || hidden ? pw.input.value : "", hidden: hid.checked, country: country.input.value || "BE" });
        if (r.ok) { out.replaceChildren(msg("ok", r.ip ? t("connected_to") + " " + name.input.value + " (" + r.ip + ")" : t("wifi_ok_noip"))); closeOsk(); setTimeout(redraw, 2500); }
        else if (r.reason === "hotspot_handover") { out.replaceChildren(msg("warn", t("hs_handover"))); closeOsk(); }
        else { out.replaceChildren(msg("bad", { wrong_passphrase: t("err_wrong"), rejected: t("err_rejected"), not_found: t("err_nf"), supplicant_failed: t("err_supp") }[r.reason] || t("error"))); go1.disabled = false; }
      } catch (e) { out.replaceChildren(msg("bad", e.message)); go1.disabled = false; }
    } }, t("connect"));
    form.replaceChildren(h("div", { class: "card" }, h("h2", {}, hidden ? t("hidden_net") : ssid), hidden ? name.el : null,
      secured || hidden ? pw.el : null, hidden ? h("label", { class: "sw" }, h("div", { class: "grow" }, t("hidden_net")), hid) : null,
      h("div", { class: "row" }, go1, h("button", { class: "btn", onclick: () => { form.replaceChildren(); closeOsk(); } }, t("cancel"))), out));
    if (hidden) hid.checked = true;
    (hidden ? name.input : secured ? pw.input : go1).focus();
    form.scrollIntoView({ behavior: "smooth", block: "start" });
  }
  const savedList = saved.saved.length ? [h("h2", { style: "margin-top:20px" }, t("saved_nets")), h("div", { class: "list" }, saved.saved.map((n) =>
    h("div", { class: "item", style: "cursor:default" }, h("span", { class: "grow" }, n.ssid), h("span", { class: "pill" }, n.secured ? t("secured") : t("open_net")),
      h("button", { class: "btn sm", onclick: async () => { await api("/api/wifi/forget", { ssid: n.ssid }).catch(() => 0); redraw(); } }, t("forget")))))] : [];
  wrap.append(h("div", { class: "row", style: "margin-bottom:14px" },
    h("button", { class: "btn primary", onclick: scan }, t("scan")), h("button", { class: "btn", onclick: () => connectForm("", true, true) }, t("hidden_net")),
    h("div", { style: "width:120px" }, country.el), h("button", { class: "btn sm", onclick: async () => { await api("/api/wifi/country", { country: country.input.value }).catch(() => 0); } }, t("save"))),
    form, results, ...savedList);
  return wrap;
}
async function tabIp(redraw) {
  const n = await api("/api/net");
  const cards = ["eth0", "wlan0"].filter((i) => n[i].present).map((iface) => {
    const c = n[iface].config;
    const mode = h("select", {}, h("option", { value: "dhcp", selected: c.mode === "dhcp" }, t("dhcp")), h("option", { value: "static", selected: c.mode === "static" }, t("static_ip")));
    const a = field(t("address") + " (192.168.1.50/24)", { value: c.address || (n[iface].addresses[0] || "") });
    const g = field(t("gateway"), { value: c.gateway || n[iface].gateway || "" });
    const d = field(t("dns"), { value: (c.dns || []).join(" ") || n.dns.join(" ") });
    const box = h("div", {}, a.el, g.el, d.el);
    const out = h("div", {});
    const sync = () => { box.style.display = mode.value === "static" ? "" : "none"; };
    mode.addEventListener("change", sync); sync();
    return h("div", { class: "card" }, h("h2", {}, iface === "eth0" ? t("ethernet") : t("wifi")), h("label", { class: "f" }, mode), box,
      h("button", { class: "btn primary", onclick: async () => {
        try { const r = await api("/api/net/set", { iface, mode: mode.value, address: a.input.value, gateway: g.input.value, dns: d.input.value }); closeOsk(); confirmNet(iface, r.confirm_seconds, redraw); }
        catch (e) { out.replaceChildren(msg("bad", e.message)); }
      } }, t("apply")), out);
  });
  return h("div", {}, cards);
}
function confirmNet(iface, secs, redraw) {
  let left = secs; const cd = h("b", {}, left + t("seconds"));
  const timer = setInterval(() => { left -= 1; cd.textContent = left + t("seconds"); if (left <= 0) { clearInterval(timer); close(); setTimeout(redraw, 4000); } }, 1000);
  const close = modal([h("h2", {}, t("keep_q")), h("p", { class: "dim" }, t("keep_d") + " ", cd),
    h("div", { class: "row" },
      h("button", { class: "btn primary", onclick: async () => { clearInterval(timer); await api("/api/net/confirm", { iface }).catch(() => 0); close(); redraw(); } }, t("keep")),
      h("button", { class: "btn", onclick: () => { clearInterval(timer); close(); /* unconfirmed: the server reverts by itself */ setTimeout(redraw, 63000); } }, t("revert")))]);
}

/* ------------------------------------------------------------ wizard ---- */
const STEPS = ["welcome", "mode", "keyboard", "network", "services", "finish"];
let WMODE = null;  // the choice of the role step ("mode", as in v6); only sent (and applied) at the end of the wizard
// The step after `step`; only an Alnasl box has the Services step (Alnasl on or off, the screen on or off).
function stepAfter(step) { let n = step + 1; if (WMODE !== "alnasl" && STEPS[n] === "services") n++; return n; }
function stepBefore(step) { let n = step - 1; if (WMODE !== "alnasl" && STEPS[n] === "services") n--; return n; }
function wizard(step) {
  if (WMODE === null) WMODE = canonRole(sessionStorage.getItem("wizmode")) || roleChosen();
  sessionStorage.setItem("wizstep", String(step));
  if (location.pathname === "/setup") qset({ step: String(step) });
  const name = STEPS[step];
  const dots = h("div", { class: "steps" }, STEPS.map((_, i) => h("i", { class: i <= step ? "on" : "" })));
  const nav = (next, nextLabel, onNext) => h("div", { class: "foot" },
    step > 0 ? h("button", { class: "btn", onclick: () => wizard(stepBefore(step)) }, t("back")) : h("span"),
    h("button", { class: "btn primary", onclick: async () => { if (onNext && !(await onNext())) return; next(); } }, nextLabel));
  let body;
  if (name === "welcome") {
    body = [h("h1", {}, t("welcome")), h("p", { class: "dim" }, t("welcome_d")), hotspotCard(), h("h2", { style: "margin-top:24px" }, t("language")),
      h("div", { class: "row" }, ["en", "nl"].map((l) => h("button", { class: "btn" + (LANG === l ? " primary" : ""), onclick: async () => { LANG = l; await api("/api/lang", { lang: l }).catch(() => 0); wizard(step); } }, l === "en" ? "English" : "Nederlands"))),
      nav(() => wizard(stepAfter(step)), t("next"))];
  } else if (name === "mode") {
    const choice = (id) => {
      const it = roleItem(id, WMODE === id, () => {
        WMODE = id; sessionStorage.setItem("wizmode", id);
        [...list.children].forEach((c) => c.classList.remove("sel")); it.classList.add("sel");
      });
      return it;
    };
    const list = h("div", { class: "list" }, ROLES.map(choice));
    body = [h("h1", {}, t("role_title")), h("p", { class: "dim" }, t("role_d")), list, nav(() => wizard(stepAfter(step)), t("next"))];
  } else if (name === "keyboard") {
    body = [h("h1", {}, t("keyboard")), kbdPage(true), nav(() => wizard(stepAfter(step)), t("next"))];
  } else if (name === "network") {
    body = [h("h1", {}, t("network")), netPage(true), nav(() => wizard(stepAfter(step)), t("next"))];
  } else if (name === "services") {
    const sb = svcPage(true);
    body = [h("h1", {}, t("services")), sb, nav(() => wizard(stepAfter(step)), t("next"), sb.save)];
  } else {
    const change = WMODE !== roleNow();
    body = [h("div", { class: "center", style: "padding:50px 0" }, h("h1", {}, t("done_title")),
      h("p", { class: "dim" }, change && WMODE !== "alnasl" ? t("done_" + WMODE + "_d") : tf("done_d", ROLE_NAME[WMODE])),
      h("button", { class: "btn primary", id: "wiz-finish", onclick: async () => {
        LEAVING = true;
        // The role goes with the last request: a box that lost power half way must not come back as something else.
        // A change of role restarts the box (the other app takes over at boot); the same role just opens its page.
        const r = await api("/api/finish", { mode: WMODE }).catch(() => ({}));
        sessionStorage.removeItem("wizstep"); sessionStorage.removeItem("wizmode");
        if (r.reboot) { modal([busy(t("restart_now"))]); location.href = "/screen"; return; }
        modal([busy(tf("open_alnasl", ROLE_NAME[WMODE]))]); await sleep(4500); location.href = "/";
      } }, change ? t("restart_now") : tf("open_alnasl", ROLE_NAME[WMODE])))];
  }
  shell(t("first_run"), [dots, ...body], {});
}

route();
