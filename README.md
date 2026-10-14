# ROG Cetra Open Wireless — full Linux & Steam Deck support

Make the **ASUS ROG Cetra Open Wireless** open-ear gaming earbuds work **properly** under
Linux when connected through their **2.4 GHz USB-C dongle** (ROG SpeedNova, USB `0b05:1cac`):

- ✅ **Full-range volume** — out of the box only the first ~5 % of the slider do anything
- ✅ **Ear-hook tap gestures** — 1–4 taps per side, fully re-mappable in the script
- ✅ **Confirmation tones always from the earbuds** — even when another device is the system default
- ✅ **Gestures control the earbuds only** — your default device is never touched or switched
- ✅ **Correct volume overlay** — the on-screen display shows the real earbud level
- ✅ Mic and audio at the same time, low latency, no Bluetooth involved

> 🇩🇪 Eine kurze deutsche Zusammenfassung steht [unten](#deutsch).

**Verified on:** SteamOS on the Steam Deck (*gaming mode* **and** *desktop mode*) and
**Fedora / KDE Plasma**. Should work on any distribution with PipeWire + WirePlumber and systemd.

**New in 1.6?** See [What's new](#whats-new) and the full [CHANGELOG](CHANGELOG.md).

---

## Installation

```bash
curl -O https://raw.githubusercontent.com/Kamikaze01git/rog-cetra-linux/main/install-rog-cetra.sh
bash install-rog-cetra.sh
```

Run it as your **normal user** (not root) – it asks for `sudo` only where needed.
Running it again is safe (it simply overwrites its own files).

Uninstall everything:

```bash
bash install-rog-cetra.sh --uninstall
```

**Steam Deck:** run it in desktop mode (Konsole) or copy it over via `scp` and run it there.
Everything is installed to your home directory and `/etc`, so it survives reboots and
SteamOS updates. Nothing on the read-only system image is touched.

### Requirements

- PipeWire + WirePlumber (0.4 and 0.5 are both handled), systemd, Python 3
- `paplay` **or** `pw-play` for the confirmation tones
  (Debian/SteamOS: `pulseaudio-utils` / `pipewire-bin`, Fedora: `pulseaudio-utils` / `pipewire-utils`)
- `pactl` (part of `pulseaudio-utils`) — used to resolve the earbuds' audio node reliably
- A local desktop session (device permissions use `uaccess`, i.e. the logged-in seat user)

---

## Default gestures

| Taps | Right                | Left               |
|------|----------------------|--------------------|
| 1×   | Volume up            | Volume down        |
| 2×   | Mute output on/off   | Mute mic on/off    |
| 3×   | Play/Pause           | Play/Pause         |
| 4×   | Next track           | Previous track     |

Edit the `ACTIONS` table in `~/.local/bin/rog-cetra-buttons.py`, then
`systemctl --user restart rog-cetra-buttons`.

Self-test (plays every confirmation tone and tells you which audio backend it uses):

```bash
python3 ~/.local/bin/rog-cetra-buttons.py --selftest
```

---

## What's new

The first public version laid the groundwork (volume fix, gesture decoding). **This release
reworks the whole gesture and audio layer** so it behaves like a native device:

- 🎯 **The earbuds are now a real, independent device.**
  Volume up/down, mute and mic-mute always act on the **ROG Cetra** — never on the system
  default. The default output device is **never switched**, so a running call or music
  stream is never diverted.
- 🔔 **Confirmation tones reliably come out of the earbuds.**
  The tone is routed to the earbuds' audio node by name (`paplay --device`, with
  `pw-play`/`PIPEWIRE_NODE` fallbacks) instead of playing on whatever device happens to be
  the system default.
- 🖥️ **Correct volume overlay (KDE Plasma).**
  Plasma's OSD is bound to the default sink, so it used to show the wrong device. The script
  now asks the OSD service to display the **actual earbud level** right after each change.
- 🔇 **No more double actions.** The dongle also emits a few hard-wired media keys; the
  script grabs the input device (`EVIOCGRAB`) so those no longer fire a second time.
- 🧹 **Simpler and more robust internals:** no more virtual `uinput` keyboard, and the audio
  node is resolved via `pw-dump` / `pactl` / `wpctl` with graceful fallbacks.

If you ran an earlier version, just run the installer again — it overwrites everything cleanly.

---

## Confirmation tones

| Action                | Tone                                   |
|-----------------------|----------------------------------------|
| Volume up/down        | short tick                             |
| Output mute / unmute  | 3 low tones, falling / rising          |
| Mic mute / unmute     | 3 high tones, falling / rising         |
| Pause / Play          | 2 tones, falling / rising              |
| No media player found | 1 long low tone (normal inside games)  |

The tones are **always played through the earbuds** and are gain-compensated for the current
volume (`TONE_LEVEL` in the script), so they stay at a constant loudness.

---

## ⚠️ Important

- **Do not also pair the earbuds via Bluetooth to the same computer.** The earbuds support
  "hybrid multipoint"; a parallel Bluetooth connection (AVRCP) grabs the button events.
  Check with `bluetoothctl devices | grep -i cetra` and remove with `bluetoothctl remove <MAC>`.
- **USB-C passthrough charging:** works fine with the Steam Deck (the author charged the
  Deck through the dongle the whole time). With a **laptop charger (65 W+)** the dongle kept
  rebooting (it briefly re-enumerates as a MediaTek device `0e8d:0003`) and the laptop did
  not charge. Use a separate USB-C port for charging laptops.
- **Volume overlay:** the on-screen display always belongs to the *default* sink in
  KDE/GNOME. This project shows the correct earbud level by asking the OSD service directly —
  it never switches your default device to do so.

---

## What the installer does

| What              | Where                                                                 |
|-------------------|-----------------------------------------------------------------------|
| Gesture script    | `~/.local/bin/rog-cetra-buttons.py`                                   |
| systemd user unit | `~/.config/systemd/user/rog-cetra-buttons.service` (fully commented)  |
| Volume fix        | `~/.config/wireplumber/wireplumber.conf.d/51-rog-cetra-softmixer.conf` (WP 0.5) or `main.lua.d/…lua` (WP 0.4) |
| udev rules        | `/etc/udev/rules.d/70-rog-cetra-open.rules` (only USB ID `0b05:1cac` + uinput) |
| uinput module     | `/etc/modules-load.d/rog-cetra-uinput.conf`                           |
| Tone files        | `~/.cache/rog-cetra/*.wav` (generated)                                |

Other audio devices, controllers and headsets are not affected.

---

## Technical background

Device: `0b05:1cac ASUSTek Computer, Inc. ROG CETRA OPEN WIRELESS` (dongle firmware bcdDevice 4.25).
The dongle is a standard USB Audio Class device plus a HID interface.

### 1. Broken volume scale

The dongle exposes a hardware mixer `PCM Playback Volume` (range 0–74, reported as
−74 … 0 dB). PipeWire uses this hardware control for the volume slider, but the dB
information does not match reality: only the lowest couple of steps are audible, everything
above is "full volume". Result: the whole slider only acts on the leftmost ~5 %.

**Fix:** tell WirePlumber to leave the hardware mixer alone and use software volume:

```
monitor.alsa.rules = [
  {
    matches = [ { device.name = "~alsa_card.usb-.*CETRA.*" } ]
    actions = { update-props = { api.alsa.soft-mixer = true } }
  }
]
```

### 2. Tap gestures (vendor HID protocol)

The dongle creates an input device *"ASUSTek ROG CETRA OPEN WIRELESS Consumer Control"*
whose key bitmap advertises volume keys – but the ear-hook taps are **not** delivered as
`KEY_VOLUMEUP/DOWN`. Instead every tap gesture is reported on the dongle's **hidraw**
interface as a vendor report:

```
cc 22 43 00 00 <side> <taps> 00 00 …        (64 bytes)
                 │      └─ number of taps: 01 … 04
                 └─ 00 = left, 01 = right
```

Depending on the connection state the report may be prefixed by 4 bytes
(e.g. `0c 10 0c 00 cc 22 43 …`), so the script searches for the `cc 22 43` signature
instead of expecting it at offset 0.

Additionally the firmware sends a few **hard-wired consumer keys** for some gestures:

| Gesture | Consumer key sent by firmware |
|---------|-------------------------------|
| R1      | Play/Pause (164)              |
| R2      | Volume up (115)               |
| L2      | Volume down (114)             |
| R3, R4  | Next song (163)               |
| L1      | – nothing –                   |

These fixed keys are what you get without this project (and only when no parallel
Bluetooth connection steals them).

### 3. How the script handles it

1. Reads the raw gestures from hidraw (found by USB ID, survives re-plugging).
2. Grabs (`EVIOCGRAB`) the Consumer Control input device so the hard-wired keys no longer
   reach the system – otherwise every gesture would trigger two actions.
3. Resolves the **ROG Cetra's own audio node** (`pw-dump` → `pactl` → `wpctl`, with
   fallbacks) — the system default device is left completely alone.
