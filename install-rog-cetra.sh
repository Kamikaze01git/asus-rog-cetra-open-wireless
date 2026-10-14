#!/usr/bin/env bash
# =============================================================================
#  install-rog-cetra.sh
#  Version: 1.6
#  Installer für ASUS ROG Cetra Open Wireless unter Linux (2,4-GHz-Dongle)
#   - Lautstärke-Fix (WirePlumber regelt in Software statt über den Dongle)
#   - Tap-Gesten an den Ohrbügeln (Lautstärke, Stumm, Mikro, Play/Pause, Titel)
#   - Bestätigungstöne
#   Alle Gesten und Töne betreffen ausschließlich die Cetra (USB-ID 0b05:1cac),
#   nie das Standardgerät (z. B. Monitor).
#
#  Getestet: SteamOS (Steam Deck). Gedacht auch für Debian und Fedora.
#  Voraussetzung: PipeWire + WirePlumber, systemd, python3.
#
#  Aufruf (als normaler Benutzer, NICHT als root - sudo wird bei Bedarf gefragt):
#    bash install-rog-cetra.sh              installieren / aktualisieren
#    bash install-rog-cetra.sh --uninstall  alles wieder entfernen
#    bash install-rog-cetra.sh --help       Hilfe
#
#  Mehrfaches Ausführen ist unproblematisch: Alle Dateien werden überschrieben.
# =============================================================================
set -euo pipefail

BIN="$HOME/.local/bin/rog-cetra-buttons.py"
SVC_DIR="$HOME/.config/systemd/user"
SVC="$SVC_DIR/rog-cetra-buttons.service"
WP_CONF05="$HOME/.config/wireplumber/wireplumber.conf.d/51-rog-cetra-softmixer.conf"
WP_CONF04="$HOME/.config/wireplumber/main.lua.d/51-rog-cetra-softmixer.lua"
UDEV_RULE="/etc/udev/rules.d/70-rog-cetra-open.rules"
CACHE="$HOME/.cache/rog-cetra"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFehler:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

# -----------------------------------------------------------------------------
#  Voraussetzungen
# -----------------------------------------------------------------------------
check_prereqs() {
    [[ $EUID -ne 0 ]] || die "Bitte als normaler Benutzer ausführen, nicht als root (sudo wird bei Bedarf gefragt)."

    local missing=()
    for c in python3 systemctl udevadm sudo busctl; do
        command -v "$c" >/dev/null || missing+=("$c")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Fehlende Programme: ${missing[*]}"

    if ! command -v pactl >/dev/null; then
        warn "pactl nicht gefunden - der Ziel-Node-Name der Cetra kann evtl. nicht exakt"
        warn "  bestimmt werden (Bestätigungston). Debian: sudo apt install pulseaudio-utils"
        warn "  Fedora: sudo dnf install pulseaudio-utils"
    fi

    command -v wpctl >/dev/null || die "wpctl nicht gefunden - PipeWire + WirePlumber werden benötigt.
    Debian: sudo apt install pipewire pipewire-pulse wireplumber
    Fedora: sudo dnf install pipewire wireplumber"

    if ! command -v paplay >/dev/null && ! command -v pw-play >/dev/null; then
        warn "Weder paplay noch pw-play gefunden - Bestätigungstöne werden nicht funktionieren."
        warn "  Debian: sudo apt install pulseaudio-utils pipewire-bin   Fedora: sudo dnf install pipewire-utils pulseaudio-utils"
    fi

    systemctl --user is-active --quiet pipewire.service \
        || warn "PipeWire läuft für diesen Benutzer gerade nicht (keine Audio-Sitzung?). Installation geht trotzdem weiter."
}

wireplumber_minor() {
    # Liefert z.B. "0.5" oder "0.4"
    wireplumber --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | cut -d. -f1,2
}

# -----------------------------------------------------------------------------
#  Dateien schreiben
# -----------------------------------------------------------------------------
write_wireplumber_conf() {
    local ver; ver="$(wireplumber_minor)"
    if [[ "$ver" == 0.4 ]]; then
        info "WirePlumber $ver erkannt - schreibe Lua-Konfiguration"
        mkdir -p "$(dirname "$WP_CONF04")"
        cat > "$WP_CONF04" <<'EOF'
-- ROG Cetra Open Wireless: Lautstärke nur in Software regeln
-- (der Dongle meldet eine falsche dB-Skala). Installiert von install-rog-cetra.sh
table.insert(alsa_monitor.rules, {
  matches = { { { "device.name", "matches", "alsa_card.usb-*CETRA*" } } },
  apply_properties = { ["api.alsa.soft-mixer"] = true },
})
EOF
        rm -f "$WP_CONF05"
        ok "$WP_CONF04"
    else
        info "WirePlumber ${ver:-?} erkannt - schreibe Konfiguration (0.5-Format)"
        mkdir -p "$(dirname "$WP_CONF05")"
        cat > "$WP_CONF05" <<'EOF'
# ROG Cetra Open Wireless: Lautstärke nur in Software regeln
# (der Dongle meldet eine falsche dB-Skala). Installiert von install-rog-cetra.sh
monitor.alsa.rules = [
  {
    matches = [ { device.name = "~alsa_card.usb-.*CETRA.*" } ]
    actions = { update-props = { api.alsa.soft-mixer = true } }
  }
]
EOF
        rm -f "$WP_CONF04"
        ok "$WP_CONF05"
    fi
}

