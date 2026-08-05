"""Path helpers shared across commands.

DOS and host filesystems disagree about separators, case and drive letters, and
every command here has to cross that boundary somewhere.
"""
from __future__ import annotations

from pathlib import Path

# Repository root: dgb/paths.py -> dgb/ -> repo root
ROOT = Path(__file__).resolve().parents[1]

# Prebuilt launcher artifacts. The repository ships the files themselves; the
# layout they are deployed into belongs to the target machine, not to us.
BIN = ROOT / "bin"
SRC = ROOT / "src"


def dos_to_host_subpath(dos_path: str) -> Path:
    """'C:\\DGB' -> Path('DGB'). Drive letters and leading separators dropped."""
    p = dos_path.strip().replace("/", "\\")
    if ":" in p:
        p = p.split(":", 1)[1]
    p = p.lstrip("\\")
    return Path(*[part for part in p.split("\\") if part])


def host_to_dos_rel(path: Path) -> str:
    """Relative host path -> DOS-style with backslashes."""
    return str(path).replace("/", "\\")


def display_path(p: Path) -> str:
    """Repo-relative when possible; game trees usually live outside the repo."""
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


def launcher_files() -> list[tuple[Path, str]]:
    """
    (source, destination-relative-path) for everything that gets deployed.

    One list, used by both install (into a mounted image) and stage (onto a
    floppy or staging directory), so the two cannot drift apart.
    """
    out = [
        (BIN / "BROWSER.COM", "BROWSER.COM"),
        (BIN / "START.BAT", "START.BAT"),
        (BIN / "UTILS" / "ABORT.COM", "UTILS/ABORT.COM"),
        (BIN / "UTILS" / "VDETECT.COM", "UTILS/VDETECT.COM"),
    ]
    # SCAN.COM lets the index be built on the DOS machine itself. It is
    # optional until it exists, so deployment works either way.
    scan_com = BIN / "SCAN.COM"
    if scan_com.is_file():
        out.append((scan_com, "SCAN.COM"))
    return out
