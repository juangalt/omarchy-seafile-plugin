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
  printf '%s\n' "$*" | tee -a "$LOG_FILE" >/dev/null
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

# Map noisy seaf-cli / urllib failures to one actionable sentence.
explain_seaf_error() {
  local output=$1
  local server=${2:-}

  if grep -q "unknown url type" <<<"$output"; then
    echo "Server URL is missing http:// or https://. Example: https://seafile.example.com"
    return
  fi
  if grep -qiE 'name or service not known|nodename nor servname|temporary failure in name resolution|could not resolve|failed to resolve' <<<"$output"; then
    echo "Could not resolve the server hostname. Check spelling and DNS/Tailscale."
    return
  fi
  if grep -qiE 'connection refused|could not connect|failed to connect|network is unreachable|timed out|timeout' <<<"$output"; then
    echo "Could not reach ${server:-the server}. Is it online, and is the port correct?"
    return
  fi
  if grep -qiE '401|403|forbidden|unauthorized|incorrect email or password|wrong password|invalid token' <<<"$output"; then
    echo "Login failed. Check username, password, and 2FA (if enabled)."
    return
  fi
  if grep -qiE 'certificate|ssl|tls' <<<"$output"; then
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

  # Fall back: first non-traceback line that looks useful
  local line
  line=$(grep -vE '^(Traceback|File "|  File |    )' <<<"$output" | grep -v '^[[:space:]]*$' | tail -1 || true)
  if [[ -n ${line:-} ]]; then
    echo "$line"
    return
  fi
  echo "Seafile command failed. See the log for the full output."
}

run_seaf() {
  # usage: run_seaf <label> <command...>
  local label=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  {
    echo "\$ $*"
    echo "$out"
    echo "(exit $rc)"
  } >>"$LOG_FILE"
  if ((rc != 0)); then
    local why
    why=$(explain_seaf_error "$out" "${server:-}")
    fail "${label}: ${why}"
  fi
  printf '%s\n' "$out"
}

read_existing_binding() {
  # Prints: repo_id|email|server|worktree|token  or nothing
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

# Prefer repairing the known vault binding without a full re-login when possible.
if [[ -n $existing_id && -n $existing_server && -n $existing_worktree && -n $existing_token && -n $existing_email ]]; then
  echo "Found a previous library binding that is no longer active:"
  echo "  Library : $existing_id"
  echo "  Server  : $existing_server"
  echo "  Folder  : $existing_worktree"
  echo "  Account : $existing_email"
  echo
  if gum confirm "Re-attach that library with the saved token (no password prompt)?"; then
    server=$existing_server
    if ! msg=$(validate_server_url "$server"); then
      fail "$msg"
    fi
    mkdir -p "$existing_worktree"
    echo "Re-attaching → $existing_worktree"
    run_seaf "Re-attach library" seaf-cli sync \
      -l "$existing_id" \
      -s "$server" \
      -u "$existing_email" \
      -T "$existing_token" \
      -d "$existing_worktree" >/dev/null
    echo
    echo "Libraries:"
    seaf-cli list || true
    echo
    echo "Setup complete (re-attached existing binding)."
    log "Repair sync succeeded"
    exit 0
  fi
  echo "Continuing with a fresh login…"
  echo
fi

default_server=${existing_server:-https://}
default_user=${existing_email:-}
default_folder=${existing_worktree:-$HOME/}

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
if gum confirm "Use two-factor authentication code?"; then
  tfa=$(gum input --placeholder "123456" --prompt "TFA> ")
fi

echo
echo "Fetching remote libraries from $server …"
list_args=(-s "$server" -u "$username" -p "$password" --json)
[[ -n $tfa ]] && list_args+=(-a "$tfa")

remote_json=$(run_seaf "List remote libraries" seaf-cli list-remote "${list_args[@]}")

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

if [[ -n $existing_worktree && $lib_id == "$existing_id" ]]; then
  default_folder=$existing_worktree
elif [[ -z $existing_worktree || $default_folder == "$HOME/" ]]; then
  default_folder="${HOME}/$(echo "$lib_name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
fi

folder=$(gum input --value "$default_folder" --prompt "Local folder> ")
[[ -n $folder ]] || fail "Folder required."

mode=$(gum choose --header "How should this library land locally?" \
  "Sync into existing/empty folder (keeps local files)" \
  "Download into a parent directory (Seafile creates the library folder)")

sync_args=(-l "$lib_id" -s "$server" -u "$username" -p "$password")
[[ -n $tfa ]] && sync_args+=(-a "$tfa")

if [[ $mode == Sync* ]]; then
  mkdir -p "$folder"
  echo "Syncing ${lib_name} → ${folder}"
  run_seaf "Sync library" seaf-cli sync "${sync_args[@]}" -d "$folder" >/dev/null
else
  parent=$(dirname "$folder")
  mkdir -p "$parent"
  echo "Downloading ${lib_name} under ${parent}"
  run_seaf "Download library" seaf-cli download "${sync_args[@]}" -d "$parent" >/dev/null
fi

echo
echo "Libraries:"
seaf-cli list || true
echo
echo "Setup complete."
log "Setup finished OK"
