#!/usr/bin/env bash
# Interactive Seafile / seaf-cli setup for the Omarchy Seafile plugin.
set -euo pipefail
# `bash -x` would print tokens, passwords, and 2FA codes. Stay off.
set +x
# Private files (token config, log) must not be group/world readable.
umask 077

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
# Mode-0600 account config passed to seaf-cli as -C. Never holds a library password.
TOKEN_CONF=""
# One-shot library password for the next seaf-cli call. Not exported.
SEAF_LIBPASS=""
SECRETS_TRAP=0
# argv actually executed. Credential flags are removed; -C is appended when needed.
SEAF_CMD=()

need() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "Missing required command: $1"
  }
}

ensure_log() {
  umask 077
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  {
    echo
    echo "===== $(date -Iseconds) setup pid=$$ ====="
  } >>"$LOG_FILE"
}

# Seafile stores the library token in repo.db. Keep client metadata private.
restrict_client_metadata() {
  local path
  for path in "$CONF_DIR" "$DATA_PARENT" "$DATA_DIR" "${CONF_DIR}/logs"; do
    if [[ -d $path ]]; then
      chmod 700 "$path" || true
    fi
  done
  local file
  for file in "$REPO_DB" "${DATA_DIR}/id" "${CONF_DIR}/seafile.ini"; do
    if [[ -f $file ]]; then
      chmod 600 "$file" || true
    fi
  done
}

log() {
  # Never tee secrets to the terminal via this helper for command lines —
  # callers should pass already-redacted text.
  printf '%s\n' "$*" >>"$LOG_FILE"
  printf '%s\n' "$*" >&2
}

clear_secrets() {
  unset AUTH_TOKEN existing_token password tfa SEAF_LIBPASS libpass
  if [[ -n ${TOKEN_CONF:-} && -e ${TOKEN_CONF} ]]; then
    rm -f -- "$TOKEN_CONF"
  fi
  TOKEN_CONF=""
}

cleanup_secrets() {
  # Keep this quiet: an EXIT trap must not print secrets or change the exit code.
  set +x
  clear_secrets || true
  restrict_client_metadata || true
}

install_secrets_trap() {
  if ((SECRETS_TRAP)); then
    return
  fi
  trap cleanup_secrets EXIT
  trap 'cleanup_secrets; exit 130' INT
  trap 'cleanup_secrets; exit 143' TERM
  SECRETS_TRAP=1
}

# seaf-cli 9.0.x reads the account token from a user config (-C), not only -T.
# Format is ConfigParser with [account] as the first section. '%' is escaped
# because ConfigParser interpolation treats a single '%' as a format marker.
# The file is created with mktemp (mode 0600) under the private log directory.
write_token_conf() {
  set +x
  local token="$1"
  if [[ -z $token || $token == *$'\n'* || $token == *$'\r'* ]]; then
    fail "Login token is empty or contains a newline; refusing to store it."
  fi
  install_secrets_trap
  umask 077
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  if [[ -z ${TOKEN_CONF} || ! -f ${TOKEN_CONF} ]]; then
    TOKEN_CONF=$(mktemp "${LOG_DIR}/token.XXXXXX") || fail "Could not create a private token file."
  fi
  chmod 600 "$TOKEN_CONF"
  local escaped="${token//%/%%}"
  # builtin printf: the token must never be an argv element of an external command.
  builtin printf '%s\n' '[account]' "token = ${escaped}" >"$TOKEN_CONF" \
    || fail "Could not write the token file."
  chmod 600 "$TOKEN_CONF"
}

# Drop credential flags and, for commands that authenticate, append -C.
# seaf-cli accepts the token only as -T/--token or this config file.
# Library passwords are not stored here; sync/download read them from getpass.
prepare_seaf_cmd() {
  set +x
  SEAF_CMD=()
  local -a cleaned=()
  local arg needs=0 skip_next=0
  for arg in "$@"; do
    if ((skip_next)); then
      skip_next=0
      continue
    fi
    case "$arg" in
    list-remote | sync | download | download-by-name | create)
      needs=1
      cleaned+=("$arg")
      ;;
    -T | --token | -e | --libpasswd | -p | --password | -a | --tfa | -C)
      # Skip the flag and its value so a caller cannot put a secret on argv.
      skip_next=1
      ;;
    --token=* | --libpasswd=* | --password=* | --tfa=* | -T=* | -e=* | -p=* | -a=* | -C=*)
      ;;
    *)
      cleaned+=("$arg")
      ;;
    esac
  done
  if ((needs)); then
    if [[ -z ${TOKEN_CONF} || ! -f ${TOKEN_CONF} ]]; then
      fail "Internal error: missing private token file."
    fi
    cleaned+=(-C "$TOKEN_CONF")
  fi
  SEAF_CMD=("${cleaned[@]}")
}

