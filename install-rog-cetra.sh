#!/usr/bin/env bash
# =============================================================================
#  install-rog-cetra.sh
#  Installer for the ASUS ROG Cetra Open Wireless on Linux (2.4 GHz dongle)
#   - Volume fix (WirePlumber uses software volume instead of the dongle mixer)
#   - Tap gestures on the ear hooks (volume, mute, mic mute, play/pause, tracks)
#   - Confirmation tones
#
#  Tested: SteamOS (Steam Deck), Debian. Should work on Fedora and others.
#  Requirements: PipeWire + WirePlumber, systemd, python3.
#
#  Usage (as your normal user, NOT as root - sudo is requested when needed):
#    bash install-rog-cetra.sh              install / update
#    bash install-rog-cetra.sh --uninstall  remove everything
#    bash install-rog-cetra.sh --help       show this help
#
#  Running it again is safe: all files are simply overwritten.
#  Project: https://github.com/Kamikaze01git/rog-cetra-linux
# =============================================================================
set -euo pipefail

BIN="$HOME/.local/bin/rog-cetra-buttons.py"
SVC_DIR="$HOME/.config/systemd/user"
SVC="$SVC_DIR/rog-cetra-buttons.service"
WP_CONF05="$HOME/.config/wireplumber/wireplumber.conf.d/51-rog-cetra-softmixer.conf"
WP_CONF04="$HOME/.config/wireplumber/main.lua.d/51-rog-cetra-softmixer.lua"
UDEV_RULE="/etc/udev/rules.d/70-rog-cetra-open.rules"
MODLOAD="/etc/modules-load.d/rog-cetra-uinput.conf"
CACHE="$HOME/.cache/rog-cetra"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

# -----------------------------------------------------------------------------
#  Prerequisites
# -----------------------------------------------------------------------------
check_prereqs() {
    [[ $EUID -ne 0 ]] || die "Please run as your normal user, not as root (sudo is requested when needed)."

    local missing=()
    for c in python3 systemctl udevadm sudo busctl; do
        command -v "$c" >/dev/null || missing+=("$c")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing programs: ${missing[*]}"

    command -v wpctl >/dev/null || die "wpctl not found - PipeWire + WirePlumber are required.
    Debian: sudo apt install pipewire pipewire-pulse wireplumber
    Fedora: sudo dnf install pipewire wireplumber"

    if ! command -v pw-play >/dev/null; then
        warn "pw-play not found - confirmation tones will not work."
        warn "  Debian: sudo apt install pipewire-bin    Fedora: sudo dnf install pipewire-utils"
    fi

    systemctl --user is-active --quiet pipewire.service \
        || warn "PipeWire is not running for this user (no audio session?). Continuing anyway."
}

wireplumber_minor() {
    # Prints e.g. "0.5" or "0.4"
    wireplumber --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 | cut -d. -f1,2
}

