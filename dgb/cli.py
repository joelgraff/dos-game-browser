"""
Single entry point for every host-side task.

    python dgb.py <command> [options]

One Python program rather than a pile of .sh and .ps1 scripts, so the same
commands work on Linux, macOS and Windows with no extra install step.
"""
from __future__ import annotations

import argparse
import sys

from . import build, dosbox, install, samples, scan, stage
from .paths import BIN, SRC

COMMANDS = {
    "doctor": ("Report what the host has installed", None),
    "build": ("Assemble the DOS binaries with NASM", build),
    "scan": ("Scan a games tree and write GAMES.LST + DGB.CFG", scan),
    "install": ("Install the launcher into a mounted image, then scan", install),
    "stage": ("Copy the launcher to a floppy, CF card or directory", stage),
    "run": ("Launch the image under DOSBox", dosbox),
    "samples": ("Download free sample games", samples),
}


def doctor(_args: argparse.Namespace) -> int:
    """What is installed, what is missing, and what that stops you doing."""
    from .build import find_nasm
    from .dosbox import find_dosbox

    print(f"Python      {sys.version.split()[0]}  ({sys.platform})")

    nasm = find_nasm()
    print(f"NASM        {nasm if nasm else 'not found'}")

    db = find_dosbox()
    print(f"DOSBox      {db if db else 'not found'}")

    print()
    missing_art = [rel for src, rel in
                   [(BIN / "BROWSER.COM", "BROWSER.COM"),
                    (BIN / "START.BAT", "START.BAT"),
                    (BIN / "UTILS" / "ABORT.COM", "UTILS/ABORT.COM"),
                    (BIN / "UTILS" / "VDETECT.COM", "UTILS/VDETECT.COM")]
                   if not src.is_file()]
    if missing_art:
        print(f"Prebuilt    missing: {', '.join(missing_art)}")
    else:
        sizes = ", ".join(
            f"{p.name} {p.stat().st_size}B"
            for p in [BIN / "BROWSER.COM", BIN / "UTILS" / "ABORT.COM"])
        print(f"Prebuilt    present ({sizes})")

    scan_com = BIN / "SCAN.COM"
    scan_src = SRC / "scan.asm"
    if scan_com.is_file():
        print(f"SCAN.COM    present ({scan_com.stat().st_size}B) "
              "- the index can be built on the DOS machine")
    elif scan_src.is_file():
        print("SCAN.COM    not built - run: python dgb.py build")
    else:
        print("SCAN.COM    not implemented yet - build the index on this "
              "machine with 'scan'")

    print()
    if not nasm:
        print("Without NASM you cannot rebuild the binaries, but the prebuilt")
        print("ones in bin/ are enough to deploy.")
    if not db:
        print("Without DOSBox you cannot test an image locally ('run'); setting")
        print("up an image for real hardware still works.")
    if nasm and db and not missing_art:
        print("Everything needed is present.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="dgb.py",
        description="DOS Game Browser - host-side tooling",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
typical flows:
  set up on this machine, deploy to a card later
      python dgb.py install --image-root /mnt/cf
  test that image under DOSBox first
      python dgb.py run --image-root /mnt/cf
  set up entirely on the DOS machine
      python dgb.py stage --out /mnt/floppy      (then run SCAN there)
""")
    sub = ap.add_subparsers(dest="command", metavar="<command>")

    for name, (help_text, module) in COMMANDS.items():
        p = sub.add_parser(name, help=help_text, description=help_text)
        if module is not None:
            module.add_arguments(p)
            p.set_defaults(_run=module.run)
        else:
            p.set_defaults(_run=doctor)

    return ap


def main(argv: list[str] | None = None) -> int:
    ap = build_parser()
    args = ap.parse_args(argv)
    if not getattr(args, "command", None):
        ap.print_help()
        return 1
    return args._run(args)
