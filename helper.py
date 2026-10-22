#!/usr/bin/env python3
"""Seafile helper for the Omarchy juangalt.seafile bar widget.

Commands print a single JSON object on stdout. Log/diagnostic strings stay English.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import NamedTuple

CONF_DIR = Path.home() / ".ccnet"
STATE_DIR = Path.home() / ".local" / "state" / "omarchy" / "plugins" / "juangalt.seafile"
STATE_PATH = STATE_DIR / "state.json"
LOG_PATH = CONF_DIR / "logs" / "seafile.log"
SEAF_UNIT = "seaf-daemon.service"
SYNC_LINE = re.compile(
    r"Repo '([^']+)' sync state transition from '.*' to 'synchronized'"
)
TS_LINE = re.compile(r"^\[(\d{2}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\]")
_NAME_KEYS = ("sync-worktree-name", "origin-repo-name", "repo-name", "name")
_REVIVE_STATES = {"active", "activating", "reloading", "deactivating"}


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
    payload = json.dumps(data, indent=2) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix="state.", suffix=".tmp", dir=str(STATE_DIR))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, STATE_PATH)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


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


def seafile_sock() -> Path | None:
    datadir = seafile_datadir()
    if datadir is None:
        return None
    return datadir / "seafile.sock"


def owning_daemon_pids() -> list[int]:
    """PIDs of seaf-daemon whose command line includes this data directory."""
    datadir = seafile_datadir()
    if datadir is None:
        return []
    needle = str(datadir)
    found: list[int] = []
    try:
        entries = list(Path("/proc").iterdir())
    except OSError:
        return []
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            raw = (entry / "cmdline").read_bytes()
            stat = (entry / "stat").read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if not raw or b"seaf-daemon" not in raw:
            continue
        # "pid (comm) state ..." — ignore zombies that no longer own the daemon.
        state = stat.rsplit(")", 1)[-1].lstrip()[:1]
        if state == "Z":
            continue
        cmd = raw.replace(b"\x00", b" ").decode("utf-8", errors="replace")
        if needle in cmd:
            found.append(int(entry.name))
    return found


def presence() -> tuple[bool, list[int]]:
    sock = seafile_sock()
    return bool(sock is not None and sock.exists()), owning_daemon_pids()


def unit_snapshot() -> dict[str, str]:
    info = {"LoadState": "", "ActiveState": "", "SubState": "", "Job": ""}
    code, out, _err = run(
        [
            "systemctl",
            "--user",
            "show",
            SEAF_UNIT,
            "-p",
            "LoadState",
            "-p",
            "ActiveState",
            "-p",
            "SubState",
            "-p",
            "Job",
        ],
        timeout=5,
    )
    if code != 0:
        return info
    for line in out.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in info:
            info[key] = value.strip()
    return info


def unit_may_revive(snap: dict[str, str] | None = None) -> bool:
    """True when the user unit exists and may start seaf-daemon again."""
    info = unit_snapshot() if snap is None else snap
    if info.get("LoadState") != "loaded":
        return False
    if info.get("Job"):
        return True
    if info.get("SubState") in {"auto-restart", "running", "start", "start-pre"}:
        return True
    # ActiveState=failed alone is not a revive: Restart=no units stay failed.
    return info.get("ActiveState") in _REVIVE_STATES


def _local_down() -> bool:
    sock_on, pids = presence()
    return not sock_on and not pids


def _wait_local_down(timeout: float = 2.5) -> None:
    deadline = time.monotonic() + timeout
    while not _local_down():
        if time.monotonic() >= deadline:
            return
        time.sleep(0.2)


def daemon_confirmed_stopped() -> bool:
    """Sock is gone (or status cannot reach a daemon) and nothing owns the data dir.

    A loaded user unit that is still active or scheduled to restart does not count
    as stopped: systemd would bring seaf-daemon back after seaf-cli stop.
    """
    sock_on, pids = presence()
    if pids or unit_may_revive():
        return False
    if not sock_on:
        return True
    code, _out, _err = run(["seaf-cli", "status", "--json"], timeout=4)
    # Exit 0 means the daemon answered. 124 is a hung RPC, not a confirmed stop.
    return code not in (0, 124)


def _stop_error(tried_unit: bool, unit_err: str, cli_err: str) -> str:
    sock_on, pids = presence()
    details: list[str] = []
    if sock_on:
        details.append("seafile.sock is still present")
    if pids:
        details.append(
            "seaf-daemon still owns the data directory (pid %s)"
            % ", ".join(str(pid) for pid in pids)
        )
    snap = unit_snapshot()
    if unit_may_revive(snap):
        details.append(
            "seaf-daemon.service is %s"
            % (snap.get("SubState") or snap.get("ActiveState") or "active")
        )
    if tried_unit:
        details.append("systemctl --user stop seaf-daemon.service did not stop it")
        if unit_err:
            details.append(unit_err)
    elif cli_err:
        details.append(cli_err)
    message = "Seafile daemon is still running after stop"
    if details:
        return message + ": " + "; ".join(details)
    return message


def stop_daemon() -> tuple[bool, str]:
    """Stop seaf-daemon and require the socket and process to actually be gone."""
    cli_err = ""
    if which_seaf():
        _code, _out, err = run(["seaf-cli", "stop"], timeout=15)
        cli_err = (err or "").strip()
    else:
        cli_err = "seaf-cli not installed"

    _wait_local_down(2.5)
    tried_unit = False
    unit_err = ""
    if not daemon_confirmed_stopped():
        snap = unit_snapshot()
        if snap.get("LoadState") == "loaded":
            tried_unit = True
            _code, _out, err = run(
                ["systemctl", "--user", "stop", SEAF_UNIT],
                timeout=20,
            )
            unit_err = (err or "").strip()
            _wait_local_down(3.0)

    if daemon_confirmed_stopped():
        return True, ""
    return False, _stop_error(tried_unit, unit_err, cli_err)


def _wait_until_up(timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while True:
        sock_on, pids = presence()
        if sock_on or pids:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.2)


def start_daemon() -> tuple[bool, str]:
    """Start the daemon. Prefer the user unit when it is installed."""
    snap = unit_snapshot()
    unit_err = ""
    if snap.get("LoadState") == "loaded":
        code, _out, err = run(["systemctl", "--user", "start", SEAF_UNIT], timeout=20)
        unit_err = (err or "").strip()
        if code == 0:
            # Unit accepted start — wait longer before falling back to seaf-cli
            # start, which can race the unit into "already used by another client".
            if _wait_until_up(8.0):
                return True, ""
            return False, unit_err or "seaf-daemon.service started but seafile.sock did not appear"
    if not which_seaf():
        return False, unit_err or "seaf-cli not installed"
    code, _out, err = run(["seaf-cli", "start"], timeout=15)
    if code == 0 or _wait_until_up(1.0):
        return True, ""
    return False, (err or "").strip() or unit_err or "failed to start seafile daemon"


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


def _as_int(value: object) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0


def read_repo_db(db_path: Path | None = None) -> tuple[list[dict], set[str]]:
    """Return (bindings, deleted_ids) from repo.db.

    bindings are Repo rows with worktree/name taken from RepoProperty.
    A name missing there falls back to FileSyncError.repo_name in the same db.
    """
    if db_path is None:
        datadir = seafile_datadir()
        if datadir is None:
            return [], set()
        db_path = datadir / "repo.db"
    if not db_path.exists():
        return [], set()
    uri = "file:%s?mode=ro" % str(db_path.resolve()).replace("?", "%3F")
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=1.0)
    except sqlite3.Error:
        return [], set()
    try:
        try:
            repo_ids = [str(row[0]) for row in conn.execute("SELECT repo_id FROM Repo")]
            deleted = {str(row[0]) for row in conn.execute("SELECT repo_id FROM DeletedRepo")}
            props: dict[str, dict[str, str]] = {}
            for rid, key, value in conn.execute(
                "SELECT repo_id, key, value FROM RepoProperty"
            ):
                props.setdefault(str(rid), {})[str(key)] = "" if value is None else str(value)
        except sqlite3.Error:
            return [], set()
        names: dict[str, str] = {}
        try:
            for rid, name in conn.execute(
                "SELECT repo_id, repo_name FROM FileSyncError "
                "WHERE repo_name IS NOT NULL AND repo_name != '' "
                "ORDER BY timestamp DESC"
            ):
                names.setdefault(str(rid), str(name))
        except sqlite3.Error:
            names = {}
    finally:
        conn.close()

    bindings: list[dict] = []
    for rid in repo_ids:
        meta = props.get(rid, {})
        name = ""
        for key in _NAME_KEYS:
            if meta.get(key):
                name = meta[key]
                break
        if not name:
            name = names.get(rid, "")
        bindings.append({"id": rid, "name": name, "path": meta.get("worktree") or ""})
    return bindings, deleted


def has_leftover_worktree(bindings: list[dict], deleted_ids: set[str]) -> bool:
    """Repo row plus a RepoProperty worktree, and the library was not deleted."""
    for binding in bindings:
        if binding.get("id") in deleted_ids:
            continue
        if str(binding.get("path") or "").strip():
            return True
    return False


def _read_seafile_log_tail(limit_bytes: int = 200_000) -> str:
    if not LOG_PATH.exists():
        return ""
    try:
        size = LOG_PATH.stat().st_size
        with LOG_PATH.open("rb") as handle:
            if size > limit_bytes:
                handle.seek(size - limit_bytes)
                handle.readline()
            return handle.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def last_sync_from_log(limit_bytes: int = 200_000) -> dict[str, int]:
    """Map repo name -> unix timestamp of last transition to synchronized.

    Seafile's log line only includes the library name, so two libraries that
    share a name will share (and overwrite) the same timestamp.
    """
    data = _read_seafile_log_tail(limit_bytes)
    if not data:
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


def enrich_unknown_error(repo_id: str, repo_name: str, error: str) -> str:
    """Replace seaf-cli's opaque 'Unknown error' with a useful log hint."""
    text = (error or "").strip()
    if text.lower() not in ("unknown error", "unknown", ""):
        return text
    rid = (repo_id or "").strip()
    short = rid[:8] if rid else ""
    name = (repo_name or "").strip()
    data = _read_seafile_log_tail(80_000)
    if not data:
        return text or "Unknown error"
    relevant: list[str] = []
    for line in data.splitlines():
        if short and short in line:
            relevant.append(line)
        elif rid and rid in line:
            relevant.append(line)
        elif name and name in line and (
            "error" in line.lower() or "denied" in line.lower() or "Bad response" in line
        ):
            relevant.append(line)
    blob = "\n".join(relevant[-12:])
    m = re.search(r"client_id=([0-9a-fA-F]*)&", blob)
    if m is not None and m.group(1) == "":
        return "Server rejected download (empty client id) — open Connect / repair"
    if m is not None and len(m.group(1)) != 40:
        return "Server rejected download (client id must be 40 hex chars) — open Connect / repair"
    if re.search(r"Download permission denied|permission-check.*400|Bad response code.*400", blob):
        return "Download permission denied by server — open Connect / repair"
    if re.search(r"Internal data corrupt", blob):
        return "Internal data corrupt on the client — open Connect / repair"
    return text or "Unknown error"


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