# -----------------------------------------------------------------------------
#  Write files
# -----------------------------------------------------------------------------
write_wireplumber_conf() {
    local ver; ver="$(wireplumber_minor)"
    if [[ "$ver" == 0.4 ]]; then
        info "WirePlumber $ver detected - writing Lua configuration"
        mkdir -p "$(dirname "$WP_CONF04")"
        cat > "$WP_CONF04" <<'EOF'
-- ROG Cetra Open Wireless: use software volume only
-- (the dongle reports a wrong dB scale). Installed by install-rog-cetra.sh
table.insert(alsa_monitor.rules, {
  matches = { { { "device.name", "matches", "alsa_card.usb-*CETRA*" } } },
  apply_properties = { ["api.alsa.soft-mixer"] = true },
})
EOF
        rm -f "$WP_CONF05"
        ok "$WP_CONF04"
    else
        info "WirePlumber ${ver:-?} detected - writing configuration (0.5 format)"
        mkdir -p "$(dirname "$WP_CONF05")"
        cat > "$WP_CONF05" <<'EOF'
# ROG Cetra Open Wireless: use software volume only
# (the dongle reports a wrong dB scale). Installed by install-rog-cetra.sh
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
    info "Writing udev rules (sudo)"
    sudo tee "$UDEV_RULE" >/dev/null <<'EOF'
# ROG Cetra Open Wireless - installed by install-rog-cetra.sh
# Read access for the logged-in user to the raw reports (hidraw) and the
# media keys of the dongle (USB ID 0b05:1cac):
KERNEL=="hidraw*", ATTRS{idVendor}=="0b05", ATTRS{idProduct}=="1cac", MODE="0660", TAG+="uaccess"
KERNEL=="event*", SUBSYSTEM=="input", ATTRS{idVendor}=="0b05", ATTRS{idProduct}=="1cac", TAG+="uaccess"
# Access to uinput (virtual keyboard for volume up/down with the system overlay).
# Already present on SteamOS; applies to the locally logged-in user.
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
EOF
    ok "$UDEV_RULE"

    echo uinput | sudo tee "$MODLOAD" >/dev/null
    sudo modprobe uinput 2>/dev/null || warn "Could not load the uinput kernel module (volume will work without the overlay)."
    ok "$MODLOAD"

    sudo udevadm control --reload
    sudo udevadm trigger --subsystem-match=hidraw --subsystem-match=input --subsystem-match=misc
}

write_script() {
    info "Writing gesture script"
    mkdir -p "$(dirname "$BIN")"
    cat > "$BIN" <<'PYEOF'
#!/usr/bin/env python3
"""ROG Cetra Open Wireless: translate tap gestures from the 2.4 GHz dongle into actions.
Installed by install-rog-cetra.sh - explanations are in the comments of
~/.config/systemd/user/rog-cetra-buttons.service

Protocol (hidraw): cc 22 43 00 00 <side 00=L/01=R> <number of taps 1-4>
- The hard-wired ASUS media keys are grabbed exclusively (EVIOCGRAB).
- Volume up/down use a virtual keyboard (uinput) -> system/Steam volume overlay.
- Every action is confirmed with its own tone at a (mostly) constant loudness."""
import fcntl, glob, math, os, struct, subprocess, time, wave

VID, PID = "0B05", "1CAC"
SIDE = {0x00: "L", 0x01: "R"}
SINK, SOURCE = "@DEFAULT_AUDIO_SINK@", "@DEFAULT_AUDIO_SOURCE@"
MPRIS_PATH, MPRIS_IF = "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player"
SOUND_DIR = os.path.expanduser("~/.cache/rog-cetra")
TONE_LEVEL = 0.2  # constant loudness of the confirmation tones (0..1) - adjust as needed

# Linux constants
EVIOCGRAB = 0x40044590                              # grab an input device exclusively
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_SETUP, UI_DEV_CREATE = 0x405C5503, 0x5501
EV_SYN, EV_KEY = 0, 1
KEY_VOLUMEDOWN, KEY_VOLUMEUP = 114, 115

KEYS = None  # virtual keyboard, created in main()

class VirtualKeys:
    """Virtual keyboard via uinput - to the system it looks like real keys."""
    def __init__(self):
        self.fd = None
        try:
            fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
            fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
            for k in (KEY_VOLUMEDOWN, KEY_VOLUMEUP):
                fcntl.ioctl(fd, UI_SET_KEYBIT, k)
            fcntl.ioctl(fd, UI_DEV_SETUP,
                        struct.pack("HHHH80sI", 0x06, 0x1234, 0x5678, 1, b"ROG Cetra Gestures", 0))
            fcntl.ioctl(fd, UI_DEV_CREATE)
            self.fd = fd
            print("Virtual keyboard created", flush=True)
        except OSError as e:
            print(f"uinput not available ({e}) - falling back to wpctl", flush=True)

    def tap(self, code):
        for v in (1, 0):  # press, release
            os.write(self.fd, struct.pack("llHHi", 0, 0, EV_KEY, code, v))
            os.write(self.fd, struct.pack("llHHi", 0, 0, EV_SYN, 0, 0))

def make_tone(name, freqs, ms=80, rate=48000, vol=0.9):
    """Creates a short WAV file with a tone sequence once (frequency 0 = silence)."""
    path = os.path.join(SOUND_DIR, name + ".wav")
    if os.path.exists(path):
        return path
    os.makedirs(SOUND_DIR, exist_ok=True)
    n = int(rate * ms / 1000)
    frames = bytearray()
    for f in freqs:
        for i in range(n):
            fade = min(1.0, i / 200, (n - i) / 200)  # soft edges to avoid clicks
            frames += struct.pack("<h", int(32767 * vol * fade * math.sin(2 * math.pi * f * i / rate)))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(frames))
    return path

