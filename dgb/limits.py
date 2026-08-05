#!/usr/bin/env python3
"""
Launcher capacity limits.

The values are read straight out of src/browser.asm so the host tooling and the
assembled binary can never disagree about them. If BROWSER.COM's limits change,
the guards here follow automatically.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BROWSER_ASM = ROOT / "src" / "browser.asm"

# Entry table stores each line's position as a 16-bit file offset, so the whole
# index has to stay addressable in 16 bits.
MAX_LST_BYTES = 65535


def _asm_const(name: str, default: int) -> int:
    try:
        text = BROWSER_ASM.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return default
    m = re.search(rf"^{re.escape(name)}\s+equ\s+(\d+)", text, re.MULTILINE)
    return int(m.group(1)) if m else default


MAX_ENT = _asm_const("MAX_ENT", 320)
MAXLINE = _asm_const("MAXLINE", 160)


def count_slots(lines: list[str]) -> int:
    """
    Mirror load_list's slot accounting: every G| and H| line takes a slot, and
    each H| that is not the very first entry is preceded by a blank spacer.
    """
    slots = 0
    for line in lines:
        kind = line[:2].upper()
        if kind == "H|":
            if slots > 0:
                slots += 1          # blank spacer
            slots += 1
        elif kind == "G|":
            slots += 1
    return slots


def check_index(lines: list[str], text: str) -> list[str]:
    """
    Return human-readable errors for an index BROWSER.COM could not load
    correctly. Empty list means the index is within limits.
    """
    errors: list[str] = []

    slots = count_slots(lines)
    if slots > MAX_ENT:
        games = sum(1 for l in lines if l[:2].upper() == "G|")
        overhead = slots - games
        msg = (
            f"index needs {slots} launcher slots but BROWSER.COM holds {MAX_ENT} "
            f"({games} games"
        )
        if overhead:
            msg += f" plus {overhead} slots of category headers and spacers)"
            if games <= MAX_ENT:
                msg += ". Re-run with --no-headers to fit"
            else:
                msg += ". Reduce the catalog"
        else:
            msg += "). Reduce the catalog"
        errors.append(msg + ".")

    size = len(text.encode("ascii", errors="replace"))
    if size > MAX_LST_BYTES:
        errors.append(
            f"index is {size} bytes; BROWSER.COM addresses at most {MAX_LST_BYTES}."
        )

    for i, line in enumerate(lines, start=1):
        if len(line) > MAXLINE:
            errors.append(
                f"line {i} is {len(line)} characters; BROWSER.COM reads at most "
                f"{MAXLINE} and would truncate it: {line[:60]}..."
            )

    return errors


def enforce_index(lines: list[str], text: str) -> None:
    """Raise ValueError if the index exceeds what the launcher can load."""
    errors = check_index(lines, text)
    if errors:
        raise ValueError(
            "generated GAMES.LST exceeds launcher limits:\n  - "
            + "\n  - ".join(errors)
        )