def classify_probe(code: int, err: str, sock_exists: bool, pids: list[int]) -> str:
    """running | paused | unreachable | unknown.

    paused is a confirmed stop (no seaf-daemon process). A leftover socket after
    stop is ignored when no process owns the data dir. Timeouts while a process
    is still expected are unreachable; process up but RPC failing is unknown.
    """
    if code == 0:
        return "running"
    if code == 124 or "timed out" in (err or "").lower():
        return "unreachable"
    if pids:
        return "unknown"
    # sock_exists is unused on purpose: stale sockets after stop are common.
    _ = sock_exists
    return "paused"


class Probe(NamedTuple):
    kind: str
    code: int
    out: str
    err: str
    sock: bool
    pids: tuple[int, ...]


def probe_status() -> Probe:
    code, out, err = run(["seaf-cli", "status", "--json"], timeout=6)
    sock_on, pids = presence()
    kind = classify_probe(code, err, sock_on, pids)
    return Probe(kind, code, out, err, sock_on, tuple(pids))


def apply_snooze(state: dict, *, start_if_expired: bool) -> tuple[dict, bool, bool]:
    """Return (state, snoozed, started). Auto-resume when the snooze expires."""
    until = int(state.get("snoozeUntil") or 0)
    now = int(time.time())
    if until <= 0:
        return state, False, False
    if now >= until:
        state = dict(state)
        state.pop("snoozeUntil", None)
        state.pop("snoozeLabel", None)
        save_state(state)
        started = False
        if start_if_expired and which_seaf():
            started, _err = start_daemon()
        return state, False, started
    return state, True, False


