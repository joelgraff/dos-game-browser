#!/usr/bin/env python3
"""
Fetch free / redistributable sample games into booth/GAMES/.

Does NOT ship copyrighted retail games. Only entries listed in
tools/sample-catalog.json (public domain, freeware, or shareware demos).

Usage:
    python tools/fetch-samples.py               # download all
    python tools/fetch-samples.py --list
    python tools/fetch-samples.py --only HELLOWOR SOPWITH1
    python tools/fetch-samples.py --seed-only   # write GAME.TXT stubs only
    python tools/scan-games.py                  # after fetch: rebuild GAMES.LST
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from fnmatch import fnmatch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAMES = ROOT / "booth" / "GAMES"
DEFAULT_CATALOG = Path(__file__).resolve().parent / "sample-catalog.json"
UA = "dos-game-browser-fetch/1.0 (+https://github.com/local/dos-game-browser)"


def load_catalog(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return list(data["games"])


def write_game_txt(folder: Path, meta: dict) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    order = ["title", "year", "genre", "publisher", "exe", "setup", "note"]
    lines = [
        "# DOS Game Browser metadata — edit freely, then re-run scan-games.py",
        "",
    ]
    for k in order:
        if meta.get(k):
            lines.append(f"{k}={meta[k]}")
    (folder / "GAME.TXT").write_text("\n".join(lines) + "\n", encoding="utf-8")


def dos_com_print_and_wait(message: bytes) -> bytes:
    """Minimal COM: print $-terminated string, wait for key, exit."""
    # org 100h — code is 16 bytes, message starts at CS:0110h
    # mov dx,0110h / mov ah,09 / int 21 / mov ah,00 / int 16 / mov ax,4C00 / int 21
    header = bytes(
        [
            0xBA,
            0x10,
            0x01,  # mov dx, 0110h
            0xB4,
            0x09,
            0xCD,
            0x21,  # mov ah,9 ; int 21h
            0xB4,
            0x00,
            0xCD,
            0x16,  # mov ah,0 ; int 16h
            0xB8,
            0x00,
            0x4C,
            0xCD,
            0x21,  # mov ax,4C00h ; int 21h
        ]
    )
    assert len(header) == 16
    body = message if message.endswith(b"$") else message + b"$"
    return header + body


def build_helloworld(folder: Path, meta: dict) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    msg = b"Hello from DOS Game Browser!\r\nPress any key to return...\r\n$"
    (folder / "HELLOWO.COM").write_bytes(dos_com_print_and_wait(msg))
    write_game_txt(folder, {**meta, "exe": "HELLOWO.COM"})


def build_snake_mini(folder: Path, meta: dict) -> None:
    """Very small 'snake-like' placeholder: draw box + message (not full game).

    Ships as a real .COM so the browser can launch something offline without
    network. Replace with a real snake if you prefer.
    """
    folder.mkdir(parents=True, exist_ok=True)
    msg = (
        b"Snake Mini (sample stub)\r\n"
        b"Replace with a full game if desired.\r\n"
        b"Press any key...\r\n$"
    )
    (folder / "SNAKEMI.COM").write_bytes(dos_com_print_and_wait(msg))
    write_game_txt(folder, {**meta, "exe": "SNAKEMI.COM"})


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    print(f"  GET {url}")
    with urllib.request.urlopen(req, timeout=120) as resp:
        dest.write_bytes(resp.read())


def match_pick(name: str, patterns: list[str]) -> bool:
    base = name.replace("\\", "/").split("/")[-1]
    for pat in patterns:
        if fnmatch(base.upper(), pat.upper()) or fnmatch(name.upper(), pat.upper()):
            return True
    return False


def safe_extract_zip(
    zpath: Path, dest: Path, patterns: list[str] | None, subdir: str | None
) -> int:
    """Extract matching members; flatten into dest or dest/subdir."""
    out = dest / subdir if subdir else dest
    out.mkdir(parents=True, exist_ok=True)
    count = 0
    with zipfile.ZipFile(zpath, "r") as zf:
        names = [n for n in zf.namelist() if not n.endswith("/")]
        if not names:
            return 0
        # If archive has a single top-level folder, strip it for friendlier paths
        tops = {n.split("/")[0] for n in names if "/" in n}
        strip_one = len(tops) == 1 and all("/" in n or n in tops for n in names)

        for name in names:
            if patterns and not match_pick(name, patterns):
                # if patterns given but nothing would match, still take exes
                continue
            parts = name.replace("\\", "/").split("/")
            if strip_one and len(parts) > 1:
                parts = parts[1:]
            if not parts or parts == [""]:
                continue
            target = out.joinpath(*parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(zf.read(name))
            count += 1
    # Fallback: if pick filtered everything, extract all
    if count == 0:
        with zipfile.ZipFile(zpath, "r") as zf:
            zf.extractall(out)
            count = sum(1 for n in zf.namelist() if not n.endswith("/"))
    return count


def find_exe(folder: Path, preferred: str | None) -> str | None:
    if preferred:
        for p in folder.rglob(preferred):
            if p.is_file():
                return preferred
        # case-insensitive
        for p in folder.rglob("*"):
            if p.is_file() and p.name.upper() == preferred.upper():
                return p.name
    for ext in (".EXE", ".COM", ".BAT"):
        for p in sorted(folder.rglob(f"*{ext}")):
            if p.is_file() and p.name.upper() not in {
                "SETUP.EXE",
                "INSTALL.EXE",
                "CWSDPMI.EXE",
                "CATALOG.EXE",
            }:
                return p.name
    return None


def fetch_one(entry: dict, seed_only: bool) -> bool:
    gid = entry["id"].upper()
    folder = GAMES / gid
    meta = {
        "title": entry.get("title", gid),
        "year": entry.get("year", ""),
        "genre": entry.get("genre", "Other"),
        "publisher": entry.get("publisher", ""),
        "exe": entry.get("exe", ""),
        "note": entry.get("note", ""),
    }

    print(f"== {gid}: {meta['title']}")

    if seed_only or entry.get("source") == "meta":
        write_game_txt(folder, meta)
        print(f"  seeded GAME.TXT only")
        return True

    if entry.get("source") == "builtin":
        if gid == "HELLOWOR":
            build_helloworld(folder, meta)
        elif gid == "SNAKEMIN":
            build_snake_mini(folder, meta)
        else:
            write_game_txt(folder, meta)
            print(f"  unknown builtin {gid}", file=sys.stderr)
            return False
        print(f"  wrote built-in sample → {folder.relative_to(ROOT)}")
        return True

    if entry.get("source") != "url":
        print(f"  skip: unknown source {entry.get('source')}")
        return False

    urls = [entry["url"]] + list(entry.get("fallback_urls") or [])
    last_err: Exception | None = None
    with tempfile.TemporaryDirectory(prefix="dgb-") as td:
        zpath = Path(td) / "pack.zip"
        ok = False
        for url in urls:
            try:
                download(url, zpath)
                ok = True
                break
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
                last_err = e
                print(f"  failed: {e}")
        if not ok:
            print(f"  ERROR: could not download {gid}: {last_err}", file=sys.stderr)
            return False

        # clear previous contents except keep folder
        if folder.exists():
            for p in folder.rglob("*"):
                if p.is_file():
                    p.unlink()
        folder.mkdir(parents=True, exist_ok=True)

        n = safe_extract_zip(
            zpath,
            folder,
            entry.get("pick"),
            entry.get("subdir"),
        )
        print(f"  extracted {n} files")

        # If exe lives in subdir, point GAME.TXT at it (scan-games handles subdirs)
        exe = entry.get("exe") or ""
        found = find_exe(folder, exe)
        if found:
            meta["exe"] = found
        write_game_txt(folder, meta)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="Fetch sample DOS games into booth/GAMES")
    ap.add_argument("--list", action="store_true", help="List catalog entries")
    ap.add_argument("--only", nargs="+", help="Only these game ids")
    ap.add_argument(
        "--seed-only",
        action="store_true",
        help="Only write GAME.TXT metadata, do not download",
    )
    ap.add_argument(
        "--catalog",
        type=Path,
        default=DEFAULT_CATALOG,
        help="Path to sample-catalog.json",
    )
    args = ap.parse_args()

    games = load_catalog(args.catalog)

    if args.list:
        for g in games:
            print(
                f"{g['id']:10} {g.get('source', '?'):8} {g.get('title', '')}  [{g.get('license', '')}]"
            )
        return 0

    only = {x.upper() for x in args.only} if args.only else None
    GAMES.mkdir(parents=True, exist_ok=True)

    ok = 0
    fail = 0
    for g in games:
        if only and g["id"].upper() not in only:
            continue
        if fetch_one(g, seed_only=args.seed_only):
            ok += 1
        else:
            fail += 1

    print(f"\nDone: {ok} ok, {fail} failed → {GAMES}")
    print("Next: python tools/scan-games.py")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
