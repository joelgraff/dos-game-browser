"""Installing the launcher into a mounted image, and staging it onto media."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

from .support import ROOT, TempDirTest, make_game, run_dgb


class InstallTest(TempDirTest):

    def image(self) -> Path:
        make_game(self.tmp / "GAMES" / "ALPHA", "ALPHA.EXE")
        return self.tmp

    def test_installs_launcher_and_builds_the_index(self):
        img = self.image()
        r = run_dgb("install", "--image-root", str(img))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        dgb = img / "DGB"
        for name in ("BROWSER.COM", "START.BAT", "GAMES.LST", "DGB.CFG"):
            self.assertTrue((dgb / name).is_file(), f"{name} not installed")
        self.assertTrue((dgb / "UTILS" / "ABORT.COM").is_file())

    def test_existing_files_are_protected_by_default(self):
        img = self.image()
        self.assertEqual(run_dgb("install", "--image-root", str(img)).returncode, 0)
        r = run_dgb("install", "--image-root", str(img))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refusing to overwrite", r.stderr + r.stdout)

    def test_conflict_skip_and_overwrite(self):
        img = self.image()
        run_dgb("install", "--image-root", str(img))
        marker = img / "DGB" / "BROWSER.COM"
        marker.write_bytes(b"STALE")

        r = run_dgb("install", "--image-root", str(img), "--on-conflict", "skip")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(marker.read_bytes(), b"STALE", "skip should not replace")

        r = run_dgb("install", "--image-root", str(img), "--on-conflict", "overwrite")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotEqual(marker.read_bytes(), b"STALE", "overwrite should replace")

    def test_custom_scan_root_and_launcher_path(self):
        make_game(self.tmp / "DOSGAMES" / "RPG" / "FOO", "FOO.EXE")
        r = run_dgb("install", "--image-root", str(self.tmp),
                    "--scan-root", "DOSGAMES", "--launcher-path", "C:\\LAUNCH")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        lst = (self.tmp / "LAUNCH" / "GAMES.LST").read_bytes().decode("ascii", "replace")
        self.assertIn("G|RPG\\FOO|FOO.EXE|", lst)
        cfg = (self.tmp / "LAUNCH" / "DGB.CFG").read_bytes().decode("ascii", "replace")
        self.assertIn("GAMES_ROOT=\\DOSGAMES", cfg)

    def test_missing_scan_root_fails_cleanly(self):
        r = run_dgb("install", "--image-root", str(self.tmp), "--scan-root", "NOPE")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not found", r.stderr)

    def test_dry_run_writes_nothing(self):
        img = self.image()
        r = run_dgb("install", "--image-root", str(img), "--dry-run")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((img / "DGB" / "BROWSER.COM").exists())


class StageTest(TempDirTest):
    """Use case 1: the floppy that carries the launcher to the DOS machine."""

    def test_stages_launcher_and_instructions(self):
        out = self.tmp / "floppy"
        r = run_dgb("stage", "--out", str(out))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        for name in ("BROWSER.COM", "START.BAT", "INSTALL.TXT"):
            self.assertTrue((out / name).is_file(), f"{name} missing")
        self.assertTrue((out / "UTILS" / "ABORT.COM").is_file())

    def test_scan_com_is_included_when_built(self):
        """UC1 depends on it: without SCAN.COM the index cannot be built on DOS."""
        if not (ROOT / "bin" / "SCAN.COM").is_file():
            self.skipTest("SCAN.COM not built")
        out = self.tmp / "floppy"
        run_dgb("stage", "--out", str(out))
        self.assertTrue((out / "SCAN.COM").is_file())

    def test_ships_a_commented_config_template(self):
        """
        Without this there is no DGB.CFG until the first scan, so nothing tells
        you ABORT_KEY exists.
        """
        out = self.tmp / "floppy"
        run_dgb("stage", "--out", str(out))
        cfg = out / "DGB.CFG"
        self.assertTrue(cfg.is_file(), "no DGB.CFG staged")
        text = cfg.read_bytes().decode("ascii")
        self.assertIn("ABORT_KEY", text)
        self.assertIn("GAMES_ROOT", text)
        # every setting commented out, so it changes nothing until edited
        for line in text.replace("\r", "").splitlines():
            if line.strip() and not line.startswith(";"):
                self.fail(f"template has an active setting: {line!r}")

    def test_staging_never_overwrites_a_real_config(self):
        out = self.tmp / "floppy"
        out.mkdir()
        (out / "DGB.CFG").write_bytes(b"GAMES_ROOT=\\MINE\r\nABORT_KEY=F11\r\n")
        run_dgb("stage", "--out", str(out))
        text = (out / "DGB.CFG").read_bytes().decode("ascii")
        self.assertIn("GAMES_ROOT=\\MINE", text)
        self.assertIn("ABORT_KEY=F11", text)

    def test_instructions_are_plain_ascii_with_crlf(self):
        """INSTALL.TXT is read with DOS TYPE, so it must be ASCII and CRLF."""
        out = self.tmp / "floppy"
        run_dgb("stage", "--out", str(out))
        raw = (out / "INSTALL.TXT").read_bytes()
        self.assertIn(b"\r\n", raw)
        raw.decode("ascii")             # raises if anything is non-ASCII

    def test_whole_set_fits_a_360k_floppy(self):
        out = self.tmp / "floppy"
        run_dgb("stage", "--out", str(out))
        total = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
        self.assertLess(total, 360 * 1024, f"staged set is {total} bytes")


class RunTest(TempDirTest):
    """
    'run' launches an image; it must not launch an unprepared one silently.

    Any case that gets as far as launching passes --dosbox, because a real
    DOSBox window waits for a human and would hang the suite indefinitely.
    """

    NOOP = "true" if sys.platform != "win32" else "rem"

    def test_unprepared_image_is_refused_with_advice(self):
        make_game(self.tmp / "GAMES" / "ALPHA", "ALPHA.EXE")
        r = run_dgb("run", "--image-root", str(self.tmp), "--launcher-dir", "DGB")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no launcher found", r.stderr)
        self.assertIn("dgb.py install", r.stderr)
        self.assertIn("--install", r.stderr)

    def test_install_flag_prepares_the_image(self):
        """One command from a bare image to a runnable one."""
        make_game(self.tmp / "GAMES" / "ALPHA", "ALPHA.EXE")
        r = run_dgb("run", "--install", "--image-root", str(self.tmp),
                    "--launcher-dir", "DGB", "--dosbox", self.NOOP)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        dgb = self.tmp / "DGB"
        for name in ("BROWSER.COM", "START.BAT", "GAMES.LST", "DGB.CFG"):
            self.assertTrue((dgb / name).is_file(), f"{name} not installed")

    def test_missing_index_is_warned_about(self):
        make_game(self.tmp / "GAMES" / "ALPHA", "ALPHA.EXE")
        run_dgb("install", "--image-root", str(self.tmp))
        (self.tmp / "DGB" / "GAMES.LST").unlink()
        r = run_dgb("run", "--image-root", str(self.tmp), "--launcher-dir", "DGB",
                    "--dosbox", self.NOOP)
        self.assertIn("no GAMES.LST", r.stderr)


class DoctorTest(TempDirTest):

    def test_doctor_reports_the_environment(self):
        r = run_dgb("doctor")
        self.assertEqual(r.returncode, 0)
        for field in ("Python", "NASM", "DOSBox", "Prebuilt", "SCAN.COM"):
            self.assertIn(field, r.stdout)


if __name__ == "__main__":
    unittest.main()
