#!/usr/bin/env bash
# Interactive Seafile / seaf-cli setup for the Omarchy Seafile plugin.
set -euo pipefail

CONF_DIR="${HOME}/.ccnet"
DATA_PARENT="${HOME}/.seafile-client"
DATA_DIR="${DATA_PARENT}/seafile-data"
REPO_DB="${DATA_DIR}/repo.db"
LOG_DIR="${HOME}/.local/state/omarchy/plugins/juangalt.seafile"
LOG_FILE="${LOG_DIR}/setup.log"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Cloudflare often blocks Python-urllib's default User-Agent (error 1010).
# Use a real argv (not a bash function) so setsid/exec can run it.
SEAF=(python3 "$SCRIPT_DIR/seaf_cli_ua.py")

need() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "Missing required command: $1"
  }
}

ensure_log() {
  umask 077
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  {
    echo
    echo "===== $(date -Iseconds) setup pid=$$ ====="
  } >>"$LOG_FILE"
}

log() {
  # Never tee secrets to the terminal via this helper for command lines —
  # callers should pass already-redacted text.
  printf '%s\n' "$*" >>"$LOG_FILE"
  printf '%s\n' "$*" >&2
}

clear_secrets() {
  unset AUTH_TOKEN existing_token password tfa
}

fail() {
  local msg=$1
  clear_secrets
  echo
  echo "✗ $msg" >&2
  echo
  echo "Details were written to:" >&2
  echo "  $LOG_FILE" >&2
  echo "Open that file if you need the full command output." >&2
  exit 1
}

# Redact -p / -T / --password / --token values before anything hits the log.
# Separate args (-T secret) and attached args (-Tsecret, --token=secret).
# Attached forms without '=' log only the flag so the secret is not kept.
redact_cmd() {
  local out=()
  local skip_next=0
  local arg
  for arg in "$@"; do
    if ((skip_next)); then
      out+=("'***'")
      skip_next=0
      continue
    fi
    case "$arg" in
    -p | --password | -T | --token | -a | --tfa | -e | --libpasswd)
      out+=("$arg")
      skip_next=1
      ;;
    --libpasswd=* | --password=* | --token=* | --tfa=* | -p=* | -T=* | -a=* | -e=*)
      out+=("${arg%%=*}='***'")
      ;;
    --libpasswd*)
      out+=("--libpasswd")
      ;;
    --password*)
      out+=("--password")
      ;;
    --token*)
      out+=("--token")
      ;;
    --tfa*)
      out+=("--tfa")
      ;;
    -p*)
      out+=("-p")
      ;;
    -T*)
      out+=("-T")
      ;;
    -a*)
      out+=("-a")
      ;;
    -e*)
      out+=("-e")
      ;;
    *)
      out+=("$arg")
      ;;
    esac
  done
  printf '%s' "${out[*]}"
}