write_udev_rules() {
    info "Schreibe udev-Regeln (sudo)"
    sudo tee "$UDEV_RULE" >/dev/null <<'EOF'
# ROG Cetra Open Wireless - installiert von install-rog-cetra.sh
# Leserechte für den angemeldeten Benutzer auf die Rohdaten (hidraw) und die
# Medientasten des Dongles (USB-ID 0b05:1cac):
KERNEL=="hidraw*", ATTRS{idVendor}=="0b05", ATTRS{idProduct}=="1cac", MODE="0660", TAG+="uaccess"
KERNEL=="event*", SUBSYSTEM=="input", ATTRS{idVendor}=="0b05", ATTRS{idProduct}=="1cac", TAG+="uaccess"
EOF
    ok "$UDEV_RULE"

    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=hidraw --subsystem-match=input
}

write_script() {
    info "Schreibe Gesten-Skript"
    mkdir -p "$(dirname "$BIN")"
    cat > "$BIN" <<'PYEOF'
#!/usr/bin/env python3
"""ROG Cetra Open Wireless: Tap-Gesten vom 2,4-GHz-Dongle in Aktionen übersetzen.
Installiert von install-rog-cetra.sh - Erklärungen im Kommentar von
~/.config/systemd/user/rog-cetra-buttons.service

Protokoll (hidraw): cc 22 43 00 00 <Seite 00=L/01=R> <Anzahl Taps 1-4>
- Die fest vorbelegten ASUS-Medientasten werden exklusiv übernommen (Grab).
- Lauter/Leiser, Stumm und Mikro wirken ausschließlich auf die Kopfhörer
  (USB-ID 0b05:1cac); die Bestätigungstöne kommen immer aus den Kopfhörern.
- Lauter/Leiser regeln direkt die Cetra; das Standard-Ausgabegerät bleibt unverändert.
- Jede Aktion bestätigt mit einem eigenen Ton in (möglichst) fester Lautstärke."""
import fcntl, glob, json, math, os, re, shutil, struct, subprocess, sys, time, wave

VID, PID = "0B05", "1CAC"
VID_HEX, PID_HEX = f"{int(VID, 16):x}", f"{int(PID, 16):x}"  # "b05" / "1cac"
SIDE = {0x00: "L", 0x01: "R"}
# Ziel ist immer die Cetra (USB 0b05:1cac). Nur wenn sie fehlt, wird auf das
# Standardgerät zurückgefallen - dann liefern die Dongle-Tasten ohnehin nichts.
FALLBACK_SINK, FALLBACK_SOURCE = "@DEFAULT_AUDIO_SINK@", "@DEFAULT_AUDIO_SOURCE@"
MPRIS_PATH, MPRIS_IF = "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player"
# KDE-Plasma: Einblendung der Lautstärke anzeigen. Reiner Anzeige-Aufruf ohne
# Wirkung auf Geräte oder Lautstärke; für Fedora/KDE (nicht SteamOS/Gamescope).
OSD_DEST, OSD_PATH, OSD_IFACE = "org.kde.plasmashell", "/org/kde/osdService", "org.kde.osdService"
SOUND_DIR = os.path.expanduser("~/.cache/rog-cetra")
TONE_LEVEL = 0.2  # feste Lautstärke der Bestätigungstöne (0..1) - bei Bedarf anpassen
PA_TOOL = shutil.which("paplay")  # PulseAudio-kompatibler Abspieler, falls vorhanden

# Linux-Konstanten
EVIOCGRAB = 0x40044590                              # Eingabegerät exklusiv reservieren

def make_tone(name, freqs, ms=80, rate=48000, vol=0.9):
    """Erzeugt einmalig eine kurze WAV-Datei mit einer Tonfolge (Frequenz 0 = Pause)."""
    path = os.path.join(SOUND_DIR, name + ".wav")
    if os.path.exists(path):
        return path
    os.makedirs(SOUND_DIR, exist_ok=True)
    n = int(rate * ms / 1000)
    frames = bytearray()
    for f in freqs:
        for i in range(n):
            fade = min(1.0, i / 200, (n - i) / 200)  # weiche Ränder gegen Knacken
            frames += struct.pack("<h", int(32767 * vol * fade * math.sin(2 * math.pi * f * i / rate)))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(frames))
    return path

