"""
SCAN.COM against dgb.py scan, over identical fixtures.

Two implementations of one set of rules will drift. Every case here scans the
same tree both ways and requires the G| lines to match byte for byte. This is
the only thing keeping the DOS-side scanner honest as the Python one changes,
and it has already caught a broken recursion and a title-casing mismatch.
"""
from __future__ import annotations

import shutil
import unittest
from pathlib import Path

from .support import (ROOT, TempDirTest, assemble, make_game, require_dosbox,
                      require_nasm, run_dgb, run_dosbox)


class ScanComParityTest(TempDirTest):

    scan_com: Path

    @classmethod
    def setUpClass(cls) -> None:
        require_nasm()
        require_dosbox()
        cls._shared = Path(__import__("tempfile").mkdtemp())
        cls.scan_com = assemble("scan.asm", cls._shared / "SCAN.COM")

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls._shared, ignore_errors=True)

    def assert_parity(self, root: Path) -> int:
        """Scan root/GAMES both ways; require identical entries. Returns count."""
        dgb_dir = root / "DGB"
        dgb_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.scan_com, dgb_dir / "SCAN.COM")

        run_dosbox(root, ["cd \\DGB", "SCAN.COM C:\\GAMES > OUT.TXT"])

        r = run_dgb("scan", "--games-root", str(root / "GAMES"),
                    "--launcher-dir", str(root / "PY"),
                    "--games-root-dos", "\\GAMES", "--sort", "title", "--no-headers")
        self.assertEqual(r.returncode, 0, f"python scan failed:\n{r.stderr}")

        def entries(p: Path) -> list[str]:
            if not p.is_file():
                return []
            text = p.read_bytes().decode("ascii", "replace").replace("\r", "")
            return [l for l in text.splitlines() if l.startswith("G|")]

        dos = entries(dgb_dir / "GAMES.LST")
        py = entries(root / "PY" / "GAMES.LST")

        out = (dgb_dir / "OUT.TXT")
        detail = out.read_bytes().decode("ascii", "replace") if out.is_file() else ""
        self.assertTrue(dos, f"SCAN.COM produced no entries. Its output:\n{detail}")
        self.assertEqual(dos, py, "SCAN.COM and dgb.py scan disagree")
        return len(dos)

    # ---------------------------------------------------------------------
    def test_depths_one_to_three(self):
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        make_game(g / "APOGEE" / "KEEN", "KEEN1.EXE")
        make_game(g / "EPIC" / "JAZZ" / "JJ1", "JAZZ.EXE")
        self.assertEqual(self.assert_parity(self.tmp), 3)

    def test_a_games_own_subdirectories_are_not_entries(self):
        g = self.tmp / "GAMES"
        make_game(g / "DOOM", "DOOM.EXE")
        make_game(g / "DOOM" / "UTILS", "EDITOR.EXE")
        make_game(g / "DOOM" / "DATA", "VIEWER.EXE")
        self.assertEqual(self.assert_parity(self.tmp), 1)

    def test_installers_are_skipped(self):
        g = self.tmp / "GAMES"
        make_game(g / "ALPHA", "ALPHA.EXE")
        (g / "ALPHA" / "SETUP.EXE").write_bytes(b"MZ")
        (g / "ALPHA" / "INSTALL.EXE").write_bytes(b"MZ")
        self.assert_parity(self.tmp)

    def test_extension_preference(self):
        g = self.tmp / "GAMES"
        make_game(g / "BETA", "BETA.COM")
        (g / "BETA" / "BETA.EXE").write_bytes(b"MZ")
        (g / "BETA" / "START.BAT").write_text("x")
        self.assert_parity(self.tmp)

    def test_every_game_txt_field_round_trips(self):
        g = self.tmp / "GAMES"
        make_game(g / "KEEN", "KEEN1.EXE")
        (g / "KEEN" / "GAME.TXT").write_bytes(
            b"title=Commander Keen\r\nyear=1990\r\ngenre=Platform\r\n"
            b"publisher=id Software\r\nnote=Invasion of the Vorticons\r\n")
        self.assert_parity(self.tmp)

    def test_game_txt_exe_overrides_discovery(self):
        g = self.tmp / "GAMES"
        make_game(g / "GAMMA", "AAA.EXE")
        (g / "GAMMA" / "ZZZ.EXE").write_bytes(b"MZ")
        (g / "GAMMA" / "GAME.TXT").write_bytes(b"title=Gamma\r\nexe=ZZZ.EXE\r\n")
        self.assert_parity(self.tmp)

    def test_entries_are_sorted_by_title(self):
        g = self.tmp / "GAMES"
        for n in ("ZULU", "ALPHA", "MIKE", "BRAVO"):
            make_game(g / n, f"{n}.EXE")
        self.assertEqual(self.assert_parity(self.tmp), 4)

    def test_existing_dgb_cfg_settings_survive_a_rescan(self):
        """
        SCAN.COM rewrites DGB.CFG, and ABORT_KEY is edited by hand on this very
        machine. Losing it on the next scan would be silent and infuriating.
        """
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        dgb = self.tmp / "DGB"
        dgb.mkdir(parents=True, exist_ok=True)
        (dgb / "DGB.CFG").write_bytes(
            b"; old\r\nGAMES_ROOT=\\OLD\r\nABORT_KEY=F11\r\nSOMETHING=42\r\n")
        shutil.copy2(self.scan_com, dgb / "SCAN.COM")
        run_dosbox(self.tmp, ["cd \\DGB", "SCAN.COM C:\\GAMES > OUT.TXT"])

        cfg = (dgb / "DGB.CFG").read_bytes().decode("ascii", "replace")
        self.assertIn("GAMES_ROOT=\\GAMES", cfg)
        self.assertIn("ABORT_KEY=F11", cfg)
        self.assertIn("SOMETHING=42", cfg)
        self.assertNotIn("OLD", cfg)

    def test_directory_names_are_title_cased_identically(self):
        """Python's str.title() treats digits as word boundaries: 2FAST4YO -> 2Fast4Yo."""
        g = self.tmp / "GAMES"
        make_game(g / "HELLOWOR", "HELLO.EXE")
        make_game(g / "2FAST4YO", "BIFI.EXE")
        self.assertEqual(self.assert_parity(self.tmp), 2)


if __name__ == "__main__":
    unittest.main()
