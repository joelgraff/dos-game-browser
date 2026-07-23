#!/usr/bin/env python3
"""
One-shot deployment flow for a mounted DOS image.

Runs Phase 1 setup-image.py against a target image root, then starts the
Phase 2 metadata review UI against the generated SETUP-REVIEW.json.

Examples:
  python tools/deploy-image.py --image-root ~/Documents/TESTIMG
  python tools/deploy-image.py --image-root /mnt/dos --port 8785
  python tools/deploy-image.py --image-root /mnt/dos --setup-only
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def dos_to_host_subpath(dos_path: str) -> Path:
    p = dos_path.strip().replace("/", "\\")
    if ":" in p:
        p = p.split(":", 1)[1]
    p = p.lstrip("\\")
    return Path(*[part for part in p.split("\\") if part])


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Run Phase 1 setup and Phase 2 review UI")
    ap.add_argument("--image-root", type=Path, required=True, help="Mounted image root path on host")
    ap.add_argument(
        "--scan-root",
        default="GAMES",
        help="GAMES root to scan (relative to image root, or absolute host path)",
    )
    ap.add_argument(
        "--launcher-path",
        default="C:\\DGB",
        help="DOS launcher path used by setup-image.py (default: C:\\DGB)",
    )
    ap.add_argument(
        "--launcher-host-path",
        type=Path,
        help="Host path where the launcher lives (default derived from --image-root and --launcher-path)",
    )
    ap.add_argument(
        "--on-conflict",
        choices=("fail", "skip", "overwrite"),
        default="fail",
        help="Phase 1 launcher-file conflict policy",
    )
    ap.add_argument("--dry-run", action="store_true", help="Show Phase 1 actions without writing files")
    ap.add_argument("--no-install", action="store_true", help="Skip copying launcher files")
    ap.add_argument("--no-scan", action="store_true", help="Skip scanning and only install launcher files")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--host", default="127.0.0.1", help="Review UI host (default: 127.0.0.1)")
    ap.add_argument("--port", type=int, default=8765, help="Review UI port (default: 8765)")
    ap.add_argument("--no-browser", action="store_true", help="Do not auto-open the review UI in a browser")
    ap.add_argument("--setup-only", action="store_true", help="Run Phase 1 only and exit")
    return ap.parse_args()


def launcher_dir_from_args(image_root: Path, launcher_path: str, launcher_host_path: Path | None) -> Path:
    if launcher_host_path is not None:
        return launcher_host_path.resolve()
    return (image_root.resolve() / dos_to_host_subpath(launcher_path)).resolve()


def run_setup(args: argparse.Namespace) -> int:
    cmd = [
        sys.executable,
        str(ROOT / "tools" / "setup-image.py"),
        "--image-root",
        str(args.image_root),
        "--scan-root",
        str(args.scan_root),
        "--launcher-path",
        args.launcher_path,
        "--on-conflict",
        args.on_conflict,
    ]
    if args.launcher_host_path is not None:
        cmd.extend(["--launcher-host-path", str(args.launcher_host_path)])
    if args.dry_run:
        cmd.append("--dry-run")
    if args.no_install:
        cmd.append("--no-install")
    if args.no_scan:
        cmd.append("--no-scan")
    if args.verbose:
        cmd.append("--verbose")

    print("Running Phase 1 setup...")
    return subprocess.call(cmd)


def wait_for_ui(url: str, timeout_s: float = 20.0) -> None:
    deadline = time.time() + timeout_s
    last_error: Exception | None = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1.0) as resp:
                if resp.status == 200:
                    return
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            time.sleep(0.2)
    raise TimeoutError(f"metadata UI did not become ready: {last_error}")


def main() -> int:
    args = parse_args()
    image_root = args.image_root.resolve()
    if not image_root.is_dir():
        print(f"image root not found: {image_root}", file=sys.stderr)
        return 1

    rc = run_setup(args)
    if rc != 0:
        return rc

    if args.dry_run or args.no_scan:
        print("Phase 1 completed; UI launch skipped because no review file was generated.")
        return 0

    launcher_dir = launcher_dir_from_args(image_root, args.launcher_path, args.launcher_host_path)
    review_file = launcher_dir / "SETUP-REVIEW.json"
    if not review_file.is_file():
        print(f"review file not found: {review_file}", file=sys.stderr)
        return 2

    ui_cmd = [
        sys.executable,
        str(ROOT / "tools" / "metadata-ui.py"),
        "--review-file",
        str(review_file),
        "--host",
        args.host,
        "--port",
        str(args.port),
    ]
    if args.no_browser:
        ui_cmd.append("--no-browser")

    ui_url = f"http://{args.host}:{args.port}/"
    print("\nStarting Phase 2 review UI...")
    proc = subprocess.Popen(ui_cmd)
    try:
        wait_for_ui(f"{ui_url}api/state")
        print(f"Review UI ready: {ui_url}")
        print(f"Review file: {review_file}")
        print("Press Ctrl+C to stop the UI server.")
        if not args.no_browser:
            import webbrowser

            try:
                webbrowser.open(ui_url)
            except Exception:
                pass
        return proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        try:
            return proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            return proc.wait()
    except Exception as exc:  # noqa: BLE001
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        print(f"deployment failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())