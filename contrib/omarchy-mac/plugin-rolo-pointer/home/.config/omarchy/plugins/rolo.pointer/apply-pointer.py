#!/usr/bin/env python3
"""Read, persist, and live-apply mouse, trackpad, and cursor settings for Hyprland.

The single source of truth for pointer, scroll, wheel and cursor settings on this Mac:
~/.config/hypr/pointer-tuning.json holds two profiles, and the active one is written to
~/.config/hypr/pointer-tuning.lua (loaded by hyprland.lua) and applied live.

  custom  the hand-tuned settings (adaptive/flat mouse, trackpad on Apple's curve)
  macos   the owner's macOS 27.3 settings through Apple's own tables (curves.lua): trackpad
          tracking 0.875 / scroll 0.4412, mouse 2.0 / wheel 0.75, natural scrolling, no tap,
          sizes matched to macOS's "looks like" width, per-app scroll normalisation,
          4-finger gestures. Derivations: contrib/omarchy-mac/macos-feel/README.md.

  apply-pointer.py --read                 print the active profile (flat JSON + "profile")
  apply-pointer.py --write JSON           save the active profile's values and apply
  apply-pointer.py --profile custom|macos switch profile and apply
  apply-pointer.py --reset                reset the active profile to its defaults and apply
"""

import json
import os
import re
import subprocess
import sys
import tempfile

HOME = os.path.expanduser("~")
CONFIG_JSON = os.path.join(HOME, ".config", "hypr", "pointer-tuning.json")
CONFIG_LUA = os.path.join(HOME, ".config", "hypr", "pointer-tuning.lua")
MACOS_FEEL = os.path.join(HOME, ".local", "bin", "macos-feel")
PROFILES = ("custom", "macos")

# Values the panel edits (both profiles have all of them).
DEFAULTS = {
    "custom": {
        "trackpad_scroll_factor": 1.0,
        "trackpad_scroll_accel": 1.0,
        "trackpad_tracking": 0.6875,
        "trackpad_gain": 1.0,
        "trackpad_natural_scroll": True,
        "trackpad_tap_to_click": True,
        "trackpad_disable_while_typing": True,
        "trackpad_three_finger_drag": False,
        "mouse_sensitivity": 0.0,
        "mouse_tracking": 2.0,
        "mouse_scroll_factor": 1.0,
        "mouse_accel_profile": "adaptive",
        "mouse_natural_scroll": False,
        "cursor_size": 24,
    },
    "macos": {
        # Trackpad: com.apple.trackpad.scaling 0.875; scroll size at rest 0.68 x libinput's default
        # (calibrated by the owner); full Apple scroll-curve shape.
        "trackpad_scroll_factor": 0.68,
        "trackpad_scroll_accel": 1.0,
        "trackpad_tracking": 0.875,
        "trackpad_gain": 1.0,          # on top of the display factor k
        "trackpad_natural_scroll": True,
        "trackpad_tap_to_click": False,
        "trackpad_disable_while_typing": True,
        "trackpad_three_finger_drag": False,
        "mouse_sensitivity": 0.0,      # only used if the acceleration is set to adaptive/flat
        "mouse_tracking": 2.0,         # com.apple.mouse.scaling
        "mouse_scroll_factor": 1.0,    # multiplies the macOS wheel curve's slow-notch size
        "mouse_accel_profile": "macos",
        "mouse_natural_scroll": True,  # com.apple.swipescrolldirection covers the mouse too
        "cursor_size": 19,             # 17 pt arrow x 1.26 x k / 0.85 (Adwaita)
    },
}

# macOS profile constants (not on the panel; edit the JSON to change them).
MACOS_FIXED = {
    "trackpad_scroll_index": 0.4412,   # com.apple.trackpad.scrolling
    "mouse_wheel_scaling": 0.75,       # com.apple.scrollwheel.scaling
    "mouse_report_hz": 1000,           # G502 X PLUS onboard profile
    "looks_like_width": 2246,          # macOS "looks like" width in points (BetterDisplay)
    "display_scale": 2,                # Hyprland scale of the panel (monitors.lua)
    "app_scroll_rules": True,          # same scroll distance in every toolkit
    "macos_gestures": True,            # 4-finger swipe = workspaces, 4-finger pinch = Apps
}

