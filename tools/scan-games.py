#!/usr/bin/env python3
"""
The scanner for DOS Game Browser.

Walks a games tree you point it at, seeds/refreshes per-game GAME.TXT metadata,
and writes the launcher index (GAMES.LST). Optionally writes the runtime path
config (DGB.CFG) and the Phase 2 review file (SETUP-REVIEW.json).

This is the only scanner. tools/setup-image.py installs launcher files and then
calls this script, so discovery and index generation exist in exactly one place.

The games root is never assumed — you always say where it is:

    python tools/scan-games.py --games-root /mnt/dos/GAMES --launcher-dir /mnt/dos/DGB
    python tools/scan-games.py --games-root booth/GAMES --launcher-dir booth
    python tools/scan-games.py --games-root /mnt/dos/GAMES --launcher-dir /mnt/dos/DGB \
        --image-root /mnt/dos --emit-review

Game directories may sit 1 to 3 levels below the games root, so all of these
work:

    <root>/GAME/GAME.EXE
    <root>/PUBLISHER/GAME/GAME.EXE
    <root>/PUBLISHER/SERIES/GAME/GAME.EXE
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dgb_limits  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "tools" / "sample-catalog.json"

MAX_DEPTH = 3               # game directories at most this far below the root
LAUNCH_EXT = {".bat", ".exe", ".com"}

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
    "abort.com",
    "vdetect.com",
    "browser.com",
}

FIELD_ORDER = ["title", "year", "genre", "publisher", "exe", "setup", "note"]


@dataclass
class Record:
    host_dir: Path
    rel_dir: str                        # DOS-style, relative to the games root
    exe: str
    title: str
    year: str
    genre: str
    publisher: str
    note: str
    setup: str
    needs_review: bool
    candidates: list[str] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

def launchables(folder: Path) -> list[Path]:
    """Launchable files directly inside folder (not recursive)."""
    out = []
    try:
        entries = sorted(folder.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        return out
    for p in entries:
        if not p.is_file():
            continue
        if p.suffix.lower() not in LAUNCH_EXT:
            continue
        if p.name.lower() in SKIP:
            continue
        out.append(p)
    return out


def discover_games(games_root: Path, max_depth: int = MAX_DEPTH,
                   exclude: Path | None = None) -> list[Path]:
    """
    Directories holding a launchable executable, at most max_depth levels below
    games_root.

    A directory that qualifies is not descended into, so a game's own util or
    data subdirectories never turn into separate catalog entries.
    """
    found: list[Path] = []

    def walk(d: Path, depth: int) -> None:
        if depth > max_depth:
            return
        if exclude is not None and (d == exclude or exclude in d.parents):
            return
        if depth >= 1 and launchables(d):
            found.append(d)
            return                      # a game is a leaf
        if depth == max_depth:
            return
        try:
            subs = sorted(d.iterdir(), key=lambda p: p.name.lower())
        except OSError:
            return
        for sub in subs:
            if sub.is_dir() and not sub.name.startswith("."):
                walk(sub, depth + 1)

    walk(games_root, 0)
    return found


def choose_exe(candidates: list[Path]) -> Path:
    ext_rank = {".bat": 0, ".exe": 1, ".com": 2}

    def score(p: Path) -> tuple[int, int, str]:
        name = p.name.lower()
        try:
            pref = PREFER_EXE.index(name)
        except ValueError:
            pref = len(PREFER_EXE) + 1
        return (ext_rank.get(p.suffix.lower(), 9), pref, name)

    return sorted(candidates, key=score)[0]


# ---------------------------------------------------------------------------
# GAME.TXT
# ---------------------------------------------------------------------------

def parse_game_txt(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    if not path.is_file():
        return meta
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        meta[key.strip().lower()] = val.strip()
    return meta


def write_game_txt(path: Path, meta: dict[str, str], dry_run: bool = False) -> None:
    lines = ["# DOS Game Browser metadata - edit freely, then re-run scan-games.py", ""]
    for key in FIELD_ORDER:
        if meta.get(key, ""):
            lines.append(f"{key}={meta[key]}")
    for key, val in sorted(meta.items()):
        if key not in FIELD_ORDER and val:
            lines.append(f"{key}={val}")
    if not dry_run:
        # CRLF so the file is readable with DOS EDIT on the target machine.
        path.write_text("\r\n".join(lines) + "\r\n", encoding="ascii", errors="replace")


def title_from_path(folder: Path) -> str:
    return folder.name.replace("_", " ").replace("-", " ").strip().title() or folder.name


def load_catalog_index(path: Path) -> dict[str, dict[str, str]]:
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


def display_path(p: Path) -> str:
    """Repo-relative when possible; the games root is often outside the repo."""
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


def host_to_dos_rel(path: Path) -> str:
    return str(path).replace("/", "\\")


# ---------------------------------------------------------------------------
# Record building
# ---------------------------------------------------------------------------

def collect_records(games_root: Path, catalog: dict[str, dict[str, str]],
                    apply_catalog: bool, dry_run: bool, verbose: bool,
                    exclude: Path | None = None) -> list[Record]:
    records: list[Record] = []

    for folder in discover_games(games_root, exclude=exclude):
        candidates = launchables(folder)
        if not candidates:
            continue
        chosen = choose_exe(candidates)

        meta_path = folder / "GAME.TXT"
        meta = parse_game_txt(meta_path)
        cat = catalog.get(folder.name.upper(), {})

        # A record needs human review when the scanner could not know these.
        needs_review = any(
            not meta.get(k, "") for k in ("title", "year", "publisher")
        )

        updated = dict(meta)
        if not updated.get("title"):
            updated["title"] = cat.get("title") or title_from_path(folder)
        if not updated.get("genre"):
            updated["genre"] = cat.get("genre") or "Other"
        if not updated.get("exe"):
            updated["exe"] = cat.get("exe") or chosen.name
        if apply_catalog:
            for k, v in cat.items():
                if v and not updated.get(k):
                    updated[k] = v

        if (not meta_path.exists()) or (updated != meta):
            write_game_txt(meta_path, updated, dry_run=dry_run)
            if verbose:
                verb = "would write" if dry_run else "wrote"
                print(f"  {verb} {display_path(meta_path)}")

        rel = folder.relative_to(games_root)
        records.append(
            Record(
                host_dir=folder,
                rel_dir=host_to_dos_rel(rel),
                exe=updated.get("exe", chosen.name),
                title=updated.get("title", ""),
                year=updated.get("year", ""),
                genre=updated.get("genre", "Other"),
                publisher=updated.get("publisher", ""),
                note=updated.get("note", ""),
                setup=updated.get("setup", ""),
                needs_review=needs_review,
                candidates=[p.name for p in candidates],
            )
        )

    return records


# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

def build_index(records: list[Record], sort: str, headers: bool) -> list[str]:
    if sort == "genre":
        records = sorted(records, key=lambda r: (r.genre.lower(), r.title.lower()))
    elif sort == "year":
        records = sorted(records, key=lambda r: (r.year or "9999", r.title.lower()))
    else:
        records = sorted(records, key=lambda r: r.title.lower())

    lines = [
        "# GAMES.LST - generated by tools/scan-games.py",
        "# Edit GAME.TXT in each game folder, then re-run the scan.",
        f"# sort={sort} headers={headers}",
        "",
    ]

    last_group = None
    for r in records:
        if headers:
            group = None
            if sort == "genre":
                group = r.genre or "Other"
            elif sort == "year":
                group = r.year or "Unknown"
            if group is not None and group != last_group:
                lines.append(f"H|{ascii_clean(group, 40)}")
                last_group = group

        lines.append(
            "G|"
            + "|".join(
                [
                    ascii_clean(r.rel_dir, 40),
                    ascii_clean(r.exe, 12),
                    ascii_clean(r.title, 40),
                    ascii_clean(r.year, 4),
                    ascii_clean(r.genre, 16),
                    ascii_clean(r.publisher, 20),
                    ascii_clean(r.note, 40),
                ]
            )
        )

    return lines


def write_browser_cfg(launcher_dir: Path, games_root_dos: str, dry_run: bool) -> Path:
    """
    Write DGB.CFG. games_root_dos is supplied by the caller - it is never
    inferred from host directory layout, which cannot be done reliably.
    """
    root = "\\" + games_root_dos.replace("/", "\\").strip("\\")
    lines = [
        "; DOS Game Browser runtime config",
        "; GAMES_ROOT is the DOS path the launcher resolves game dirs against.",
        f"GAMES_ROOT={root}",
    ]
    out = launcher_dir / "DGB.CFG"
    if not dry_run:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("\r\n".join(lines) + "\r\n", encoding="ascii", errors="replace")
    return out


def write_review(records: list[Record], games_root: Path, launcher_dir: Path,
                 games_root_dos: str | None, dry_run: bool) -> Path:
    payload = {
        "version": 1,
        "scan_root": str(games_root),
        "launcher_dir": str(launcher_dir),
        "games_root_dos": games_root_dos or "",
        "records": [
            {
                "dir": str(r.host_dir),
                "exe": r.exe,
                "title": r.title,
                "year": r.year,
                "genre": r.genre,
                "publisher": r.publisher,
                "note": r.note,
                "setup": r.setup,
                "needs_review": r.needs_review,
                "candidates": r.candidates,
            }
            for r in records
        ],
    }
    out = launcher_dir / "SETUP-REVIEW.json"
    if not dry_run:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return out


# ---------------------------------------------------------------------------

def resolve_games_root_dos(args: argparse.Namespace, games_root: Path) -> str | None:
    """
    The DOS-side path of the games tree. Either stated outright, or derived
    from an explicit image root. Never guessed from host directory nesting.
    """
    if args.games_root_dos:
        return args.games_root_dos
    if args.image_root:
        image_root = args.image_root.resolve()
        try:
            return host_to_dos_rel(games_root.relative_to(image_root))
        except ValueError:
            return None
    return None


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="Scan a games tree and write the launcher index",
    )
    ap.add_argument(
        "--games-root",
        type=Path,
        required=True,
        help="Host path to the games tree (required; never assumed)",
    )
    ap.add_argument(
        "--launcher-dir",
        type=Path,
        required=True,
        help="Host path where GAMES.LST (and DGB.CFG / SETUP-REVIEW.json) are written",
    )
    ap.add_argument(
        "--out",
        type=Path,
        help="Override the GAMES.LST path (default: <launcher-dir>/GAMES.LST)",
    )
    ap.add_argument(
        "--image-root",
        type=Path,
        help="Mounted image root, used to derive the DOS GAMES_ROOT for DGB.CFG",
    )
    ap.add_argument(
        "--games-root-dos",
        help="DOS path of the games tree, e.g. \\GAMES (overrides --image-root)",
    )
    ap.add_argument("--sort", choices=("genre", "year", "title"), default="genre")
    ap.add_argument("--no-headers", action="store_true")
    ap.add_argument(
        "--emit-review",
        action="store_true",
        help="Also write SETUP-REVIEW.json for the Phase 2 metadata UI",
    )
    ap.add_argument(
        "--no-cfg",
        action="store_true",
        help="Do not write DGB.CFG even when the DOS games root is known",
    )
    ap.add_argument(
        "--apply-catalog",
        action="store_true",
        help="Fill missing GAME.TXT fields from tools/sample-catalog.json",
    )
    ap.add_argument("--catalog", type=Path, default=CATALOG)
    ap.add_argument("--dry-run", action="store_true", help="Do not write anything")
    ap.add_argument("--verbose", action="store_true")
    return ap.parse_args()


def main() -> int:
    args = parse_args()

    games_root = args.games_root.resolve()
    if not games_root.is_dir():
        print(f"games root not found: {games_root}", file=sys.stderr)
        return 1

    launcher_dir = args.launcher_dir.resolve()
    out_lst = args.out.resolve() if args.out else (launcher_dir / "GAMES.LST")

    catalog = load_catalog_index(args.catalog) if args.apply_catalog else {}

    print(f"  games root:   {games_root}")
    print(f"  launcher dir: {launcher_dir}")
    if args.dry_run:
        print("  mode:         DRY RUN")

    # Never catalog the launcher's own files as games. Discovery only ever
    # descends from the games root, so this matters solely when the launcher
    # lives inside that tree; excluding it otherwise would discard the scan
    # whenever the games root is nested under the launcher dir (booth/GAMES).
    exclude = None
    if launcher_dir == games_root or games_root in launcher_dir.parents:
        exclude = launcher_dir

    records = collect_records(
        games_root,
        catalog,
        apply_catalog=args.apply_catalog,
        dry_run=args.dry_run,
        verbose=args.verbose,
        exclude=exclude,
    )

    if not records:
        print(f"No games found under {games_root}", file=sys.stderr)
        print(
            "Game directories must hold a .BAT/.EXE/.COM and sit at most "
            f"{MAX_DEPTH} levels below the games root.",
            file=sys.stderr,
        )
        return 1

    for r in sorted(records, key=lambda r: r.rel_dir.lower()):
        flag = "  (needs review)" if r.needs_review else ""
        print(f"  {r.rel_dir}\\{r.exe}: {r.title}{flag}")

    lines = build_index(records, args.sort, not args.no_headers)
    text = "\r\n".join(lines) + "\r\n"

    # Refuse to emit an index the launcher would silently truncate.
    try:
        dgb_limits.enforce_index(lines, text)
    except ValueError as exc:
        print(f"\n{exc}", file=sys.stderr)
        return 1

    if not args.dry_run:
        out_lst.parent.mkdir(parents=True, exist_ok=True)
        out_lst.write_bytes(text.encode("ascii", errors="replace"))
    verb = "Would write" if args.dry_run else "Wrote"
    unresolved = sum(1 for r in records if r.needs_review)
    print(f"\n{verb} {len(records)} games -> {out_lst}")
    if unresolved:
        print(f"  records needing metadata review: {unresolved}")

    games_root_dos = resolve_games_root_dos(args, games_root)
    if args.no_cfg:
        pass
    elif games_root_dos:
        cfg = write_browser_cfg(launcher_dir, games_root_dos, args.dry_run)
        print(f"{verb} runtime config -> {cfg} (GAMES_ROOT=\\{games_root_dos.strip(chr(92))})")
    else:
        print(
            "Skipped DGB.CFG: pass --games-root-dos (or --image-root) to say where\n"
            "  the games tree lives on the DOS machine. Without it the launcher\n"
            "  falls back to its built-in \\GAMES default.",
            file=sys.stderr,
        )

    if args.emit_review:
        review = write_review(records, games_root, launcher_dir, games_root_dos, args.dry_run)
        print(f"{verb} review file -> {review}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
