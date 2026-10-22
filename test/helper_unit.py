#!/usr/bin/env python3
"""Small unit checks for helper.py helpers (no daemon required)."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("seafile_helper", ROOT / "helper.py")
helper = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(helper)


class HelperUnit(unittest.TestCase):
    def test_unit_may_revive_failed_alone(self):
        self.assertFalse(
            helper.unit_may_revive(
                {
                    "LoadState": "loaded",
                    "ActiveState": "failed",
                    "SubState": "failed",
                    "Job": "",
                }
            )
        )

    def test_unit_may_revive_auto_restart(self):
        self.assertTrue(
            helper.unit_may_revive(
                {
                    "LoadState": "loaded",
                    "ActiveState": "activating",
                    "SubState": "auto-restart",
                    "Job": "",
                }
            )
        )

    def test_unit_may_revive_pending_job(self):
        self.assertTrue(
            helper.unit_may_revive(
                {
                    "LoadState": "loaded",
                    "ActiveState": "failed",
                    "SubState": "failed",
                    "Job": "start",
                }
            )
        )

    def test_classify_probe(self):
        self.assertEqual(helper.classify_probe(0, "", False, []), "running")
        self.assertEqual(helper.classify_probe(124, "timed out", True, [1]), "unreachable")
        self.assertEqual(helper.classify_probe(1, "err", False, [9]), "unknown")
        self.assertEqual(helper.classify_probe(1, "err", True, []), "paused")

    def test_enrich_unknown_keeps_real_errors(self):
        self.assertEqual(
            helper.enrich_unknown_error("abc", "vault", "Permission denied"),
            "Permission denied",
        )


if __name__ == "__main__":
    unittest.main()