4. Executes the configured action:
   - **volume up/down** → `wpctl` on the earbuds' sink, then shows the correct OSD
   - **mute / mic mute** → `wpctl` on the earbuds' sink/source
   - **play/pause / next / previous** → **MPRIS** (`busctl --user`) to the currently playing player
5. Plays a short confirmation tone **on the earbuds** (`paplay --device`, then
   `pw-play` with `PIPEWIRE_NODE`), gain-compensated for the current volume.

### Handy debugging one-liners

```bash
# which hidraw belongs to the dongle?
for h in /sys/class/hidraw/hidraw*; do echo "$h: $(grep HID_NAME $h/device/uevent)"; done
# watch raw gesture reports (tap the ear hooks)
sudo cat /dev/hidrawN | od -An -tx1
# service log
journalctl --user -u rog-cetra-buttons -f
```

---

## Contributing

Issues and pull requests are welcome – especially reports from other distributions, other
dongle firmware versions, or other ASUS SpeedNova devices that might use the same
`cc 22 43` report format.

## Credits

Developed by **Kamikaze01git**. Testing, hardware analysis and requirements by the author.

Built **in collaboration with AI**: protocol analysis and the original implementation with
**Claude Code (Anthropic)**; the gesture/audio rework, porting and documentation with
**DeepSeek v4.1 Flash** (running inside the OpenHands agent).

