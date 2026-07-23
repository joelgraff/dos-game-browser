#!/usr/bin/env python3
"""
Scan booth/GAMES tree, create/update GAME.TXT metadata, write GAMES.LST.

This is the config autogenerator for the launcher: edit per-game GAME.TXT
(or let this tool seed it), then re-run to rebuild booth/GAMES.LST.

Usage:
    python tools/scan-games.py
    python tools/scan-games.py --sort genre     # default: genre headers
    python tools/scan-games.py --sort year
    python tools/scan-games.py --sort title
    python tools/scan-games.py --no-headers
    python tools/scan-games.py --apply-catalog  # fill gaps from sample-catalog.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAMES = ROOT / "booth" / "GAMES"
OUT_LST = ROOT / "booth" / "GAMES.LST"
CATALOG = ROOT / "tools" / "sample-catalog.json"

PREFER_EXE = [
    "start.bat",
    "run.bat",
    "go.bat",
    "play.bat",
    "jill.exe",
    "jill1.exe",
    "keen1e.exe",
    "keen1.exe",
    "ptomb1.exe",
    "alex.exe",
    "digger.exe",
    "sopwith.exe",
    "aliens.exe",
    "airlift.exe",
    "bifi.exe",
    "absence.exe",
    "doom.exe",
    "game.exe",
]
SKIP = {
    "setup.exe",
    "install.exe",
    "config.exe",
    "cwsdpmi.exe",
    "unzip.exe",
    "pkunzip.exe",
    "catalog.exe",
}


def find_exes(folder: Path) -> list[Path]:
    found = []
    for p in folder.rglob("*"):
        if not p.is_file():
            continue
        if p.suffix.lower() not in {".exe", ".com", ".bat"}:
            continue
        if p.name.lower() in SKIP:
            continue
        found.append(p)
    return found


def pick_exe(folder: Path, games_root: Path) -> tuple[str, str] | None:
    """Return (relpath_from_GAMES with backslash, exe filename) or None."""
    exes = find_exes(folder)
    if not exes:
        return None

    ext_rank = {".bat": 0, ".exe": 1, ".com": 2}

    def score(p: Path):
        n = p.name.lower()
        try:
            pref = PREFER_EXE.index(n)
        except ValueError:
            pref = len(PREFER_EXE) + 1
        ext = ext_rank.get(p.suffix.lower(), 9)
        depth = len(p.relative_to(folder).parts)
        return (ext, pref, depth, n)

    best = sorted(exes, key=score)[0]
    # dir relative to GAMES, exe name only in that dir
    # If exe is in subfolder of game root, dir becomes GAMES/game/sub
    rel_dir = best.parent.relative_to(games_root)
    return str(rel_dir).replace("/", "\\"), best.name


def parse_game_txt(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    if not path.is_file():
        return meta
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        meta[k.strip().lower()] = v.strip()
    return meta


def write_game_txt(path: Path, meta: dict[str, str]) -> None:
    order = ["title", "year", "genre", "publisher", "exe", "setup", "note"]
    lines = ["# DOS Game Browser metadata — edit freely, then re-run scan-games.py", ""]
    for k in order:
        if k in meta and meta[k] != "":
            lines.append(f"{k}={meta[k]}")
    # extras
    for k, v in sorted(meta.items()):
        if k not in order and v:
            lines.append(f"{k}={v}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def guess_from_name(folder_name: str) -> dict[str, str]:
    """Weak defaults when no GAME.TXT yet."""
    title = folder_name.title()
    return {
        "title": title,
        "year": "",
        "genre": "Other",
        "publisher": "",
        "note": "",
    }


def load_catalog_index(path: Path) -> dict[str, dict[str, str]]:
    """Map package id (upper) → metadata fields from sample-catalog.json."""
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    out: dict[str, dict[str, str]] = {}
    for g in data.get("games", []):
        gid = str(g.get("id", "")).upper()
        if not gid:
            continue
        out[gid] = {
            k: str(g.get(k, "") or "")
            for k in ("title", "year", "genre", "publisher", "exe", "note")
        }
    return out


def ascii_clean(s: str, maxlen: int) -> str:
    s = s.encode("ascii", "replace").decode("ascii")
    s = s.replace("|", "/").replace("\r", " ").replace("\n", " ")
    return s[:maxlen]


def main() -> int:
    ap = argparse.ArgumentParser(description="Scan GAMES tree → GAMES.LST")
    ap.add_argument("--sort", choices=("genre", "year", "title"), default="genre")
    ap.add_argument("--no-headers", action="store_true")
    ap.add_argument("--games", type=Path, default=GAMES)
    ap.add_argument("--out", type=Path, default=OUT_LST)
    ap.add_argument(
        "--apply-catalog",
        action="store_true",
        help="Fill missing GAME.TXT fields from tools/sample-catalog.json",
    )
    ap.add_argument(
        "--catalog",
        type=Path,
        default=CATALOG,
        help="Catalog JSON for --apply-catalog",
    )
    args = ap.parse_args()

    games_root: Path = args.games
    if not games_root.is_dir():
        print(f"Missing {games_root}", file=sys.stderr)
        return 1

    catalog = load_catalog_index(args.catalog) if args.apply_catalog else {}

    # Top-level game packages = immediate subdirs of GAMES
    packages = sorted(
        [p for p in games_root.iterdir() if p.is_dir() and not p.name.startswith(".")],
        key=lambda p: p.name.lower(),
    )

    records = []
    for pkg in packages:
        picked = pick_exe(pkg, games_root)
        if not picked:
            print(f"  skip {pkg.name}: no executable")
            continue
        rel_dir, exe_name = picked
        meta_path = pkg / "GAME.TXT"
        meta = parse_game_txt(meta_path)
        cat = catalog.get(pkg.name.upper(), {})

        if not meta.get("title"):
            g = guess_from_name(pkg.name)
            # catalog overrides weak guesses
            for k, v in cat.items():
                if v:
                    g[k] = v
            g["exe"] = cat.get("exe") or exe_name
            meta = {**g, **meta}
            meta["exe"] = meta.get("exe") or exe_name
            write_game_txt(meta_path, meta)
            print(f"  created {meta_path.relative_to(ROOT)}")
        else:
            changed = False
            if not meta.get("exe"):
                meta["exe"] = cat.get("exe") or exe_name
                changed = True
            if args.apply_catalog:
                for k, v in cat.items():
                    if v and not meta.get(k):
                        meta[k] = v
                        changed = True
            if changed:
                write_game_txt(meta_path, meta)

        title = meta.get("title") or pkg.name
        year = meta.get("year") or ""
        genre = meta.get("genre") or "Other"
        publisher = meta.get("publisher") or ""
        note = meta.get("note") or ""
        setup = meta.get("setup") or ""

        records.append(
            {
                "dir": rel_dir,
                "exe": meta.get("exe") or exe_name,
                "setup": setup,
                "title": title,
                "year": year,
                "genre": genre,
                "publisher": publisher,
                "note": note,
                "pkg": pkg.name,
            }
        )
        print(f"  {rel_dir}\\{records[-1]['exe']}: {title}")

    if not records:
        print("No games found", file=sys.stderr)
        print(
            "Add folders under booth/GAMES or run: python tools/fetch-samples.py",
            file=sys.stderr,
        )
        return 1

    # Sort
    if args.sort == "genre":
        records.sort(key=lambda r: (r["genre"].lower(), r["title"].lower()))
    elif args.sort == "year":
        records.sort(key=lambda r: (r["year"] or "9999", r["title"].lower()))
    else:
        records.sort(key=lambda r: r["title"].lower())

    lines = [
        "# GAMES.LST - generated by tools/scan-games.py",
        "# Edit GAME.TXT in each game folder, then re-run scan.",
        f"# sort={args.sort} headers={not args.no_headers}",
        "",
    ]

    last_group = None
    for r in records:
        if not args.no_headers:
            if args.sort == "genre":
                group = r["genre"] or "Other"
            elif args.sort == "year":
                group = r["year"] or "Unknown"
            else:
                group = None
            if group is not None and group != last_group:
                lines.append(f"H|{ascii_clean(group, 40)}")
                last_group = group

        lines.append(
            "G|"
            + "|".join(
                [
                    ascii_clean(r["dir"], 40),
                    ascii_clean(r["exe"], 12),
                    ascii_clean(r["title"], 40),
                    ascii_clean(r["year"], 4),
                    ascii_clean(r["genre"], 16),
                    ascii_clean(r["publisher"], 20),
                    ascii_clean(r["note"], 40),
                ]
            )
        )

    text = "\r\n".join(lines) + "\r\n"
    args.out.write_bytes(text.encode("ascii", errors="replace"))
    print(f"\nWrote {len(records)} games → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
