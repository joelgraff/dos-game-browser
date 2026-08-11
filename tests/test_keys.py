"""
Key names for ABORT_KEY.

Three programs have to agree about what a name means: ABORT.COM parses it,
BROWSER.COM displays it, and the host tooling validates it. They agree by
construction - the two .COM files %include src/keynames.inc and dgb/keys.py
reads it - so what is worth testing here is that the shared file really is
shared, and that the host resolver matches the assembly parser's rules.

The end-to-end check that the DOS side honours the table lives in
test_browser.py::test_abort_key_is_configurable, which runs both binaries.
"""
from __future__ import annotations

import re
import unittest

from dgb import keys

from .support import ROOT


class TableTest(unittest.TestCase):

    def test_the_table_parses(self):
        names = keys.named_keys()
        self.assertGreater(len(names), 10, "table looks empty; parser broken?")
        for name, code in names.items():
            self.assertRegex(name, r"^[A-Z]+$")
            self.assertTrue(0 < code < 0x80, f"{name}={code:#04x} is not a make-code")

    def test_the_default_is_a_name_in_the_table(self):
        self.assertIn(keys.DEFAULT_KEY, keys.named_keys())

    def test_both_com_sources_include_the_shared_table(self):
        """
        If either stops including it, that program keeps a private copy of the
        names and the two can silently disagree.
        """
        for src in ("abort.asm", "browser.asm"):
            text = (ROOT / "src" / src).read_text(encoding="ascii", errors="replace")
            self.assertRegex(text, r'%include\s+"keynames\.inc"',
                             f"{src} no longer includes keynames.inc")

    def test_no_name_is_a_prefix_of_another_with_a_different_code(self):
        """
        Prefix matching is rejected by the parser, but two names where one is a
        prefix of the other are still worth knowing about: it means a typo of
        the longer one resolves to the shorter.
        """
        names = keys.named_keys()
        for a in names:
            for b in names:
                if a != b and b.startswith(a) and names[a] != names[b]:
                    self.fail(f"{a} is a prefix of {b} with a different code")

    def test_assembly_default_matches_the_python_default(self):
        text = (ROOT / "src" / "abort.asm").read_text(encoding="ascii",
                                                      errors="replace")
        m = re.search(r"^SC_SCRLOCK\s+equ\s+([0-9A-Fa-f]{2})h", text, re.M)
        self.assertIsNotNone(m, "SC_SCRLOCK not found in abort.asm")
        self.assertEqual(int(m.group(1), 16), keys.resolve(keys.DEFAULT_KEY))

        browser = (ROOT / "src" / "browser.asm").read_text(encoding="ascii",
                                                           errors="replace")
        m = re.search(r"^abort_scan\s+db\s+([0-9A-Fa-f]{2})h", browser, re.M)
        self.assertIsNotNone(m, "abort_scan not found in browser.asm")
        self.assertEqual(int(m.group(1), 16), keys.resolve(keys.DEFAULT_KEY),
                         "BROWSER.COM would show the wrong key before the TSR "
                         "is queried")


class DocTableTest(unittest.TestCase):
    """
    FORMAT.md lists every name and its make-code. A hand-maintained table is
    exactly the kind of thing that drifts, and a wrong code there sends someone
    to a key that does nothing.
    """

    DOC = "docs/FORMAT.md"

    ROW = re.compile(r"^\|\s*`([A-Z]+)`\s*\|\s*`([0-9A-F]{2})`\s*\|(.*)\|\s*$",
                     re.MULTILINE)

    def documented(self) -> dict[str, int]:
        text = (ROOT / self.DOC).read_text(encoding="utf-8")
        rows = {}
        for name, code, extra in (m.groups() for m in self.ROW.finditer(text)):
            rows[name] = int(code, 16)
            for alias in re.findall(r"`([A-Z]+)`", extra):
                rows[alias] = int(code, 16)
        return rows

    def test_every_name_is_documented_with_the_right_code(self):
        documented = self.documented()
        self.assertTrue(documented, f"no key table found in {self.DOC}")
        for name, code in keys.named_keys().items():
            self.assertIn(name, documented, f"{name} is missing from {self.DOC}")
            self.assertEqual(documented[name], code,
                             f"{self.DOC} gives {name} the wrong make-code")

    def test_nothing_is_documented_that_does_not_exist(self):
        for name in self.documented():
            self.assertIn(name, keys.named_keys(),
                          f"{self.DOC} documents {name}, which is not a key name")


