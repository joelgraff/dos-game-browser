#!/usr/bin/env python3
"""
First-time mounted-image setup for DOS Game Browser.

This script scans an existing mounted DOS image recursively for launchable
executables, installs launcher files into a target path, and generates a
GAMES.LST with placeholder metadata so the launcher is immediately runnable.

Usage examples:
  python tools/setup-image.py --image-root /mnt/dos
  python tools/setup-image.py --image-root /mnt/dos --scan-root GAMES --launcher-path C:\\DGB
  python tools/setup-image.py --image-root /mnt/dos --dry-run --verbose
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_BOOTH = ROOT / "booth"

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


@dataclass
class Record:
    host_dir: Path
    exe: str
    title: str
    year: str
    genre: str
    publisher: str
    note: str
    needs_review: bool
    candidates: list[str]


def dos_to_host_subpath(dos_path: str) -> Path:
    p = dos_path.strip().replace("/", "\\")
    if ":" in p:
        p = p.split(":", 1)[1]
    p = p.lstrip("\\")
    return Path(*[part for part in p.split("\\") if part])


def host_to_dos_rel(path: Path) -> str:
    return str(path).replace("/", "\\")


def ascii_clean(s: str, maxlen: int) -> str:
    s = s.encode("ascii", "replace").decode("ascii")
    s = s.replace("|", "/").replace("\r", " ").replace("\n", " ")
    return s[:maxlen]


def title_from_path(folder: Path) -> str:
    return folder.name.replace("_", " ").replace("-", " ").strip().title() or folder.name


def find_exes(scan_root: Path, launcher_dir: Path) -> dict[Path, list[Path]]:
    grouped: dict[Path, list[Path]] = {}
    for p in scan_root.rglob("*"):
        if not p.is_file():
            continue
        if launcher_dir in p.parents:
            continue
        if p.suffix.lower() not in {".bat", ".exe", ".com"}:
            continue
        if p.name.lower() in SKIP:
            continue
        grouped.setdefault(p.parent, []).append(p)
    return grouped


def choose_exe(candidates: list[Path], base_dir: Path) -> Path:
    ext_rank = {".bat": 0, ".exe": 1, ".com": 2}

    def score(p: Path) -> tuple[int, int, int, str]:
        name = p.name.lower()
        try:
            pref = PREFER_EXE.index(name)
        except ValueError:
            pref = len(PREFER_EXE) + 1
        ext = ext_rank.get(p.suffix.lower(), 9)
        depth = len(p.relative_to(base_dir).parts)
        return (ext, pref, depth, name)

    return sorted(candidates, key=score)[0]


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


def write_game_txt(path: Path, meta: dict[str, str], dry_run: bool) -> None:
    order = ["title", "year", "genre", "publisher", "exe", "setup", "note"]
    lines = ["# DOS Game Browser metadata — edit freely, then regenerate index", ""]
    for key in order:
        if meta.get(key, "") != "":
            lines.append(f"{key}={meta[key]}")
    text = "\n".join(lines) + "\n"
    if not dry_run:
        path.write_text(text, encoding="utf-8")


def collect_records(scan_root: Path, launcher_dir: Path, dry_run: bool, verbose: bool) -> list[Record]:
    grouped = find_exes(scan_root, launcher_dir)
    records: list[Record] = []

    for folder in sorted(grouped.keys(), key=lambda p: str(p).lower()):
        candidates = grouped[folder]
        chosen = choose_exe(candidates, scan_root)
        meta_path = folder / "GAME.TXT"
        meta = parse_game_txt(meta_path)

        title = meta.get("title") or title_from_path(folder)
        year = meta.get("year", "")
        genre = meta.get("genre") or "Other"
        publisher = meta.get("publisher", "")
        note = meta.get("note", "")
        exe_name = meta.get("exe") or chosen.name

        needs_review = any(not x for x in (meta.get("title", ""), meta.get("year", ""), meta.get("publisher", "")))

        updated = dict(meta)
        if not updated.get("title"):
            updated["title"] = title
        if not updated.get("year"):
            updated["year"] = year
        if not updated.get("genre"):
            updated["genre"] = genre
        if not updated.get("publisher"):
            updated["publisher"] = publisher
        if not updated.get("note"):
            updated["note"] = note
        if not updated.get("exe"):
            updated["exe"] = exe_name

        if (not meta_path.exists()) or (updated != meta):
            write_game_txt(meta_path, updated, dry_run=dry_run)
            if verbose:
                print(f"  {'would write' if dry_run else 'wrote'} {meta_path}")

        records.append(
            Record(
                host_dir=folder,
                exe=exe_name,
                title=title,
                year=year,
                genre=genre,
                publisher=publisher,
                note=note,
                needs_review=needs_review,
                candidates=sorted([p.name for p in candidates], key=str.lower),
            )
        )

    return records


def install_launcher(
    launcher_dir: Path,
    dry_run: bool,
    verbose: bool,
    on_conflict: str,
) -> tuple[list[Path], list[Path]]:
    files = [
        (SOURCE_BOOTH / "BROWSER.COM", launcher_dir / "BROWSER.COM"),
        (SOURCE_BOOTH / "START.BAT", launcher_dir / "START.BAT"),
        (SOURCE_BOOTH / "UTILS" / "ABORT.COM", launcher_dir / "UTILS" / "ABORT.COM"),
        (SOURCE_BOOTH / "UTILS" / "VDETECT.COM", launcher_dir / "UTILS" / "VDETECT.COM"),
    ]

    skipped: list[Path] = []
    overwritten: list[Path] = []

    for src, dst in files:
        if not src.is_file():
            raise FileNotFoundError(f"Missing source file: {src}")

        if dst.exists():
            if on_conflict == "fail":
                raise FileExistsError(
                    f"refusing to overwrite existing launcher file: {dst} "
                    "(use --on-conflict overwrite or skip)"
                )
            if on_conflict == "skip":
                skipped.append(dst)
                if verbose:
                    print(f"  skip existing {dst}")
                continue
            overwritten.append(dst)

        if verbose:
            print(f"  {'would copy' if dry_run else 'copy'} {src} -> {dst}")
        if not dry_run:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

    return skipped, overwritten


def write_games_lst(records: list[Record], games_root: Path, launcher_dir: Path, dry_run: bool) -> Path:
    lines = [
        "# GAMES.LST - generated by tools/setup-image.py",
        "# Edit GAME.TXT files, then regenerate with tools/scan-games.py or setup-image.py",
        "# fields: G|dir|exe|title|year|genre|publisher|note",
        "",
    ]

    for rec in sorted(records, key=lambda r: r.title.lower()):
        try:
            rel = rec.host_dir.relative_to(games_root)
        except ValueError:
            raise ValueError(
                f"record directory {rec.host_dir} is outside scan root {games_root}; "
                "cannot create stable GAMES.LST mapping"
            )
        dos_dir = host_to_dos_rel(rel)
        lines.append(
            "G|"
            + "|".join(
                [
                    ascii_clean(dos_dir, 40),
                    ascii_clean(rec.exe, 12),
                    ascii_clean(rec.title, 40),
                    ascii_clean(rec.year, 4),
                    ascii_clean(rec.genre, 16),
                    ascii_clean(rec.publisher, 20),
                    ascii_clean(rec.note, 40),
                ]
            )
        )

    out = launcher_dir / "GAMES.LST"
    text = "\r\n".join(lines) + "\r\n"
    if not dry_run:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(text.encode("ascii", errors="replace"))
    return out


def write_review(records: list[Record], scan_root: Path, launcher_dir: Path, dry_run: bool) -> Path:
    payload = {
        "version": 1,
        "scan_root": str(scan_root),
        "launcher_dir": str(launcher_dir),
        "records": [
            {
                "dir": str(r.host_dir),
                "exe": r.exe,
                "title": r.title,
                "year": r.year,
                "genre": r.genre,
                "publisher": r.publisher,
                "note": r.note,
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


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Set up DOS Game Browser on a mounted image")
    ap.add_argument("--image-root", type=Path, required=True, help="Mounted image root path on host")
    ap.add_argument(
        "--scan-root",
        default="GAMES",
        help="GAMES root path to scan (relative to image root, or absolute host path)",
    )
    ap.add_argument(
        "--launcher-path",
        default="C:\\DGB",
        help="DOS launcher path label used for reporting (default: C:\\DGB)",
    )
    ap.add_argument(
        "--launcher-host-path",
        type=Path,
        help="Host path where launcher is installed (default derived from --image-root and --launcher-path)",
    )
    ap.add_argument("--dry-run", action="store_true", help="Show actions without writing files")
    ap.add_argument("--no-install", action="store_true", help="Skip copying launcher files")
    ap.add_argument("--no-scan", action="store_true", help="Skip scan and only install launcher files")
    ap.add_argument(
        "--on-conflict",
        choices=("fail", "skip", "overwrite"),
        default="fail",
        help="Behavior when launcher files already exist (default: fail)",
    )
    ap.add_argument("--verbose", action="store_true")
    return ap.parse_args()


def main() -> int:
    args = parse_args()
    image_root = args.image_root.resolve()
    if not image_root.is_dir():
        print(f"image root not found: {image_root}", file=sys.stderr)
        return 1

    if args.launcher_host_path:
        launcher_dir = args.launcher_host_path.resolve()
    else:
        launcher_dir = (image_root / dos_to_host_subpath(args.launcher_path)).resolve()

    scan_root = Path(args.scan_root)
    if not scan_root.is_absolute():
        scan_root = (image_root / scan_root).resolve()
    else:
        scan_root = scan_root.resolve()

    if not args.no_scan and not scan_root.is_dir():
        print(f"scan root not found: {scan_root}", file=sys.stderr)
        return 1

    print("DOS Game Browser setup")
    print(f"  image root:   {image_root}")
    print(f"  scan root:    {scan_root}")
    print(f"  launcher dos: {args.launcher_path}")
    print(f"  launcher dir: {launcher_dir}")
    if args.dry_run:
        print("  mode:         DRY RUN")

    records: list[Record] = []
    if not args.no_scan:
        print("\nScanning image for launchable executables...")
        records = collect_records(scan_root, launcher_dir, dry_run=args.dry_run, verbose=args.verbose)
        print(f"  discovered directories with executables: {len(records)}")

    if not args.no_install:
        print("\nInstalling launcher files...")
        try:
            skipped, overwritten = install_launcher(
                launcher_dir,
                dry_run=args.dry_run,
                verbose=args.verbose,
                on_conflict=args.on_conflict,
            )
        except (FileExistsError, FileNotFoundError) as exc:
            print(f"setup failed: {exc}", file=sys.stderr)
            return 2
        if skipped:
            print(f"  skipped existing files: {len(skipped)}")
        if overwritten:
            print(f"  overwritten files:      {len(overwritten)}")

    if records:
        print("\nGenerating launcher index...")
        try:
            out_lst = write_games_lst(records, scan_root, launcher_dir, dry_run=args.dry_run)
        except ValueError as exc:
            print(f"setup failed: {exc}", file=sys.stderr)
            return 2
        review = write_review(records, scan_root, launcher_dir, dry_run=args.dry_run)
        unresolved = sum(1 for r in records if r.needs_review)
        print(f"  {'would write' if args.dry_run else 'wrote'} {out_lst}")
        print(f"  {'would write' if args.dry_run else 'wrote'} {review}")
        print(f"  records needing metadata review: {unresolved}")
    else:
        print("\nNo scan results available; skipped GAMES.LST generation.")

    print("\nNext steps:")
    print("  1. Review GAME.TXT files and SETUP-REVIEW.json")
    print("  2. Regenerate index if needed with tools/scan-games.py")
    print("  3. Boot image and run START.BAT from launcher path")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
