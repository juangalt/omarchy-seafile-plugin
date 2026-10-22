#!/usr/bin/env python3
"""Seafile helper for the Omarchy juangalt.seafile bar widget.

Commands print a single JSON object on stdout. Log/diagnostic strings stay English.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

CONF_DIR = Path.home() / ".ccnet"
STATE_DIR = Path.home() / ".local" / "state" / "omarchy" / "plugins" / "juangalt.seafile"
STATE_PATH = STATE_DIR / "state.json"
LOG_PATH = CONF_DIR / "logs" / "seafile.log"
SYNC_LINE = re.compile(
    r"Repo '([^']+)' sync state transition from '.*' to 'synchronized'"
)
TS_LINE = re.compile(r"^\[(\d{2}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\]")


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def run(cmd: list[str], timeout: float = 8.0) -> tuple[int, str, str]:
    try:
        completed = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return 127, "", "command not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    return completed.returncode, completed.stdout or "", completed.stderr or ""


def which_seaf() -> str | None:
    return shutil.which("seaf-cli")


def load_state() -> dict:
    if not STATE_PATH.exists():
        return {}
    try:
        data = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(data: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def seafile_datadir() -> Path | None:
    ini = CONF_DIR / "seafile.ini"
    if not ini.exists():
        return None
    try:
        line = ini.read_text(encoding="utf-8").strip().splitlines()
        if not line:
            return None
        path = Path(line[0].strip())
        return path if path.exists() else None
    except OSError:
        return None


def rpc_client():
    datadir = seafile_datadir()
    if datadir is None:
        return None
    sock = datadir / "seafile.sock"
    if not sock.exists():
        return None
    try:
        from seafile.rpcclient import SeafileRpcClient
    except ImportError:
        return None
    try:
        return SeafileRpcClient(str(sock))
    except Exception:
        return None


def parse_status_json(raw: str) -> dict:
    text = (raw or "").strip()
    if not text:
        return {"repos": [], "sync_errors": []}
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            parsed["repos"] = parsed.get("repos") if isinstance(parsed.get("repos"), list) else []
            parsed["sync_errors"] = (
                parsed.get("sync_errors") if isinstance(parsed.get("sync_errors"), list) else []
            )
            return parsed
    except json.JSONDecodeError:
        pass
    return {"repos": [], "sync_errors": []}


def parse_list_json(raw: str) -> list:
    text = (raw or "").strip()
    if not text:
        return []
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, list) else []
    except json.JSONDecodeError:
        return []


def last_sync_from_log(limit_bytes: int = 200_000) -> dict[str, int]:
    """Map repo name -> unix timestamp of last transition to synchronized."""
    if not LOG_PATH.exists():
        return {}
    try:
        size = LOG_PATH.stat().st_size
        with LOG_PATH.open("rb") as handle:
            if size > limit_bytes:
                handle.seek(size - limit_bytes)
                handle.readline()
            data = handle.read().decode("utf-8", errors="replace")
    except OSError:
        return {}

    found: dict[str, int] = {}
    current_ts = 0
    for line in data.splitlines():
        ts_match = TS_LINE.match(line)
        if ts_match:
            try:
                current_ts = int(time.mktime(time.strptime(ts_match.group(1), "%m/%d/%y %H:%M:%S")))
            except ValueError:
                current_ts = 0
        sync_match = SYNC_LINE.search(line)
        if sync_match and current_ts > 0:
            found[sync_match.group(1)] = current_ts
    return found


def aggregate_state(repos: list) -> str:
    if not repos:
        return "idle"
    states = [str(repo.get("state") or "") for repo in repos]
    if any(s == "error" for s in states):
        return "error"
    if any(s in ("uploading", "downloading", "committing", "fetch", "initializing") for s in states):
        return "syncing"
    if any(s == "waiting for sync" for s in states):
        return "waiting"
    if any(s == "auto sync disabled" for s in states):
        return "paused"
    if all(s == "synchronized" for s in states):
        return "synchronized"
    return states[0] if states else "idle"


def apply_snooze(state: dict, running: bool) -> tuple[dict, bool]:
    """Return (state, snoozed). Auto-resume when the snooze expires."""
    until = int(state.get("snoozeUntil") or 0)
    now = int(time.time())
    if until <= 0:
        return state, False
    if now >= until:
        state = dict(state)
        state.pop("snoozeUntil", None)
        state.pop("snoozeLabel", None)
        save_state(state)
        if which_seaf() and not running:
            run(["seaf-cli", "start"], timeout=15)
        return state, False
    return state, True


def build_status() -> dict:
    seaf = which_seaf()
    installed = seaf is not None
    configured = CONF_DIR.exists() and (CONF_DIR / "seafile.ini").exists()
    state = load_state()

    if not installed:
        return {
            "ok": True,
            "installed": False,
            "configured": False,
            "running": False,
            "active": False,
            "snoozed": False,
            "snoozeUntil": 0,
            "snoozeLabel": "",
            "aggregate": "missing",
            "statusText": "Not installed",
            "lastSyncTs": 0,
            "repos": [],
            "syncErrors": [],
            "logPath": str(LOG_PATH),
            "worktreeParent": "",
        }

    code, out, err = run(["seaf-cli", "status", "--json"], timeout=6)
    running = code == 0
    status = parse_status_json(out) if running else {"repos": [], "sync_errors": []}
    state, snoozed = apply_snooze(state, running)

    # Re-check after possible auto-resume.
    if not running and which_seaf():
        code, out, err = run(["seaf-cli", "status", "--json"], timeout=6)
        running = code == 0
        status = parse_status_json(out) if running else {"repos": [], "sync_errors": []}

    list_code, list_out, _ = run(["seaf-cli", "list", "--json"], timeout=6)
    listed = parse_list_json(list_out) if list_code == 0 else []
    by_id = {str(item.get("id") or ""): item for item in listed if isinstance(item, dict)}

    last_by_name = last_sync_from_log()
    repos = []
    last_sync_ts = 0
    for repo in status.get("repos") or []:
        if not isinstance(repo, dict):
            continue
        rid = str(repo.get("id") or "")
        name = str(repo.get("name") or "")
        meta = by_id.get(rid) or {}
        path = str(meta.get("path") or "")
        ts = int(last_by_name.get(name) or 0)
        if ts > last_sync_ts:
            last_sync_ts = ts
        entry = {
            "id": rid,
            "name": name,
            "state": str(repo.get("state") or ""),
            "path": path,
            "lastSyncTs": ts,
            "error": str(repo.get("error") or ""),
        }
        if "progress" in repo:
            entry["progress"] = repo.get("progress")
        repos.append(entry)

    # Libraries listed but missing from status (daemon down).
    if not repos and listed:
        for item in listed:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or "")
            ts = int(last_by_name.get(name) or 0)
            if ts > last_sync_ts:
                last_sync_ts = ts
            repos.append(
                {
                    "id": str(item.get("id") or ""),
                    "name": name,
                    "state": "daemon stopped" if not running else "unknown",
                    "path": str(item.get("path") or ""),
                    "lastSyncTs": ts,
                    "error": "",
                }
            )

    sync_errors = []
    for err_item in status.get("sync_errors") or []:
        if isinstance(err_item, dict):
            sync_errors.append(
                {
                    "id": err_item.get("id"),
                    "repoName": str(err_item.get("repo_name") or err_item.get("repoName") or ""),
                    "path": str(err_item.get("path") or ""),
                    "error": str(err_item.get("error") or err_item.get("err") or ""),
                }
            )

    if snoozed:
        aggregate = "snoozed"
        status_text = "Snoozed"
    elif not running:
        aggregate = "paused"
        status_text = "Paused"
    elif not configured and not repos:
        aggregate = "setup"
        status_text = "Not configured"
    elif not repos and sync_errors:
        # Library was dropped from the client (corrupt/resync) but errors remain.
        aggregate = "needs-resync"
        status_text = "Needs re-attach"
    elif not repos:
        aggregate = "idle"
        status_text = "No libraries"
    else:
        aggregate = aggregate_state(repos)
        status_text = {
            "synchronized": "Synchronized",
            "syncing": "Syncing",
            "error": "Error",
            "waiting": "Waiting",
            "paused": "Paused",
            "idle": "Idle",
        }.get(aggregate, aggregate)

    worktree = ""
    datadir = seafile_datadir()
    if datadir is not None:
        worktree = str(datadir.parent / "seafile")

    active = running and not snoozed

    return {
        "ok": True,
        "installed": True,
        "configured": configured or len(repos) > 0,
        "running": running,
        "active": active,
        "snoozed": snoozed,
        "snoozeUntil": int(state.get("snoozeUntil") or 0),
        "snoozeLabel": str(state.get("snoozeLabel") or ""),
        "aggregate": aggregate,
        "statusText": status_text,
        "lastSyncTs": last_sync_ts,
        "repos": repos,
        "syncErrors": sync_errors[:10],
        "logPath": str(LOG_PATH),
        "worktreeParent": worktree,
        "detail": (err or "").strip()[:200] if not running and err else "",
    }


def cmd_status() -> int:
    emit(build_status())
    return 0


def cmd_sync_now() -> int:
    if not which_seaf():
        emit({"ok": False, "error": "seaf-cli not installed"})
        return 1

    status = build_status()
    if status.get("snoozed"):
        state = load_state()
        state.pop("snoozeUntil", None)
        state.pop("snoozeLabel", None)
        save_state(state)

    if not status.get("running"):
        code, _, err = run(["seaf-cli", "start"], timeout=15)
        if code != 0:
            emit({"ok": False, "error": err.strip() or "failed to start seafile daemon"})
            return 1
        time.sleep(0.8)

    client = rpc_client()
    if client is None:
        emit({"ok": False, "error": "seafile RPC unavailable; is the daemon running?"})
        return 1

    repos = status.get("repos") or []
    if not repos:
        # Refresh after start.
        repos = build_status().get("repos") or []

    synced = 0
    errors = []
    for repo in repos:
        rid = str(repo.get("id") or "")
        if not rid:
            continue
        try:
            client.sync(rid, "")
            synced += 1
        except Exception as exc:  # noqa: BLE001 — surface to UI
            errors.append(f"{repo.get('name') or rid}: {exc}")

    emit({"ok": len(errors) == 0, "synced": synced, "errors": errors})
    return 0 if not errors else 1


def cmd_pause() -> int:
    if not which_seaf():
        emit({"ok": False, "error": "seaf-cli not installed"})
        return 1
    code, _, err = run(["seaf-cli", "stop"], timeout=15)
    emit({"ok": code == 0, "error": err.strip() if code else ""})
    return 0 if code == 0 else 1


def cmd_resume() -> int:
    if not which_seaf():
        emit({"ok": False, "error": "seaf-cli not installed"})
        return 1
    state = load_state()
    state.pop("snoozeUntil", None)
    state.pop("snoozeLabel", None)
    save_state(state)
    code, _, err = run(["seaf-cli", "start"], timeout=15)
    emit({"ok": code == 0, "error": err.strip() if code else ""})
    return 0 if code == 0 else 1


def cmd_snooze(seconds: int, label: str) -> int:
    if seconds <= 0:
        emit({"ok": False, "error": "invalid snooze duration"})
        return 1
    if not which_seaf():
        emit({"ok": False, "error": "seaf-cli not installed"})
        return 1
    until = int(time.time()) + seconds
    state = load_state()
    state["snoozeUntil"] = until
    state["snoozeLabel"] = label
    save_state(state)
    code, _, err = run(["seaf-cli", "stop"], timeout=15)
    emit({"ok": code == 0, "snoozeUntil": until, "error": err.strip() if code else ""})
    return 0 if code == 0 else 1


def cmd_clear_snooze() -> int:
    state = load_state()
    state.pop("snoozeUntil", None)
    state.pop("snoozeLabel", None)
    save_state(state)
    emit({"ok": True})
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(
            "usage: helper.py status|sync-now|pause|resume|snooze <seconds> <label>|clear-snooze",
            file=sys.stderr,
        )
        return 2

    cmd = argv[1]
    if cmd == "status":
        return cmd_status()
    if cmd == "sync-now":
        return cmd_sync_now()
    if cmd == "pause":
        return cmd_pause()
    if cmd == "resume":
        return cmd_resume()
    if cmd == "clear-snooze":
        return cmd_clear_snooze()
    if cmd == "snooze":
        if len(argv) < 4:
            emit({"ok": False, "error": "usage: snooze <seconds> <label>"})
            return 2
        try:
            seconds = int(argv[2])
        except ValueError:
            emit({"ok": False, "error": "seconds must be an integer"})
            return 2
        return cmd_snooze(seconds, argv[3])

    emit({"ok": False, "error": f"unknown command: {cmd}"})
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