class ScanComTemplateTest(unittest.TestCase):
    """
    SCAN.COM writes DGB.CFG on the DOS machine, and its comment block lists the
    names as literal text - it cannot call into keynames.inc the way the parser
    does. So the one place a name can go stale is here.
    """

    def listed(self) -> set[str]:
        text = (ROOT / "src" / "scan.asm").read_text(encoding="ascii",
                                                     errors="replace")
        # Anchored to the label definition: the name also appears earlier as a
        # code reference, and matching that yielded an empty list that silently
        # looked like "no names have drifted".
        block = re.search(r"^cfg_akey_hint\s+db(.*?)^\w", text,
                          re.DOTALL | re.MULTILINE)
        self.assertIsNotNone(block, "cfg_akey_hint definition not found "
                                    "in scan.asm")
        body = block.group(1)
        names: set[str] = set()
        # the wrapped ';   NAME NAME NAME' lines that follow '; Names:'
        for line in re.findall(r"db\s+';\s{2,}([A-Z0-9 ]+)'", body):
            names.update(line.split())
        return names

    def test_the_names_match(self):
        self.assertEqual(self.listed(), set(keys.canonical_names().values()))

    def test_the_default_matches(self):
        text = (ROOT / "src" / "scan.asm").read_text(encoding="ascii",
                                                     errors="replace")
        self.assertIn(f";ABORT_KEY={keys.DEFAULT_KEY}", text)


class ResolveTest(unittest.TestCase):
    """resolve() must accept exactly what ABORT.COM's parse_key accepts."""

    def ok(self, token, code):
        self.assertEqual(keys.resolve(token), code, token)

    def bad(self, token):
        self.assertIsNone(keys.resolve(token), token)

    def test_names(self):
        self.ok("SCRLOCK", 0x46)
        self.ok("scrlock", 0x46)
        self.ok("ScrLock", 0x46)
        self.ok("SCROLLLOCK", 0x46)     # alias
        self.ok("ESC", 0x01)
        self.ok("BACKSPACE", 0x0E)
        self.ok("BKSP", 0x0E)

    def test_names_that_look_like_numbers_are_still_names(self):
        """DEL, END and ESC all start with a hex digit or an F."""
        self.ok("DEL", 0x53)
        self.ok("END", 0x4F)
        self.ok("ESC", 0x01)

    def test_function_keys(self):
        self.ok("F1", 0x3B)
        self.ok("f1", 0x3B)
        self.ok("F11", 0x57)
        self.ok("F12", 0x58)
        self.bad("F0")
        self.bad("F13")
        self.bad("F")

    def test_hex(self):
        self.ok("46", 0x46)
        self.ok("1e", 0x1E)
        self.ok("5B", 0x5B)
        self.bad("00")
        self.bad("5BX")
        self.bad("123")

    def test_a_hex_code_starting_with_f_is_read_as_a_function_key(self):
        """
        A documented quirk rather than a bug: F0h-FFh are not make-codes, so
        nothing real is unreachable. It must be rejected, not misread.
        """
        self.bad("FA")
        self.bad("FF")

    def test_rubbish(self):
        self.bad("banana")
        self.bad("")
        self.bad("   ")
        self.bad("UPPER")               # a name is only a prefix of it
        self.bad("ESCX")

    def test_whitespace_is_tolerated(self):
        self.ok(" SCRLOCK ", 0x46)


if __name__ == "__main__":
    unittest.main()