TONE_TICK    = make_tone("tick_v3",    [880], ms=50)            # volume up/down
TONE_MIC_ON  = make_tone("mic_on_v3",  [784, 988, 1175])        # high, rising
TONE_MIC_OFF = make_tone("mic_off_v3", [1175, 988, 784])        # high, falling
TONE_SPK_ON  = make_tone("spk_on_v3",  [392, 494, 587])         # low, rising
TONE_SPK_OFF = make_tone("spk_off_v3", [587, 494, 392])         # low, falling
TONE_PLAY    = make_tone("play_v3",    [523, 0, 784], ms=90)    # two tones, rising
TONE_PAUSE   = make_tone("pause_v3",   [784, 0, 523], ms=90)    # two tones, falling
TONE_ERROR   = make_tone("error_v3",   [220], ms=250)           # no media player found

def sink_linear():
    """Current output volume as a linear factor (wpctl shows a cubic scale)."""
    out = subprocess.run(["wpctl", "get-volume", SINK], capture_output=True, text=True).stdout
    try:
        v = float(out.split()[1])
    except (IndexError, ValueError):
        return 1.0
    return max(v ** 3, 1e-4)

def play_tone(path):
    """Plays a tone so that it sounds equally loud regardless of the current volume."""
    gain = min(TONE_LEVEL / sink_linear(), 100.0)
    subprocess.run(["pw-play", "--volume", f"{gain:.3f}", path], check=False)

def key(code, *fallback):
    """Presses a virtual key (or runs a fallback command)."""
    if KEYS is not None and KEYS.fd is not None:
        KEYS.tap(code)
    else:
        subprocess.run(list(fallback), check=False)

def volume(code, *fallback):
    """Creates a volume up/down action with a short tick as confirmation."""
    def action():
        key(code, *fallback)
        play_tone(TONE_TICK)
    return action

def mic_toggle():
    """Toggles mic mute and confirms with a tone."""
    subprocess.run(["wpctl", "set-mute", SOURCE, "toggle"], check=False)
    state = subprocess.run(["wpctl", "get-volume", SOURCE], capture_output=True, text=True).stdout
    muted = "MUTED" in state
    print(f"  mic {'muted' if muted else 'on'}", flush=True)
    play_tone(TONE_MIC_OFF if muted else TONE_MIC_ON)

def sink_toggle():
    """Toggles output mute. When muting, play the tone first - otherwise it would be inaudible."""
    state = subprocess.run(["wpctl", "get-volume", SINK], capture_output=True, text=True).stdout
    if "MUTED" in state:
        subprocess.run(["wpctl", "set-mute", SINK, "0"], check=False)
        print("  output on", flush=True)
        play_tone(TONE_SPK_ON)
    else:
        print("  output muted", flush=True)
        play_tone(TONE_SPK_OFF)
        subprocess.run(["wpctl", "set-mute", SINK, "1"], check=False)

def player_status(p):
    """Returns the playback status of an MPRIS player (Playing/Paused/Stopped)."""
    return subprocess.run(["busctl", "--user", "get-property", p, MPRIS_PATH,
                           MPRIS_IF, "PlaybackStatus"], capture_output=True, text=True).stdout