fail() {
  local msg="$1"
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
  local output
  output=$(redact_secrets "${1:-}")
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

_valid_client_id() {
  [[ -n ${1:-} && ${#1} -eq 40 && $1 =~ ^[0-9a-fA-F]{40}$ ]]
}

wait_for_daemon_sock() {
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    [[ -S ${DATA_DIR}/seafile.sock ]] && return 0
    sleep 0.2
  done
  return 1
}

restart_seafile_daemon() {
  if systemctl --user is-enabled seaf-daemon.service >/dev/null 2>&1; then
    systemctl --user restart seaf-daemon.service >/dev/null 2>&1 || true
  else
    "${SEAF[@]}" stop >/dev/null 2>&1 || true
    "${SEAF[@]}" start >/dev/null 2>&1 || true
  fi
  wait_for_daemon_sock || fail "Seafile daemon did not create seafile.sock after restart."
}

# seaf-daemon sends client_id on every download permission-check. The server
# requires exactly 40 hex chars. Auth login uses seafile-data/id as device_id —
# keep config client_id and that file identical.
ensure_client_id() {
  local current file_id chosen cname id_file_changed=0
  current=$("${SEAF[@]}" config -k client_id 2>/dev/null | sed -n 's/^client_id = //p' | tr -d '[:space:]')
  file_id=""
  if [[ -f ${DATA_DIR}/id ]]; then
    file_id=$(tr -d '[:space:]' <"${DATA_DIR}/id")
  fi

  if _valid_client_id "$current"; then
    chosen=$current
  elif _valid_client_id "$file_id"; then
    chosen=$file_id
  else
    chosen=$(python3 -c 'import secrets; print(secrets.token_hex(20))')
  fi

  mkdir -p "$DATA_DIR"
  if [[ $file_id != "$chosen" ]]; then
    printf '%s\n' "$chosen" >"${DATA_DIR}/id"
    chmod 600 "${DATA_DIR}/id" 2>/dev/null || true
    id_file_changed=1
    log "Wrote seafile-data/id to match client_id ${chosen:0:8}…"
  fi

  if [[ $current == "$chosen" ]]; then
    # Auth readers may cache seafile-data/id — restart when only the file changed.
    if ((id_file_changed)); then
      restart_seafile_daemon
    fi
    return 0
  fi

  log "Aligning client_id to ${chosen:0:8}… (was '${current:-empty}', len=${#current})"
  echo "Aligning Seafile client id (must be 40 hex characters)…"
  if ! "${SEAF[@]}" config -k client_id -v "$chosen" >/dev/null 2>&1; then
    fail "Could not set Seafile client_id. Is the daemon running?"
  fi
  cname=$("${SEAF[@]}" config -k client_name 2>/dev/null | sed -n 's/^client_name = //p' | tr -d '[:space:]')
  if [[ -z $cname ]]; then
    "${SEAF[@]}" config -k client_name -v "$(hostname -s 2>/dev/null || echo seafile)" >/dev/null 2>&1 || true
  fi
  restart_seafile_daemon
}

# seaf-cli sync/download return as soon as the clone task is queued. Wait until
# the clone task finishes cleanly, or the library is listed AND synchronized.
# Do not treat "already in list" alone as success — leftover bindings false-green.
await_clone_success() {
  local repo_id=$1
  local timeout=${2:-180}
  local deadline state err msg line ticks=0 repo_state listed
  deadline=$((SECONDS + timeout))
  echo "Waiting for library download to finish…"
  while ((SECONDS < deadline)); do
    ticks=$((ticks + 1))
    # Inspect clone task state via RPC (tab-separated: state may contain spaces).
    IFS=$'\t' read -r state err < <(python3 - "$repo_id" "$DATA_DIR" <<'PY' || true
import sys
from pathlib import Path
repo_id, datadir = sys.argv[1], Path(sys.argv[2])
sock = datadir / "seafile.sock"
if not sock.exists():
    print("none\t0")
    raise SystemExit(0)
try:
    from seafile.rpcclient import SeafileRpcClient
    client = SeafileRpcClient(str(sock))
except Exception:
    print("none\t0")
    raise SystemExit(0)
for task in client.get_clone_tasks() or []:
    rid = getattr(task, "repo_id", None) or ""
    if rid != repo_id:
        continue
    state = str(getattr(task, "state", "") or "").replace("\t", " ")
    err = getattr(task, "error", 0) or 0
    print(f"{state}\t{err}")
    raise SystemExit(0)
print("none\t0")
PY
)
    state=${state:-none}
    err=${err:-0}
    case "$state" in
    done | success | finished)
      # 0 = OK, 29 = SYNC_ERROR_ID_NO_ERROR. Any other code is a real failure.
      if [[ $err == 0 || $err == 29 ]]; then
        log "Clone task state=$state error=$err for $repo_id"
        return 0
      fi
      fail "Clone finished with error=$err (state=$state). See ${CONF_DIR}/logs/seafile.log"
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

    listed=0
    if "${SEAF[@]}" list --json 2>/dev/null | python3 -c '
import json, sys
rid = sys.argv[1]
try:
    repos = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if any(str(r.get("id") or "") == rid for r in (repos or []) if isinstance(r, dict)) else 1)
' "$repo_id"; then
      listed=1
    fi

    if ((listed)); then
      repo_state=$(
        "${SEAF[@]}" status --json 2>/dev/null | python3 -c '
import json, sys
rid = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
repos = data.get("repos") if isinstance(data, dict) else data
for r in repos or []:
    if isinstance(r, dict) and str(r.get("id") or "") == rid:
        print(str(r.get("state") or ""))
        break
' "$repo_id" 2>/dev/null || true
      )
      case "$repo_state" in
      synchronized)
        log "Clone finished: library $repo_id listed and synchronized"
        return 0
        ;;
      error)
        fail "Library $repo_id is listed but in error state. See ${CONF_DIR}/logs/seafile.log"
        ;;
      esac
      # Listed, no active clone task — give the daemon a few seconds before accepting
      # a leftover binding that was already present before this sync/download.
      if [[ $state == none ]] && ((ticks >= 3)); then
        log "Clone finished: library $repo_id listed (no clone task after ${ticks}s)"
        return 0
      fi
    fi
    sleep 1
  done
  fail "Timed out waiting for library $repo_id to finish downloading. See ${CONF_DIR}/logs/seafile.log"
}

