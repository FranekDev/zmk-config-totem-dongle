# Totem Status (macOS menu bar)

Shows Win/Mac mode and battery of both Totem halves in the menu bar, and lets you switch Win/Mac mode.

Requires dongle firmware with `CONFIG_TOTEM_STATUS=y` (see `modules/totem_status` and
`config/boards/shields/totem/totem_dongle.conf`). Communication: raw HID, usage page 0xFF60 / usage 0x61.

## Build & install

    ./build-app.sh
    cp -R TotemStatus.app /Applications/ && open /Applications/TotemStatus.app

Works with Command Line Tools only (no Xcode needed). macOS 26+.

## Protocol (32-byte reports)

Host -> dongle: `[0xA7, cmd, arg]`, cmd: `0x01` get state, `0x02` set OS (arg 0 = mac, 1 = win), `0x03` toggle.

Dongle -> host: `[0xA7, 0x81, ver, win, highest_layer, layer_mask(4, LE), N, battery[N]...]`.
After the batteries: `connected_mask` (v2+), `left_slot` (v3+, 0xFF = unknown), then
`voltage_mv[N]` as uint16 LE (v4+, 0 = unknown), then a bitmask of halves on USB power (v5+;
their % is shown as approximate, since on USB the charger drives the battery pin), then the
RSSI of each half's link as int8 dBm (v6+, 0 = unknown), then the charger state (v7+): bit i =
the charger of slot i is charging, bit 4+i = the half reports it. On USB and not charging = full.

While a half is on a cable its voltage is the charger's, so the app estimates the level instead:
the last reading on battery plus the time on the cable times a charge rate, which it corrects
after every charge from the reading once the half is back on battery.

Key press counts (v6+): host sends `[0xA7, 0x04, chunk]`, dongle answers
`[0xA7, 0x82, boot_id(4, LE), total, first, count, count × uint32 LE]`, cumulative per key position
since the dongle booted. The app asks chunk by chunk and adds the difference to its own totals
(`~/Library/Application Support/TotemStatus/key-stats.json`); a new boot id means the counters
restarted. Battery history lives next to it in `battery-history.json` (30 days).

- `0` battery means nearly empty, not disconnected; use `connected_mask` for that.
- Slot order follows pairing order; the dongle learns which slot is the left half from the first
  key press on a half.
- Battery % on the halves comes from a LiPo discharge curve (`totem,battery-lipo` sensor in
  `modules/totem_status`) instead of ZMK's linear 3.45–4.2 V scale, and the halves expose the
  voltage over GATT. Both need the halves reflashed; with older half firmware the voltage is 0.

## Icons

Menu bar glyph = the "face" from the TOTEM logo (github.com/GEIGEIGEIST/TOTEM), drawn in code in
`Sources/TotemStatus/TotemIcon.swift`. To regenerate `Resources/AppIcon.icns` from it:

    swiftc -o /tmp/mkicons Sources/TotemStatus/TotemIcon.swift scripts/make-icons/main.swift
    /tmp/mkicons /tmp && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns

## Charging indicator

ZMK forwards only the battery percentage of the halves (no charger status), so "ładuje" / the bolt
is inferred: a half counts as charging after its level rose by ≥3 points, and stops when the level
drops or hasn't risen for 20 minutes. It may take a few minutes after plugging in to show up.

## Layout viewer

"Układ klawiszy" (⌘K in the panel) shows every layer on the real TOTEM geometry, for macOS or
Windows mode (WIN + conditional layers applied). `build-app.sh` regenerates `Resources/keymap.json`
from `config/totem.keymap` and `totem-layouts.dtsi` via `scripts/gen-keymap.py`, so rebuild the app
after changing the keymap. Debug preview: `swift run TotemStatus --preview --layout --layer 2 [--win]`.
