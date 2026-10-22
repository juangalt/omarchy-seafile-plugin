#!/usr/bin/env bash
# Interactive Seafile / seaf-cli setup for the Omarchy Seafile plugin.
set -euo pipefail

CONF_DIR="${HOME}/.ccnet"
DATA_PARENT="${HOME}/.seafile-client"
DATA_DIR="${DATA_PARENT}/seafile-data"
REPO_DB="${DATA_DIR}/repo.db"
LOG_DIR="${HOME}/.local/state/omarchy/plugins/juangalt.seafile"
LOG_FILE="${LOG_DIR}/setup.log"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "Missing required command: $1"
  }
}

ensure_log() {
  mkdir -p "$LOG_DIR"
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

fail() {
  local msg=$1
  echo
  echo "✗ $msg" >&2
  echo
  echo "Details were written to:" >&2
  echo "  $LOG_FILE" >&2
  echo "Open that file if you need the full command output." >&2
  exit 1
}

# Redact -p / -T / --password / --token values before anything hits the log.
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
    -p* | --password=* | -T* | --token=* | -a* | --tfa=* | -e* | --libpasswd=*)
      out+=("${arg%%=*}='***'")
      ;;
    *)
      out+=("$arg")
      ;;
    esac
  done
  printf '%s' "${out[*]}"
}

