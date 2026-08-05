#!/usr/bin/env python3
"""DOS Game Browser - host-side tooling. Run 'python dgb.py --help'."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dgb.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
