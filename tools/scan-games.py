#!/usr/bin/env python3
"""
The scanner for DOS Game Browser.

Walks a games tree you point it at, seeds/refreshes per-game GAME.TXT metadata,
and writes the launcher index (GAMES.LST), plus the runtime path config
(DGB.CFG) when the DOS-side games root is known.

This is the only scanner. tools/setup-image.py installs launcher files and then
calls this script, so discovery and index generation exist in exactly one place.

The games root is never assumed — you always say where it is:

    python tools/scan-games.py --games-root /mnt/dos/GAMES --launcher-dir /mnt/dos/DGB
    python tools/scan-games.py --games-root booth/GAMES --launcher-dir booth

Game directories may sit 1 to 3 levels below the games root, so all of these
work:

    <root>/GAME/GAME.EXE
    <root>/PUBLISHER/GAME/GAME.EXE
    <root>/PUBLISHER/SERIES/GAME/GAME.EXE
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
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


# DOSBox internal commands, and its bare config shortcuts. Repack launch
# scripts use both forms. Real-DOS commands that merely look similar --
# LOADFIX, LOADHIGH/LH, KEYB, MODE, SHARE -- are deliberately absent.
DOSBOX_COMMANDS = {
    "imgmount", "intro", "rescan", "ipxnet", "mixer",
}
DOSBOX_SETTINGS = {
    "aspect", "autolock", "core", "cputype", "cycles", "frameskip",
    "fullscreen", "glshader", "joysticktype", "machine", "memsize",
    "nosound", "oplmode", "output", "prebuffer", "sbtype", "scaler",
    "sensitivity", "usescancodes", "vsync",
}


def is_dosbox_wrapper(path: Path, _depth: int = 0) -> bool:
    """
    True for a .BAT that drives DOSBox rather than DOS.

    Repacks (DOS Games Archive and similar) ship launch scripts that configure
    the emulator before starting the game. They work under emulation and fail
    on real hardware, which is the target here, so they must never be chosen as
    a game's entry point.
    """
    if path.suffix.lower() != ".bat":
        return False
    try:
        text = path.read_text(encoding="ascii", errors="replace")
    except OSError:
        return False

    called: list[str] = []

    for raw in text.splitlines():
        line = raw.strip().lstrip("@").strip()
        if not line:
            continue
        low = line.lower()
        if low.startswith("rem ") or low.startswith("::"):
            continue
        head = low.split()
        cmd = head[0] if head else ""
        rest = " ".join(head[1:])

        if cmd in DOSBOX_COMMANDS:
            return True
        if cmd in DOSBOX_SETTINGS and rest:
            return True
        if cmd == "config" and ("-set" in rest or "-get" in rest):
            return True
        if cmd == "mount" and re.match(r"^[a-z]\b", rest):
            return True
        if cmd == "boot" and rest:
            return True
        # DOSBox's virtual drive, holding its internal programs
        if re.search(r"\bz:[\\/]", low):
            return True
        if cmd == "call" and rest.endswith(".bat"):
            called.append(rest.split()[0])

    # A script whose only job is to tweak settings and CALL the real wrapper.
    if _depth < 1:
        for name in called:
            target = path.parent / name
            if target.is_file() and is_dosbox_wrapper(target, _depth + 1):
                return True

    return False


def real_launchables(folder: Path) -> list[Path]:
    """Launchables excluding DOSBox-only wrapper scripts."""
    return [p for p in launchables(folder) if not is_dosbox_wrapper(p)]


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

    def score(p: Path) -> tuple[int, int, int, str]:
        name = p.name.lower()
        try:
            pref = PREFER_EXE.index(name)
        except ValueError:
            pref = len(PREFER_EXE) + 1
        # DOSBox wrappers rank below everything real.
        wrapper = 1 if is_dosbox_wrapper(p) else 0
        return (wrapper, ext_rank.get(p.suffix.lower(), 9), pref, name)

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

def deep_real_launchable(folder: Path) -> Path | None:
    """Shallowest non-wrapper launchable anywhere under folder."""
    found = [p for p in folder.rglob("*")
             if p.is_file()
             and p.suffix.lower() in LAUNCH_EXT
             and p.name.lower() not in SKIP
             and not is_dosbox_wrapper(p)]
    if not found:
        return None
    found.sort(key=lambda p: (len(p.relative_to(folder).parts), str(p).lower()))
    depth = len(found[0].relative_to(folder).parts)
    return choose_exe([p for p in found
                       if len(p.relative_to(folder).parts) == depth])


def resolve_exe(folder: Path, exe: str) -> tuple[Path, str, str | None]:
    """
    Locate the executable a GAME.TXT names.

    An `exe=` value is often carried over from a repack or hand-edited, and can
    name a file that lives in a subdirectory rather than the directory holding
    GAME.TXT. Launching that entry would CHDIR to the wrong place and fail with
    "file not found", so re-point the directory at where the file actually is.

    Returns (directory, actual filename, status) where status is None if the
    file was already in place, "moved" if the directory had to be re-pointed,
    or "missing" if it exists nowhere. Matching is case-insensitive because DOS
    filenames are, but Linux hosts are not.
    """
    if not exe:
        return folder, exe, None

    want = exe.strip().replace("/", "\\").split("\\")[-1].lower()

    for f in folder.iterdir():
        if f.is_file() and f.name.lower() == want:
            return folder, f.name, None            # already correct

    # Search the game's own subtree, shallowest first.
    matches = sorted(
        (p for p in folder.rglob("*") if p.is_file() and p.name.lower() == want),
        key=lambda p: (len(p.relative_to(folder).parts), str(p).lower()),
    )
    if matches:
        found = matches[0]
        return found.parent, found.name, "moved"

    return folder, exe, "missing"


def collect_records(games_root: Path, catalog: dict[str, dict[str, str]],
                    apply_catalog: bool, dry_run: bool, verbose: bool,
                    exclude: Path | None = None) -> list[Record]:
    records: list[Record] = []
    warnings: list[str] = []

    for folder in discover_games(games_root, exclude=exclude):
        candidates = launchables(folder)
        if not candidates:
            continue

        # Prefer something that runs on real DOS over a DOSBox launch script.
        reals = real_launchables(folder)
        skipped = [p.name for p in candidates if p not in reals]
        deep = None
        if reals:
            chosen = choose_exe(reals)
        else:
            deep = deep_real_launchable(folder)
            chosen = deep if deep else choose_exe(candidates)

        no_real_anywhere = not reals and not deep

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

        # The recorded directory must be the one holding the executable, or the
        # launcher CHDIRs somewhere the exe is not and EXEC fails.
        run_dir, exe_name, status = resolve_exe(folder, updated.get("exe", chosen.name))
        if not exe_name:
            exe_name = chosen.name
        updated["exe"] = exe_name

        # One message per game, describing where it actually ended up.
        where = exe_name
        if run_dir != folder:
            where = host_to_dos_rel(run_dir.relative_to(folder)) + "\\" + exe_name
        if no_real_anywhere:
            warnings.append(
                f"{folder.name}: only DOSBox-only script(s) found "
                f"({', '.join(skipped)}); this entry will not run on real DOS"
            )
        elif skipped:
            warnings.append(
                f"{folder.name}: ignoring DOSBox-only script(s) "
                f"{', '.join(skipped)}; using {where}"
            )
        elif status == "moved":
            warnings.append(
                f"{folder.name}: exe={updated.get('exe')} is not in that "
                f"directory; using {where}"
            )
        elif status == "missing":
            warnings.append(
                f"{folder.name}: exe={exe_name} was not found anywhere under "
                "the game folder"
            )

        if (not meta_path.exists()) or (updated != meta):
            write_game_txt(meta_path, updated, dry_run=dry_run)
            if verbose:
                verb = "would write" if dry_run else "wrote"
                print(f"  {verb} {display_path(meta_path)}")

        rel = run_dir.relative_to(games_root)
        records.append(
            Record(
                host_dir=run_dir,
                rel_dir=host_to_dos_rel(rel),
                exe=exe_name,
                title=updated.get("title", ""),
                year=updated.get("year", ""),
                genre=updated.get("genre", "Other"),
                publisher=updated.get("publisher", ""),
                note=updated.get("note", ""),
                setup=updated.get("setup", ""),
                needs_review=needs_review,
            )
        )

    if warnings:
        print("\nEntry corrections (review these):", file=sys.stderr)
        for w in warnings:
            print(f"  {w}", file=sys.stderr)

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
        help="Host path where GAMES.LST and DGB.CFG are written",
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

    return 0


if __name__ == "__main__":
    sys.exit(main())
