"""
Assemble the DOS-side binaries with NASM.

Replaces the old build.sh / build.ps1 pair: one implementation that behaves the
same on Linux, macOS and Windows.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from .paths import BIN, SRC

# (source, output relative to bin/). scan.asm is optional so the tree builds
# before it exists.
TARGETS = [
    ("browser.asm", "BROWSER.COM"),
    ("abort.asm", "UTILS/ABORT.COM"),
    ("vdetect.asm", "UTILS/VDETECT.COM"),
    ("scan.asm", "SCAN.COM"),
]


def find_nasm() -> Path | None:
    found = shutil.which("nasm")
    if found:
        return Path(found)
    # Windows installers commonly land here and do not touch PATH.
    if sys.platform == "win32":
        import os
        for env in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
            base = os.environ.get(env)
            if not base:
                continue
            for d in sorted(Path(base).glob("NASM*")):
                exe = d / "nasm.exe"
                if exe.is_file():
                    return exe
    return None


def normalize_bat(path: Path) -> None:
    """DOS batch files need CRLF; a checkout on Linux can end up with LF."""
    if not path.is_file():
        return
    raw = path.read_bytes()
    norm = raw.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    if norm != raw:
        path.write_bytes(norm)


def add_arguments(ap: argparse.ArgumentParser) -> None:
    ap.add_argument("--verbose", action="store_true")


def run(args: argparse.Namespace) -> int:
    nasm = find_nasm()
    if nasm is None:
        print("NASM not found. Install it, then check: python dgb.py doctor",
              file=sys.stderr)
        return 1

    print(f"NASM: {nasm}")
    built = 0

    for source, out_rel in TARGETS:
        src = SRC / source
        if not src.is_file():
            if args.verbose:
                print(f"  skip {source} (not present)")
            continue

        out = BIN / out_rel
        out.parent.mkdir(parents=True, exist_ok=True)
        cmd = [str(nasm), "-f", "bin", "-o", str(out), str(src)]
        if args.verbose:
            print("  " + " ".join(cmd))
        rc = subprocess.call(cmd)
        if rc != 0:
            print(f"assembly failed: {source}", file=sys.stderr)
            return rc
        print(f"  {out_rel:<20} {out.stat().st_size:>6} bytes")
        built += 1

    normalize_bat(BIN / "START.BAT")

    if built == 0:
        print("nothing to build", file=sys.stderr)
        return 1
    print("Build OK")
    return 0