# The Logitech G502 X PLUS receiver's two interfaces (hyprctl devices). Mouse settings go to these
# per device; other pointers (KM Link's virtual pointer) keep the custom profile's global values.
MOUSE_DEVICES = ["logitech-usb-receiver", "logitech-usb-receiver-keyboard-1"]

ACCEL_PROFILES = ("adaptive", "flat", "macos")


def clamp(val, lo, hi, default):
    try:
        num = float(val)
        if num != num:  # NaN
            return default
        return max(lo, min(hi, num))
    except (TypeError, ValueError):
        return default


def sanitize(raw, profile):
    base = DEFAULTS[profile]
    data = dict(base)
    if not isinstance(raw, dict):
        return data
    def num(key, lo, hi, digits):
        data[key] = round(clamp(raw.get(key), lo, hi, base[key]), digits)
    num("trackpad_scroll_factor", 0.1, 3.0, 3)
    num("trackpad_scroll_accel", 0.0, 1.0, 3)
    num("trackpad_tracking", 0.0, 3.0, 4)
    num("trackpad_gain", 0.4, 2.0, 3)
    num("mouse_sensitivity", -1.0, 1.0, 3)
    num("mouse_tracking", 0.0, 3.0, 4)
    num("mouse_scroll_factor", 0.2, 4.0, 3)
    for key in ("trackpad_natural_scroll", "trackpad_tap_to_click", "trackpad_disable_while_typing",
                "trackpad_three_finger_drag", "mouse_natural_scroll"):
        data[key] = bool(raw.get(key, base[key]))
    accel = raw.get("mouse_accel_profile", base["mouse_accel_profile"])
    data["mouse_accel_profile"] = accel if accel in ACCEL_PROFILES else base["mouse_accel_profile"]
    data["cursor_size"] = int(round(clamp(raw.get("cursor_size"), 16, 64, base["cursor_size"])))
    return data


def atomic_write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp_path, path)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


def cursor_theme():
    theme = os.environ.get("XCURSOR_THEME", "Adwaita").strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", theme) or theme == "omarchy-startup":
        return "Adwaita"
    return theme


