"""
Shared machinery for the test suite.

Most of what is worth testing here only exists inside DOS, so a lot of these
helpers exist to assemble a .COM, run it under headless DOSBox, and get its
output back onto the host.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from dgb.build import find_nasm            # noqa: E402
from dgb.dosbox import find_dosbox         # noqa: E402

# No X server and no audio device on CI runners or servers.
os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")

DOSBOX_TIMEOUT = 60


def require_nasm() -> Path:
    nasm = find_nasm()
    if nasm is None:
        raise unittest.SkipTest("nasm not installed")
    return nasm


def require_dosbox() -> Path:
    db = find_dosbox()
    if db is None:
        raise unittest.SkipTest("dosbox not installed")
    if str(db).startswith("flatpak:"):
        raise unittest.SkipTest("flatpak DOSBox cannot mount test fixtures")
    return db


def assemble(source: str, out: Path) -> Path:
    """Assemble src/<source> to out. Returns out."""
    nasm = require_nasm()
    out.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(nasm), "-f", "bin", "-o", str(out),
                        str(ROOT / "src" / source)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError(f"assembling {source} failed:\n{r.stderr}")
    return out


def run_dosbox(workdir: Path, lines: list[str], capture: str = "OUT.TXT") -> str:
    """
    Mount workdir as C:, run `lines` from autoexec, return the captured file.

    DOS writes CRLF; carriage returns are stripped so assertions can be written
    normally. A missing capture file yields "" rather than raising, because the
    interesting failure is usually what the output does or does not contain.
    """
    dosbox = require_dosbox()
    conf = workdir / "T.CONF"
    body = "\n".join(lines)
    conf.write_text(
        f"[sdl]\nautolock=false\n[autoexec]\nmount c {workdir}\nc:\n{body}\nexit\n",
        encoding="ascii", errors="replace")

    try:
        subprocess.run([str(dosbox), "-conf", str(conf), "-noconsole"],
                       cwd=workdir, capture_output=True,
                       timeout=DOSBOX_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise AssertionError(f"DOSBox timed out after {DOSBOX_TIMEOUT}s")

    out = workdir / capture
    if not out.is_file():
        return ""
    return out.read_text(encoding="ascii", errors="replace").replace("\r", "")


def selftest(workdir: Path, browser: Path, extra: list[str] | None = None) -> str:
    """Run BROWSER.COM /T in workdir and return its dump."""
    shutil.copy2(browser, workdir / "BROWSER.COM")
    lines = list(extra or [])
    lines.append("BROWSER.COM /T > OUT.TXT")
    return run_dosbox(workdir, lines)


def write_lst(directory: Path, *entries: str, comment: str = "# test") -> Path:
    """Write a GAMES.LST with CRLF, as the real tooling does."""
    directory.mkdir(parents=True, exist_ok=True)
    body = "\r\n".join([comment, *entries]) + "\r\n"
    p = directory / "GAMES.LST"
    p.write_bytes(body.encode("ascii", errors="replace"))
    return p


def make_game(directory: Path, exe: str, content: bytes = b"MZ") -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    p = directory / exe
    p.write_bytes(content)
    return p


def run_dgb(*args: str) -> subprocess.CompletedProcess:
    """Invoke the CLI the way a user would."""
    return subprocess.run([sys.executable, str(ROOT / "dgb.py"), *args],
                          capture_output=True, text=True)


class TempDirTest(unittest.TestCase):
    """TestCase with a per-test temporary directory."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