# Cancel leftover clone tasks for a library (failed earlier attempts leave
# "Task is already in progress"). Restart the daemon if a canceled task sticks.
clear_clone_tasks_for() {
  local repo_id=$1
  local rc=0
  [[ -n $repo_id ]] || return 0
  set +e
  python3 - "$repo_id" "$DATA_DIR" <<'PY' >>"$LOG_FILE" 2>&1
import sys
from pathlib import Path

repo_id, datadir = sys.argv[1], Path(sys.argv[2])
sock = datadir / "seafile.sock"
if not sock.exists():
    print("clear_clone_tasks: seafile.sock missing")
    sys.exit(1)
try:
    from seafile.rpcclient import SeafileRpcClient
    client = SeafileRpcClient(str(sock))
except Exception as exc:
    print("clear_clone_tasks: rpc unavailable:", exc)
    sys.exit(1)

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
# canceled/error/fetch stick; done also sticks (cancel returns -1) — restart.
need_restart = bool(after) and (
    any(s in ("canceled", "cancelled", "error", "done", "fetch") for s in after)
    or any(s not in ("", "canceled", "cancelled", "success", "done") for s in after)
)
sys.exit(2 if need_restart else 0)
PY
  rc=$?
  set -e
  if ((rc == 1 || rc == 2)); then
    log "Restarting seafile daemon to clear stuck clone task for $repo_id (rc=$rc)"
    restart_seafile_daemon
  fi
}

# sync/download call getpass() for an encrypted library. Capturing stderr
# hides that prompt and the read blocks. Detach from the tty and close
# stdin so the first attempt fails fast instead of waiting on /dev/tty.
seaf_cli_prompts_for_library() {
  local arg
  for arg in "$@"; do
    if [[ $arg == sync || $arg == download ]]; then
      return 0
    fi
  done
  return 1
}