def media(method):
    """Sends an MPRIS command to the player that is currently playing. Returns the player or None."""
    out = subprocess.run(["busctl", "--user", "list", "--no-legend"],
                         capture_output=True, text=True).stdout
    players = [l.split()[0] for l in out.splitlines() if l.startswith("org.mpris.MediaPlayer2.")]
    target = next((p for p in players if "Playing" in player_status(p)), None)
    if target is None and players:
        target = players[0]  # nothing is playing: use the first player
    if target:
        subprocess.run(["busctl", "--user", "call", target, MPRIS_PATH, MPRIS_IF, method],
                       check=False)
    else:
        print("  no media player found", flush=True)
    return target

def track(method):
    """Creates a next/previous track action; error tone if no player is available."""
    def action():
        if not media(method):
            play_tone(TONE_ERROR)
    return action

def playpause():
    """Toggles play/pause and confirms with a distinct tone for playing or paused."""
    target = media("PlayPause")
    if not target:
        play_tone(TONE_ERROR)
        return
    time.sleep(0.3)  # give the player time to report its new state
    playing = "Playing" in player_status(target)
    print(f"  {'playing' if playing else 'paused'}", flush=True)
    play_tone(TONE_PLAY if playing else TONE_PAUSE)

# (side, taps) -> (description, action). Change the mapping here as you like.
ACTIONS = {
    ("R", 1): ("Volume up",          volume(KEY_VOLUMEUP, "wpctl", "set-volume", "-l", "1.0", SINK, "5%+")),
    ("L", 1): ("Volume down",        volume(KEY_VOLUMEDOWN, "wpctl", "set-volume", SINK, "5%-")),
    ("R", 2): ("Mute output on/off", sink_toggle),
    ("L", 2): ("Mute mic on/off",    mic_toggle),
    ("R", 3): ("Play/Pause",         playpause),
    ("L", 3): ("Play/Pause",         playpause),
    ("R", 4): ("Next track",         track("Next")),
    ("L", 4): ("Previous track",     track("Previous")),
}

def find_hidraw():
    """Finds the dongle's hidraw interface by vendor/product ID."""
    for dev in glob.glob("/sys/class/hidraw/hidraw*"):
        try:
            with open(os.path.join(dev, "device/uevent")) as f:
                if f"HID_ID=0003:0000{VID}:0000{PID}" in f.read().upper():
                    return "/dev/" + os.path.basename(dev)
        except OSError:
            pass
    return None

def find_consumer_event():
    """Finds the input device carrying the ASUS media keys ('... Consumer Control')."""
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
    """Grabs the ASUS media keys exclusively. Returns the file descriptor or None."""
    path = find_consumer_event()
    if not path:
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        fcntl.ioctl(fd, EVIOCGRAB, 1)
        print(f"Native media keys grabbed ({path})", flush=True)
        return fd
    except OSError as e:
        print(f"Could not grab {path}: {e}", flush=True)
        return None

def main():
    global KEYS
    KEYS = VirtualKeys()
    while True:
        path = find_hidraw()
        if not path:
            time.sleep(2)
            continue
        try:
            fd = os.open(path, os.O_RDONLY)
        except PermissionError:
            print(f"No read access to {path} - check the udev rule", flush=True)
            time.sleep(5)
            continue
        except OSError:
            time.sleep(2)
            continue
        print(f"Listening on {path}", flush=True)
        time.sleep(0.5)  # give the key device time to appear after plugging in
        grab_fd = grab_native_keys()
        try:
            while True:
                data = os.read(fd, 256)  # blocks until the next report
                i = data.find(b"\xcc\x22\x43")  # look for the signature anywhere in the report
                if i < 0 or len(data) < i + 7:
                    continue  # e.g. the consumer key reports (0c xx) - ignore
                if grab_fd is None:
                    grab_fd = grab_native_keys()  # retry if it was missing at startup
                side, taps = SIDE.get(data[i + 5], "?"), data[i + 6]
                entry = ACTIONS.get((side, taps))
                print(f"Gesture {side}{taps}" + (f" -> {entry[0]}" if entry else ""), flush=True)
                if entry:
                    try:
                        entry[1]()
                    except Exception as e:  # a failing action must not kill the service
                        print(f"  Error: {e}", flush=True)
        except OSError:
            print("Dongle disconnected, waiting for it to come back ...", flush=True)
        finally:
            os.close(fd)
            if grab_fd is not None:
                os.close(grab_fd)  # closing releases the grab automatically
        time.sleep(1)

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "$BIN"
    python3 -m py_compile "$BIN" || die "The gesture script contains an error."
    ok "$BIN"
}

