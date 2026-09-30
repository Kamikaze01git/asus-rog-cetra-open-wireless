# ROG Cetra Open Wireless on Linux (Steam Deck, Debian, Fedora …)

Make the **ASUS ROG Cetra Open Wireless** open-ear gaming earbuds work properly on Linux
when connected via their **2.4 GHz USB-C dongle** (ROG SpeedNova):

- ✅ **Volume slider works across its full range** (out of the box only the first ~5 % of the slider do anything)
- ✅ **Tap controls on the ear hooks work** (out of the box they do nothing useful on Linux)
- ✅ **Freely assignable gestures** – 1–4 taps, left and right = 8 gestures
- ✅ **Audible confirmation tones** (mute, mic mute, play/pause) and the normal Steam volume overlay
- ✅ Mic and audio at the same time, low latency, no Bluetooth involved

Tested on the **Steam Deck (SteamOS, gaming and desktop mode)** and a **Debian laptop**.
Should work on any distribution with PipeWire + WirePlumber and systemd.

> Deutsch: Eine kurze deutsche Zusammenfassung steht [unten](#deutsch).

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

**Steam Deck:** run it in desktop mode (Konsole) or via SSH. Everything is installed to
your home directory and `/etc`, so it survives reboots and SteamOS updates. Nothing on the
read-only system image is touched.

### Requirements

- PipeWire + WirePlumber (0.4 and 0.5 are both handled), systemd, Python 3
- `pw-play` for the confirmation tones (Debian: `pipewire-bin`, Fedora: `pipewire-utils`)
- A local desktop session (the device permissions use `uaccess`, i.e. the logged-in seat user)

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

### Confirmation tones

| Action                | Tone                                   |
|-----------------------|----------------------------------------|
| Volume up/down        | short tick (+ Steam volume overlay)    |
| Output mute / unmute  | 3 low tones, falling / rising          |
| Mic mute / unmute     | 3 high tones, falling / rising         |
| Pause / Play          | 2 tones, falling / rising              |
| No media player found | 1 long low tone (normal inside games)  |

Tone loudness is compensated for the current volume (`TONE_LEVEL` in the script).

---

## ⚠️ Important

- **Do not also pair the earbuds via Bluetooth to the same computer.** The earbuds support
  "hybrid multipoint"; a parallel Bluetooth connection (AVRCP) grabs the button events.
  Check with `bluetoothctl devices | grep -i cetra` and remove with `bluetoothctl remove <MAC>`.
- **USB-C passthrough charging:** works fine with the Steam Deck (the author charged the
  Deck through the dongle the whole time). With a **laptop charger (65 W+)** the dongle kept
  rebooting (it briefly re-enumerates as a MediaTek device `0e8d:0003`) and the laptop did
  not charge. Use a separate USB-C port for charging laptops.

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

**How the script handles it:**

1. Reads the raw gestures from hidraw (found by USB ID, survives re-plugging).
2. Grabs (`EVIOCGRAB`) the Consumer Control input device so the hard-wired keys no longer
   reach the system – otherwise every gesture would trigger two actions.
3. Executes the configured action:
   - volume up/down via a virtual **uinput** keyboard → identical to the Steam Deck's own
     volume buttons, including the Steam overlay
   - mute / mic mute via `wpctl`
   - play/pause / next / previous via **MPRIS** (`busctl --user`) to the currently playing player
4. Plays a short confirmation tone via `pw-play`, gain-compensated for the current sink volume.

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

Issues and pull requests are welcome – especially reports from other distributions,
other dongle firmware versions, or other ASUS SpeedNova devices that might use the same
`cc 22 43` report format.

## Credits

Developed by **Kamikaze01git** together with **Claude (Anthropic)**: testing, hardware
analysis and requirements by the author; protocol analysis and code written with Claude.

## License

MIT – see [LICENSE](LICENSE).

---

## Deutsch

Macht die **ASUS ROG Cetra Open Wireless** (über den 2,4-GHz-Dongle) unter Linux voll nutzbar:
Lautstärkeregler über den ganzen Bereich, frei belegbare Tipp-Gesten an den Ohrbügeln mit
Bestätigungstönen, Mikro und Ton gleichzeitig ohne Bluetooth-Latenz. Getestet auf dem
Steam Deck und einem Debian-Laptop.

```bash
curl -O https://raw.githubusercontent.com/Kamikaze01git/rog-cetra-linux/main/install-rog-cetra.sh
bash install-rog-cetra.sh            # installieren
bash install-rog-cetra.sh --uninstall  # entfernen
```

Alle Details und Erklärungen stehen zusätzlich (auf Englisch) als Kommentar in
`~/.config/systemd/user/rog-cetra-buttons.service`.
