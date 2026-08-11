"""
Find and drive a DOSBox installation.

Use case 3: prepare a DOS image on a modern machine and test it under DOSBox
before committing it to real media, with the games referenced where they
actually live rather than copied.

Nothing here assumes a platform or an install location: detection walks PATH
first, then the conventional locations for each operating system.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from .paths import ROOT, dos_to_host_subpath

LOCAL_CFG = ROOT / "dgb-local.json"

# Staging is actively maintained, DOSBox-X the most featureful, plain DOSBox
# the most widely installed.
PATH_NAMES = ["dosbox-staging", "dosbox", "dosbox-x"]


def _candidates() -> list[Path]:
    """Conventional install locations for the current platform."""
    out: list[Path] = []

    if sys.platform == "win32":
        for env in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
            base = os.environ.get(env)
            if not base:
                continue
            # Installers use versioned directory names (DOSBox-0.74-3), so
            # glob rather than trying to guess the version.
            for pattern in ("DOSBox*", "dosbox*"):
                for d in sorted(Path(base).glob(pattern)):
                    for exe in ("dosbox.exe", "DOSBox.exe", "dosbox-x.exe"):
                        out.append(d / exe)

    elif sys.platform == "darwin":
        for app in ("DOSBox.app", "dosbox-staging.app", "DOSBox-X.app"):
            for base in (Path("/Applications"), Path.home() / "Applications"):
                d = base / app / "Contents" / "MacOS"
                out.extend([d / "DOSBox", d / "dosbox", d / "dosbox-x"])
        for pre in (Path("/usr/local/bin"), Path("/opt/homebrew/bin")):
            out.extend(pre / n for n in PATH_NAMES)

    else:
        for pre in (Path("/usr/bin"), Path("/usr/local/bin"), Path("/opt/bin")):
            out.extend(pre / n for n in PATH_NAMES)

    return out


def find_dosbox() -> Path | None:
    """First usable DOSBox executable, or None."""
    for name in PATH_NAMES:
        found = shutil.which(name)
        if found:
            return Path(found)

    for cand in _candidates():
        if cand.is_file() and os.access(cand, os.X_OK):
            return cand

    # Flatpak keeps binaries off PATH; the wrapper is the entry point.
    if shutil.which("flatpak"):
        for app in ("io.github.dosbox-staging", "com.dosbox_x.DOSBox-X",
                    "org.dosbox.DOSBox"):
            try:
                r = subprocess.run(["flatpak", "info", app],
                                   capture_output=True, timeout=10)
                if r.returncode == 0:
                    return Path(f"flatpak:{app}")
            except (OSError, subprocess.SubprocessError):
                pass

    return None


def launch_command(dosbox: Path, commands: list[str]) -> list[str]:
    """argv for a DOSBox run, honouring the flatpak pseudo-path."""
    s = str(dosbox)
    if s.startswith("flatpak:"):
        cmd = ["flatpak", "run", s.split(":", 1)[1]]
    else:
        cmd = [s]
        # Staging reads a primary config that can override what we pass.
        if "staging" in dosbox.name:
            cmd.append("--noprimaryconf")
    for c in commands:
        cmd.extend(["-c", c])
    return cmd


def _install_first(image_root: Path, launcher: str,
                   args: argparse.Namespace) -> int:
    """Prepare the image, reusing install rather than duplicating it."""
    from . import install as install_mod

    parser = argparse.ArgumentParser()
    install_mod.add_arguments(parser)
    ns = parser.parse_args([
        "--image-root", str(image_root),
        "--scan-root", args.scan_root,
        "--launcher-path", launcher,
        "--on-conflict", "overwrite",
    ])
    print(f"Preparing {image_root} ...")
    rc = install_mod.run(ns)
    print()
    return rc


def load_local() -> dict:
    if not LOCAL_CFG.is_file():
        return {}
    try:
        data = json.loads(LOCAL_CFG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def save_local(image_root: Path, launcher: str, entry: str) -> None:
    LOCAL_CFG.write_text(
        json.dumps({"image_root": str(image_root),
                    "launcher_dir": launcher,
                    "entry": entry}, indent=2) + "\n",
        encoding="utf-8",
    )


def add_arguments(ap: argparse.ArgumentParser) -> None:
    ap.add_argument("--image-root", type=Path,
                    help="Host directory to mount as C: (default: saved value)")
    ap.add_argument("--launcher-dir", default=None,
                    help="Launcher directory under C: (default: saved, else DGB)")
    ap.add_argument("--entry", default=None,
                    help="Program to run (default: saved, else START.BAT)")
    ap.add_argument("--save", action="store_true",
                    help="Remember these settings in dgb-local.json and exit")
    ap.add_argument("--install", action="store_true",
                    help="Install the launcher into the image first, then run")
    ap.add_argument("--scan-root", default="GAMES",
                    help="With --install: games tree, relative to the image root")
    ap.add_argument("--dosbox", type=Path,
                    help="Use this DOSBox binary instead of the detected one")


def run(args: argparse.Namespace) -> int:
    local = load_local()

    raw = args.image_root or local.get("image_root")
    if not raw:
        print("no image root given and none saved; pass --image-root",
              file=sys.stderr)
        return 1
    image_root = Path(raw).expanduser().resolve()

    launcher = args.launcher_dir or local.get("launcher_dir", "DGB")
    entry = args.entry or local.get("entry", "START.BAT")

    if not image_root.is_dir():
        print(f"image root not found: {image_root}", file=sys.stderr)
        return 1

    if args.save:
        save_local(image_root, launcher, entry)
        print(f"Saved: {LOCAL_CFG}")
        return 0

    # 'run' launches an image; it does not prepare one. Starting DOSBox on an
    # unprepared image drops the user at a prompt where 'cd \\DGB' fails, with
    # nothing to explain why, so check first and say what to do.
    launcher_host = image_root / dos_to_host_subpath(launcher)
    if args.install:
        rc = _install_first(image_root, launcher, args)
        if rc != 0:
            return rc
    elif not (launcher_host / "BROWSER.COM").is_file():
        print(f"no launcher found in {launcher_host}", file=sys.stderr)
        print(file=sys.stderr)
        print("Prepare the image first:", file=sys.stderr)
        print(f"  python dgb.py install --image-root {image_root}", file=sys.stderr)
        print("or do both in one step:", file=sys.stderr)
        print(f"  python dgb.py run --install --image-root {image_root}",
              file=sys.stderr)
        return 1

    if not (launcher_host / "GAMES.LST").is_file():
        print(f"warning: no GAMES.LST in {launcher_host}; the browser will "
              "report it as missing.", file=sys.stderr)
        print("         build it with 'python dgb.py scan', or SCAN.COM in DOS.",
              file=sys.stderr)

    dosbox = args.dosbox or find_dosbox()
    if dosbox is None:
        print("DOSBox not found. Install it, then check: python dgb.py doctor",
              file=sys.stderr)
        return 1

    launcher = launcher.strip().replace("/", "\\").strip("\\")

    commands = [f"mount c {image_root}", "c:"]
    if launcher and launcher != ".":
        commands.append(f"cd \\{launcher}")
    commands.append(entry)

    print(f"DOSBox:       {dosbox}")
    print(f"Image root:   {image_root}  (mounted as C:)")
    print(f"Launcher dir: C:\\{launcher}" if launcher else "Launcher dir: C:\\")
    print(f"Entry:        {entry}")

    return subprocess.call(launch_command(dosbox, commands))
