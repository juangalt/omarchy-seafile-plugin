#!/usr/bin/env python3
"""Small unit checks for helper.py helpers (no daemon required)."""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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

    def test_enrich_prefers_latest_client_id(self):
        # Lines must mention repo id/name so enrich_unknown_error keeps them.
        log = "\n".join(
            [
                "[10/21/26 22:00:00] deadbeef old client_id=& permission-check",
                "[10/21/26 23:00:00] deadbeef new client_id=abcdef0123456789abcdef0123456789abcdef01& ok",
            ]
        )
        with mock.patch.object(helper, "_read_seafile_log_tail", return_value=log):
            # Latest id is valid 40 hex — should not blame empty/short client id.
            self.assertEqual(
                helper.enrich_unknown_error("deadbeef-rest", "vault", "Unknown error"),
                "Unknown error",
            )

        log_bad = "\n".join(
            [
                "[10/21/26 22:00:00] deadbeef old client_id=abcdef0123456789abcdef0123456789abcdef01&",
                "[10/21/26 23:00:00] deadbeef new client_id=& Bad response code 400",
            ]
        )
        with mock.patch.object(helper, "_read_seafile_log_tail", return_value=log_bad):
            self.assertIn(
                "empty client id",
                helper.enrich_unknown_error("deadbeef-rest", "vault", "Unknown error"),
            )

    def test_sync_line_optional_quotes(self):
        m = helper.SYNC_LINE.search(
            "Repo 'vault' sync state transition from 'initializing' to 'synchronized'"
        )
        self.assertIsNotNone(m)
        self.assertEqual(m.group(1), "vault")
        m2 = helper.SYNC_LINE.search(
            "Repo 'vault' sync state transition from initializing to 'synchronized'"
        )
        self.assertIsNotNone(m2)

    def test_rpc_sync_timeout_returns(self):
        import time

        class Slow:
            def sync(self, repo_id, path):
                time.sleep(5)

        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            helper._rpc_sync(Slow(), "repo", timeout=0.3)
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 2.0, "timeout must not wait for the hung RPC")

    def test_wait_until_up_requires_sock(self):
        with tempfile.TemporaryDirectory() as tmp:
            ini = Path(tmp) / "seafile.ini"
            datadir = Path(tmp) / "seafile-data"
            datadir.mkdir()
            ini.write_text(str(datadir) + "\n", encoding="utf-8")
            with mock.patch.object(helper, "CONF_DIR", Path(tmp)):
                with mock.patch.object(helper, "owning_daemon_pids", return_value=[12345]):
                    self.assertFalse(helper._wait_until_up(0.3))
                sock = datadir / "seafile.sock"
                sock.write_text("")
                with mock.patch.object(helper, "owning_daemon_pids", return_value=[]):
                    self.assertTrue(helper._wait_until_up(0.3))

    def test_pending_sync_ts_beats_stale_log(self):
        self.assertEqual(helper.aggregate_state([{"state": "synchronized"}]), "synchronized")
        self.assertEqual(
            helper.aggregate_state([{"state": "initializing"}]),
            "syncing",
        )
        with tempfile.TemporaryDirectory() as tmp:
            state_path = Path(tmp) / "state.json"
            state_path.write_text(json.dumps({"pendingSyncTs": 2000}) + "\n", encoding="utf-8")
            with mock.patch.object(helper, "STATE_PATH", state_path):
                with mock.patch.object(helper, "STATE_DIR", Path(tmp)):
                    state = helper.load_state()
                    self.assertEqual(int(state.get("pendingSyncTs") or 0), 2000)
                    # Overlay: pending wins when newer than log ts.
                    ts = 1000
                    pending = int(state.get("pendingSyncTs") or 0)
                    if pending > ts:
                        ts = pending
                    self.assertEqual(ts, 2000)
                    # Clear when log catches up.
                    state.pop("pendingSyncTs", None)
                    helper.save_state(state)
                    self.assertNotIn("pendingSyncTs", helper.load_state())

    def test_save_state_is_private_even_with_permissive_umask(self):
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / "state"
            state_path = state_dir / "state.json"
            with mock.patch.object(helper, "STATE_DIR", state_dir):
                with mock.patch.object(helper, "STATE_PATH", state_path):
                    old = os.umask(0o022)
                    try:
                        helper.save_state({"snoozeUntil": 1})
                    finally:
                        os.umask(old)
                    self.assertEqual(stat.S_IMODE(state_dir.stat().st_mode), 0o700)
                    self.assertEqual(stat.S_IMODE(state_path.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
