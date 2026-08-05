#!/usr/bin/env python3
"""
First-time launcher setup on a mounted DOS image.

Installs the launcher files into a target directory on the image, then calls
tools/scan-games.py to discover games and generate GAMES.LST and DGB.CFG.

Discovery and index generation live entirely in scan-games.py; this script only
handles installation and the file-conflict policy.

Usage examples:
  python tools/setup-image.py --image-root /mnt/dos
  python tools/setup-image.py --image-root /mnt/dos --scan-root GAMES --launcher-path C:\\DGB
  python tools/setup-image.py --image-root /mnt/dos --dry-run --verbose
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_BOOTH = ROOT / "booth"
SCANNER = ROOT / "tools" / "scan-games.py"


def dos_to_host_subpath(dos_path: str) -> Path:
    p = dos_path.strip().replace("/", "\\")
    if ":" in p:
        p = p.split(":", 1)[1]
    p = p.lstrip("\\")
    return Path(*[part for part in p.split("\\") if part])


def host_to_dos_rel(path: Path) -> str:
    return str(path).replace("/", "\\")


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


def run_scanner(args: argparse.Namespace, image_root: Path, scan_root: Path,
                launcher_dir: Path) -> int:
    cmd = [
        sys.executable,
        str(SCANNER),
        "--games-root", str(scan_root),
        "--launcher-dir", str(launcher_dir),
        "--image-root", str(image_root),
    ]
    if args.dry_run:
        cmd.append("--dry-run")
    if args.verbose:
        cmd.append("--verbose")
    if args.sort:
        cmd.extend(["--sort", args.sort])
    if args.no_headers:
        cmd.append("--no-headers")
    sys.stdout.flush()          # keep our output ahead of the child's
    return subprocess.call(cmd)


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Set up DOS Game Browser on a mounted image")
    ap.add_argument("--image-root", type=Path, required=True, help="Mounted image root path on host")
    ap.add_argument(
        "--scan-root",
        default="GAMES",
        help="Games tree to scan (relative to image root, or absolute host path)",
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
    ap.add_argument("--sort", choices=("genre", "year", "title"), default="genre")
    ap.add_argument("--no-headers", action="store_true")
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

    if args.no_scan:
        print("\nSkipped scan; no index generated.")
        return 0

    print("\nScanning image for launchable executables...")
    rc = run_scanner(args, image_root, scan_root, launcher_dir)
    if rc != 0:
        print("setup failed: scan-games.py reported an error", file=sys.stderr)
        return 2

    print("\nNext steps:")
    print("  1. Review the GAME.TXT files the scan reported as needing it")
    print("  2. Regenerate the index with tools/scan-games.py after edits")
    print("  3. Boot image and run START.BAT from launcher path")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
