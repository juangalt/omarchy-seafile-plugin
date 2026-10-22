#!/usr/bin/env bash
# Interactive Seafile / seaf-cli setup for the Omarchy Seafile plugin.
set -euo pipefail

CONF_DIR="${HOME}/.ccnet"
DATA_PARENT="${HOME}/.seafile-client"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need seaf-cli
need gum

echo "Seafile setup"
echo

if [[ ! -f "${CONF_DIR}/seafile.ini" ]]; then
  echo "Initializing Seafile client data under ${DATA_PARENT}"
  mkdir -p "${DATA_PARENT}"
  seaf-cli init -d "${DATA_PARENT}"
fi

if ! seaf-cli status >/dev/null 2>&1; then
  echo "Starting seafile daemon…"
  seaf-cli start
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

server=$(gum input --placeholder "https://seafile.example.com" --prompt "Server URL> ")
[[ -n $server ]] || { echo "Server URL required"; exit 1; }

username=$(gum input --placeholder "you@example.com" --prompt "Username> ")
[[ -n $username ]] || { echo "Username required"; exit 1; }

password=$(gum input --password --placeholder "password" --prompt "Password> ")
[[ -n $password ]] || { echo "Password required"; exit 1; }

tfa=""
if gum confirm "Use two-factor authentication code?"; then
  tfa=$(gum input --placeholder "123456" --prompt "TFA> ")
fi

echo
echo "Fetching remote libraries…"
list_args=(-s "$server" -u "$username" -p "$password" --json)
[[ -n $tfa ]] && list_args+=(-a "$tfa")

remote_json=$(seaf-cli list-remote "${list_args[@]}") || {
  echo "Failed to list remote libraries. Check server URL and credentials." >&2
  exit 1
}

mapfile -t choices < <(printf '%s\n' "$remote_json" | python3 -c '
import json, sys
try:
    repos = json.load(sys.stdin)
except Exception:
    repos = []
if not isinstance(repos, list):
    repos = []
for r in repos:
    if not isinstance(r, dict):
        continue
    name = str(r.get("name") or "")
    rid = str(r.get("id") or r.get("repo_id") or "")
    if name and rid:
        print(f"{name}\t{rid}")
')

if ((${#choices[@]} == 0)); then
  echo "No remote libraries found (or unexpected list-remote output)." >&2
  echo "Raw output:" >&2
  echo "$remote_json" >&2
  exit 1
fi

picked=$(printf '%s\n' "${choices[@]}" | gum choose --header "Pick a library to sync")
[[ -n $picked ]] || exit 1
lib_name=${picked%%$'\t'*}
lib_id=${picked#*$'\t'}

default_folder="${HOME}/$(echo "$lib_name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
folder=$(gum input --value "$default_folder" --prompt "Local folder> ")
[[ -n $folder ]] || { echo "Folder required"; exit 1; }

mode=$(gum choose --header "How should this library land locally?" \
  "Sync into existing/empty folder (keeps local files)" \
  "Download into a parent directory (Seafile creates the library folder)")

sync_args=(-l "$lib_id" -s "$server" -u "$username" -p "$password")
[[ -n $tfa ]] && sync_args+=(-a "$tfa")

if [[ $mode == Sync* ]]; then
  mkdir -p "$folder"
  echo "Syncing ${lib_name} → ${folder}"
  seaf-cli sync "${sync_args[@]}" -d "$folder"
else
  parent=$(dirname "$folder")
  mkdir -p "$parent"
  echo "Downloading ${lib_name} under ${parent}"
  seaf-cli download "${sync_args[@]}" -d "$parent"
fi

echo
echo "Libraries:"
seaf-cli list || true
echo
echo "Setup complete."
