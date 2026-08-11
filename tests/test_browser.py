"""
BROWSER.COM, exercised under headless DOSBox via its /T and /X modes.

These drive the shipped code paths in the shipped binary, so what CI checks is
what runs on hardware. Several of the cases below exist because the behaviour
they pin was once broken in a way that was invisible from the outside.
"""
from __future__ import annotations

import re
import shutil
import unittest
from pathlib import Path

from .support import (ROOT, TempDirTest, assemble, make_game, require_dosbox,
                      require_nasm, run_dosbox, selftest, write_lst)

GAME_LINE = "G|JILL|JILL.EXE|Jill of the Jungle|1992|Platform|Epic|A note"


class _BrowserBase(TempDirTest):
    """
    Shared setup only: no test methods, because subclasses would re-run them.
    BROWSER.COM is assembled once per class since DOSBox runs dominate the
    runtime.
    """

    browser: Path
    abort: Path

    @classmethod
    def setUpClass(cls) -> None:
        require_nasm()
        require_dosbox()
        cls._shared = Path(__import__("tempfile").mkdtemp())
        cls.browser = assemble("browser.asm", cls._shared / "BROWSER.COM")
        cls.abort = assemble("abort.asm", cls._shared / "ABORT.COM")

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls._shared, ignore_errors=True)

    # -- helpers ----------------------------------------------------------
    def fixture(self, name: str, *entries: str, cfg: str | None = None) -> Path:
        d = self.tmp / name
        d.mkdir(parents=True, exist_ok=True)
        write_lst(d, *(entries or (("H|Action"), GAME_LINE)))
        if cfg is not None:
            (d / "DGB.CFG").write_bytes(cfg.encode("ascii", "replace"))
        return d

    def dump(self, d: Path, extra: list[str] | None = None) -> str:
        return selftest(d, self.browser, extra)