def load_store():
    """{"profile": name, "profiles": {name: values}, "macos_fixed": {...}}; the old flat file
    (one set of values) becomes the custom profile."""
    raw = None
    if os.path.exists(CONFIG_JSON):
        try:
            with open(CONFIG_JSON, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except Exception:
            raw = None
    store = {"profile": "custom", "profiles": {}, "macos_fixed": dict(MACOS_FIXED)}
    if isinstance(raw, dict) and isinstance(raw.get("profiles"), dict):
        store["profile"] = raw.get("profile") if raw.get("profile") in PROFILES else "custom"
        for p in PROFILES:
            store["profiles"][p] = sanitize(raw["profiles"].get(p), p)
        if isinstance(raw.get("macos_fixed"), dict):
            for key, val in raw["macos_fixed"].items():
                if key in MACOS_FIXED:
                    store["macos_fixed"][key] = val
    else:
        store["profiles"]["custom"] = sanitize(raw, "custom")
        store["profiles"]["macos"] = dict(DEFAULTS["macos"])
    return store


def flat(store):
    out = dict(store["profiles"][store["profile"]])
    out["profile"] = store["profile"]
    return out


def lua_bool(v):
    return "true" if v else "false"


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def generate_lua(store):
    prof = store["profile"]
    cfg = store["profiles"][prof]
    custom = store["profiles"]["custom"]
    fixed = store["macos_fixed"]
    macos = prof == "macos"
    theme = cursor_theme()
    L = []
    w = L.append
    w("-- Auto-generated by rolo.pointer plugin. Do not edit by hand.")
    w(f"-- Profile: {prof}. Values: ~/.config/hypr/pointer-tuning.json (Pointer panel).")
    w('local C = dofile(os.getenv("HOME") .. "/.config/hypr/trackpad/curves.lua")')
    w(f"local k = C.display_k({fixed['display_scale']}, {fixed['looks_like_width']})" if macos else "local k = 1")
    w("")
    # Global mouse settings: every pointer that has no device block (KM Link's virtual pointer).
    g_accel = custom["mouse_accel_profile"] if custom["mouse_accel_profile"] in ("adaptive", "flat") else "adaptive"
    w("hl.config({")
    w("  input = {")
    w(f"    sensitivity = {custom['mouse_sensitivity']},")
    w(f'    accel_profile = "{g_accel}",')
    w(f"    scroll_factor = {custom['mouse_scroll_factor']},")
    w(f"    natural_scroll = {lua_bool(custom['mouse_natural_scroll'])},")
    w("  },")
    w("})")
    w("")
    # Trackpad.
    w("hl.device({")
    w('  name = "apple-mtp-multi-touch",')
    if macos:
        w(f'  accel_profile = C.motion_profile({{ shape = "macos", tracking = {cfg["trackpad_tracking"]}, gain = k * {cfg["trackpad_gain"]} }}),')
        w(f"  scroll_points = C.scroll_points({{ index = {fixed['trackpad_scroll_index']}, accel = {cfg['trackpad_scroll_accel']}, mac_velocity = true, factor = {cfg['trackpad_scroll_factor']} }}),")
        w("  sensitivity = 0,")
        w("  scroll_factor = 1.0,           -- size is in scroll_points; window rules replace this per app")
    else:
        w(f'  accel_profile = C.motion_profile({{ shape = "macos", tracking = {cfg["trackpad_tracking"]}, gain = {cfg["trackpad_gain"]} }}),')
        w(f"  scroll_points = C.scroll_points({{ accel = {cfg['trackpad_scroll_accel']} }}),")
        w("  sensitivity = 0,")
        w(f"  scroll_factor = {cfg['trackpad_scroll_factor']},")
    w(f"  natural_scroll = {lua_bool(cfg['trackpad_natural_scroll'])},")
    w('  scroll_method = "2fg",')
    w("  clickfinger_behavior = true,")
    w(f"  tap_to_click = {lua_bool(cfg['trackpad_tap_to_click'])},")
    w('  tap_button_map = "lrm",')
    # macOS: Dragging = 0 and DragLock = 0; the custom profile keeps tap-and-drag with a timeout.
    w(f"  tap_and_drag = {lua_bool(not macos or cfg['trackpad_tap_to_click'])},")
    w(f"  drag_lock = {0 if macos else 1},")
    w(f"  drag_3fg = {1 if cfg['trackpad_three_finger_drag'] else 0},")
    w(f"  disable_while_typing = {lua_bool(cfg['trackpad_disable_while_typing'])},")
    w("  middle_button_emulation = false,")
    w("  left_handed = false,")
    w("})")
    w("")
    # Mouse (per device).
    w("for _, name in ipairs({ " + ", ".join(lua_str(n) for n in MOUSE_DEVICES) + " }) do")
    w("  hl.device({")
    w("    name = name,")
    if cfg["mouse_accel_profile"] == "macos":
        w(f"    accel_profile = C.mouse_profile({{ scaling = {cfg['mouse_tracking']}, hz = {fixed['mouse_report_hz']}, k = k, gain = 1.0 }}),")
        w(f"    scroll_points = C.wheel_points({{ scaling = {fixed['mouse_wheel_scaling']}, base = 4 * k * {fixed['display_scale']} / 120 * {cfg['mouse_scroll_factor']} }}),")
        w("    sensitivity = 0,")
        w("    scroll_factor = 1.0,")
    else:
        w(f'    accel_profile = "{cfg["mouse_accel_profile"]}",')
        w(f"    sensitivity = {cfg['mouse_sensitivity']},")
        w(f"    scroll_factor = {cfg['mouse_scroll_factor']},")
    w(f"    natural_scroll = {lua_bool(cfg['mouse_natural_scroll'])},")
    w("    left_handed = false,")
    w("    middle_button_emulation = false,")
    w("  })")
    w("end")
    w("")
    if macos and fixed.get("macos_gestures"):
        w("-- macOS: four-finger swipes switch Spaces, four-finger pinch opens Apps.")
        w('hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })')
        w('hl.gesture({ fingers = 4, direction = "pinchin", action = function() hl.exec_cmd("omarchy-shell omarchy.dock apps") end })')
        w("")
    if macos and fixed.get("app_scroll_rules"):
        scale = fixed["display_scale"]
        w("-- Same scroll distance in every toolkit, Chromium/Electron as the reference (no rule):")
        w("-- rule = reference px per unit / toolkit px per unit (macos-feel README, \"Scrolling in every app\").")
        w(f"local ref_tp, ref_wheel = 12 / {scale}, 120 / {scale}")
        w('local GTK4 = "(org\\\\.gnome\\\\.(Nautilus|Papers|TextEditor|Calculator|Loupe|Snapshot|Settings|Characters|clocks|Weather)|com\\\\.github\\\\.PintaProject\\\\.Pinta)"')
        w('local GTK3 = "(org\\\\.gnome\\\\.(Evince|DiskUtility)|evince|gnome-disks)"')
        w("local rules = {")
        w("  { GTK4, nil, 2.5, 1000 ^ (2 / 3) },")
        w("  { GTK3, nil, 1000 ^ (2 / 3) / 10, nil },")
        w('  { "(Alacritty)", "(Alacritty)", 3, nil },')
        w('  { "(kitty)", "(kitty)", 1, nil },')
        w(f'  {{ "foot", "foot", 7 / {scale}, 7 * 13 }},')
        w("}")
        w('if type(o) == "table" and o.window then')
        w("  for _, r in ipairs(rules) do")
        w("    local function rule()")
        w("      return { scroll_touchpad = ref_tp / r[3], scroll_mouse = r[4] and ref_wheel / r[4] or nil }")
        w("    end")
        w("    o.window(r[1], rule())")
        w('    if r[2] then o.window({ class = "(org\\\\.omarchy\\\\..*|TUI\\\\..*)", initial_title = r[2] }, rule()) end')
        w("  end")
        w("end")
        w("")
    w(f'hl.exec_cmd("hyprctl setcursor {theme} {cfg["cursor_size"]}")')
    return "\n".join(L) + "\n"


def save(store):
    out = {"profile": store["profile"], "profiles": store["profiles"], "macos_fixed": store["macos_fixed"]}
    atomic_write(CONFIG_JSON, json.dumps(out, indent=2) + "\n")
    atomic_write(CONFIG_LUA, generate_lua(store))


def apply(store, prev):
    save(store)
    subprocess.run(
        ["hyprctl", "eval", 'dofile(os.getenv("HOME") .. "/.config/hypr/pointer-tuning.lua")'],
        check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    cfg = store["profiles"][store["profile"]]
    if prev is None or cfg["cursor_size"] != prev["profiles"][prev["profile"]]["cursor_size"]:
        for cmd in (["hyprctl", "setcursor", cursor_theme(), str(cfg["cursor_size"])],
                    ["gsettings", "set", "org.gnome.desktop.interface", "cursor-size", str(cfg["cursor_size"])]):
            subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Text size and browser wheel animation follow the profile (macos-feel keeps the old values).
    if (prev is None or prev["profile"] != store["profile"]) and os.access(MACOS_FEEL, os.X_OK):
        subprocess.run([MACOS_FEEL, "desktop", "on" if store["profile"] == "macos" else "off"],
                       check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "--read"
    store = load_store()
    if arg == "--read":
        if not os.path.exists(CONFIG_LUA) or not os.path.exists(CONFIG_JSON):
            save(store)
        print(json.dumps(flat(store)))
        return
    prev = json.loads(json.dumps(store))
    if arg == "--reset":
        store["profiles"][store["profile"]] = dict(DEFAULTS[store["profile"]])
    elif arg == "--profile" and len(sys.argv) >= 3 and sys.argv[2] in PROFILES:
        store["profile"] = sys.argv[2]
    elif arg == "--write" and len(sys.argv) >= 3:
        raw = json.loads(sys.argv[2])
        store["profiles"][store["profile"]] = sanitize(raw, store["profile"])
    elif arg == "--generate":  # rewrite the .lua from the JSON without applying (install step)
        save(store)
        print(json.dumps(flat(store)))
        return
    else:
        sys.exit(1)
    apply(store, prev)
    print(json.dumps(flat(store)))


if __name__ == "__main__":
    main()
