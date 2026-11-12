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
Battery `0` means the half is disconnected. Slot order follows pairing order; use "Zamień lewą i prawą" if swapped.

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