class ConfigAndIndexTest(_BrowserBase):
    """Config resolution and index parsing, via the /T dump."""

    # -- DGB.CFG parsing --------------------------------------------------
    def test_no_config_keeps_legacy_defaults(self):
        out = self.dump(self.fixture("cfgmissing"))
        self.assertIn("CFG=0", out)
        self.assertIn("PFX=GAMES\\", out)
        self.assertIn("PFXABS=\\GAMES\\", out)

    def test_config_variants(self):
        # (name, DGB.CFG body, expected PFX, expected PFXABS)
        cases = [
            ("absolute", "GAMES_ROOT=\\GAMES\r\n", "GAMES\\", "\\GAMES\\"),
            ("relative", "GAMES_ROOT=GAMES\r\n", "GAMES\\", "\\GAMES\\"),
            ("nested", "GAMES_ROOT=\\DOS\\GAMES\r\n", "DOS\\GAMES\\", "\\DOS\\GAMES\\"),
            ("trailing separator", "GAMES_ROOT=\\GAMES\\\r\n", "GAMES\\", "\\GAMES\\"),
            ("forward slashes", "GAMES_ROOT=/DOS/GAMES\r\n", "DOS\\GAMES\\", "\\DOS\\GAMES\\"),
            ("spaces after =", "GAMES_ROOT=  \\PLAY\r\n", "PLAY\\", "\\PLAY\\"),
            # An empty value must fall back rather than yield a bare separator.
            ("empty value", "GAMES_ROOT=\r\n", "GAMES\\", "\\GAMES\\"),
            # Regression: the key was once matched anywhere in the buffer, so a
            # commented-out line silently won.
            ("commented-out key first",
             "; GAMES_ROOT=\\WRONGDIR\r\nGAMES_ROOT=\\RIGHTDIR\r\n",
             "RIGHTDIR\\", "\\RIGHTDIR\\"),
            ("hash comment and indented key",
             "# GAMES_ROOT=\\NOPE\r\n  GAMES_ROOT=\\INDENT\r\n",
             "INDENT\\", "\\INDENT\\"),
            # Hand-edited configs should not have to match our casing.
            ("lowercase key", "games_root=\\LOWER\r\n", "LOWER\\", "\\LOWER\\"),
        ]
        for i, (name, cfg, pfx, pfxabs) in enumerate(cases):
            with self.subTest(name):
                d = self.fixture(f"cfg{i}", "H|Action", GAME_LINE, cfg=cfg)
                out = self.dump(d)
                self.assertIn("CFG=1", out)
                self.assertIn(f"PFX={pfx}", out)
                self.assertIn(f"PFXABS={pfxabs}", out)

    def test_games_root_is_found_past_the_shipped_templates_length(self):
        """
        The launcher used to read only the first 240 bytes of DGB.CFG. The
        shipped template puts GAMES_ROOT at byte 178, so a handful of added
        comment lines pushed the real setting out of range and the launcher
        fell back to \\GAMES without saying anything - the same silent-window
        bug that once hid ABORT_KEY from the TSR.
        """
        padding = "".join(f"; comment line {i} added by hand\r\n" for i in range(20))
        # Past the old 240-byte window, comfortably inside the new one.
        self.assertGreater(len(padding), 300)
        self.assertLess(len(padding), 900)
        d = self.fixture("cfgdeep", "H|Action", GAME_LINE,
                         cfg=padding + "GAMES_ROOT=\\DEEP\r\n")
        out = self.dump(d)
        self.assertIn("CFG=1", out)
        self.assertIn("PFXABS=\\DEEP\\", out)
        self.assertNotIn("TRUNCATED", out)

    def test_an_oversized_config_says_so_instead_of_failing_quietly(self):
        """
        Past the buffer we cannot honour the setting, but we can refuse to be
        silent about it: a wrong games root with no explanation is the worst
        outcome here.
        """
        padding = "".join(f"; padding line {i}\r\n" for i in range(120))
        self.assertGreater(len(padding), 1024)
        d = self.fixture("cfghuge", "H|Action", GAME_LINE,
                         cfg=padding + "GAMES_ROOT=\\TOOFAR\r\n")
        out = self.dump(d)
        self.assertIn("TRUNCATED", out)

    # -- index parsing ----------------------------------------------------
    def test_index_parsing_and_offsets(self):
        d = self.fixture(
            "index",
            "H|Action",
            "G|JILL|JILL.EXE|Jill of the Jungle|1992|Platform|Epic|note one",
            "G|KEEN|KEEN1.EXE|Commander Keen|1990|Platform|Apogee|note two",
            "H|Puzzle",
            "G|TETRIS|TETRIS.EXE|Tetris|1986|Puzzle|Spectrum|note three",
        )
        out = self.dump(d)
        # two headers, one spacer before the second header, three games
        self.assertIn("NENT=6", out)
        for pattern in (r"^E0 T1 O\d+ Action$",
                        r"^E1 T0 O\d+ Jill of the Jungle$",
                        r"^E2 T0 O\d+ Commander Keen$",
                        r"^E3 T2 O\d+ *$",
                        r"^E4 T1 O\d+ Puzzle$",
                        r"^E5 T0 O\d+ Tetris$"):
            self.assertRegex(out, re.compile(pattern, re.M))
        # The R lines re-read each record from disk using the stored offset, so
        # they only match if those offsets are right.
        self.assertIn("R1 DIR=JILL EXE=JILL.EXE YEAR=1992 PUB=Epic NOTE=note one", out)
        self.assertIn("R5 DIR=TETRIS EXE=TETRIS.EXE YEAR=1986 PUB=Spectrum NOTE=note three", out)

    def test_subdirectory_in_dir_field(self):
        d = self.fixture("nested",
                         "G|COMMANDE\\KEEN|KEEN1.EXE|Commander Keen|1990|Platform|Apogee|nested")
        out = self.dump(d)
        self.assertIn("NENT=1", out)
        self.assertIn("R0 DIR=COMMANDE\\KEEN EXE=KEEN1.EXE YEAR=1990 PUB=Apogee NOTE=nested", out)

    def test_short_line_leaves_later_fields_empty(self):
        """A truncated record must not read into the following field."""
        d = self.fixture("short", "G|SOLO|SOLO.EXE|Solo")
        out = self.dump(d)
        self.assertIn("R0 DIR=SOLO EXE=SOLO.EXE YEAR= PUB= NOTE=", out)

    def test_large_catalog(self):
        """250 games; the pre-rework build silently truncated at 64."""
        entries = [f"G|G{i:03d}|G{i:03d}.EXE|Game {i:03d}|19{80 + i % 20:02d}|"
                   f"Genre|Pub{i:03d}|note {i:03d}" for i in range(250)]
        d = self.fixture("large", *entries)
        out = self.dump(d)
        self.assertIn("NENT=250", out)
        self.assertRegex(out, re.compile(r"^E249 T0 O\d+ Game 249$", re.M))
        # deep into the file, so offsets have to stay correct throughout
        self.assertIn("R249 DIR=G249 EXE=G249.EXE YEAR=1989 PUB=Pub249 NOTE=note 249", out)

    def test_catalog_over_capacity_clamps(self):
        entries = [f"G|G{i:03d}|G{i:03d}.EXE|Game {i:03d}|1990|Genre|Pub|note"
                   for i in range(400)]
        out = self.dump(self.fixture("overflow", *entries))
        self.assertIn("NENT=320", out)

    def test_missing_index_reports_failure(self):
        d = self.tmp / "nolst"
        d.mkdir()
        self.assertIn("LST=FAIL", self.dump(d))

    def test_image_excludes_the_entry_table(self):
        """
        The table (MAX_ENT * ENT_SIZE = 11520 bytes) lives past the end of the
        image. Reinstating it as emitted data would show up as a size jump.
        """
        self.assertLess(self.browser.stat().st_size, 11520)


