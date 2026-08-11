"""
The key names ABORT_KEY accepts, read from the table that defines them.

src/keynames.inc is the single definition: ABORT.COM parses ABORT_KEY with it,
BROWSER.COM renders the on-screen hint from it. Reading the same file here
means the host tooling cannot accept a name DOS would reject, nor reject one it
would take - a divergence that would only show up on the target machine.

resolve() mirrors ABORT.COM's parse_key exactly, quirks included.
"""
from __future__ import annotations

import re

from .paths import SRC

INC = SRC / "keynames.inc"

# F1..F12 are not in the table; both programs derive them from the number.
FKEY_CODES = [0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40,
              0x41, 0x42, 0x43, 0x44, 0x57, 0x58]

DEFAULT_KEY = "SCRLOCK"

_ENTRY = re.compile(r"^\s*db\s+'([A-Za-z]+)'\s*,\s*0\s*,\s*([0-9A-Fa-f]{1,2})h",
                    re.MULTILINE)


def named_keys() -> dict[str, int]:
    """{NAME: make-code} from keynames.inc, in table order."""
    return {m.group(1).upper(): int(m.group(2), 16)
            for m in _ENTRY.finditer(INC.read_text(encoding="ascii"))}


def canonical_names() -> dict[int, str]:
    """{make-code: first name listed for it} - what BROWSER.COM will display."""
    out: dict[int, str] = {}
    for name, code in named_keys().items():
        out.setdefault(code, name)
    return out


def resolve(token: str) -> int | None:
    """
    The make-code ABORT.COM would use for this ABORT_KEY value, or None if it
    would reject it and fall back to the default.
    """
    token = token.strip()
    if not token:
        return None

    code = named_keys().get(token.upper())
    if code is not None:
        return code

    # A leading F means a function key, so a hex code starting with F cannot be
    # written. Nothing is lost: F0h-FFh are not make-codes.
    if token[0] in "fF":
        digits = token[1:]
        if digits.isdigit() and 1 <= len(digits) <= 2:
            n = int(digits)
            if 1 <= n <= 12:
                return FKEY_CODES[n - 1]
        return None

    if 1 <= len(token) <= 2 and all(c in "0123456789abcdefABCDEF" for c in token):
        n = int(token, 16)
        return n or None             # 00h is rejected, it is not a key

    return None


def describe() -> str:
    """The accepted forms, short enough for --help and a config comment."""
    return "a key name, F1-F12, or a hex make-code"


def describe_full() -> str:
    """As describe(), with every name spelled out. For error messages."""
    return "%s. Names: %s" % (describe(), " ".join(sorted(canonical_names().values())))


def name_lines(width: int = 60) -> list[str]:
    """
    The canonical names wrapped to `width`, for comment blocks that have to fit
    an 80-column DOS screen.
    """
    lines: list[str] = []
    cur = ""
    for name in sorted(canonical_names().values()):
        nxt = f"{cur} {name}" if cur else name
        if len(nxt) > width:
            lines.append(cur)
            cur = name
        else:
            cur = nxt
    if cur:
        lines.append(cur)
    return lines