# Replace known secrets in command output before it is appended to the log.
redact_secrets() {
  set +x
  local text="$1"
  shift
  local secret
  for secret in "$@" "${AUTH_TOKEN:-}" "${existing_token:-}"; do
    [[ -n $secret ]] || continue
    text=${text//"$secret"/'***'}
  done
  builtin printf '%s\n' "$text"
}

# Runs a command; on failure sets SEAF_RC / SEAF_OUT and returns non-zero
# without exiting. Logs a redacted command line always.
#
# Account token: seaf-cli reads [account] token from the -C file (verified on
# seaf-cli 9.0.21). It is not passed as -T.
# Library password: seaf-cli has no file or environment option. It uses -e or
# getpass(). With no controlling terminal, getpass reads one line from stdin.
# setsid provides that, and `builtin printf` writes the line so it never
# appears in an external command's argv.
run_seaf_capture() {
  set +x
  local label=$1
  shift
  local libpass="${SEAF_LIBPASS-}"
  SEAF_LIBPASS=""
  prepare_seaf_cmd "$@"
  set +e
  if [[ -n $libpass ]]; then
    if [[ $libpass == *$'\n'* || $libpass == *$'\r'* ]]; then
      unset libpass
      set -e
      fail "Library password must be a single line."
    fi
    if ! command -v setsid >/dev/null 2>&1; then
      unset libpass
      set -e
      fail "setsid is required so the library password can be passed on stdin instead of the command line."
    fi
    SEAF_OUT=$(builtin printf '%s\n' "$libpass" | setsid --wait "${SEAF_CMD[@]}" 2>&1)
  elif seaf_cli_prompts_for_library "$@"; then
    if command -v setsid >/dev/null 2>&1; then
      SEAF_OUT=$(setsid --wait "${SEAF_CMD[@]}" </dev/null 2>&1)
    else
      SEAF_OUT=$("${SEAF_CMD[@]}" </dev/null 2>&1)
    fi
  else
    SEAF_OUT=$("${SEAF_CMD[@]}" 2>&1)
  fi
  SEAF_RC=$?
  set -e
  local logged
  logged=$(redact_secrets "$SEAF_OUT" "$libpass")
  unset libpass
  {
    echo "\$ $(redact_cmd "${SEAF_CMD[@]}")   # $label"
    builtin printf '%s\n' "$logged"
    echo "(exit $SEAF_RC)"
  } >>"$LOG_FILE"
  return "$SEAF_RC"
}

prompt_library_password() {
  gum input --password --placeholder "library password" --prompt "Library password> " || true
}

# Account password (+ optional 2FA) only. Sets AUTH_TOKEN via obtain_token_checked.
# Caller must already have set server + username. Password stays ephemeral.
prompt_account_auth() {
  set +x
  local password tfa
  password=$(gum input --password --placeholder "password" --prompt "Password> ")
  [[ -n $password ]] || fail "Password required."
  tfa=""
  if gum confirm --default=No "This account uses two-factor authentication (2FA)?"; then
    tfa=$(gum input --placeholder "123456" --prompt "2FA code> ")
    [[ -n $tfa ]] || fail "2FA code required when 2FA is enabled."
  fi
  echo "Signing in to $server as $username …"
  obtain_token_checked "$server" "$username" "$password" "$tfa"
  unset password tfa
}

# Repair: keep the leftover server URL unless the user opts to edit it.
accept_repair_server() {
  local saved=$1
  if gum confirm --default=No "Change server URL from ${saved}?"; then
    local raw_server
    raw_server=$(gum input --value "$saved" \
      --placeholder "https://seafile.example.com" \
      --prompt "Server URL> ")
    [[ -n $raw_server ]] || fail "Server URL required."
    accept_server_url "$raw_server"
  else
    accept_server_url "$saved"
  fi
}

# Like run_seaf_capture, but an encrypted library can be retried once.
# The password is collected by gum and written to seaf-cli's stdin, not -e.
run_seaf_allow_libpass() {
  set +x
  local label=$1
  shift
  if run_seaf_capture "$label" "$@"; then
    return 0
  fi
  if is_encrypted_lib_error "$SEAF_OUT" && ! is_auth_error "$SEAF_OUT"; then
    local libpass=""
    echo "This library is encrypted. Encrypted libraries need a library password." >&2
    echo "Enter it now, or leave it empty to abort and re-run setup later." >&2
    libpass=$(prompt_library_password)
    if [[ -n $libpass ]]; then
      SEAF_LIBPASS=$libpass
      unset libpass
      if run_seaf_capture "$label" "$@"; then
        return 0
      fi
    fi
    unset libpass SEAF_LIBPASS
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
  set +x
  local server="$1" username="$2" password="$3" tfa="${4:-}"
  local out rc log_server
  set +e
  # Prefix assignments apply only to this python process. They are not exported,
  # and the script is on stdin so the password is not an argv element.
  # python pops them from os.environ after copying so it does not pass them on.
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

server = os.environ.pop("SERVER").rstrip("/")
username = os.environ.pop("USERNAME")
password = os.environ.pop("PASSWORD")
tfa = os.environ.pop("TFA", "") or ""
datadir = os.environ.pop("DATADIR", "") or ""

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
        os.chmod(datadir, 0o700)
        fd = os.open(idfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
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
  local log_out
  log_out="$out"
  if [[ -n ${password:-} ]]; then
    log_out=${log_out//"$password"/'***'}
  fi
  if [[ -n ${tfa:-} ]]; then
    log_out=${log_out//"$tfa"/'***'}
  fi
  {
    echo "\$ auth-token POST $log_server  # login check"
    # never log token, password, or 2FA code
    if [[ $out == OK$'\t'* ]]; then
      echo "OK (token acquired)"
    else
      builtin printf '%s\n' "$log_out"
    fi
    echo "(exit $rc)"
  } >>"$LOG_FILE"
  unset log_out

  if ((rc != 0)) || [[ $out != OK$'\t'* ]]; then
    local detail
    detail="${out#ERROR$'\t'}"
    detail=$(redact_secrets "$detail" "$password" "$tfa")
    unset password tfa
    fail "Login failed: $(explain_seaf_error "$detail" "$server")"
  fi
  unset password tfa
  AUTH_TOKEN=${out#OK$'\t'}
  unset out
  [[ -n $AUTH_TOKEN ]] || fail "Login returned an empty token."
  write_token_conf "$AUTH_TOKEN"
}

# Prints one pipe-separated binding per line (id|email|server|worktree|token).
read_existing_bindings() {
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
    ORDER BY r.repo_id;
  " 2>/dev/null || true
}

# Sets existing_* globals from a pipe-separated binding row.
load_binding_row() {
  local row=$1
  IFS='|' read -r existing_id existing_email existing_server existing_worktree existing_token <<<"$row"
}

accept_server_url() {
  # Sets server from raw input. Confirms cleartext HTTP. Logs normalization.
  local raw_server="$1"
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
  set +x
  # Full sign-in: server, username, then password (+ optional 2FA).
  local default_server="$1" default_user="$2"
  local raw_server

  raw_server=$(gum input --value "$default_server" --placeholder "https://seafile.example.com" --prompt "Server URL> ")
  [[ -n $raw_server ]] || fail "Server URL required."
  accept_server_url "$raw_server"

  username=$(gum input --value "$default_user" --placeholder "you@example.com" --prompt "Username> ")
  [[ -n $username ]] || fail "Username required."

  prompt_account_auth
}

main() {
  set +x
  install_secrets_trap
  need seaf-cli
  need gum
  ensure_log
  restrict_client_metadata
  log "Starting Seafile setup"

echo "Seafile setup"
echo "Log: $LOG_FILE"
echo

if [[ ! -f "${CONF_DIR}/seafile.ini" ]]; then
  echo "Initializing Seafile client data under ${DATA_PARENT}"
  log "seaf-cli init -d $DATA_PARENT"
  run_seaf "Initialize client" "${SEAF[@]}" init -d "$DATA_PARENT" >/dev/null
fi

if ! timeout 8 "${SEAF[@]}" status >/dev/null 2>&1; then
  echo "Starting seafile daemon…"
  run_seaf "Start daemon" "${SEAF[@]}" start >/dev/null
  wait_for_daemon_sock || fail "Seafile daemon did not create seafile.sock."
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

existing_id=""
existing_email=""
existing_server=""
existing_worktree=""
existing_token=""
mapfile -t _binding_rows < <(read_existing_bindings || true)
if ((${#_binding_rows[@]} == 1)); then
  load_binding_row "${_binding_rows[0]}"
  log "Found leftover binding id=$existing_id email=$existing_email server=$existing_server worktree=$existing_worktree"
elif ((${#_binding_rows[@]} > 1)); then
  echo "Found ${#_binding_rows[@]} leftover library bindings."
  _pick_labels=()
  for i in "${!_binding_rows[@]}"; do
    IFS='|' read -r _bid _bemail _bserver _bwt _btok <<<"${_binding_rows[$i]}"
    # Prefix with index so gum labels stay unique even when worktrees match.
    _pick_labels+=("$((i + 1)). ${_bwt:-?}  (${_bid:0:8}… · ${_bemail:-no-email})")
  done
  _picked=$(printf '%s\n' "${_pick_labels[@]}" | gum choose --header "Which binding should Connect repair?")
  [[ -n ${_picked:-} ]] || fail "No binding selected."
  for i in "${!_pick_labels[@]}"; do
    if [[ ${_pick_labels[$i]} == "$_picked" ]]; then
      load_binding_row "${_binding_rows[$i]}"
      break
    fi
  done
  log "Selected leftover binding id=$existing_id email=$existing_email server=$existing_server worktree=$existing_worktree"
fi
unset _binding_rows _pick_labels _picked _bid _bemail _bserver _bwt _btok i

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
    # Identity comes from the leftover binding. Only the account password
    # (and optional 2FA) is prompted when the saved token is missing or dead.
    accept_repair_server "$existing_server"
    mkdir -p "$existing_worktree"
    username=$existing_email

    if [[ -n $existing_token ]]; then
      echo "Re-attaching with saved token → $existing_worktree"
      write_token_conf "$existing_token"
      clear_clone_tasks_for "$existing_id"
      if run_seaf_allow_libpass "Re-attach library (token)" "${SEAF[@]}" sync \
        -l "$existing_id" \
        -s "$server" \
        -u "$username" \
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
      echo "Continuing with a password login for the same account…"
    else
      echo "No saved token — password required for $existing_email."
    fi

    prompt_account_auth
    echo "Syncing ${existing_id} → ${existing_worktree}"
    clear_clone_tasks_for "$existing_id"
    if ! run_seaf_allow_libpass "Sync library" "${SEAF[@]}" sync \
      -l "$existing_id" \
      -s "$server" \
      -u "$username" \
      -d "$existing_worktree"; then
      if grep -qi 'Task is already in progress' <<<"$SEAF_OUT"; then
        clear_clone_tasks_for "$existing_id"
        run_seaf_allow_libpass "Sync library (retry)" "${SEAF[@]}" sync \
          -l "$existing_id" \
          -s "$server" \
          -u "$username" \
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
remote_json=$(run_seaf "List remote libraries" "${SEAF[@]}" list-remote -s "$server" -u "$username" --json)

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

# Only reuse a leftover worktree when the same library id was selected.
default_folder="${HOME}/$(echo "$lib_name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
if [[ -n $existing_worktree && -n $existing_id && $lib_id == "$existing_id" ]]; then
  default_folder=$existing_worktree
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
  if ! run_seaf_allow_libpass "Sync library" "${SEAF[@]}" sync -l "$lib_id" -s "$server" -u "$username" -d "$folder"; then
    if grep -qi 'Task is already in progress' <<<"$SEAF_OUT"; then
      clear_clone_tasks_for "$lib_id"
      run_seaf_allow_libpass "Sync library (retry)" "${SEAF[@]}" sync -l "$lib_id" -s "$server" -u "$username" -d "$folder" \
        || fail "Sync library: $(explain_seaf_error "$SEAF_OUT" "${server:-}")"
    else
      fail "Sync library: $(explain_seaf_error "$SEAF_OUT" "${server:-}")"
    fi
  fi
else
  parent=$(dirname "$folder")
  mkdir -p "$parent"
  echo "Downloading ${lib_name} under ${parent}"
  if ! run_seaf_allow_libpass "Download library" "${SEAF[@]}" download -l "$lib_id" -s "$server" -u "$username" -d "$parent"; then
    if grep -qi 'Task is already in progress' <<<"$SEAF_OUT"; then
      clear_clone_tasks_for "$lib_id"
      run_seaf_allow_libpass "Download library (retry)" "${SEAF[@]}" download -l "$lib_id" -s "$server" -u "$username" -d "$parent" \
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
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