class LaunchTest(_BrowserBase):
    """End-to-end: the browser actually EXECs a child in the right directory."""

    STUB = """\
        bits    16
        cpu     8086
        org     100h
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, fn
        int     21h
        jc      done
        mov     bx, ax
        mov     ah, 40h
        mov     cx, 3
        mov     dx, msg
        int     21h
        mov     ah, 3Eh
        int     21h
done:   mov     ax, 4C00h
        int     21h
fn      db 'RAN.TXT',0
msg     db 'OK',13
"""

    def stub(self, dest: Path) -> None:
        """A stand-in game that records the directory it started in."""
        src = self.tmp / "stub.asm"
        src.write_text(self.STUB)
        nasm = require_nasm()
        import subprocess
        dest.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(nasm), "-f", "bin", "-o", str(dest), str(src)],
                       check=True, capture_output=True)

    def test_launch_without_config(self):
        """Games under the launcher directory, no DGB.CFG."""
        d = self.tmp / "legacy"
        self.stub(d / "GAMES" / "JILL" / "JILL.COM")
        write_lst(d, "G|JILL|JILL.COM|Jill|1992|Platform|Epic|note")
        shutil.copy2(self.browser, d / "BROWSER.COM")
        out = run_dosbox(d, ["BROWSER.COM /X > OUT.TXT"])
        self.assertIn("XDONE", out)
        self.assertIn("XREC DIR=JILL EXE=JILL.COM", out)
        self.assertTrue((d / "GAMES" / "JILL" / "RAN.TXT").is_file(),
                        "child did not run in GAMES/JILL")

    def test_configured_root_beats_a_lookalike_under_the_launcher(self):
        """
        With DGB.CFG naming an absolute root, a same-named directory under the
        launcher must not shadow it. Relative-first ordering used to launch the
        decoy.
        """
        d = self.tmp / "cfglaunch"
        self.stub(d / "GAMES" / "JILL" / "JILL.COM")
        self.stub(d / "DGB" / "GAMES" / "JILL" / "JILL.COM")     # decoy
        (d / "DGB" / "DGB.CFG").write_bytes(b"GAMES_ROOT=\\GAMES\r\n")
        write_lst(d / "DGB", "G|JILL|JILL.COM|Jill|1992|Platform|Epic|note")
        shutil.copy2(self.browser, d / "DGB" / "BROWSER.COM")

        out = run_dosbox(d, ["cd \\DGB", "BROWSER.COM /X > \\OUT.TXT"])
        self.assertIn("XDONE", out)
        self.assertTrue((d / "GAMES" / "JILL" / "RAN.TXT").is_file(),
                        "child did not run in the configured \\GAMES\\JILL")
        self.assertFalse((d / "DGB" / "GAMES" / "JILL" / "RAN.TXT").is_file(),
                         "the decoy under the launcher directory was launched")

    def test_entry_table_is_handed_back_to_the_child(self):
        """
        The table is 11.5KB of the browser's footprint and idle during a game,
        so it is returned to DOS and rebuilt afterwards. Memory-hungry games
        depend on this.
        """
        MEMREP = """\
        bits    16
        cpu     8086
        org     100h
        mov     ah, 4Ah
        mov     bx, 20h
        int     21h
        mov     ah, 48h
        mov     bx, 0FFFFh
        int     21h
        mov     ax, bx
        mov     cl, 6
        shr     ax, cl
        mov     di, buf
        call    putdec
        mov     byte [di], '$'
        mov     dx, msg
        mov     ah, 09h
        int     21h
        mov     dx, buf
        mov     ah, 09h
        int     21h
        mov     dx, crlf
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h
putdec: push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.d1:    xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .d1
.d2:    pop     ax
        add     al, '0'
        mov     [di], al
        inc     di
        dec     cx
        jnz     .d2
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
msg     db 'FREEKB=$'
crlf    db 13,10,'$'
buf     times 8 db 0
"""
        import subprocess
        d = self.tmp / "mem"
        src = self.tmp / "memrep.asm"
        src.write_text(MEMREP)
        target = d / "GAMES" / "MEMREP" / "MEMREP.COM"
        target.parent.mkdir(parents=True)
        subprocess.run([str(require_nasm()), "-f", "bin", "-o", str(target), str(src)],
                       check=True, capture_output=True)
        write_lst(d, "G|MEMREP|MEMREP.COM|Mem Report|1990|Test|x|n")
        shutil.copy2(self.browser, d / "BROWSER.COM")

        out = run_dosbox(d, ["BROWSER.COM /X > OUT.TXT"])
        m = re.search(r"FREEKB=(\d+)", out)
        self.assertIsNotNone(m, f"child did not report free memory:\n{out}")
        self.assertGreaterEqual(int(m.group(1)), 620,
                                "the entry table is not being handed back")
        # and it must be rebuilt afterwards - this lookup needs its offset
        self.assertIn("XREC DIR=MEMREP EXE=MEMREP.COM", out)