def clear_snooze_state() -> dict:
    state = load_state()
    state.pop("snoozeUntil", None)
    state.pop("snoozeLabel", None)
    save_state(state)
    return state


def build_sync_errors(raw_errors: list, repos: list, deleted_ids: set[str]) -> list:
    """Keep repo_id and timestamp. Drop stale errors for synchronized repos.

    When a repo carries its own error string, that string is what the UI should
    show. File sync_errors for a library that is already synchronized, or that
    only remains in DeletedRepo, are ignored.
    """
    by_id = {
        str(repo.get("id") or ""): repo
        for repo in repos
        if isinstance(repo, dict)
    }
    synced = {
        rid
        for rid, repo in by_id.items()
        if str(repo.get("state") or "") == "synchronized"
    }

    parsed: list[dict] = []
    for item in raw_errors or []:
        if not isinstance(item, dict):
            continue
        repo_id = str(item.get("repo_id") or item.get("id") or "")
        entry = {
            "id": item.get("id", repo_id or None),
            "repo_id": repo_id,
            "repoName": str(item.get("repo_name") or item.get("repoName") or ""),
            "path": str(item.get("path") or ""),
            "error": str(item.get("error") or item.get("err") or ""),
            "timestamp": _as_int(item.get("timestamp")),
        }
        if item.get("time"):
            entry["time"] = str(item.get("time"))
        parsed.append(entry)

    out: list[dict] = []
    covered: set[str] = set()
    for repo in repos:
        if not isinstance(repo, dict):
            continue
        rid = str(repo.get("id") or "")
        if str(repo.get("state") or "") == "synchronized":
            continue
        repo_error = str(repo.get("error") or "").strip()
        if not repo_error:
            continue
        match = next((err for err in parsed if err["repo_id"] == rid), None)
        entry = {
            "id": (match or {}).get("id", rid or None),
            "repo_id": rid,
            "repoName": str(repo.get("name") or (match or {}).get("repoName") or ""),
            "path": str((match or {}).get("path") or repo.get("path") or ""),
            "error": repo_error,
            "timestamp": int((match or {}).get("timestamp") or 0),
        }
        if match and match.get("time"):
            entry["time"] = match["time"]
        if match and match.get("error") and match["error"] != repo_error:
            entry["syncError"] = match["error"]
        out.append(entry)
        if rid:
            covered.add(rid)

    for err in parsed:
        rid = err["repo_id"]
        if rid and rid in synced:
            continue
        if rid and rid in covered:
            continue
        if rid and rid in deleted_ids and rid not in by_id:
            continue
        out.append(err)
    return out