# seaf-cli requires a scheme. Accept host[:port]/path] and add https://.
# Never strip the slash pair in "https://" — `${url%/}` turns that into "https:/".
normalize_server_url() {
  local raw=${1// /}
  if [[ -z $raw ]]; then
    echo ""
    return
  fi
  if [[ $raw =~ ^(https?://[^/]+)(/.*)$ ]]; then
    local hostpart=${BASH_REMATCH[1]}
    local pathpart=${BASH_REMATCH[2]}
    while [[ $pathpart == */ ]]; do
      pathpart=${pathpart%/}
    done
    raw="${hostpart}${pathpart}"
  fi
  if [[ $raw =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
    echo "$raw"
    return
  fi
  echo "https://${raw}"
}

validate_server_url() {
  local url=$1
  if [[ -z $url ]]; then
    echo "Server URL is empty."
    return 1
  fi
  # Reject before any error text echoes the URL (user:pass@host).
  if [[ $url =~ ://[^[:space:]/]*@ ]]; then
    echo "Server URL must not include a username or password."
    return 1
  fi
  if [[ ! $url =~ ^https?:// ]]; then
    echo "Server URL must start with http:// or https:// (got: $url)."
    return 1
  fi
  if [[ $url =~ ^https?:///*$ ]]; then
    echo "Server URL is missing a host. Example: https://seafile.example.com"
    return 1
  fi
  if [[ $url =~ [[:space:]] ]]; then
    echo "Server URL must not contain spaces."
    return 1
  fi
  return 0
}

# https is the default. Cleartext is an explicit, logged choice.
confirm_cleartext_http() {
  local url=$1
  if [[ $url != http://* ]]; then
    return 0
  fi
  if gum confirm "Use cleartext HTTP? Password will be sent unencrypted."; then
    log "Accepted cleartext HTTP for $url"
    return 0
  fi
  log "Declined cleartext HTTP for $url"
  fail "Refusing to send your password over cleartext HTTP."
}

is_auth_error() {
  # Credential failures only. Seafile uses HTTP 400 with
  # "Unable to login with provided credentials" for a bad password, and
  # HTTP 401 / "invalid token" when a saved token is rejected.
  # Do NOT treat every HTTP 400 or 403 as a bad password.
  # Do NOT match bare "timeout" — Python urlopen tracebacks contain that
  # parameter name on every failure.
  grep -qiE 'Unable to login with provided credentials|invalid token|HTTP Error 401|HTTPError: HTTP Error 401' <<<"$1"
}

is_encrypted_lib_error() {
  # Library-password hints from seaf-cli (getpass prompt or encrypt errors).
  # Account-password failures are classified by is_auth_error instead.
  grep -qiE 'password for the library|library password|libpasswd' <<<"$1"
}

# Map noisy seaf-cli / urllib failures to one actionable sentence.
explain_seaf_error() {
  local output=$1
  local server=${2:-}

  if grep -q "unknown url type" <<<"$output"; then
    echo "Server URL is missing http:// or https://. Example: https://seafile.example.com"
    return
  fi
  if grep -qiE 'error code:[[:space:]]*1010|cf-error-code.*1010|Cloudflare.*1010' <<<"$output"; then
    echo "Cloudflare blocked the API client (error 1010). This plugin retries with a browser User-Agent; if it still fails, allow /api2/ for API clients in Cloudflare, or temporarily use your direct/Tailscale URL."
    return
  fi
  if is_auth_error "$output"; then
    if grep -qiE 'invalid token|HTTP Error 401|HTTPError: HTTP Error 401' <<<"$output"; then
      echo "Saved login token was rejected (401). Sign in again with your password."
    else
      echo "Username/password rejected by the server. Check credentials, and enable 2FA in the next prompt if your account uses it."
    fi
    return
  fi
  if grep -qiE 'name or service not known|nodename nor servname|temporary failure in name resolution|could not resolve|failed to resolve' <<<"$output"; then
    echo "Could not resolve the server hostname. Check spelling and DNS/Tailscale."
    return
  fi
  if grep -qiE 'connection refused|could not connect to server|failed to connect|network is unreachable|timed out|TimeoutError|Read timed out' <<<"$output"; then
    echo "Could not reach ${server:-the server}. Is it online, and is the port correct?"
    return
  fi
  if grep -qiE 'certificate verify failed|SSLError|ssl\.SSLError|CERTIFICATE_VERIFY_FAILED' <<<"$output"; then
    echo "TLS/certificate problem talking to the server. Fix the certificate, or confirm a trusted LAN URL separately."
    return
  fi
  if grep -qi 'already used by another Seafile client' <<<"$output"; then
    echo "Another Seafile process is using this data directory. Stop seafile-applet / other daemons and retry."
    return
  fi
  if grep -qi 'No such file or directory' <<<"$output"; then
    echo "A local path from the sync command does not exist."
    return
  fi
  if is_encrypted_lib_error "$output"; then
    echo "This library is encrypted. Re-run setup; encrypted libraries need a library password."
    return
  fi
  if grep -qi 'Task is already in progress' <<<"$output"; then
    echo "A sync/download for this library was already running (or stuck). It was cleared — run Connect/repair again."
    return
  fi

  local line
  line=$(grep -vE '^(Traceback|File "|  File |    )' <<<"$output" | grep -v '^[[:space:]]*$' | tail -1 || true)
  if [[ -n ${line:-} ]]; then
    echo "$line"
    return
  fi
  echo "Seafile command failed. See the log for the full output."
}

# seaf-daemon sends client_id on every download permission-check. The server
# requires exactly 40 hex chars (same as the device id in seafile-data/id).
# Empty or wrong-length ids return HTTP 400 ("Unknown error" in status).
ensure_client_id() {
  local current cid cname need_set=0
  current=$("${SEAF[@]}" config -k client_id 2>/dev/null | sed -n 's/^client_id = //p' | tr -d '[:space:]')
  if [[ -z $current || ${#current} -ne 40 || ! $current =~ ^[0-9a-fA-F]{40}$ ]]; then
    need_set=1
  fi
  if [[ -f ${DATA_DIR}/id ]]; then
    cid=$(tr -d '[:space:]' <"${DATA_DIR}/id")
  fi
  if [[ -z ${cid:-} || ${#cid} -ne 40 || ! $cid =~ ^[0-9a-fA-F]{40}$ ]]; then
    cid=$(python3 -c 'import secrets; print(secrets.token_hex(20))')
    mkdir -p "$DATA_DIR"
    printf '%s\n' "$cid" >"${DATA_DIR}/id"
    chmod 600 "${DATA_DIR}/id" 2>/dev/null || true
  fi
  if ((need_set == 0)) && [[ $current == "$cid" ]]; then
    return 0
  fi
  if ((need_set == 0)); then
    # Config already valid; keep it even if id file differs.
    return 0
  fi
  log "client_id invalid (was '${current:-empty}', len=${#current}) — setting 40-char id and restarting daemon"
  echo "Fixing Seafile client id (server requires 40 hex characters)…"
  "${SEAF[@]}" config -k client_id -v "$cid" >/dev/null 2>&1 || true
  cname=$("${SEAF[@]}" config -k client_name 2>/dev/null | sed -n 's/^client_name = //p' | tr -d '[:space:]')
  if [[ -z $cname ]]; then
    "${SEAF[@]}" config -k client_name -v "$(hostname -s 2>/dev/null || echo seafile)" >/dev/null 2>&1 || true
  fi
  if systemctl --user is-enabled seaf-daemon.service >/dev/null 2>&1; then
    systemctl --user restart seaf-daemon.service >/dev/null 2>&1 || true
  else
    "${SEAF[@]}" stop >/dev/null 2>&1 || true
    "${SEAF[@]}" start >/dev/null 2>&1 || true
  fi
  sleep 1
}

# seaf-cli sync/download return as soon as the clone task is queued. Wait until
# the library appears in `list`, or fail with the real clone/log error.
await_clone_success() {
  local repo_id=$1
  local timeout=${2:-180}
  local deadline state err msg line
  deadline=$((SECONDS + timeout))
  echo "Waiting for library download to finish…"
  while ((SECONDS < deadline)); do
    if "${SEAF[@]}" list --json 2>/dev/null | python3 -c '
import json, sys
rid = sys.argv[1]
try:
    repos = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if any(str(r.get("id") or "") == rid for r in (repos or []) if isinstance(r, dict)) else 1)
' "$repo_id"; then
      log "Clone finished: library $repo_id is listed locally"
      return 0
    fi
    # Inspect clone task state via RPC.
    read -r state err < <(python3 - "$repo_id" "$DATA_DIR" <<'PY' || true
import sys
from pathlib import Path
repo_id, datadir = sys.argv[1], Path(sys.argv[2])
sock = datadir / "seafile.sock"
if not sock.exists():
    print("none 0")
    raise SystemExit(0)
try:
    from seafile.rpcclient import SeafileRpcClient
    client = SeafileRpcClient(str(sock))
except Exception:
    print("none 0")
    raise SystemExit(0)
for task in client.get_clone_tasks() or []:
    rid = getattr(task, "repo_id", None) or ""
    if rid != repo_id:
        continue
    state = str(getattr(task, "state", "") or "")
    err = getattr(task, "error", 0) or 0
    print(f"{state} {err}")
    raise SystemExit(0)
print("none 0")
PY
)
    state=${state:-none}
    err=${err:-0}
    case "$state" in
    done | success | finished)
      log "Clone task state=$state for $repo_id"
      return 0
      ;;
    error | canceled | cancelled)
      msg="Clone failed (state=$state"
      if [[ $err != 0 && $err != 28 && $err != 29 ]]; then
        msg+=" error=$err"
      fi
      msg+=")"
      line=$(grep -E "${repo_id}|${repo_id:0:8}|permission denied|Bad response code" \
        "${CONF_DIR}/logs/seafile.log" 2>/dev/null | tail -8 || true)
      if grep -qi 'permission denied\|Bad response code.*400' <<<"$line"; then
        # Prefer the permission-check URL from this failure (not old log lines).
        if grep -qoE 'client_id=[0-9a-fA-F]*&' <<<"$line"; then
          local bad_cid
          bad_cid=$(grep -oE 'client_id=[0-9a-fA-F]*&' <<<"$line" | tail -1 | sed 's/^client_id=//;s/&$//')
          if [[ -z $bad_cid ]]; then
            msg="Server rejected the download (empty client id). Re-run Connect."
          elif [[ ${#bad_cid} -ne 40 ]]; then
            msg="Server rejected the download (client id length ${#bad_cid}, need 40). Re-run Connect."
          else
            msg="Server denied download permission for this library (HTTP 400). Check account access, then retry Connect."
          fi
        else
          msg="Server denied download permission for this library (HTTP 400). Check account access, then retry Connect."
        fi
      elif [[ -n $line ]]; then
        msg="Clone failed. Last log: $(tail -1 <<<"$line")"
      fi
      fail "$msg"
      ;;
    esac
    sleep 1
  done
  fail "Timed out waiting for library $repo_id to finish downloading. See ${CONF_DIR}/logs/seafile.log"
}

# Cancel leftover clone tasks for a library (failed earlier attempts leave
# "Task is already in progress"). Restart the daemon if a canceled task sticks.
clear_clone_tasks_for() {
  local repo_id=$1
  [[ -n $repo_id ]] || return 0
  python3 - "$repo_id" "$DATA_DIR" <<'PY' >>"$LOG_FILE" 2>&1 || true
import sys
from pathlib import Path

repo_id, datadir = sys.argv[1], Path(sys.argv[2])
sock = datadir / "seafile.sock"
if not sock.exists():
    sys.exit(0)
try:
    from seafile.rpcclient import SeafileRpcClient
    client = SeafileRpcClient(str(sock))
except Exception as exc:
    print("clear_clone_tasks: rpc unavailable:", exc)
    sys.exit(0)

def states():
    out = []
    for task in client.get_clone_tasks() or []:
        rid = getattr(task, "repo_id", None) or ""
        if rid == repo_id or not repo_id:
            out.append(str(getattr(task, "state", "") or ""))
    return out

before = states()
if before:
    print("clear_clone_tasks: before", before)
    try:
        print("cancel", client.cancel_clone_task(repo_id))
    except Exception as exc:
        print("cancel failed:", exc)
after = states()
print("clear_clone_tasks: after", after)
# Stick around as canceled/error/fetch → ask caller to restart.
need_restart = any(s not in ("", "done", "canceled", "cancelled", "success") for s in after) or any(
    s in ("canceled", "cancelled", "error") for s in after
)
sys.exit(2 if need_restart and after else 0)
PY
  local rc=$?
  if ((rc == 2)); then
    log "Restarting seafile daemon to clear stuck clone task for $repo_id"
    if systemctl --user is-enabled seaf-daemon.service >/dev/null 2>&1; then
      systemctl --user restart seaf-daemon.service >/dev/null 2>&1 || true
    else
      "${SEAF[@]}" stop >/dev/null 2>&1 || true
      "${SEAF[@]}" start >/dev/null 2>&1 || true
    fi
    sleep 1
  fi
}

# sync/download call getpass() for an encrypted library. Capturing stderr
# hides that prompt and the read blocks. Detach from the tty and close
# stdin so it fails fast; the caller can then ask with gum and pass -e.
seaf_cli_prompts_for_library() {
  local arg
  for arg in "$@"; do
    if [[ $arg == sync || $arg == download ]]; then
      return 0
    fi
  done
  return 1
}

# Runs a command; on failure sets SEAF_RC / SEAF_OUT and returns non-zero
# without exiting. Logs a redacted command line always.
run_seaf_capture() {
  local label=$1
  shift
  set +e
  if seaf_cli_prompts_for_library "$@"; then
    if command -v setsid >/dev/null 2>&1; then
      SEAF_OUT=$(setsid --wait "$@" </dev/null 2>&1)
    else
      SEAF_OUT=$("$@" </dev/null 2>&1)
    fi
  else
    SEAF_OUT=$("$@" 2>&1)
  fi
  SEAF_RC=$?
  set -e
  {
    echo "\$ $(redact_cmd "$@")   # $label"
    # Keep command output; secrets should never appear there from seaf-cli.
    printf '%s\n' "$SEAF_OUT"
    echo "(exit $SEAF_RC)"
  } >>"$LOG_FILE"
  return "$SEAF_RC"
}

# Like run_seaf_capture, but an encrypted library can be retried once with
# a library password collected by gum (-e), not seaf-cli's getpass.
run_seaf_allow_libpass() {
  local label=$1
  shift
  if run_seaf_capture "$label" "$@"; then
    return 0
  fi
  if is_encrypted_lib_error "$SEAF_OUT" && ! is_auth_error "$SEAF_OUT"; then
    local libpass=""
    echo "This library is encrypted. Encrypted libraries need a library password." >&2
    echo "Enter it now, or leave it empty to abort and re-run setup later." >&2
    libpass=$(gum input --password --placeholder "library password" --prompt "Library password> ") || libpass=""
    if [[ -n $libpass ]]; then
      if run_seaf_capture "$label" "$@" -e "$libpass"; then
        unset libpass
        return 0
      fi
    fi
    unset libpass
  fi
  return 1
}

run_seaf() {
  local label=$1
  shift
  if ! run_seaf_capture "$label" "$@"; then
    fail "${label}: $(explain_seaf_error "$SEAF_OUT" "${server:-}")"
  fi
  printf '%s\n' "$SEAF_OUT"
}

# POST /api2/auth-token/ ourselves so we can show Seafile's JSON error body
# and avoid putting the password on a logged seaf-cli argv.
# Sets AUTH_TOKEN on success. Does not follow redirects.
obtain_token_checked() {
  local server=$1 username=$2 password=$3 tfa=${4:-}
  local out rc log_server
  set +e
  out=$(
    SERVER="$server" USERNAME="$username" PASSWORD="$password" TFA="$tfa" DATADIR="$DATA_DIR" python3 - <<'PY'
import json, os, ssl, sys, urllib.error, urllib.parse, urllib.request, secrets

class RefuseRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow redirects. Auth POST bodies must stay on the requested host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(
            req.full_url, code, f"refusing redirect to {newurl}", headers, fp
        )

    def http_error_302(self, req, fp, code, msg, headers):
        location = headers.get("Location") or headers.get("URI") or ""
        raise urllib.error.HTTPError(
            req.full_url, code, f"refusing redirect to {location}", headers, fp
        )

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302

def is_tls_error(exc):
    seen = []
    if exc is not None:
        seen.append(exc)
    reason = getattr(exc, "reason", None)
    if reason is not None and reason is not exc:
        seen.append(reason)
    for item in seen:
        if isinstance(item, ssl.SSLError):
            return True
        text = str(item).lower()
        if "certificate" in text or "ssl" in text or "tls" in text:
            return True
    return False

TLS_MSG = (
    "TLS/certificate problem talking to the server. "
    "Fix the certificate, or confirm a trusted LAN URL separately."
)

server = os.environ["SERVER"].rstrip("/")
username = os.environ["USERNAME"]
password = os.environ["PASSWORD"]
tfa = os.environ.get("TFA") or ""
datadir = os.environ.get("DATADIR") or ""

parts = urllib.parse.urlsplit(server)
if parts.username is not None or parts.password is not None or "@" in parts.netloc:
    print("ERROR\tServer URL must not include userinfo (user:pass@host).")
    sys.exit(1)
requested_host = (parts.hostname or "").lower()
if not requested_host:
    print("ERROR\tServer URL is missing a host.")
    sys.exit(1)

idfile = os.path.join(datadir, "id")
device_id = ""
if datadir and os.path.isfile(idfile):
    device_id = open(idfile, encoding="utf-8").read().strip()
if not device_id:
    device_id = secrets.token_hex(20)
    if datadir:
        os.makedirs(datadir, exist_ok=True)
        with open(idfile, "w", encoding="utf-8") as fh:
            fh.write(device_id)

data = urllib.parse.urlencode({
    "username": username,
    "password": password,
    "platform": "linux",
    "device_id": device_id,
    "device_name": "terminal-" + os.uname().nodename[:25],
    "client_version": "9.0.0",
    "platform_version": "",
}).encode("utf-8")

# Cloudflare (and similar) often block Python-urllib's default User-Agent with
# error 1010. Send a normal browser UA so /api2/auth-token/ can reach Seafile.
headers = {
    "Content-Type": "application/x-www-form-urlencoded",
    "User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json,text/plain,*/*",
}
if tfa:
    headers["X-SEAFILE-OTP"] = tfa

opener = urllib.request.build_opener(RefuseRedirect())
req = urllib.request.Request(server + "/api2/auth-token/", data=data, headers=headers)
try:
    with opener.open(req, timeout=20) as resp:
        final = urllib.parse.urlsplit(resp.geturl())
        if final.username is not None or final.password is not None or "@" in final.netloc:
            print("ERROR\tAuth response URL must not include userinfo.")
            sys.exit(1)
        final_host = (final.hostname or "").lower()
        if final_host != requested_host:
            print("ERROR\tAuth response host does not match the requested server.")
            sys.exit(1)
        body = resp.read().decode("utf-8", errors="replace")
        payload = json.loads(body)
        token = payload.get("token")
        if not token:
            print("ERROR\tServer response had no token field.")
            sys.exit(2)
        print("OK\t" + token)
except urllib.error.HTTPError as exc:
    if 300 <= exc.code < 400:
        print(f"ERROR\tHTTP {exc.code}: {exc.reason}")
        sys.exit(1)
    raw = exc.read().decode("utf-8", errors="replace")
    detail = raw.strip() or str(exc.reason)
    try:
        parsed = json.loads(raw)
        errs = parsed.get("non_field_errors") or parsed.get("detail") or parsed
        if isinstance(errs, list):
            detail = "; ".join(str(x) for x in errs)
        else:
            detail = str(errs)
    except Exception:
        pass
    print(f"ERROR\tHTTP {exc.code}: {detail}")
    sys.exit(1)
except urllib.error.URLError as exc:
    if is_tls_error(exc):
        print(f"ERROR\t{TLS_MSG}")
    else:
        print(f"ERROR\t{exc.reason or exc}")
    sys.exit(1)
except ssl.SSLError:
    print(f"ERROR\t{TLS_MSG}")
    sys.exit(1)
except Exception as exc:
    if is_tls_error(exc):
        print(f"ERROR\t{TLS_MSG}")
    else:
        print(f"ERROR\t{exc}")
    sys.exit(1)
PY
  )
  rc=$?
  set -e
  if [[ $server =~ ://[^[:space:]/]*@ ]]; then
    log_server="<url-with-userinfo-redacted>"
  else
    log_server=$server
  fi
  {
    echo "\$ auth-token POST $log_server  # login check"
    # never log token
    if [[ $out == OK$'\t'* ]]; then
      echo "OK (token acquired)"
    else
      echo "$out"
    fi
    echo "(exit $rc)"
  } >>"$LOG_FILE"

  if ((rc != 0)) || [[ $out != OK$'\t'* ]]; then
    local detail=${out#ERROR$'\t'}
    fail "Login failed: $(explain_seaf_error "$out" "$server")"
  fi
  AUTH_TOKEN=${out#OK$'\t'}
  [[ -n $AUTH_TOKEN ]] || fail "Login returned an empty token."
}

read_existing_binding() {
  [[ -f $REPO_DB ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  sqlite3 "$REPO_DB" "
    SELECT
      r.repo_id,
      IFNULL((SELECT value FROM RepoProperty WHERE repo_id=r.repo_id AND key='email'), ''),
      IFNULL((SELECT value FROM RepoProperty WHERE repo_id=r.repo_id AND key='server-url'), ''),
      IFNULL((SELECT value FROM RepoProperty WHERE repo_id=r.repo_id AND key='worktree'), ''),
      IFNULL((SELECT value FROM RepoProperty WHERE repo_id=r.repo_id AND key='token'), '')
    FROM Repo r
    LIMIT 1;
  " 2>/dev/null || true
}

accept_server_url() {
  # Sets server from raw input. Confirms cleartext HTTP. Logs normalization.
  local raw_server=$1
  server=$(normalize_server_url "$raw_server")
  if ! msg=$(validate_server_url "$server"); then
    log "Rejected server URL"
    fail "$msg"
  fi
  if [[ $server != "$raw_server" ]]; then
    echo "Using server URL: $server"
    log "Normalized server URL: '$raw_server' -> '$server'"
  fi
  confirm_cleartext_http "$server"
}

prompt_login() {
  # Sets: server username AUTH_TOKEN (and uses password ephemerally)
  local default_server=$1 default_user=$2
  local raw_server password tfa

  raw_server=$(gum input --value "$default_server" --placeholder "https://seafile.example.com" --prompt "Server URL> ")
  [[ -n $raw_server ]] || fail "Server URL required."
  accept_server_url "$raw_server"

  username=$(gum input --value "$default_user" --placeholder "you@example.com" --prompt "Username> ")
  [[ -n $username ]] || fail "Username required."

  password=$(gum input --password --placeholder "password" --prompt "Password> ")
  [[ -n $password ]] || fail "Password required."

  tfa=""
  if gum confirm "This account uses two-factor authentication (2FA)?"; then
    tfa=$(gum input --placeholder "123456" --prompt "2FA code> ")
    [[ -n $tfa ]] || fail "2FA code required when 2FA is enabled."
  fi

  echo "Signing in to $server …"
  obtain_token_checked "$server" "$username" "$password" "$tfa"
  unset password tfa
}

need seaf-cli
need gum
ensure_log
log "Starting Seafile setup"

echo "Seafile setup"
echo "Log: $LOG_FILE"
echo

if [[ ! -f "${CONF_DIR}/seafile.ini" ]]; then
  echo "Initializing Seafile client data under ${DATA_PARENT}"
  log "seaf-cli init -d $DATA_PARENT"
  run_seaf "Initialize client" "${SEAF[@]}" init -d "$DATA_PARENT" >/dev/null
fi

if ! "${SEAF[@]}" status >/dev/null 2>&1; then
  echo "Starting seafile daemon…"
  run_seaf "Start daemon" "${SEAF[@]}" start >/dev/null
  sleep 1
fi

ensure_client_id

if "${SEAF[@]}" list 2>/dev/null | awk 'NR>1{found=1} END{exit !found}'; then
  echo
  echo "Local libraries already configured:"
  "${SEAF[@]}" list || true
  echo
  if ! gum confirm "Add another library?"; then
    echo "Done."
    exit 0
  fi
fi

existing=$(read_existing_binding || true)
existing_id=""
existing_email=""
existing_server=""
existing_worktree=""
existing_token=""
if [[ -n ${existing:-} ]]; then
  IFS='|' read -r existing_id existing_email existing_server existing_worktree existing_token <<<"$existing"
  log "Found leftover binding id=$existing_id email=$existing_email server=$existing_server worktree=$existing_worktree"
fi

server=""
username=""
AUTH_TOKEN=""

if [[ -n $existing_id && -n $existing_server && -n $existing_worktree && -n $existing_email ]]; then
  echo "Found a previous library binding that is no longer active:"
  echo "  Library : $existing_id"
  echo "  Server  : $existing_server"
  echo "  Folder  : $existing_worktree"
  echo "  Account : $existing_email"
  echo
  if gum confirm "Try to re-attach that library?"; then
    repair_mode=1
    raw_server=$(gum input --value "$existing_server" \
      --placeholder "https://seafile.example.com" \
      --prompt "Server URL (edit if the saved one is wrong)> ")
    accept_server_url "$raw_server"
    mkdir -p "$existing_worktree"
    username=$existing_email

    if [[ -n $existing_token ]]; then
      echo "Re-attaching with saved token → $existing_worktree"
      clear_clone_tasks_for "$existing_id"
      if run_seaf_allow_libpass "Re-attach library (token)" "${SEAF[@]}" sync \
        -l "$existing_id" \
        -s "$server" \
        -u "$username" \
        -T "$existing_token" \
        -d "$existing_worktree"; then
        await_clone_success "$existing_id"
        echo
        echo "Libraries:"
        "${SEAF[@]}" list || true
        echo
        echo "Setup complete (re-attached existing binding)."
        log "Repair sync succeeded (token)"
        clear_secrets
        exit 0
      fi
      if grep -qi 'Task is already in progress' <<<"$SEAF_OUT"; then
        clear_clone_tasks_for "$existing_id"
        if run_seaf_allow_libpass "Re-attach library (token retry)" "${SEAF[@]}" sync \
          -l "$existing_id" \
          -s "$server" \
          -u "$username" \
          -T "$existing_token" \
          -d "$existing_worktree"; then
          await_clone_success "$existing_id"
          echo
          echo "Libraries:"
          "${SEAF[@]}" list || true
          echo
          echo "Setup complete (re-attached existing binding)."
          log "Repair sync succeeded (token retry)"
          clear_secrets
          exit 0
        fi
      fi
      why=$(explain_seaf_error "$SEAF_OUT" "$server")
      echo "✗ Token re-attach failed: $why"
      log "Token re-attach failed: $why"
      unset existing_token
      echo "Continuing with a password login for the same library…"
    else
      echo "No saved token — need a password login for this library."
    fi

    password=$(gum input --password --placeholder "password" --prompt "Password> ")
    [[ -n $password ]] || fail "Password required."
    tfa=""
    if gum confirm "This account uses two-factor authentication (2FA)?"; then
      tfa=$(gum input --placeholder "123456" --prompt "2FA code> ")
      [[ -n $tfa ]] || fail "2FA code required when 2FA is enabled."
    fi
    echo "Signing in to $server …"
    obtain_token_checked "$server" "$username" "$password" "$tfa"
    unset password tfa
    echo "Syncing ${existing_id} → ${existing_worktree}"
    clear_clone_tasks_for "$existing_id"
    if ! run_seaf_allow_libpass "Sync library" "${SEAF[@]}" sync \
      -l "$existing_id" \
      -s "$server" \
      -u "$username" \
      -T "$AUTH_TOKEN" \
      -d "$existing_worktree"; then
      if grep -qi 'Task is already in progress' <<<"$SEAF_OUT"; then
        clear_clone_tasks_for "$existing_id"
        run_seaf_allow_libpass "Sync library (retry)" "${SEAF[@]}" sync \
          -l "$existing_id" \
          -s "$server" \
          -u "$username" \
          -T "$AUTH_TOKEN" \
          -d "$existing_worktree" || fail "Sync library: $(explain_seaf_error "$SEAF_OUT" "${server:-}")"
      else
        fail "Sync library: $(explain_seaf_error "$SEAF_OUT" "${server:-}")"
      fi
    fi
    await_clone_success "$existing_id"
    echo
    echo "Libraries:"
    "${SEAF[@]}" list || true
    echo
    echo "Setup complete (re-attached with fresh login)."
    log "Repair sync succeeded (password→token)"
    clear_secrets
    exit 0
  fi
  echo "Continuing with a fresh login…"
  echo
fi

# Saved library token is only for the re-attach attempt above.
unset existing_token

prompt_login "${existing_server:-https://}" "${existing_email:-}"

echo
echo "Fetching remote libraries from $server …"
remote_json=$(run_seaf "List remote libraries" "${SEAF[@]}" list-remote -s "$server" -u "$username" -T "$AUTH_TOKEN" --json)

mapfile -t choices < <(printf '%s\n' "$remote_json" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    repos = json.loads(raw)
except Exception as e:
    print(f"BADJSON\t{e}", file=sys.stderr)
    sys.exit(2)
if not isinstance(repos, list):
    print("BADJSON\texpected a list", file=sys.stderr)
    sys.exit(2)
for r in repos:
    if not isinstance(r, dict):
        continue
    name = str(r.get("name") or "")
    rid = str(r.get("id") or r.get("repo_id") or "")
    if name and rid:
        print(f"{name}\t{rid}")
' 2>>"$LOG_FILE") || fail "Remote library list was not valid JSON. See $LOG_FILE"

if ((${#choices[@]} == 0)); then
  fail "No remote libraries found for this account on $server."
fi

picked=$(printf '%s\n' "${choices[@]}" | gum choose --header "Pick a library to sync")
[[ -n $picked ]] || fail "No library selected."
lib_name=${picked%%$'\t'*}
lib_id=${picked#*$'\t'}

default_folder=${existing_worktree:-}
if [[ -n $existing_worktree && $lib_id == "$existing_id" ]]; then
  default_folder=$existing_worktree
elif [[ -z $default_folder ]]; then
  default_folder="${HOME}/$(echo "$lib_name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
fi

folder=$(gum input --value "$default_folder" --prompt "Local folder> ")
[[ -n $folder ]] || fail "Folder required."

mode=$(gum choose --header "How should this library land locally?" \
  "Sync into existing/empty folder (keeps local files)" \
  "Download into a parent directory (Seafile creates the library folder)")

clear_clone_tasks_for "$lib_id"
if [[ $mode == Sync* ]]; then
  mkdir -p "$folder"
  echo "Syncing ${lib_name} → ${folder}"
  if ! run_seaf_allow_libpass "Sync library" "${SEAF[@]}" sync -l "$lib_id" -s "$server" -u "$username" -T "$AUTH_TOKEN" -d "$folder"; then
    if grep -qi 'Task is already in progress' <<<"$SEAF_OUT"; then
      clear_clone_tasks_for "$lib_id"
      run_seaf_allow_libpass "Sync library (retry)" "${SEAF[@]}" sync -l "$lib_id" -s "$server" -u "$username" -T "$AUTH_TOKEN" -d "$folder" \
        || fail "Sync library: $(explain_seaf_error "$SEAF_OUT" "${server:-}")"
    else
      fail "Sync library: $(explain_seaf_error "$SEAF_OUT" "${server:-}")"
    fi
  fi
else
  parent=$(dirname "$folder")
  mkdir -p "$parent"
  echo "Downloading ${lib_name} under ${parent}"
  if ! run_seaf_allow_libpass "Download library" "${SEAF[@]}" download -l "$lib_id" -s "$server" -u "$username" -T "$AUTH_TOKEN" -d "$parent"; then
    if grep -qi 'Task is already in progress' <<<"$SEAF_OUT"; then
      clear_clone_tasks_for "$lib_id"
      run_seaf_allow_libpass "Download library (retry)" "${SEAF[@]}" download -l "$lib_id" -s "$server" -u "$username" -T "$AUTH_TOKEN" -d "$parent" \
        || fail "Download library: $(explain_seaf_error "$SEAF_OUT" "${server:-}")"
    else
      fail "Download library: $(explain_seaf_error "$SEAF_OUT" "${server:-}")"
    fi
  fi
fi

await_clone_success "$lib_id"

echo
echo "Libraries:"
"${SEAF[@]}" list || true
echo
echo "Setup complete."
log "Setup finished OK"
clear_secrets