TONE_TICK    = make_tone("tick_v3",    [880], ms=50)            # Lauter/Leiser
TONE_MIC_ON  = make_tone("mic_on_v3",  [784, 988, 1175])        # hoch, aufsteigend
TONE_MIC_OFF = make_tone("mic_off_v3", [1175, 988, 784])        # hoch, absteigend
TONE_SPK_ON  = make_tone("spk_on_v3",  [392, 494, 587])         # tief, aufsteigend
TONE_SPK_OFF = make_tone("spk_off_v3", [587, 494, 392])         # tief, absteigend
TONE_PLAY    = make_tone("play_v3",    [523, 0, 784], ms=90)    # zwei Töne, aufsteigend
TONE_PAUSE   = make_tone("pause_v3",   [784, 0, 523], ms=90)    # zwei Töne, absteigend
TONE_ERROR   = make_tone("error_v3",   [220], ms=250)           # kein Player gefunden

DEFAULT_SINK, DEFAULT_SOURCE = None, None  # wpctl-Ziele (Node-ID), werden in main() aufgelöst
PLAY_SINK = None  # Ziel für pw-play (node.name oder object.serial)

def _hex_id(value):
    """VID/PID-Wert vereinheitlichen: Zahl oder Hex-String ('0b05') -> 'b05'."""
    if value is None:
        return None
    if isinstance(value, int):
        return f"{value:x}"
    try:
        return f"{int(str(value).strip(), 16):x}"
    except ValueError:
        return None

def _cetra_nodes():
    """Sink-ID/-Name und Source-ID der Cetra (VID/PID 0b05:1cac) über pw-dump ermitteln.
    Gibt (sink_id, sink_name, source_id) zurück; fehlende Werte None ohne pw-dump."""
    try:
        dump = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=10).stdout
        objs = json.loads(dump)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None, None, None
    dev_ids = set()
    for o in objs:
        if not isinstance(o, dict) or o.get("type") != "PipeWire:Interface:Device":
            continue
        props = o.get("info", {}).get("props", {})
        if _hex_id(props.get("device.vendor.id")) == VID_HEX \
                and _hex_id(props.get("device.product.id")) == PID_HEX:
            dev_ids.add(o.get("id"))
    sinks, sources = [], []
    for o in objs:
        if not isinstance(o, dict) or o.get("type") != "PipeWire:Interface:Node":
            continue
        info = o.get("info", {})
        props = info.get("props", {})
        cls = props.get("media.class")
        if cls not in ("Audio/Sink", "Audio/Source", "Audio/Source/Virtual"):
            continue
        # Zugehörigkeit: über die Geräte-ID (VID/PID) oder ersatzweise über den Namen
        by_id = props.get("device.id") in dev_ids
        by_name = "cetra" in (str(props.get("node.name", "")) + " "
                              + str(props.get("node.description", "")) + " "
                              + str(props.get("device.description", ""))).lower()
        if not (by_id or by_name):
            continue
        entry = (o.get("id"), props.get("node.name"), info.get("state"))
        (sinks if cls == "Audio/Sink" else sources).append(entry)
    # bevorzugt eine laufende (nicht suspendierte) Node, sonst die erste
    def pick(nodes):
        if not nodes:
            return None, None
        n = next((n for n in nodes if n[2] != "suspended"), nodes[0])
        return n[0], n[1]
    sid, sname = pick(sinks)
    src, _ = pick(sources)
    return sid, sname, src