def _repo_entry(rid: str, name: str, state: str, path: str, ts: int, error: str = "") -> dict:
    return {
        "id": rid,
        "name": name,
        "state": state,
        "path": path,
        "lastSyncTs": ts,
        "error": error,
    }


def _status_text_for(aggregate: str) -> str:
    return {
        "synchronized": "Synchronized",
        "syncing": "Syncing",
        "error": "Error",
        "waiting": "Waiting",
        "paused": "Paused",
        "idle": "Idle",
        "unreachable": "Unreachable",
        "unknown": "Unknown",
        "snoozed": "Snoozed",
        "setup": "Not configured",
        "needs-resync": "Needs re-attach",
    }.get(aggregate, aggregate)


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
            "runningDespiteSnooze": False,
            "aggregate": "missing",
            "statusText": "Not installed",
            "lastSyncTs": 0,
            "repos": [],
            "syncErrors": [],
            "logPath": str(LOG_PATH),
            "worktreeParent": "",
        }

    probe = probe_status()
    # Only auto-start after expiry when the daemon is confirmed down. A timeout
    # or a live socket means it may still be up.
    state, snoozed, started = apply_snooze(state, start_if_expired=probe.kind == "paused")
    if started:
        time.sleep(0.4)
        probe = probe_status()

    running_despite = False
    stop_detail = ""
    if snoozed and probe.kind != "paused":
        stopped, stop_detail = stop_daemon()
        if stopped:
            probe = probe_status()
        else:
            running_despite = True

    running = probe.kind == "running"
    status = parse_status_json(probe.out) if running else {"repos": [], "sync_errors": []}

    listed: list = []
    if probe.kind != "unreachable":
        list_timeout = 6 if running else 4
        list_code, list_out, _list_err = run(
            ["seaf-cli", "list", "--json"],
            timeout=list_timeout,
        )
        if list_code == 0:
            listed = parse_list_json(list_out)
    by_id = {str(item.get("id") or ""): item for item in listed if isinstance(item, dict)}

    bindings, deleted_ids = read_repo_db()
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
        repo_state = str(repo.get("state") or "")
        raw_err = str(repo.get("error") or "")
        err = "" if repo_state == "synchronized" else enrich_unknown_error(rid, name, raw_err)
        entry = _repo_entry(rid, name, repo_state, path, ts, err)
        if "progress" in repo:
            entry["progress"] = repo.get("progress")
        repos.append(entry)

    # Libraries listed but missing from status (daemon down, list still answered).
    if not repos and listed:
        fallback_state = "daemon stopped" if probe.kind == "paused" else "unknown"
        for item in listed:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or "")
            ts = int(last_by_name.get(name) or 0)
            if ts > last_sync_ts:
                last_sync_ts = ts
            repos.append(
                _repo_entry(
                    str(item.get("id") or ""),
                    name,
                    fallback_state,
                    str(item.get("path") or ""),
                    ts,
                )
            )

    # Daemon is down and list failed: show libraries cached in repo.db.
    if not repos and not running:
        cached_state = {
            "paused": "daemon stopped",
            "unreachable": "unreachable",
            "unknown": "unknown",
        }.get(probe.kind, "daemon stopped")
        for binding in bindings:
            if binding["id"] in deleted_ids:
                continue
            name = str(binding.get("name") or "")
            ts = int(last_by_name.get(name) or 0)
            if ts > last_sync_ts:
                last_sync_ts = ts
            repos.append(
                _repo_entry(
                    str(binding.get("id") or ""),
                    name,
                    cached_state,
                    str(binding.get("path") or ""),
                    ts,
                )
            )

    sync_errors = build_sync_errors(status.get("sync_errors") or [], repos, deleted_ids)

    # Needs re-attach only when the daemon is up, reported no libraries, and
    # repo.db still has a worktree binding. Empty repos after a deleted library,
    # or a non-empty sync_errors list on its own, stay "No libraries".
    needs_resync = running and not repos and has_leftover_worktree(bindings, deleted_ids)

    if snoozed and probe.kind == "paused" and not running_despite:
        aggregate = "snoozed"
    elif probe.kind == "unreachable":
        aggregate = "unreachable"
    elif probe.kind == "unknown":
        aggregate = "unknown"
    elif probe.kind == "paused":
        aggregate = "paused"
    elif not configured and not repos:
        aggregate = "setup"
    elif needs_resync:
        aggregate = "needs-resync"
    elif not repos:
        aggregate = "idle"
    else:
        aggregate = aggregate_state(repos)

    status_text = _status_text_for(aggregate)
    if aggregate == "idle":
        status_text = "No libraries"

    worktree = ""
    datadir = seafile_datadir()
    if datadir is not None:
        worktree = str(datadir.parent / "seafile")

    active = running and (not snoozed or running_despite)
    detail = ""
    if running_despite and stop_detail:
        detail = stop_detail[:200]
    elif not running and probe.err:
        detail = probe.err.strip()[:200]

    return {
        "ok": True,
        "installed": True,
        "configured": configured or len(repos) > 0,
        "running": running,
        "active": active,
        "snoozed": snoozed,
        "snoozeUntil": int(state.get("snoozeUntil") or 0),
        "snoozeLabel": str(state.get("snoozeLabel") or ""),
        "runningDespiteSnooze": running_despite,
        "aggregate": aggregate,
        "statusText": status_text,
        "lastSyncTs": last_sync_ts,
        "repos": repos,
        "syncErrors": sync_errors[:10],
        "logPath": str(LOG_PATH),
        "worktreeParent": worktree,
        "detail": detail,
    }