write_service() {
    info "Writing systemd user service"
    mkdir -p "$SVC_DIR"
    cat > "$SVC" <<'EOF'
# =============================================================================
#  ROG Cetra Open Wireless - tap gestures & volume fix
#  Installed on @DATE@ on @HOST@ by install-rog-cetra.sh
#  Project: https://github.com/Kamikaze01git/rog-cetra-linux
# =============================================================================
#
#  WHY?
#  The ASUS ROG Cetra Open Wireless (2.4 GHz dongle, USB ID 0b05:1cac) do not
#  work properly on Linux out of the box:
#   - The volume slider only worked on the first ~5 % (the dongle reports a
#     wrong dB scale). -> Fix: WirePlumber uses software volume only.
#   - The ear-hook buttons only report raw gestures (side + number of taps)
#     in a vendor-specific protocol. -> Fix: the script reads them and runs
#     the configured action.
#   - The hard-wired ASUS media keys are grabbed exclusively by the script
#     ("grab") so the system does not react twice.
#
#  GESTURE MAPPING (change it in the script under ACTIONS)
#   Gesture     Right                  Left
#   1x tap      Volume up              Volume down
#   2x tap      Mute output on/off     Mute mic on/off
#   3x tap      Play/Pause             Play/Pause
#   4x tap      Next track             Previous track
#
#  CONFIRMATION TONES
#   Volume up/down    short tick (+ system volume overlay)
#   Output mute/on    3 low tones, falling / rising
#   Mic mute/on       3 high tones, falling / rising
#   Pause/Play        2 tones, falling / rising
#   Error             1 long low tone = no media player found
#                     (normal inside games, they do not offer MPRIS)
#   Tone loudness:    TONE_LEVEL in the script
#
#  ALL CHANGES
#   What                Where
#   Gesture script      ~/.local/bin/rog-cetra-buttons.py
#   This service        ~/.config/systemd/user/rog-cetra-buttons.service
#                       (+ link in ~/.config/systemd/user/default.target.wants/)
#   Volume fix          WirePlumber 0.5: ~/.config/wireplumber/wireplumber.conf.d/51-rog-cetra-softmixer.conf
#                       WirePlumber 0.4: ~/.config/wireplumber/main.lua.d/51-rog-cetra-softmixer.lua
#                       (only affects audio devices with "CETRA" in their name)
#   udev rules          /etc/udev/rules.d/70-rog-cetra-open.rules
#                       (read access only for USB ID 0b05:1cac + access to uinput)
#   uinput module       /etc/modules-load.d/rog-cetra-uinput.conf
#   Tone files          ~/.cache/rog-cetra/*.wav (generated by the script)
#
#  IMPORTANT: Do NOT additionally pair the Cetra with this computer via Bluetooth!
#  A parallel Bluetooth connection grabs the button events. Check / remove:
#   bluetoothctl devices | grep -i cetra
#   bluetoothctl remove <MAC address>
#
#  Other devices (controllers, other headsets, USB devices) are not affected.
#  Without the ASUS dongle the script only checks every 2 s whether it is present.
#
#  USEFUL COMMANDS
#   Status:            systemctl --user status rog-cetra-buttons
#   Live log:          journalctl --user -u rog-cetra-buttons -f
#   Log since boot:    journalctl --user -u rog-cetra-buttons -b
#   Restart:           systemctl --user restart rog-cetra-buttons
#                      (required after every change to the script)
#   Check volume:      wpctl get-volume @DEFAULT_AUDIO_SINK@
#   Unmute:            wpctl set-mute @DEFAULT_AUDIO_SINK@ 0
#                      (PipeWire remembers "muted" across reboots!)
#
#  AFTER A SYSTEM UPDATE
#   Usually everything survives. If the buttons stop working:
#   Run the installer again:  bash install-rog-cetra.sh
#   or manually:
#    sudo udevadm control --reload
#    sudo udevadm trigger --subsystem-match=input --subsystem-match=hidraw --subsystem-match=misc
#    systemctl --user restart rog-cetra-buttons
#
#  REMOVE EVERYTHING
#   Easiest:  bash install-rog-cetra.sh --uninstall
#   Or manually:
#    systemctl --user disable --now rog-cetra-buttons.service
#    rm ~/.local/bin/rog-cetra-buttons.py
#    rm -f ~/.config/wireplumber/wireplumber.conf.d/51-rog-cetra-softmixer.conf
#    rm -f ~/.config/wireplumber/main.lua.d/51-rog-cetra-softmixer.lua
#    rm -r ~/.cache/rog-cetra
#    sudo rm /etc/udev/rules.d/70-rog-cetra-open.rules /etc/modules-load.d/rog-cetra-uinput.conf
#    sudo udevadm control --reload
#    rm ~/.config/systemd/user/rog-cetra-buttons.service    (this file - last!)
#    systemctl --user daemon-reload
#    systemctl --user restart wireplumber
# =============================================================================

[Unit]
Description=ROG Cetra Open Wireless tap gestures
After=pipewire.service wireplumber.service

[Service]
ExecStart=/usr/bin/python3 %h/.local/bin/rog-cetra-buttons.py
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    sed -i "s|@DATE@|$(date '+%Y-%m-%d')|; s|@HOST@|$(hostname)|" "$SVC"
    ok "$SVC"
}

