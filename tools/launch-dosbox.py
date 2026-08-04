#!/usr/bin/env python3
"""
Launch DOS Game Browser in DOSBox (staging or classic) from a mounted image root.

Examples:
  python tools/launch-dosbox.py
  python tools/launch-dosbox.py --image-root ~/Documents/TESTIMG --launcher-dir DGB
  python tools/launch-dosbox.py --image-root /mnt/dos --launcher-dir DGB --entry BROWSER.COM
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCAL_CFG = ROOT / "tools" / "launch-dosbox.local.json"


def load_local_config(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    out: dict[str, str] = {}
    for key in ("image_root", "launcher_dir", "entry"):
        val = data.get(key)
        if isinstance(val, str) and val.strip() != "":
            out[key] = val.strip()
    return out


def save_local_config(path: Path, image_root: Path, launcher_dir: str, entry: str) -> None:
    payload = {
        "image_root": str(image_root),
        "launcher_dir": launcher_dir,
        "entry": entry,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def find_dosbox() -> str | None:
    candidates = [
        "dosbox-staging",
        "dosbox",
        str(ROOT / ".." / "dos-launcher-dev" / "tools" / "dosbox-staging" / "dosbox"),
        str(Path.home() / "Documents" / "dos-launcher-dev" / "tools" / "dosbox-staging" / "dosbox"),
        str(Path.home() / "dos-launcher-dev" / "tools" / "dosbox-staging" / "dosbox"),
    ]

    for cand in candidates:
        if os.path.sep in cand:
            p = Path(cand).expanduser().resolve()
            if p.is_file() and os.access(p, os.X_OK):
                return str(p)
            continue

        path = shutil_which(cand)
        if path:
            return path
    return None


def shutil_which(name: str) -> str | None:
    paths = os.environ.get("PATH", "").split(os.pathsep)
    for base in paths:
        p = Path(base) / name
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
    return None


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Launch DGB using a local DOSBox install")
    ap.add_argument(
        "--image-root",
        type=Path,
        default=None,
        help="Mounted DOS filesystem root to mount as C: (default: local config, then ./booth)",
    )
    ap.add_argument(
        "--launcher-dir",
        default=None,
        help="Launcher directory under C: (default: local config, then .)",
    )
    ap.add_argument(
        "--entry",
        default=None,
        help="Program to run after changing to launcher dir (default: local config, then START.BAT)",
    )
    ap.add_argument(
        "--save-local",
        action="store_true",
        help="Write effective launch settings to tools/launch-dosbox.local.json and exit",
    )
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    local_cfg = load_local_config(LOCAL_CFG)

    raw_image_root = args.image_root
    if raw_image_root is None:
        raw_image_root = Path(local_cfg.get("image_root", str(ROOT / "booth")))
    image_root = raw_image_root.expanduser().resolve()

    launcher_dir = args.launcher_dir
    if launcher_dir is None:
        launcher_dir = local_cfg.get("launcher_dir", ".")

    entry = args.entry
    if entry is None:
        entry = local_cfg.get("entry", "START.BAT")

    if not image_root.is_dir():
        print(f"image root not found: {image_root}", file=sys.stderr)
        return 1

    if args.save_local:
        save_local_config(LOCAL_CFG, image_root, launcher_dir, entry)
        print(f"Wrote local launcher config: {LOCAL_CFG}")
        return 0

    dosbox = find_dosbox()
    if not dosbox:
        print("DOSBox not found. Install dosbox-staging or dosbox.", file=sys.stderr)
        return 1

    launcher = launcher_dir.strip().replace("/", "\\")
    launcher = launcher.strip("\\")

    cmd = [dosbox]

    # DOSBox Staging supports --noprimaryconf; classic dosbox may not.
    if "staging" in Path(dosbox).name:
        cmd.append("--noprimaryconf")

    cmd.extend(["-c", f"mount c {image_root}"])
    cmd.extend(["-c", "c:"])

    if launcher and launcher != ".":
        cmd.extend(["-c", f"cd \\{launcher}"])

    cmd.extend(["-c", entry])

    print(f"Using DOSBox: {dosbox}")
    print(f"Image root:   {image_root}")
    if launcher and launcher != ".":
        print(f"Launcher dir: C:\\{launcher}")
    else:
        print("Launcher dir: C:\\")
    print(f"Entry:        {entry}")
    if LOCAL_CFG.is_file():
        print(f"Local config: {LOCAL_CFG}")

    return subprocess.call(cmd)


if __name__ == "__main__":
    raise SystemExit(main())