def cmd_status() -> int:
    emit(build_status())
    return 0


def _rpc_sync(client, repo_id: str, timeout: float = 20.0) -> None:
    """Call seafile RPC sync with a hard timeout so control never hangs forever."""
    from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout

    with ThreadPoolExecutor(max_workers=1) as pool:
        fut = pool.submit(client.sync, repo_id, "")
        try:
            fut.result(timeout=timeout)
        except FuturesTimeout as exc:
            raise TimeoutError("seafile sync RPC timed out after %.0fs" % timeout) from exc


def cmd_sync_now() -> int:
    if not which_seaf():
        emit({"ok": False, "error": "seaf-cli not installed"})
        return 1

    # Clear snooze before status so a sync request does not stop the daemon first.
    if int(load_state().get("snoozeUntil") or 0) > 0:
        clear_snooze_state()

    status = build_status()

    if not status.get("running"):
        ok, err = start_daemon()
        if not ok:
            emit({"ok": False, "error": err or "failed to start seafile daemon"})
            return 1
        time.sleep(0.8)

    client = rpc_client()
    if client is None:
        emit({"ok": False, "error": "seafile RPC unavailable; is the daemon running?"})
        return 1

    repos = status.get("repos") or []
    if not repos:
        # Refresh after start. Skip another stop attempt; snooze was cleared.
        repos = build_status().get("repos") or []

    synced = 0
    errors = []
    for repo in repos:
        rid = str(repo.get("id") or "")
        if not rid:
            continue
        try:
            _rpc_sync(client, rid)
            synced += 1
        except Exception as exc:  # noqa: BLE001 — surface to UI
            errors.append("%s: %s" % (repo.get("name") or rid, exc))

    error_text = "; ".join(errors)
    # "synced" means RPC accepted the request, not that transfer finished.
    emit({
        "ok": len(errors) == 0,
        "synced": synced,
        "requested": synced > 0,
        "errors": errors,
        "error": error_text,
    })
    return 0 if not errors else 1