# -----------------------------------------------------------------------------
#  Reload services
# -----------------------------------------------------------------------------
restart_audio() {
    info "Restarting WirePlumber (activating the volume fix)"
    local units=()
    for u in wireplumber pipewire pipewire-pulse; do
        systemctl --user is-active --quiet "$u.service" && units+=("$u.service")
    done
    if [[ ${#units[@]} -gt 0 ]]; then
        systemctl --user restart "${units[@]}" || warn "Restarting ${units[*]} failed"
    else
        warn "No running audio services found - the fix takes effect at the next login."
    fi
}

check_bluetooth() {
    command -v bluetoothctl >/dev/null || return 0
    local bt
    bt="$(timeout 5 bluetoothctl devices 2>/dev/null | grep -i cetra || true)"
    if [[ -n "$bt" ]]; then
        warn "The Cetra are additionally paired with this computer via Bluetooth:"
        printf '     %s\n' "$bt"
        warn "This pairing grabs the button events. Remove it with: bluetoothctl remove <MAC address>"
    fi
}

# -----------------------------------------------------------------------------
#  Install / uninstall
# -----------------------------------------------------------------------------
do_install() {
    check_prereqs
    write_wireplumber_conf
    write_udev_rules
    write_script
    write_service

    info "Enabling service"
    systemctl --user daemon-reload
    systemctl --user enable rog-cetra-buttons.service >/dev/null 2>&1
    systemctl --user restart rog-cetra-buttons.service
    restart_audio
    check_bluetooth

    sleep 2
    info "Latest service messages:"
    journalctl --user -u rog-cetra-buttons -n 4 --no-pager -o cat 2>/dev/null || true
    echo
    ok "Done. All explanations are in the comments of $SVC"
}

do_uninstall() {
    [[ $EUID -ne 0 ]] || die "Please run as your normal user, not as root."
    info "Removing ROG Cetra customisations"
    systemctl --user disable --now rog-cetra-buttons.service 2>/dev/null || true
    rm -f "$BIN" "$WP_CONF05" "$WP_CONF04"
    rm -rf "$CACHE"
    sudo rm -f "$UDEV_RULE" "$MODLOAD"
    sudo udevadm control --reload
    rm -f "$SVC"
    systemctl --user daemon-reload
    restart_audio
    ok "Everything removed. (A removed Bluetooth pairing can be re-created if needed.)"
}

case "${1:-}" in
    ""|--install)  do_install ;;
    --uninstall)   do_uninstall ;;
    -h|--help)     usage ;;
    *)             usage; exit 1 ;;
esac
