#!/usr/bin/env python3
"""Converts a ZMK keymap + physical layout into keymap.json for the TotemStatus layout viewer.

Usage: gen-keymap.py <keymap> <layouts.dtsi> <out.json>

Labels may contain SF Symbols as "{sf:name}" and OS-dependent modifier glyphs as
"{gui}", "{alt}", "{ctrl}", "{shift}" (the app renders them for macOS or Windows).
"""
import json
import re
import sys

MODS = {
    "LCTRL": "{ctrl}", "RCTRL": "{ctrl}", "LCTL": "{ctrl}", "RCTL": "{ctrl}",
    "LALT": "{alt}", "RALT": "{alt}",
    "LGUI": "{gui}", "RGUI": "{gui}", "LCMD": "{gui}", "RCMD": "{gui}", "LWIN": "{gui}", "RWIN": "{gui}",
    "LSHFT": "{shift}", "RSHFT": "{shift}", "LSHIFT": "{shift}", "RSHIFT": "{shift}",
}
MOD_FUNCS = {"LC": "{ctrl}", "RC": "{ctrl}", "LA": "{alt}", "RA": "{alt}",
             "LG": "{gui}", "RG": "{gui}", "LS": "{shift}", "RS": "{shift}"}

KEYS = {
    "SEMI": ";", "SEMICOLON": ";", "COMMA": ",", "DOT": ".", "PERIOD": ".", "FSLH": "/", "SLASH": "/",
    "BSLH": "\\", "BACKSLASH": "\\", "SQT": "'", "APOS": "'", "SINGLE_QUOTE": "'", "DQT": '"',
    "DOUBLE_QUOTES": '"', "GRAVE": "`", "TILDE": "~", "EXCL": "!", "EXCLAMATION": "!", "AT": "@",
    "AT_SIGN": "@", "HASH": "#", "POUND": "#", "DLLR": "$", "DOLLAR": "$", "PRCNT": "%",
    "PERCENT": "%", "CARET": "^", "AMPS": "&", "AMPERSAND": "&", "STAR": "*", "ASTERISK": "*",
    "LPAR": "(", "RPAR": ")", "LBKT": "[", "RBKT": "]", "LBRC": "{", "RBRC": "}", "MINUS": "-",
    "UNDER": "_", "UNDERSCORE": "_", "EQUAL": "=", "PLUS": "+", "PIPE": "|", "QMARK": "?",
    "QUESTION": "?", "LT": "<", "LESS_THAN": "<", "GT": ">", "GREATER_THAN": ">",
    "SPACE": "{sf:space}", "SPC": "{sf:space}", "RET": "{sf:return}", "ENTER": "{sf:return}",
    "RETURN": "{sf:return}", "BSPC": "{sf:delete.left}", "BACKSPACE": "{sf:delete.left}",
    "DEL": "{sf:delete.right}", "DELETE": "{sf:delete.right}", "TAB": "{sf:arrow.right.to.line}",
    "ESC": "esc", "ESCAPE": "esc", "CAPS": "{sf:capslock}", "CAPSLOCK": "{sf:capslock}",
    "INS": "ins", "INSERT": "ins", "HOME": "home", "END": "end", "PG_UP": "pg{sf:arrow.up}",
    "PG_DN": "pg{sf:arrow.down}", "LEFT": "{sf:arrow.left}", "RIGHT": "{sf:arrow.right}",
    "UP": "{sf:arrow.up}", "DOWN": "{sf:arrow.down}",
    "C_MUTE": "{sf:speaker.slash.fill}", "C_VOL_UP": "{sf:speaker.wave.3.fill}",
    "C_VOL_DN": "{sf:speaker.wave.1.fill}", "C_PREV": "{sf:backward.fill}",
    "C_NEXT": "{sf:forward.fill}", "C_PP": "{sf:playpause.fill}", "C_PLAY_PAUSE": "{sf:playpause.fill}",
    "C_BRI_UP": "{sf:sun.max.fill}", "C_BRI_DN": "{sf:sun.min.fill}",
    "PSCRN": "prt", "PRINTSCREEN": "prt",
}
KEYS.update({f"N{i}": str(i) for i in range(10)})
KEYS.update({f"NUMBER_{i}": str(i) for i in range(10)})
KEYS.update({f"F{i}": f"F{i}" for i in range(1, 25)})