def cmd_pause() -> int:
    if not which_seaf():
        emit({"ok": False, "error": "seaf-cli not installed"})
        return 1
    stopped, err = stop_daemon()
    emit({"ok": stopped, "error": "" if stopped else err})
    return 0 if stopped else 1


def cmd_resume() -> int:
    if not which_seaf():
        emit({"ok": False, "error": "seaf-cli not installed"})
        return 1
    clear_snooze_state()
    ok, err = start_daemon()
    emit({"ok": ok, "error": "" if ok else err})
    return 0 if ok else 1


def cmd_snooze(seconds: int, label: str) -> int:
    if seconds <= 0:
        emit({"ok": False, "error": "invalid snooze duration"})
        return 1
    if not which_seaf():
        emit({"ok": False, "error": "seaf-cli not installed"})
        return 1
    stopped, err = stop_daemon()
    if not stopped:
        # Do not leave a snooze window armed when the daemon is still up.
        clear_snooze_state()
        emit({"ok": False, "error": err or "Seafile daemon is still running after stop", "snoozeUntil": 0})
        return 1
    until = int(time.time()) + seconds
    state = load_state()
    state["snoozeUntil"] = until
    state["snoozeLabel"] = label
    save_state(state)
    emit({"ok": True, "snoozeUntil": until, "snoozeLabel": label, "error": ""})
    return 0


def cmd_clear_snooze() -> int:
    clear_snooze_state()
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

    emit({"ok": False, "error": "unknown command: %s" % cmd})
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