## License

MIT – see [LICENSE](LICENSE).

---

## Deutsch

Macht die **ASUS ROG Cetra Open Wireless** (über den 2,4-GHz-Dongle) unter Linux voll nutzbar:
Lautstärkeregler über den ganzen Bereich, frei belegbare Tipp-Gesten an den Ohrbügeln mit
Bestätigungstönen, Mikro und Ton gleichzeitig ohne Bluetooth-Latenz.

**Wichtig:** Alle Gesten und Töne betreffen **ausschließlich die Cetra**. Das
Standard-Ausgabegerät wird **nie** umgeschaltet — ein laufendes Gespräch (z. B. Nextcloud Talk)
oder Musik bleibt unangetastet. Der Bestätigungston kommt immer aus den Ohrhörern, und die
Lautstärke-Einblendung (KDE Plasma) zeigt den korrekten Cetra-Wert.

Getestet auf dem **Steam Deck (SteamOS, Gaming- und Desktop-Modus)** und einem
**Fedora/KDE-Laptop**.

```bash
curl -O https://raw.githubusercontent.com/Kamikaze01git/rog-cetra-linux/main/install-rog-cetra.sh
bash install-rog-cetra.sh               # installieren
bash install-rog-cetra.sh --uninstall   # entfernen
```

Alle Details stehen zusätzlich (auf Englisch) als Kommentar in
`~/.config/systemd/user/rog-cetra-buttons.service`.

> **Hinweis:** Dieses Projekt wurde in Zusammenarbeit mit KI erstellt – Claude Code (Anthropic)
> für die ursprüngliche Protokollanalyse und Umsetzung, DeepSeek v4.1 Flash (im OpenHands-Agent)
> für die Überarbeitung von Gesten/Audio sowie die Dokumentation.