def _pactl_node(kind):
    """Sink-/Source-ID und echten node.name der Cetra über pactl (zuverlässigste Namensquelle).
    kind: 'sinks' oder 'sources'. Gibt (id, node.name) oder (None, None)."""
    try:
        out = subprocess.run(["pactl", "list", "short", kind],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None, None
    for line in out.splitlines():
        if "cetra" not in line.lower():
            continue
        cols = re.split(r"\s+", line.strip())
        if len(cols) >= 2:
            return cols[0], cols[1]
    return None, None

def _wpctl_id(fragment, section):
    """Node-ID und -Name suchen, deren Beschreibung `fragment` enthält - Fallback ohne pw-dump."""
    try:
        out = subprocess.run(["wpctl", "status"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None, None
    in_section = False
    for line in out.splitlines():
        if re.search(rf"\b{section}:\s*$", line):
            in_section = True
            continue
        if re.search(r"\b(Sinks|Sources|Filters|Streams|Devices|Clients):\s*$", line):
            in_section = False
            continue
        if not in_section:
            continue
        m = re.match(r"^\s*[│|├└─\s]*\*?\s*(\d+)\.\s+(.*)$", line)
        if m and fragment.lower() in m.group(2).lower():
            desc = re.sub(r"\s*\[.*\]\s*$", "", m.group(2)).strip()
            return m.group(1), desc
    return None, None

def resolve_cetra():
    """Löst das Zielgerät auf: bevorzugt die Cetra, sonst das Standardgerät."""
    global DEFAULT_SINK, DEFAULT_SOURCE, PLAY_SINK
    s, sname, src = _cetra_nodes()          # s = wpctl-ID, sname = echter node.name
    if s is None:
        s, _ = _wpctl_id("CETRA", "Sinks")  # Beschreibung hier NICHT als Name übernehmen
    if src is None:
        src, _ = _wpctl_id("CETRA", "Sources")
    # Für pw-play/paplay zählt ausschließlich object.serial oder node.name; den
    # echten Namen liefert pactl am zuverlässigsten (auch wenn pw-dump ihn nicht fand).
    _, ps_name = _pactl_node("sinks")
    if ps_name:
        sname = ps_name
    elif not (sname and str(sname).startswith("alsa_")):
        sname = None  # niemals eine Anzeige-Beschreibung als Abspielziel verwenden
    psrc_id, _ = _pactl_node("sources")
    if src is None and psrc_id:
        src = psrc_id
    if s is None and src is None:
        DEFAULT_SINK, DEFAULT_SOURCE, PLAY_SINK = FALLBACK_SINK, FALLBACK_SOURCE, None
        print("Zielgerät: Cetra nicht gefunden -> Standardgerät", flush=True)
    else:
        DEFAULT_SINK, DEFAULT_SOURCE, PLAY_SINK = s, src, sname
        print(f"Zielgerät: Cetra (Sink {s} '{sname}', Source {src})", flush=True)

def target_sink():
    return DEFAULT_SINK or FALLBACK_SINK

def target_source():
    return DEFAULT_SOURCE or FALLBACK_SOURCE

def target_play_sink():
    return PLAY_SINK if PLAY_SINK is not None else FALLBACK_SINK

def show_osd(percent):
    """Plasma ein Lautstärke-OSD mit `percent` anzeigen lassen (best effort).
    Plasma blendet das OSD nur für den Standard-Sink ein; da wir die Cetra regeln
    und den Standard bewusst nicht umschalten, holen wir die korrekte Anzeige explizit
    nach. Der Aufruf ist reine Anzeige - er ändert kein Gerät und keine Lautstärke."""
    pct = max(0, min(100, int(round(percent))))
    for tool in ("qdbus6", "qdbus-qt6", "qdbus5", "qdbus-qt5", "qdbus"):
        exe = shutil.which(tool)
        if exe and subprocess.run([exe, OSD_DEST, OSD_PATH,
                                   f"{OSD_IFACE}.volumeChanged", str(pct)],
                                  check=False).returncode == 0:
            return
    if shutil.which("busctl"):
        subprocess.run(["busctl", "--user", "call", OSD_DEST, OSD_PATH,
                        OSD_IFACE, "volumeChanged", "i", str(pct)], check=False)

def sink_linear():
    """Aktuelle Ausgabelautstärke der Cetra als linearer Faktor (wpctl zeigt eine kubische Skala)."""
    out = subprocess.run(["wpctl", "get-volume", str(target_sink())], capture_output=True, text=True).stdout
    try:
        v = float(out.split()[1])
    except (IndexError, ValueError):
        return 1.0
    return max(v ** 3, 1e-4)

def play_tone(path):
    """Gibt den Ton ausschließlich über die Cetra aus und kompensiert deren Lautstärke.
    `pw-play --target` wird nicht von jeder WirePlumber-Version beachtet; daher
    läuft der Ton über den PulseAudio-kompatiblen paplay mit festem Zielgerät
    (Cetra-node.name). Ersatzwege: PIPEWIRE_NODE (native) und zuletzt pw-play."""
    gain = TONE_LEVEL / sink_linear()
    node = str(target_play_sink())
    if PA_TOOL:
        vol = min(int(round(gain * 65536)), 65536)  # paplay: 0..65536 = 0..100 %
        if subprocess.run([PA_TOOL, "--device", node, "--volume", str(vol), path],
                          check=False).returncode == 0:
            return
    env = dict(os.environ, PIPEWIRE_NODE=node)
    if subprocess.run(["pw-play", "--volume", f"{gain:.3f}", path],
                      env=env, check=False).returncode == 0:
        return
    subprocess.run(["pw-play", "--target", node, "--volume", f"{gain:.3f}", path], check=False)

def wpctl_volume(amount):
    """Regelt ausschließlich die Cetra-Lautstärke - das Standardgerät bleibt unberührt.
    Bewusst ohne Standard-Umschaltung (das würde laufendes Audio umleiten)."""
    subprocess.run(["wpctl", "set-volume", "-l", "1.0", str(target_sink()), amount], check=False)
    out = subprocess.run(["wpctl", "get-volume", str(target_sink())], capture_output=True, text=True).stdout
    try:
        show_osd(float(out.split()[1]) * 100.0)  # korrektes OSD der Cetra nachholen
    except (IndexError, ValueError):
        pass
    play_tone(TONE_TICK)

def mic_toggle():
    """Schaltet das Cetra-Mikrofon stumm/an und bestätigt mit einem Ton."""
    subprocess.run(["wpctl", "set-mute", str(target_source()), "toggle"], check=False)
    state = subprocess.run(["wpctl", "get-volume", str(target_source())], capture_output=True, text=True).stdout
    muted = "MUTED" in state
    print(f"  Mikro {'stumm' if muted else 'an'}", flush=True)
    play_tone(TONE_MIC_OFF if muted else TONE_MIC_ON)

def sink_toggle():
    """Schaltet die Cetra stumm/an. Beim Stummschalten erst Ton, dann stumm - sonst hört man ihn nicht."""
    state = subprocess.run(["wpctl", "get-volume", str(target_sink())], capture_output=True, text=True).stdout
    if "MUTED" in state:
        subprocess.run(["wpctl", "set-mute", str(target_sink()), "0"], check=False)
        print("  Ton an", flush=True)
        play_tone(TONE_SPK_ON)
    else:
        print("  Ton stumm", flush=True)
        play_tone(TONE_SPK_OFF)
        subprocess.run(["wpctl", "set-mute", str(target_sink()), "1"], check=False)

def player_status(p):
    """Liefert den Wiedergabestatus eines MPRIS-Players (Playing/Paused/Stopped)."""
    return subprocess.run(["busctl", "--user", "get-property", p, MPRIS_PATH,
                           MPRIS_IF, "PlaybackStatus"], capture_output=True, text=True).stdout

def media(method):
    """Schickt einen MPRIS-Befehl an den Player, der gerade spielt. Gibt den Player zurück oder None."""
    out = subprocess.run(["busctl", "--user", "list", "--no-legend"],
                         capture_output=True, text=True).stdout
    players = [l.split()[0] for l in out.splitlines() if l.startswith("org.mpris.MediaPlayer2.")]
    target = next((p for p in players if "Playing" in player_status(p)), None)
    if target is None and players:
        target = players[0]  # nichts spielt gerade: ersten Player nehmen
    if target:
        subprocess.run(["busctl", "--user", "call", target, MPRIS_PATH, MPRIS_IF, method],
                       check=False)
    else:
        print("  kein Mediaplayer gefunden", flush=True)
    return target

def track(method):
    """Erzeugt eine Titel-vor/zurück-Aktion; Fehlerton, wenn kein Player da ist."""
    def action():
        if not media(method):
            play_tone(TONE_ERROR)
    return action

def playpause():
    """Play/Pause umschalten und mit eigenem Ton für Wiedergabe bzw. Pause bestätigen."""
    target = media("PlayPause")
    if not target:
        play_tone(TONE_ERROR)
        return
    time.sleep(0.3)  # dem Player Zeit geben, seinen neuen Zustand zu melden
    playing = "Playing" in player_status(target)
    print(f"  {'Wiedergabe' if playing else 'Pause'}", flush=True)
    play_tone(TONE_PLAY if playing else TONE_PAUSE)

# (Seite, Taps) -> (Beschreibung, Aktion). Hier kannst du die Belegung frei ändern.
# Lauter/Leiser regeln die Cetra direkt; das Standard-Ausgabegerät bleibt unangetastet.
ACTIONS = {
    ("R", 1): ("Lauter",             lambda: wpctl_volume("5%+")),
    ("L", 1): ("Leiser",             lambda: wpctl_volume("5%-")),
    ("R", 2): ("Ton stumm an/aus",   sink_toggle),
    ("L", 2): ("Mikro stumm an/aus", mic_toggle),
    ("R", 3): ("Play/Pause",         playpause),
    ("L", 3): ("Play/Pause",         playpause),
    ("R", 4): ("Nächster Titel",     track("Next")),
    ("L", 4): ("Vorheriger Titel",   track("Previous")),
}

def find_hidraw():
    """Sucht die hidraw-Schnittstelle des Dongles anhand von Vendor/Product-ID."""
    for dev in glob.glob("/sys/class/hidraw/hidraw*"):
        try:
            with open(os.path.join(dev, "device/uevent")) as f:
                if f"HID_ID=0003:0000{VID}:0000{PID}" in f.read().upper():
                    return "/dev/" + os.path.basename(dev)
        except OSError:
            pass
    return None

def find_consumer_event():
    """Sucht das Eingabegerät mit den ASUS-Medientasten ('... Consumer Control')."""
    name = ""
    for line in open("/proc/bus/input/devices"):
        if line.startswith("N: Name="):
            name = line.split("=", 1)[1].strip().strip('"')
        elif line.startswith("H: Handlers=") and "CETRA" in name and "Consumer Control" in name:
            for h in line.split("=", 1)[1].split():
                if h.startswith("event"):
                    return "/dev/input/" + h
    return None

def grab_native_keys():
    """Reserviert die ASUS-Medientasten exklusiv. Gibt den Dateideskriptor zurück oder None."""
    path = find_consumer_event()
    if not path:
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        fcntl.ioctl(fd, EVIOCGRAB, 1)
        print(f"Standard-Tasten übernommen ({path})", flush=True)
        return fd
    except OSError as e:
        print(f"Konnte {path} nicht übernehmen: {e}", flush=True)
        return None

def main():
    if "--selftest" in sys.argv:
        resolve_cetra()
        print(f"Ton-Abspieler: {PA_TOOL or 'pw-play (PIPEWIRE_NODE)'}", flush=True)
        for name, tone in (("Tick", TONE_TICK), ("Ton stumm/an", TONE_SPK_OFF),
                           ("Mikro stumm/an", TONE_MIC_OFF), ("Pause/Wiedergabe", TONE_PAUSE)):
            print(f"spiele {name} ...", flush=True)
            play_tone(tone)
            time.sleep(0.7)
        return
    print(f"Ton-Abspieler: {PA_TOOL or 'pw-play (PIPEWIRE_NODE)'}", flush=True)
    while True:
        path = find_hidraw()
        if not path:
            time.sleep(2)
            continue
        try:
            fd = os.open(path, os.O_RDONLY)
        except PermissionError:
            print(f"Keine Leserechte auf {path} - udev-Regel prüfen", flush=True)
            time.sleep(5)
            continue
        except OSError:
            time.sleep(2)
            continue
        print(f"Lausche auf {path}", flush=True)
        resolve_cetra()  # Ziel-Audiogerät (Cetra) ermitteln
        time.sleep(0.5)  # dem Tasten-Gerät Zeit geben, nach dem Anstecken zu erscheinen
        grab_fd = grab_native_keys()
        try:
            while True:
                data = os.read(fd, 256)  # blockiert bis zur nächsten Meldung
                i = data.find(b"\xcc\x22\x43")  # Kennung irgendwo in der Meldung suchen
                if i < 0 or len(data) < i + 7:
                    continue  # z. B. die Standard-Tasten-Meldungen (0c xx) - ignorieren
                if grab_fd is None:
                    grab_fd = grab_native_keys()  # erneut versuchen, falls es beim Start noch fehlte
                resolve_cetra()  # Zielgerät auffrischen (Dongle/Profil kann sich geändert haben)
                side, taps = SIDE.get(data[i + 5], "?"), data[i + 6]
                entry = ACTIONS.get((side, taps))
                print(f"Geste {side}{taps}" + (f" -> {entry[0]}" if entry else ""), flush=True)
                if entry:
                    try:
                        entry[1]()
                    except Exception as e:  # eine fehlgeschlagene Aktion darf den Dienst nicht beenden
                        print(f"  Fehler: {e}", flush=True)
        except OSError:
            print("Dongle getrennt, warte auf Wiederverbindung ...", flush=True)
        finally:
            os.close(fd)
            if grab_fd is not None:
                os.close(grab_fd)  # beim Schließen wird die Reservierung automatisch aufgehoben
        time.sleep(1)

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$BIN"
    python3 -m py_compile "$BIN" || die "Das Gesten-Skript enthält einen Fehler."
    ok "$BIN"
}

write_service() {
    info "Schreibe systemd-Dienst"
    mkdir -p "$SVC_DIR"
    cat > "$SVC" <<'EOF'
# =============================================================================
#  ROG Cetra Open Wireless - Tap-Gesten & Lautstärke-Fix
#  Installiert am @DATE@ auf @HOST@ mit install-rog-cetra.sh
# =============================================================================
#
#  WARUM?
#  Die ASUS ROG Cetra Open Wireless (2,4-GHz-Dongle, USB-ID 0b05:1cac) laufen
#  unter Linux nicht richtig:
#   - Der Lautstärkebalken regelte nur auf den ersten ~5 % (falsche dB-Angabe
#     des Dongles). -> Lösung: WirePlumber regelt nur noch in Software.
#   - Die Tasten an den Ohrbügeln melden nur rohe Gesten (Seite + Anzahl Taps)
#     in einem ASUS-eigenen Protokoll. -> Lösung: das Skript liest sie mit
#     und führt die passende Aktion aus.
#   - Die fest vorbelegten ASUS-Medientasten werden vom Skript exklusiv
#     übernommen ("Grab"), damit das System nicht doppelt reagiert.
#   - Damit die Ohrbügel-Tasten und ihre Bestätigungstöne nicht versehentlich
#     das Standardgerät (z. B. Monitor/Radio) regeln, wirken Lautstärke, Stumm
#     und Mikro sowie alle Töne ausschließlich auf die Cetra (USB 0b05:1cac).
#     Erkennung über pw-dump, Ersatzweg über 'wpctl status' (Name enthält CETRA).
#   - Das Volume-OSD von KDE/GNOME hängt fest am Standard-Sink; ein OSD nur für
#     ein anderes Gerät gibt es nicht. Deshalb wird bewusst KEIN Standardgerät
#     umgeschaltet: das OSD zeigt weiter den Standard, aber Geste und Ton treffen
#     immer nur die Cetra. (Ein Umschalten würde laufendes Audio umleiten.)
#
#  GESTEN-BELEGUNG (änderbar im Skript unter ACTIONS)
#   Geste       Rechts                 Links
#   1x tippen   Lauter                 Leiser
#   2x tippen   Ton stumm an/aus       Mikro stumm an/aus
#   3x tippen   Play/Pause             Play/Pause
#   4x tippen   Nächster Titel         Vorheriger Titel
#
#  BESTÄTIGUNGSTÖNE (immer aus der Cetra, unabhängig vom Standardgerät)
#   Lauter/Leiser     kurzes Tick
#   Ton stumm/an      3 tiefe Töne ab-/aufsteigend
#   Mikro stumm/an    3 hohe Töne ab-/aufsteigend
#   Pause/Wiedergabe  2 Töne ab-/aufsteigend
#   Fehler            1 tiefer, längerer Ton = kein Mediaplayer gefunden
#                     (normal in Spielen, die bieten kein MPRIS an)
#   Lautstärke der Töne: TONE_LEVEL im Skript
#
#  ALLE ÄNDERUNGEN
#   Was                 Wo
#   Gesten-Skript       ~/.local/bin/rog-cetra-buttons.py
#   Dieser Dienst       ~/.config/systemd/user/rog-cetra-buttons.service
#                       (+ Verknüpfung in ~/.config/systemd/user/default.target.wants/)
#   Lautstärke-Fix      WirePlumber 0.5: ~/.config/wireplumber/wireplumber.conf.d/51-rog-cetra-softmixer.conf
#                       WirePlumber 0.4: ~/.config/wireplumber/main.lua.d/51-rog-cetra-softmixer.lua
#                       (wirkt nur auf Audiogeräte mit "CETRA" im Namen)
#   udev-Regeln         /etc/udev/rules.d/70-rog-cetra-open.rules
#                       (Leserechte nur für USB-ID 0b05:1cac)
#   Tondateien          ~/.cache/rog-cetra/*.wav (erzeugt das Skript selbst)
#
#  WICHTIG: Die Cetra auf diesem Rechner NICHT zusätzlich per Bluetooth koppeln!
#  Eine parallele BT-Verbindung fängt die Tasten ab. Prüfen/entfernen:
#   bluetoothctl devices | grep -i cetra
#   bluetoothctl remove <MAC-Adresse>
#
#  Andere Geräte (Controller, andere Kopfhörer, USB-Geräte) sind nicht
#  betroffen. Ohne die ASUS prüft das Skript nur alle 2 s, ob der Dongle da ist.
#
#  NÜTZLICHE BEFEHLE
#   Status:            systemctl --user status rog-cetra-buttons
#   Live-Log:          journalctl --user -u rog-cetra-buttons -f
#   Log seit Start:    journalctl --user -u rog-cetra-buttons -b
#   Neu starten:       systemctl --user restart rog-cetra-buttons
#                      (nötig nach jeder Änderung am Skript)
#   Lautstärke prüfen: wpctl get-volume @DEFAULT_AUDIO_SINK@   (Standardgerät)
#                      die Cetra: wpctl status -> ID suchen, dann wpctl get-volume <ID>
#   Stumm aufheben:    wpctl set-mute <Cetra-ID> 0
#                      (PipeWire merkt sich "stumm" auch über Neustarts!)
#
#  NACH EINEM SYSTEM-UPDATE
#   Normalerweise bleibt alles erhalten. Falls die Tasten nicht gehen:
#   Installer erneut ausführen:  bash install-rog-cetra.sh
#   oder von Hand:
#    sudo udevadm control --reload
#    sudo udevadm trigger --subsystem-match=input --subsystem-match=hidraw
#    systemctl --user restart rog-cetra-buttons
#
#  ALLES WIEDER ENTFERNEN
#   Am einfachsten:  bash install-rog-cetra.sh --uninstall
#   Oder von Hand:
#    systemctl --user disable --now rog-cetra-buttons.service
#    rm ~/.local/bin/rog-cetra-buttons.py
#    rm -f ~/.config/wireplumber/wireplumber.conf.d/51-rog-cetra-softmixer.conf
#    rm -f ~/.config/wireplumber/main.lua.d/51-rog-cetra-softmixer.lua
#    rm -r ~/.cache/rog-cetra
#    sudo rm /etc/udev/rules.d/70-rog-cetra-open.rules
#    sudo udevadm control --reload
#    rm ~/.config/systemd/user/rog-cetra-buttons.service    (diese Datei - zuletzt!)
#    systemctl --user daemon-reload
#    systemctl --user restart wireplumber
# =============================================================================

[Unit]
Description=ROG Cetra Open Wireless Tap-Gesten
After=pipewire.service wireplumber.service

[Service]
ExecStart=/usr/bin/python3 %h/.local/bin/rog-cetra-buttons.py
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    sed -i "s|@DATE@|$(date '+%d.%m.%Y')|; s|@HOST@|$(hostname)|" "$SVC"
    ok "$SVC"
}

# -----------------------------------------------------------------------------
#  Dienste neu laden
# -----------------------------------------------------------------------------
restart_audio() {
    info "Starte WirePlumber neu (Lautstärke-Fix aktivieren)"
    local units=()
    for u in wireplumber pipewire pipewire-pulse; do
        systemctl --user is-active --quiet "$u.service" && units+=("$u.service")
    done
    if [[ ${#units[@]} -gt 0 ]]; then
        systemctl --user restart "${units[@]}" || warn "Neustart von ${units[*]} fehlgeschlagen"
    else
        warn "Keine laufenden Audio-Dienste gefunden - Fix wirkt ab der nächsten Anmeldung."
    fi
}

check_bluetooth() {
    command -v bluetoothctl >/dev/null || return 0
    local bt
    bt="$(timeout 5 bluetoothctl devices 2>/dev/null | grep -i cetra || true)"
    if [[ -n "$bt" ]]; then
        warn "Die Cetra sind hier zusätzlich per Bluetooth gekoppelt:"
        printf '     %s\n' "$bt"
        warn "Diese Kopplung fängt die Tasten ab. Entfernen mit: bluetoothctl remove <MAC-Adresse>"
    fi
}

# -----------------------------------------------------------------------------
#  Installieren / Entfernen
# -----------------------------------------------------------------------------
do_install() {
    check_prereqs
    write_wireplumber_conf
    write_udev_rules
    write_script
    write_service

    info "Aktiviere Dienst"
    systemctl --user daemon-reload
    systemctl --user enable rog-cetra-buttons.service >/dev/null 2>&1
    systemctl --user restart rog-cetra-buttons.service
    restart_audio
    check_bluetooth

    sleep 2
    info "Letzte Meldungen des Dienstes:"
    journalctl --user -u rog-cetra-buttons -n 4 --no-pager -o cat 2>/dev/null || true
    echo
    ok "Fertig. Alle Erklärungen stehen im Kommentar von $SVC"
}

do_uninstall() {
    [[ $EUID -ne 0 ]] || die "Bitte als normaler Benutzer ausführen, nicht als root."
    info "Entferne ROG-Cetra-Anpassungen"
    systemctl --user disable --now rog-cetra-buttons.service 2>/dev/null || true
    rm -f "$BIN" "$WP_CONF05" "$WP_CONF04"
    rm -rf "$CACHE"
    sudo rm -f "$UDEV_RULE"
    sudo udevadm control --reload
    rm -f "$SVC"
    systemctl --user daemon-reload
    restart_audio
    ok "Alles entfernt. (Eine entfernte Bluetooth-Kopplung kann bei Bedarf neu angelegt werden.)"
}

case "${1:-}" in
    ""|--install)  do_install ;;
    --uninstall)   do_uninstall ;;
    -h|--help)     usage ;;
    *)             usage; exit 1 ;;
esac
