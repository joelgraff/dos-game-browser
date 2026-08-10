"""
The Python scanner: discovery rules, DGB.CFG, capacity guards, arguments.

Most cases here pin behaviour that was wrong at some point and produced a
catalog the launcher could not use.
"""
from __future__ import annotations

import unittest
from pathlib import Path

from .support import TempDirTest, make_game, run_dgb


class ScanTest(TempDirTest):

    def scan(self, *args: str, expect_ok: bool = True):
        r = run_dgb("scan", *args)
        if expect_ok:
            self.assertEqual(r.returncode, 0,
                             f"scan failed:\n{r.stdout}\n{r.stderr}")
        return r

    def index(self, launcher: Path) -> list[str]:
        p = launcher / "GAMES.LST"
        if not p.is_file():
            return []
        text = p.read_text(encoding="ascii", errors="replace")
        return [l for l in text.replace("\r", "").splitlines() if l.startswith("G|")]

    # -- discovery --------------------------------------------------------
    def test_games_at_depths_one_to_three(self):
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        make_game(g / "APOGEE" / "KEEN", "KEEN1.EXE")
        make_game(g / "EPIC" / "JAZZ" / "JJ1", "JAZZ.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--no-headers")
        lines = self.index(self.tmp / "DGB")
        self.assertTrue(any(l.startswith("G|JILL|") for l in lines))
        self.assertTrue(any(l.startswith("G|APOGEE\\KEEN|") for l in lines))
        self.assertTrue(any(l.startswith("G|EPIC\\JAZZ\\JJ1|") for l in lines))

    def test_a_games_own_subdirectories_are_not_entries(self):
        g = self.tmp / "GAMES"
        make_game(g / "DOOM", "DOOM.EXE")
        make_game(g / "DOOM" / "UTILS", "EDITOR.EXE")
        make_game(g / "DOOM" / "DATA", "VIEWER.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--no-headers")
        self.assertEqual(len(self.index(self.tmp / "DGB")), 1)

    def test_directories_deeper_than_three_levels_are_ignored(self):
        g = self.tmp / "GAMES"
        make_game(g / "A" / "B" / "C" / "D", "DEEP.EXE")
        make_game(g / "OK", "OK.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--no-headers")
        lines = self.index(self.tmp / "DGB")
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("G|OK|"))

    def test_launcher_directory_is_never_catalogued(self):
        g = self.tmp / "GAMES"
        make_game(g / "REAL", "REAL.EXE")
        make_game(g / "DGB", "BROWSER.COM")
        self.scan("--games-root", str(g), "--launcher-dir", str(g / "DGB"),
                  "--no-headers")
        lines = self.index(g / "DGB")
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("G|REAL|"))

    def test_games_root_nested_inside_the_launcher_directory(self):
        """Excluding the launcher dir unconditionally discarded the whole scan."""
        base = self.tmp / "launcher"
        make_game(base / "GAMES" / "HELLOWOR", "HELLO.EXE")
        make_game(base / "GAMES" / "TESTGAME", "TEST.EXE")
        (base / "BROWSER.COM").write_bytes(b"MZ")
        self.scan("--games-root", str(base / "GAMES"), "--launcher-dir", str(base),
                  "--games-root-dos", "GAMES", "--no-headers")
        self.assertEqual(len(self.index(base)), 2)

    # -- exe resolution ---------------------------------------------------
    def test_exe_in_a_subdirectory_repoints_the_recorded_directory(self):
        """
        A GAME.TXT exe= naming a file one level down was recorded against the
        parent, so the launcher chdir'd there and failed with DOS error 02.
        """
        g = self.tmp / "GAMES"
        (g / "COMMANDE" / "KEEN").mkdir(parents=True)
        (g / "COMMANDE" / "KEEN.BAT").write_text("x")
        (g / "COMMANDE" / "KEEN" / "KEEN1.EXE").write_bytes(b"MZ")
        (g / "COMMANDE" / "GAME.TXT").write_bytes(
            b"title=Commander Keen\r\nyear=1990\r\npublisher=id\r\nexe=KEEN1.EXE\r\n")
        r = self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                      "--no-headers")
        self.assertTrue(any(l.startswith("G|COMMANDE\\KEEN|KEEN1.EXE|")
                            for l in self.index(self.tmp / "DGB")))
        self.assertIn("Entry corrections", r.stderr)

    def test_exe_matching_is_case_insensitive(self):
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        (g / "JILL" / "GAME.TXT").write_bytes(
            b"title=Jill\r\nyear=1992\r\npublisher=Epic\r\nexe=jill.exe\r\n")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--no-headers")
        self.assertTrue(any("|JILL.EXE|" in l for l in self.index(self.tmp / "DGB")))

    def test_missing_exe_warns_and_falls_back(self):
        g = self.tmp / "GAMES"
        make_game(g / "GHOST", "REAL.EXE")
        (g / "GHOST" / "GAME.TXT").write_bytes(
            b"title=Ghost\r\nyear=1990\r\npublisher=X\r\nexe=NOSUCH.EXE\r\n")
        r = self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                      "--no-headers")
        self.assertIn("was not found anywhere", r.stderr)

    # -- DOSBox wrapper scripts -------------------------------------------
    def test_dosbox_wrapper_loses_to_a_real_executable(self):
        """Repack .BATs configure the emulator and fail on real hardware."""
        g = self.tmp / "GAMES"
        (g / "AIRLIFT").mkdir(parents=True)
        (g / "AIRLIFT" / "AIRLIFT.BAT").write_bytes(
            b"@echo off\r\nREM DOS Games Archive launch script\r\ncycles max\r\nAIRLIFT.EXE\r\n")
        (g / "AIRLIFT" / "AIRLIFT.EXE").write_bytes(b"MZ")
        r = self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                      "--no-headers")
        self.assertTrue(any("|AIRLIFT.EXE|" in l for l in self.index(self.tmp / "DGB")))
        self.assertIn("ignoring DOSBox-only script", r.stderr)

    def test_a_plain_bat_is_still_preferred(self):
        g = self.tmp / "GAMES"
        (g / "MYGAME").mkdir(parents=True)
        (g / "MYGAME" / "START.BAT").write_bytes(b"@echo off\r\nLOADFIX -25\r\nGAME.EXE\r\n")
        (g / "MYGAME" / "GAME.EXE").write_bytes(b"MZ")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--no-headers")
        self.assertTrue(any("|START.BAT|" in l for l in self.index(self.tmp / "DGB")))

    def test_only_wrappers_up_top_finds_the_real_executable_below(self):
        g = self.tmp / "GAMES"
        (g / "COMMANDE" / "KEEN").mkdir(parents=True)
        (g / "COMMANDE" / "KEEN.BAT").write_bytes(
            b"@echo off\r\nconfig -set cpu cycles=auto\r\ncd KEEN\r\nKEEN1.EXE\r\n")
        (g / "COMMANDE" / "KEEN" / "KEEN1.EXE").write_bytes(b"MZ")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--no-headers")
        self.assertTrue(any(l.startswith("G|COMMANDE\\KEEN|KEEN1.EXE|")
                            for l in self.index(self.tmp / "DGB")))

    def test_a_call_to_another_wrapper_is_also_a_wrapper(self):
        g = self.tmp / "GAMES"
        (g / "ABS").mkdir(parents=True)
        (g / "ABS" / "ABSWEB.BAT").write_bytes(b"@echo off\r\nscaler normal2x\r\nCALL ABS.BAT\r\n")
        (g / "ABS" / "ABS.BAT").write_bytes(b"@echo off\r\naspect true\r\nABS.EXE\r\n")
        (g / "ABS" / "ABS.EXE").write_bytes(b"MZ")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--no-headers")
        self.assertTrue(any("|ABS.EXE|" in l for l in self.index(self.tmp / "DGB")))

    # -- DGB.CFG ----------------------------------------------------------
    def cfg_text(self, launcher: Path) -> str:
        # read_text() applies universal newlines, which would hide CRLF
        return (launcher / "DGB.CFG").read_bytes().decode("ascii", "replace")

    def test_games_root_derived_from_image_root(self):
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--image-root", str(self.tmp))
        self.assertIn("GAMES_ROOT=\\GAMES", self.cfg_text(self.tmp / "DGB"))
        self.assertIn("\r\n", self.cfg_text(self.tmp / "DGB"))

    def test_nested_games_root_under_the_image_root(self):
        g = self.tmp / "DOS" / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--image-root", str(self.tmp))
        self.assertIn("GAMES_ROOT=\\DOS\\GAMES", self.cfg_text(self.tmp / "DGB"))

    def test_explicit_dos_root_overrides_image_root(self):
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--image-root", str(self.tmp), "--games-root-dos", "\\PLAY")
        self.assertIn("GAMES_ROOT=\\PLAY", self.cfg_text(self.tmp / "DGB"))

    def test_unknown_dos_root_is_skipped_with_an_explanation(self):
        """Never guessed: a wrong GAMES_ROOT is worse than none."""
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        r = self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"))
        self.assertFalse((self.tmp / "DGB" / "DGB.CFG").exists())
        self.assertIn("games-root-dos", r.stderr)
        self.assertTrue((self.tmp / "DGB" / "GAMES.LST").exists())

    def test_no_cfg_suppresses_the_write(self):
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--image-root", str(self.tmp), "--no-cfg")
        self.assertFalse((self.tmp / "DGB" / "DGB.CFG").exists())

    def test_existing_settings_survive_a_rescan(self):
        """
        ABORT_KEY is edited by hand on the DOS machine. Rewriting DGB.CFG
        wholesale used to delete it on the next scan without saying anything.
        """
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        dgb = self.tmp / "DGB"
        dgb.mkdir()
        (dgb / "DGB.CFG").write_bytes(
            b"; old\r\nGAMES_ROOT=\\OLD\r\nABORT_KEY=F11\r\nSOMETHING=42\r\n")
        self.scan("--games-root", str(g), "--launcher-dir", str(dgb),
                  "--games-root-dos", "\\GAMES")
        cfg = self.cfg_text(dgb)
        self.assertIn("GAMES_ROOT=\\GAMES", cfg)      # ours, updated
        self.assertIn("ABORT_KEY=F11", cfg)            # not ours, kept
        self.assertIn("SOMETHING=42", cfg)             # not ours, kept
        self.assertNotIn("OLD", cfg)                   # stale value gone

    def test_generated_config_documents_the_abort_key(self):
        """
        A shipped template's comments do not survive the rewrite, so the
        generated file has to carry the hint itself or the option is invisible.
        """
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--games-root-dos", "\\GAMES")
        cfg = self.cfg_text(self.tmp / "DGB")
        self.assertIn(";ABORT_KEY=F12", cfg)        # commented, so inert
        self.assertNotIn("\nABORT_KEY=", cfg)      # and not actually set

    def test_the_hint_is_dropped_once_the_key_is_really_set(self):
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        dgb = self.tmp / "DGB"
        dgb.mkdir()
        (dgb / "DGB.CFG").write_bytes(b"ABORT_KEY=F11\r\n")
        self.scan("--games-root", str(g), "--launcher-dir", str(dgb),
                  "--games-root-dos", "\\GAMES")
        cfg = self.cfg_text(dgb)
        self.assertIn("ABORT_KEY=F11", cfg)
        self.assertNotIn(";ABORT_KEY=F12", cfg)

    def test_abort_key_can_be_set_from_the_host(self):
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--games-root-dos", "\\GAMES", "--abort-key", "F11")
        self.assertIn("ABORT_KEY=F11", self.cfg_text(self.tmp / "DGB"))

    # -- capacity ---------------------------------------------------------
    def test_oversized_catalog_is_refused_and_nothing_written(self):
        g = self.tmp / "GAMES"
        for i in range(350):
            make_game(g / f"G{i:03d}", f"G{i:03d}.EXE")
        r = self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                      "--no-headers", expect_ok=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((self.tmp / "DGB" / "GAMES.LST").exists())
        self.assertIn("exceeds launcher limits", r.stderr)

    def test_headers_pushing_past_the_limit_suggest_no_headers(self):
        g = self.tmp / "GAMES"
        for i in range(300):
            d = g / f"G{i:03d}"
            make_game(d, f"G{i:03d}.EXE")
            (d / "GAME.TXT").write_bytes(
                f"title=Game {i:03d}\r\ngenre=Genre{i % 40}\r\nexe=G{i:03d}.EXE\r\n".encode())
        r = self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                      expect_ok=False)
        self.assertIn("--no-headers", r.stderr)
        # and it fits once headers are dropped
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--no-headers")

    # -- outputs ----------------------------------------------------------
    def test_outputs_use_crlf(self):
        g = self.tmp / "GAMES"
        make_game(g / "JILL", "JILL.EXE")
        self.scan("--games-root", str(g), "--launcher-dir", str(self.tmp / "DGB"),
                  "--no-headers")
        raw = (self.tmp / "DGB" / "GAMES.LST").read_bytes()
        self.assertIn(b"\r\n", raw)
        self.assertIn(b"\r\n", (g / "JILL" / "GAME.TXT").read_bytes())

    # -- arguments --------------------------------------------------------
    def test_games_root_is_required(self):
        self.assertNotEqual(run_dgb("scan", "--launcher-dir", str(self.tmp)).returncode, 0)

    def test_launcher_dir_is_required(self):
        self.assertNotEqual(run_dgb("scan", "--games-root", str(self.tmp)).returncode, 0)

    def test_missing_games_root_fails_cleanly(self):
        r = run_dgb("scan", "--games-root", str(self.tmp / "nope"),
                    "--launcher-dir", str(self.tmp / "DGB"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not found", r.stderr)


if __name__ == "__main__":
    unittest.main()
