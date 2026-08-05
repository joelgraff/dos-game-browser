"""
Run the test suite.

Uses stdlib unittest rather than pytest so that 'python dgb.py test' works on a
fresh checkout with no pip install, which is the point of the Python move.
"""
from __future__ import annotations

import argparse
import sys
import unittest

from .paths import ROOT


def add_arguments(ap: argparse.ArgumentParser) -> None:
    ap.add_argument("-k", "--pattern", default="test*.py",
                    help="Only run test files matching this pattern")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--quick", action="store_true",
                    help="Skip the DOSBox suites (much faster, far less cover)")


def run(args: argparse.Namespace) -> int:
    sys.path.insert(0, str(ROOT))
    pattern = args.pattern
    if args.quick:
        # The DOSBox-backed files are the slow ones.
        pattern = "test_scan.py"
    loader = unittest.TestLoader()
    suite = loader.discover(str(ROOT / "tests"), pattern=pattern,
                            top_level_dir=str(ROOT))
    runner = unittest.TextTestRunner(verbosity=2 if args.verbose else 1)
    return 0 if runner.run(suite).wasSuccessful() else 1