class AbortTsrTest(_BrowserBase):
    """ABORT.COM: detection, the re-arm, and the deliberate non-behaviour."""

    THIEF = """\
        bits    16
        cpu     8086
        org     100h
start:  mov     ax, 2509h
        mov     dx, dummy09
        int     21h
        xor     ax, ax
        mov     es, ax
        mov     ax, [es:46Ch]
        add     ax, 5
        mov     bx, ax
.wait:  mov     ax, [es:46Ch]
        cmp     ax, bx
        jb      .wait
        xor     ax, ax
        mov     es, ax
        mov     ax, [es:24h]
        mov     dx, [es:26h]
        mov     si, msg_kept
        mov     bx, cs
        cmp     dx, bx
        jne     .taken
        cmp     ax, dummy09
        jne     .taken
        jmp     .say
.taken: mov     si, msg_taken
.say:   mov     dx, si
        mov     ah, 09h
        int     21h
        mov     ax, 4C00h
        int     21h
dummy09:
        push    ax
        mov     al, 20h
        out     20h, al
        pop     ax
        iret
msg_kept   db 'WATCHDOG=NO',13,10,'$'
msg_taken  db 'WATCHDOG=YES',13,10,'$'
"""

    SPEND = """\
        bits    16
        cpu     8086
        org     100h
        mov     ax, 0AB02h
        int     2Fh
        mov     dx, msg_spent
        or      si, si
        jz      .say
        mov     dx, msg_armed
.say:   mov     ah, 09h
        int     21h
        mov     ax, 0AB05h
        int     2Fh
        mov     ax, 4C00h
        int     21h
msg_armed db 'ARMED=1',13,10,'$'
msg_spent db 'ARMED=0',13,10,'$'
"""

    def _asm(self, text: str, dest: Path) -> None:
        import subprocess
        src = self.tmp / (dest.stem.lower() + ".asm")
        src.write_text(text)
        dest.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(require_nasm()), "-f", "bin", "-o", str(dest), str(src)],
                       check=True, capture_output=True)

    def test_resident_tsr_is_detected(self):
        d = self.fixture("abortpresent")
        (d / "UTILS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.abort, d / "UTILS" / "ABORT.COM")
        out = self.dump(d, ["UTILS\\ABORT.COM"])
        self.assertIn("ABORT=1", out)
        self.assertRegex(out, re.compile(
            r"^KBD scancodes=\d+ last=[0-9A-F]{2} ctrlalt=[0-9A-F]{2} "
            r"grabs=\d+ armed=[01] pend=[01] busydos=\d+ irq1off=\d+ wdticks=\d+$",
            re.M))
        # loading the TSR must not stop the batch before the browser runs
        self.assertIn("NENT=2", out)

    def test_controller_probe_line_is_reported(self):
        """
        The KBC line carries the 8042 command byte around a game. Each field is
        two hex digits or '--' for a sample that was never taken, so a missing
        reading can never be misread as a byte of 00h.
        """
        d = self.fixture("kbcprobe")
        (d / "UTILS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.abort, d / "UTILS" / "ABORT.COM")
        out = self.dump(d, ["UTILS\\ABORT.COM /P"])
        self.assertRegex(out, re.compile(
            r"^KBC base=(?:[0-9A-F]{2}|--) game=(?:[0-9A-F]{2}|--) "
            r"last=(?:[0-9A-F]{2}|--)$", re.M))

    def test_probe_mode_does_not_reclaim_the_vector(self):
        """
        /P is the diagnostic-only half of /W: it must hook the timer to sample,
        and must never put our handler back in front of a game. Loading it has
        to leave everything else working.
        """
        d = self.fixture("probeonly")
        (d / "UTILS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.abort, d / "UTILS" / "ABORT.COM")
        out = self.dump(d, ["UTILS\\ABORT.COM /P"])
        self.assertIn("ABORT=1", out)
        self.assertIn("NENT=2", out)

    def test_controller_probe_is_absent_without_the_tsr(self):
        """No TSR, no KBC line - the browser must not invent one."""
        out = self.dump(self.fixture("kbcnotsr"))
        self.assertIn("ABORT=0", out)
        self.assertNotIn("KBC ", out)

    def test_abort_key_is_configurable(self):
        """
        A game may want the abort key for play, so the trigger is settable in
        DGB.CFG. Bad values fall back to the default rather than picking
        something arbitrary - "banana" was once read as scancode BAh.

        This runs both halves of keynames.inc against each other: ABORT.COM
        parses the name and BROWSER.COM renders the hint from the code, so a
        table the two disagreed about would show up here.
        """
        cases = [
            ("default", None, "SCRLOCK"),
            ("F11", "ABORT_KEY=F11\r\n", "F11"),
            ("F1", "ABORT_KEY=F1\r\n", "F1"),
            ("lowercase", "abort_key=f11\r\n", "F11"),
            ("raw hex", "ABORT_KEY=5B\r\n", "KEY 5B"),
            ("commented out first", "; ABORT_KEY=F1\r\nABORT_KEY=F11\r\n", "F11"),
            ("trailing comment", "ABORT_KEY=F11 ; why\r\n", "F11"),
            # named keys
            ("name", "ABORT_KEY=ESC\r\n", "ESC"),
            ("name lowercase", "abort_key=grave\r\n", "GRAVE"),
            ("name mixed case", "ABORT_KEY=ScrLock\r\n", "SCRLOCK"),
            ("alias renders canonical", "ABORT_KEY=SCROLLLOCK\r\n", "SCRLOCK"),
            ("alias renders canonical 2", "ABORT_KEY=BACKSPACE\r\n", "BKSP"),
            # a code with a name is displayed as that name however it was given
            ("hex of a named key", "ABORT_KEY=46\r\n", "SCRLOCK"),
            # names starting with a hex digit or F must not be read as numbers
            ("name beginning with hex digit", "ABORT_KEY=DEL\r\n", "DEL"),
            ("name beginning with E", "ABORT_KEY=END\r\n", "END"),
            # rejections all fall back to the default
            ("not a key", "ABORT_KEY=banana\r\n", "SCRLOCK"),
            ("out of range", "ABORT_KEY=F13\r\n", "SCRLOCK"),
            ("trailing rubbish", "ABORT_KEY=5BX\r\n", "SCRLOCK"),
            ("name is only a prefix", "ABORT_KEY=UPPER\r\n", "SCRLOCK"),
            ("name with rubbish after", "ABORT_KEY=ESCX\r\n", "SCRLOCK"),
        ]
        for i, (name, cfg, expected) in enumerate(cases):
            with self.subTest(name):
                d = self.fixture(f"key{i}", "H|Action", GAME_LINE, cfg=cfg)
                (d / "UTILS").mkdir(parents=True, exist_ok=True)
                shutil.copy2(self.abort, d / "UTILS" / "ABORT.COM")
                out = self.dump(d, ["UTILS\\ABORT.COM"])
                self.assertIn(f"HINT={expected} or CTRL+ALT+BKSP exits game", out)

    def test_abort_key_is_found_in_a_realistic_config(self):
        """
        Every other case here uses a two-line config. The shipped template is
        several hundred bytes with the setting near the end, and a 512-byte
        read buffer silently missed it - the end-to-end run caught what these
        tests did not.
        """
        preamble = "".join(f"; padding line {i} to push the setting down\r\n"
                           for i in range(40))
        d = self.fixture("bigcfg", "H|Action", GAME_LINE,
                         cfg=preamble + "ABORT_KEY=F11\r\n")
        self.assertGreater(len((d / "DGB.CFG").read_bytes()), 1200)
        (d / "UTILS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.abort, d / "UTILS" / "ABORT.COM")
        out = self.dump(d, ["UTILS\\ABORT.COM"])
        self.assertIn("HINT=F11 or CTRL+ALT+BKSP exits game", out)

    def test_abort_key_command_line_overrides_the_config(self):
        d = self.fixture("keyarg", "H|Action", GAME_LINE, cfg="ABORT_KEY=F11\r\n")
        (d / "UTILS").mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.abort, d / "UTILS" / "ABORT.COM")
        out = self.dump(d, ["UTILS\\ABORT.COM /K:F9"])
        self.assertIn("HINT=F9 or CTRL+ALT+BKSP exits game", out)

    def test_absent_tsr_is_reported(self):
        out = self.dump(self.fixture("abortabsent"))
        self.assertIn("ABORT=0", out)
        self.assertIn("NENT=2", out)

    def test_game_that_seizes_int09_keeps_it_by_default(self):
        """
        Deliberate: taking the vector back put us in front of games expecting
        exclusive keyboard control. /W opts back in; the default does not fight.
        """
        # The directory name becomes a DOSBox mount path, so keep it plain.
        for slug, label, load, expected in (
            ("none", "no TSR", [], "WATCHDOG=NO"),
            ("default", "default", ["UTILS\\ABORT.COM"], "WATCHDOG=NO"),
            ("optin", "/W", ["UTILS\\ABORT.COM /W"], "WATCHDOG=YES"),
        ):
            with self.subTest(label):
                d = self.tmp / f"wd-{slug}"
                d.mkdir(parents=True, exist_ok=True)
                self._asm(self.THIEF, d / "STEAL.COM")
                if load:
                    (d / "UTILS").mkdir(exist_ok=True)
                    shutil.copy2(self.abort, d / "UTILS" / "ABORT.COM")
                out = run_dosbox(d, [*load, "STEAL.COM > OUT.TXT"])
                self.assertIn(expected, out)

    def test_hotkey_rearms_between_games(self):
        """
        try_abort sets a busy flag before terminating; nothing cleared it, so
        the force-exit worked exactly once per boot and then died silently.
        """
        d = self.tmp / "rearm"
        (d / "UTILS").mkdir(parents=True)
        self._asm(self.SPEND, d / "GAMES" / "SP" / "SPEND.COM")
        shutil.copy2(self.abort, d / "UTILS" / "ABORT.COM")
        shutil.copy2(self.browser, d / "BROWSER.COM")
        write_lst(d, "G|SP|SPEND.COM|Spend|1990|Test|x|n")

        run_dosbox(d, ["UTILS\\ABORT.COM",
                       "BROWSER.COM /X > OUT1.TXT",
                       "BROWSER.COM /X > OUT2.TXT"], capture="OUT1.TXT")
        first = (d / "OUT1.TXT").read_text(errors="replace").replace("\r", "")
        second = (d / "OUT2.TXT").read_text(errors="replace").replace("\r", "")
        self.assertIn("ARMED=1", first)
        self.assertIn("ARMED=1", second, "the hotkey did not re-arm for the second game")


if __name__ == "__main__":
    unittest.main()