KEY_NAMES = {  # tooltip names for symbol-only keys
    "SPACE": "Spacja", "RET": "Enter", "ENTER": "Enter", "BSPC": "Backspace", "DEL": "Delete",
    "TAB": "Tab", "CAPS": "Caps Lock", "LEFT": "Strzałka w lewo", "RIGHT": "Strzałka w prawo",
    "UP": "Strzałka w górę", "DOWN": "Strzałka w dół", "C_MUTE": "Wycisz", "C_VOL_UP": "Głośniej",
    "C_VOL_DN": "Ciszej", "C_PREV": "Poprzedni utwór", "C_NEXT": "Następny utwór",
    "C_PP": "Play/Pauza", "C_BRI_UP": "Jaśniej", "C_BRI_DN": "Ciemniej", "PG_UP": "Page Up",
    "PG_DN": "Page Down",
}
MOD_NAMES = {"{ctrl}": "Control", "{alt}": "Option/Alt", "{gui}": "Command/Win", "{shift}": "Shift"}


def key_label(code):
    """'LG(LS(LBKT))' -> '{gui}{shift}['"""
    m = re.fullmatch(r"(\w+)\((.*)\)", code)
    if m and m.group(1) in MOD_FUNCS:
        return MOD_FUNCS[m.group(1)] + key_label(m.group(2))
    if code in MODS:
        return MODS[code]
    if code in KEYS:
        return KEYS[code]
    if re.fullmatch(r"[A-Z]", code):
        return code
    return code.replace("C_", "").replace("_", " ").lower()


def key_desc(code):
    m = re.fullmatch(r"(\w+)\((.*)\)", code)
    if m and m.group(1) in MOD_FUNCS:
        return MOD_NAMES[MOD_FUNCS[m.group(1)]] + " + " + key_desc(m.group(2))
    if code in MODS:
        return MOD_NAMES[MODS[code]]
    return KEY_NAMES.get(code, re.sub(r"\{sf:[^}]*\}", "", key_label(code)) or code)


def binding(tokens):
    b, args = tokens[0], tokens[1:]
    if b in ("trans",):
        return {"kind": "trans"}
    if b == "none":
        return {"kind": "none"}
    if b == "kp":
        return {"kind": "key", "tap": key_label(args[0]), "desc": key_desc(args[0])}
    if b == "mt":
        return {"kind": "mod", "tap": key_label(args[1]), "hold": MODS.get(args[0], args[0]),
                "desc": f"Tap: {key_desc(args[1])} · Przytrzymaj: {key_desc(args[0])}"}
    if b == "lt":
        return {"kind": "layer", "tap": key_label(args[1]), "hold": args[0], "layer": args[0],
                "desc": f"Tap: {key_desc(args[1])} · Przytrzymaj: warstwa {args[0]}"}
    if b in ("mo", "tog", "to", "sl"):
        verb = {"mo": "Przytrzymaj", "tog": "Przełącz", "to": "Przejdź do", "sl": "Jednorazowo"}[b]
        sym = {"mo": "", "tog": "{sf:switch.2} ", "to": "→", "sl": "1×"}[b]
        return {"kind": "layer", "tap": f"{sym}{args[0]}", "layer": args[0],
                "desc": f"{verb}: warstwa {args[0]}"}
    if b == "bt":
        what = args[0].replace("BT_", "")
        lbl = {"CLR": "BT clr", "NXT": "BT →", "PRV": "BT ←", "SEL": f"BT {args[1] if len(args) > 1 else ''}",
               "CLR_ALL": "BT clr*"}.get(what, f"BT {what.lower()}")
        return {"kind": "system", "tap": lbl, "desc": f"Bluetooth: {what}"}
    if b == "out":
        return {"kind": "system", "tap": "out", "desc": f"Wyjście: {args[0]}"}
    if b == "sys_reset":
        return {"kind": "system", "tap": "reset", "desc": "Restart klawiatury"}
    if b == "bootloader":
        return {"kind": "system", "tap": "boot", "desc": "Tryb bootloadera (flashowanie)"}
    if b == "studio_unlock":
        return {"kind": "system", "tap": "studio", "desc": "Odblokuj ZMK Studio"}
    return {"kind": "key", "tap": b, "desc": " ".join(tokens)}


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return re.sub(r"//[^\n]*", "", s)