# seaf-cli requires a scheme. Accept host[:port]/path] and add https://.
normalize_server_url() {
  local raw=${1// /}
  raw=${raw%/}
  if [[ -z $raw ]]; then
    echo ""
    return
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
  if [[ ! $url =~ ^https?:// ]]; then
    echo "Server URL must start with http:// or https:// (got: $url)."
    return 1
  fi
  if [[ $url =~ [[:space:]] ]]; then
    echo "Server URL must not contain spaces."
    return 1
  fi
  return 0
}

is_auth_error() {
  # Seafile often returns HTTP 400 with "Unable to login with provided credentials"
  # for a bad password (not 401). Do NOT match bare "timeout" — Python urlopen
  # tracebacks contain that parameter name on every failure.
  grep -qiE 'HTTP Error 401|HTTP Error 403|HTTP Error 400|HTTPError: HTTP Error 40[013]|Unable to login with provided credentials|incorrect email or password|wrong password|invalid token|non_field_errors' <<<"$1"
}

# Map noisy seaf-cli / urllib failures to one actionable sentence.
explain_seaf_error() {
  local output=$1
  local server=${2:-}

  if grep -q "unknown url type" <<<"$output"; then
    echo "Server URL is missing http:// or https://. Example: https://seafile.example.com"
    return
  fi
  if is_auth_error "$output"; then
    if grep -qiE 'HTTP Error 401|invalid token' <<<"$output"; then
      echo "Saved login token was rejected (401). Sign in again with your password."
    elif grep -qiE 'Unable to login|HTTP Error 400|non_field_errors' <<<"$output"; then
      echo "Username/password rejected by the server. Check credentials, and enable 2FA in the next prompt if your account uses it."
    else
      echo "Login failed. Check username, password, and 2FA."
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
  if grep -qiE 'certificate verify failed|SSLError|ssl\.SSLError' <<<"$output"; then
    echo "TLS/certificate problem talking to the server. Try http:// only if you trust the LAN URL."
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

  local line
  line=$(grep -vE '^(Traceback|File "|  File |    )' <<<"$output" | grep -v '^[[:space:]]*$' | tail -1 || true)
  if [[ -n ${line:-} ]]; then
    echo "$line"
    return
  fi
  echo "Seafile command failed. See the log for the full output."
}

# Runs a command; on failure sets SEAF_RC / SEAF_OUT and returns non-zero
# without exiting. Logs a redacted command line always.
run_seaf_capture() {
  local label=$1
  shift
  set +e
  SEAF_OUT=$("$@" 2>&1)
  SEAF_RC=$?
  set -e
  {
    echo "\$ $(redact_cmd "$@")   # $label"
    # Redact any accidental secret echoes from child output (unlikely).
    echo "$SEAF_OUT" | sed -E 's/(token["'\'']?\s*[:=]\s*)[^[:space:]"',:}]+/\1***/Ig'
    echo "(exit $SEAF_RC)"
  } >>"$LOG_FILE"
  return "$SEAF_RC"
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
# Sets AUTH_TOKEN on success.
obtain_token_checked() {
  local server=$1 username=$2 password=$3 tfa=${4:-}
  local out rc
  set +e
  out=$(
    SERVER="$server" USERNAME="$username" PASSWORD="$password" TFA="$tfa" DATADIR="$DATA_DIR" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.parse, urllib.request, secrets

server = os.environ["SERVER"].rstrip("/")
username = os.environ["USERNAME"]
password = os.environ["PASSWORD"]
tfa = os.environ.get("TFA") or ""
datadir = os.environ.get("DATADIR") or ""

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

headers = {"Content-Type": "application/x-www-form-urlencoded"}
if tfa:
    headers["X-SEAFILE-OTP"] = tfa

req = urllib.request.Request(server + "/api2/auth-token/", data=data, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read().decode("utf-8", errors="replace")
        payload = json.loads(body)
        token = payload.get("token")
        if not token:
            print("ERROR\tServer response had no token field.")
            sys.exit(2)
        print("OK\t" + token)
except urllib.error.HTTPError as exc:
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
except Exception as exc:
    print(f"ERROR\t{exc}")
    sys.exit(1)
PY
  )
  rc=$?
  set -e
  {
    echo "\$ auth-token POST $server  # login check"
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
    if [[ $detail == *"Unable to login"* ]]; then
      fail "Login rejected: wrong username/password${tfa:+, or bad 2FA code}. Server said: Unable to login with provided credentials."
    fi
    fail "Login failed: ${detail:-unknown error}"
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

prompt_login() {
  # Sets: server username AUTH_TOKEN (and uses password ephemerally)
  local default_server=$1 default_user=$2
  local raw_server password tfa

  raw_server=$(gum input --value "$default_server" --placeholder "https://seafile.example.com" --prompt "Server URL> ")
  [[ -n $raw_server ]] || fail "Server URL required."
  server=$(normalize_server_url "$raw_server")
  if [[ $server != "$raw_server" ]]; then
    echo "Using server URL: $server"
    log "Normalized server URL: '$raw_server' -> '$server'"
  fi
  if ! msg=$(validate_server_url "$server"); then
    fail "$msg"
  fi

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
  # password goes out of scope when function returns; do not export it
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
  run_seaf "Initialize client" seaf-cli init -d "$DATA_PARENT" >/dev/null
fi

if ! seaf-cli status >/dev/null 2>&1; then
  echo "Starting seafile daemon…"
  run_seaf "Start daemon" seaf-cli start >/dev/null
  sleep 1
fi

if seaf-cli list 2>/dev/null | awk 'NR>1{found=1} END{exit !found}'; then
  echo
  echo "Local libraries already configured:"
  seaf-cli list || true
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
    server=$(normalize_server_url "$raw_server")
    if [[ $server != "$raw_server" ]]; then
      echo "Using server URL: $server"
      log "Normalized server URL: '$raw_server' -> '$server'"
    fi
    if ! msg=$(validate_server_url "$server"); then
      fail "$msg"
    fi
    mkdir -p "$existing_worktree"
    username=$existing_email

    if [[ -n $existing_token ]]; then
      echo "Re-attaching with saved token → $existing_worktree"
      if run_seaf_capture "Re-attach library (token)" seaf-cli sync \
        -l "$existing_id" \
        -s "$server" \
        -u "$username" \
        -T "$existing_token" \
        -d "$existing_worktree"; then
        echo
        echo "Libraries:"
        seaf-cli list || true
        echo
        echo "Setup complete (re-attached existing binding)."
        log "Repair sync succeeded (token)"
        exit 0
      fi
      why=$(explain_seaf_error "$SEAF_OUT" "$server")
      echo "✗ Token re-attach failed: $why"
      log "Token re-attach failed: $why"
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
    unset password
    echo "Syncing ${existing_id} → ${existing_worktree}"
    run_seaf "Sync library" seaf-cli sync \
      -l "$existing_id" \
      -s "$server" \
      -u "$username" \
      -T "$AUTH_TOKEN" \
      -d "$existing_worktree" >/dev/null
    echo
    echo "Libraries:"
    seaf-cli list || true
    echo
    echo "Setup complete (re-attached with fresh login)."
    log "Repair sync succeeded (password→token)"
    exit 0
  fi
  echo "Continuing with a fresh login…"
  echo
fi

prompt_login "${existing_server:-https://}" "${existing_email:-}"

echo
echo "Fetching remote libraries from $server …"
remote_json=$(run_seaf "List remote libraries" seaf-cli list-remote -s "$server" -u "$username" -T "$AUTH_TOKEN" --json)

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

if [[ $mode == Sync* ]]; then
  mkdir -p "$folder"
  echo "Syncing ${lib_name} → ${folder}"
  run_seaf "Sync library" seaf-cli sync -l "$lib_id" -s "$server" -u "$username" -T "$AUTH_TOKEN" -d "$folder" >/dev/null
else
  parent=$(dirname "$folder")
  mkdir -p "$parent"
  echo "Downloading ${lib_name} under ${parent}"
  run_seaf "Download library" seaf-cli download -l "$lib_id" -s "$server" -u "$username" -T "$AUTH_TOKEN" -d "$parent" >/dev/null
fi

echo
echo "Libraries:"
seaf-cli list || true
echo
echo "Setup complete."
log "Setup finished OK"
