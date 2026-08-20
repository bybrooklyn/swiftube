#!/usr/bin/env python3
"""Add YouTube.app to Steam as a non-Steam game, with library artwork.

    ./Scripts/install-to-steam.py            # add or update the shortcut
    ./Scripts/install-to-steam.py --remove   # take it back out

Steam keeps non-Steam shortcuts in a binary VDF file that it holds in memory
while running and rewrites wholesale on exit. Editing it under a live Steam
therefore looks like it worked and is silently reverted the moment Steam quits,
so this refuses to run until Steam is closed, and backs the file up first.
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

STEAM = Path.home() / "Library" / "Application Support" / "Steam"
APP_NAME = "YouTube"
REPO = Path(__file__).resolve().parent.parent


# --- Binary VDF -------------------------------------------------------------
# Types: 0x00 nested map, 0x01 string, 0x02 int32; 0x08 closes a map.

def read_vdf(data):
    pos = 0

    def read_cstring():
        nonlocal pos
        end = data.index(b"\x00", pos)
        value = data[pos:end].decode("utf-8", "replace")
        pos = end + 1
        return value

    def read_map():
        nonlocal pos
        out = {}
        while True:
            marker = data[pos]
            pos += 1
            if marker == 0x08:
                return out
            key = read_cstring()
            if marker == 0x00:
                out[key] = read_map()
            elif marker == 0x01:
                out[key] = read_cstring()
            elif marker == 0x02:
                out[key] = struct.unpack("<i", data[pos:pos + 4])[0]
                pos += 4
            else:
                raise ValueError(f"unknown VDF marker {marker:#x} at {pos}")

    root_marker = data[pos]
    pos += 1
    if root_marker != 0x00:
        raise ValueError("not a binary VDF map")
    read_cstring()  # "shortcuts"
    return read_map()


def write_vdf(shortcuts):
    out = bytearray()

    def cstring(value):
        out.extend(value.encode("utf-8"))
        out.append(0)

    def write_map(mapping):
        for key, value in mapping.items():
            if isinstance(value, dict):
                out.append(0x00)
                cstring(key)
                write_map(value)
            elif isinstance(value, bool):
                out.append(0x02)
                cstring(key)
                out.extend(struct.pack("<i", int(value)))
            elif isinstance(value, int):
                out.append(0x02)
                cstring(key)
                out.extend(struct.pack("<i", value))
            else:
                out.append(0x01)
                cstring(key)
                cstring(str(value))
        out.append(0x08)

    out.append(0x00)
    cstring("shortcuts")
    write_map(shortcuts)
    out.append(0x08)
    return bytes(out)


def grid_appid(exe, appname):
    """The id Steam derives for a non-Steam shortcut's artwork filenames.

    Steam hashes the quoted Exe string concatenated with AppName, so the art
    stops matching if either changes — which is why the .app is installed to a
    fixed path rather than wherever the repo happens to sit.
    """
    crc = zlib.crc32((exe + appname).encode("utf-8")) & 0xFFFFFFFF
    return crc | 0x80000000


def steam_running():
    result = subprocess.run(["pgrep", "-x", "steam_osx"], capture_output=True)
    if result.returncode == 0:
        return True
    return subprocess.run(["pgrep", "-f", "Steam.app/Contents/MacOS"],
                          capture_output=True).returncode == 0


def user_config_dirs():
    userdata = STEAM / "userdata"
    if not userdata.is_dir():
        sys.exit(f"✗ No Steam userdata at {userdata} — is Steam installed and signed in?")
    dirs = [p / "config" for p in userdata.iterdir() if p.is_dir() and p.name.isdigit()]
    if not dirs:
        sys.exit("✗ No Steam user profiles found under userdata/.")
    return dirs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--remove", action="store_true", help="remove the shortcut")
    parser.add_argument("--app", default=str(REPO / "build" / f"{APP_NAME}.app"))
    args = parser.parse_args()

    app_path = Path(args.app).resolve()
    if not args.remove and not app_path.is_dir():
        sys.exit(f"✗ {app_path} not found — run `just app` first.")

    if steam_running():
        sys.exit(
            "✗ Steam is running. Quit it completely, then re-run.\n"
            "  Steam holds shortcuts.vdf in memory and overwrites it on exit, so a\n"
            "  shortcut added now would be silently discarded."
        )

    # Steam launches the bundle, not the inner Mach-O: running the executable
    # directly starts a process with no window (see AGENTS.md).
    exe = f'"{app_path}"'
    start_dir = f'"{app_path.parent}"'

    for config in user_config_dirs():
        config.mkdir(parents=True, exist_ok=True)
        vdf_path = config / "shortcuts.vdf"

        shortcuts = {}
        if vdf_path.exists():
            backup = vdf_path.with_suffix(f".vdf.bak-{int(time.time())}")
            shutil.copy2(vdf_path, backup)
            try:
                shortcuts = read_vdf(vdf_path.read_bytes())
            except Exception as exc:                      # noqa: BLE001
                sys.exit(f"✗ Could not parse {vdf_path}: {exc}\n  Your backup is at {backup}")

        # Drop any existing entry for this app so re-running updates in place
        # instead of stacking duplicate tiles.
        entries = [v for v in shortcuts.values()
                   if isinstance(v, dict) and v.get("AppName") != APP_NAME]

        if not args.remove:
            entries.append({
                "appid": struct.unpack("<i", struct.pack("<I", grid_appid(exe, APP_NAME)))[0],
                "AppName": APP_NAME,
                "Exe": exe,
                "StartDir": start_dir,
                "icon": str(REPO / "Resources" / "steam" / "icon.png"),
                "ShortcutPath": "",
                "LaunchOptions": "",
                "IsHidden": 0,
                "AllowDesktopConfig": 1,
                "AllowOverlay": 1,
                "OpenVR": 0,
                "Devkit": 0,
                "DevkitGameID": "",
                "DevkitOverrideAppID": 0,
                "LastPlayTime": 0,
                "FlatpakAppID": "",
                "tags": {"0": "Media"},
            })

        vdf_path.write_bytes(write_vdf({str(i): e for i, e in enumerate(entries)}))

        # Artwork. Filenames are keyed off the derived app id.
        appid = grid_appid(exe, APP_NAME)
        grid_dir = config / "grid"
        art = REPO / "Resources" / "steam"
        mapping = {
            f"{appid}.png": "grid.png",
            f"{appid}p.png": "portrait.png",
            f"{appid}_hero.png": "hero.png",
            f"{appid}_logo.png": "logo.png",
        }
        if args.remove:
            for name in mapping:
                (grid_dir / name).unlink(missing_ok=True)
        else:
            grid_dir.mkdir(parents=True, exist_ok=True)
            for dest, src in mapping.items():
                if (art / src).exists():
                    shutil.copy2(art / src, grid_dir / dest)

        action = "Removed" if args.remove else "Installed"
        print(f"✅ {action} '{APP_NAME}' in {config.parent.name} (appid {appid})")

    if not args.remove:
        print("   Start Steam — 'YouTube' appears in your library under Media.")


if __name__ == "__main__":
    main()