def block_after(s, start):
    """Returns the {...} block content starting at the first '{' after `start`."""
    i = s.index("{", start)
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "{":
            depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0:
                return s[i + 1:j]
    raise ValueError("unbalanced braces")


def child_nodes(block):
    """Yields (name, body) of direct child nodes in a devicetree block."""
    i = 0
    for m in re.finditer(r"([\w-]+)\s*\{", block):
        if m.start() < i:
            continue
        body = block_after(block, m.start())
        i = m.end() + len(body)
        yield m.group(1), body


def parse_keymap(path):
    src = open(path, encoding="utf-8").read()
    defines = {k: int(v) for k, v in re.findall(r"#define\s+(\w+)\s+(\d+)\b", src)}
    src = strip_comments(src)

    keymap_at = src.index('"zmk,keymap"')
    keymap_block = block_after(src, src.rindex("keymap", 0, keymap_at))
    layers = []
    for name, body in child_nodes(keymap_block):
        label = re.search(r'(?:display-name|label)\s*=\s*"([^"]*)"', body)
        bindings = re.search(r"bindings\s*=\s*<(.*?)>\s*;", body, re.S).group(1)
        chunks = [c.split() for c in bindings.split("&") if c.strip()]
        layers.append({"id": name, "name": label.group(1) if label else name,
                       "keys": [binding(c) for c in chunks]})

    names = [l["name"] for l in layers]

    def layer_index(tok):
        return defines[tok] if tok in defines else (int(tok) if tok.isdigit() else names.index(tok))

    for l in layers:
        for k in l["keys"]:
            if "layer" in k:
                idx = layer_index(k["layer"])
                k["layer"] = idx
                if k.get("hold"):
                    k["hold"] = names[idx]
                k["tap"] = k["tap"].replace(next(n for n, v in defines.items() if v == idx), names[idx]) \
                    if any(v == idx for v in defines.values()) else k["tap"]

    conditional = []
    if '"zmk,conditional-layers"' in src:
        at = src.index('"zmk,conditional-layers"')
        block = block_after(src, src.rindex("conditional_layers", 0, at))
        for _, body in child_nodes(block):
            ifs = re.search(r"if-layers\s*=\s*<([^>]*)>", body).group(1).split()
            then = re.search(r"then-layer\s*=\s*<([^>]*)>", body).group(1).strip()
            conditional.append({"if": [layer_index(t) for t in ifs], "then": layer_index(then)})
    return layers, conditional


def parse_layout(path):
    src = strip_comments(open(path, encoding="utf-8").read())
    keys = []
    for m in re.finditer(r"&key_physical_attrs((?:\s+\(?-?\d+\)?){7})", src):
        w, h, x, y, rot, rx, ry = (int(v.strip("()")) for v in m.group(1).split())
        keys.append({"w": w, "h": h, "x": x, "y": y, "rot": rot / 100, "rx": rx, "ry": ry})
    return keys


def main():
    keymap, layout, out = sys.argv[1:4]
    layers, conditional = parse_keymap(keymap)
    keys = parse_layout(layout)
    for l in layers:
        if len(l["keys"]) != len(keys):
            sys.exit(f"Layer {l['name']} has {len(l['keys'])} keys, layout has {len(keys)}")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"layout": keys, "layers": layers, "conditional": conditional}, f,
                  ensure_ascii=False, indent=1)
    print(f"keymap.json: {len(layers)} layers, {len(keys)} keys")


if __name__ == "__main__":
    main()
