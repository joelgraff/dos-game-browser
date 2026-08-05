"""
Copy the launcher onto a floppy, a CF card, or any staging directory.

Use case 1: everything is set up on the DOS machine itself. Stage the launcher
onto a floppy, carry it over, and run SCAN there to build the index — no modern
machine involved beyond writing the disk.

The destination gets the launcher files and an INSTALL.TXT explaining what to do
next, in plain ASCII so it is readable with DOS TYPE.
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from .paths import BIN, launcher_files

INSTALL_TXT = """\
DOS GAME BROWSER - INSTALLATION
===============================

Copy the files on this disk into a directory on the DOS machine, for
example C:\\DGB:

    MD C:\\DGB
    MD C:\\DGB\\UTILS
    COPY A:\\*.*        C:\\DGB
    COPY A:\\UTILS\\*.*  C:\\DGB\\UTILS

Put your games somewhere sensible, one directory per game, for example
C:\\GAMES\\JILL. Game directories may be up to three levels below that
root, so C:\\GAMES\\APOGEE\\KEEN works too.

Build the index. Run this from the launcher directory, pointing at the
root your games are under:

    C:
    CD \\DGB
    SCAN C:\\GAMES

SCAN writes GAMES.LST (the index the browser reads) and DGB.CFG (which
records where the games are). Re-run it whenever you add games.

Start the browser:

    START

Keys:
    Arrow keys / PgUp / PgDn    move
    Enter                       play
    A-Z                         jump to a title
    Esc                         quit (START.BAT restarts it)
    F12                         force-exit a stuck game

To edit a game's details, edit GAME.TXT in that game's directory with
any text editor (EDIT works), then re-run SCAN:

    title=Jill of the Jungle
    year=1992
    genre=Platform
    publisher=Epic MegaGames
    exe=JILL.EXE

To start the browser automatically at boot, add this to AUTOEXEC.BAT:

    C:
    CD \\DGB
    CALL START.BAT
"""


def add_arguments(ap: argparse.ArgumentParser) -> None:
    ap.add_argument("--out", type=Path, required=True,
                    help="Destination directory (a floppy mount, CF card, or "
                         "a staging directory)")
    ap.add_argument("--no-instructions", action="store_true",
                    help="Do not write INSTALL.TXT")
    ap.add_argument("--verbose", action="store_true")


def run(args: argparse.Namespace) -> int:
    out = args.out.expanduser().resolve()

    files = launcher_files()
    missing = [src for src, _ in files if not src.is_file()]
    if missing:
        for m in missing:
            print(f"missing artifact: {m}", file=sys.stderr)
        print("run 'python dgb.py build' first", file=sys.stderr)
        return 1

    out.mkdir(parents=True, exist_ok=True)

    total = 0
    for src, rel in files:
        dst = out / Path(rel)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        total += dst.stat().st_size
        if args.verbose:
            print(f"  {rel}")

    if not args.no_instructions:
        (out / "INSTALL.TXT").write_text(
            INSTALL_TXT.replace("\n", "\r\n"), encoding="ascii", errors="replace")
        total += (out / "INSTALL.TXT").stat().st_size

    print(f"Staged {len(files)} launcher files to {out}")
    print(f"  total {total} bytes"
          + ("  (fits a 360K floppy)" if total < 360 * 1024 else ""))

    if not (BIN / "SCAN.COM").is_file():
        print("\nNote: SCAN.COM is not built, so the index cannot be created on")
        print("the DOS machine. Generate GAMES.LST here first:")
        print("  python dgb.py scan --games-root <dir> --launcher-dir <dir>")

    return 0
