#!/usr/bin/env bash
# Secrets passed to seaf-cli must not show up in the process list.
# There is no bats/shellcheck suite in this repo; this script is the check.
set -euo pipefail
set +x

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/argv-secrets.XXXXXX")
chmod 700 "$TMP"
TEST_TMP=$TMP
# Pathname expansion of an unquoted secret would see this decoy.
touch "$TMP/lib pass%word-decoy"
cd "$TMP"

# Placeholder values only. Never echo them.
TOKEN='place%holder=token#ok'
# Space, percent, and a glob metacharacter. Must stay literal on stdin.
LIBPASS='lib pass%word*'
ACCOUNT_PASS='acct-pass%word'
TFA_CODE='tfa-placeholder-9'
printf '%s' "$TOKEN" >"$TMP/token-value"
printf '%s' "$LIBPASS" >"$TMP/libpass-value"
printf '%s' "$ACCOUNT_PASS" >"$TMP/account-pass"
printf '%s' "$TFA_CODE" >"$TMP/tfa-code"
chmod 600 "$TMP/token-value" "$TMP/libpass-value" "$TMP/account-pass" "$TMP/tfa-code"

say() { printf '%s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

assert_mode() {
  local path=$1 want=$2
  local got
  got=$(stat -c %a "$path")
  [[ $got == "$want" ]] || die "$path mode is $got, want $want"
}

assert_file_lacks_secrets() {
  local path=$1 label=$2
  python3 - "$path" "$TMP/token-value" "$TMP/libpass-value" "$TMP/account-pass" "$TMP/tfa-code" "$label" <<'PY'
import sys
from pathlib import Path
hay = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
label = sys.argv[6]
for secret_path in sys.argv[2:6]:
    secret = Path(secret_path).read_text(encoding="utf-8")
    if secret and secret in hay:
        print(f"FAIL: {label} contains a secret", file=sys.stderr)
        raise SystemExit(1)
PY
}

# shellcheck source=scripts/setup.sh
source "$ROOT/scripts/setup.sh"

LOG_DIR=$TMP/log
LOG_FILE=$LOG_DIR/setup.log
CONF_DIR=$TMP/ccnet
DATA_PARENT=$TMP/seafile-client
DATA_DIR=$DATA_PARENT/seafile-data
REPO_DB=$DATA_DIR/repo.db

install_secrets_trap() {
  if ((SECRETS_TRAP)); then
    return
  fi
  trap 'cleanup_secrets || true; rm -rf "$TEST_TMP"' EXIT
  trap 'cleanup_secrets || true; rm -rf "$TEST_TMP"; exit 130' INT
  trap 'cleanup_secrets || true; rm -rf "$TEST_TMP"; exit 143' TERM
  SECRETS_TRAP=1
}

# Reject a multi-line token before any private file is installed.
if (write_token_conf $'line1\nline2' >/dev/null 2>&1); then
  die "multi-line token was accepted"
fi

umask 022
mkdir -p "$LOG_DIR" "$CONF_DIR/logs" "$DATA_DIR"
chmod 755 "$LOG_DIR" "$CONF_DIR" "$CONF_DIR/logs" "$DATA_PARENT" "$DATA_DIR"
: >"$LOG_FILE"
chmod 644 "$LOG_FILE"
: >"$REPO_DB"
: >"$CONF_DIR/seafile.ini"
printf '%s\n' '0123456789abcdef0123456789abcdef01234567' >"$DATA_DIR/id"
chmod 644 "$REPO_DB" "$CONF_DIR/seafile.ini" "$DATA_DIR/id"

ensure_log
assert_mode "$LOG_DIR" 700
assert_mode "$LOG_FILE" 600

restrict_client_metadata
assert_mode "$CONF_DIR" 700
assert_mode "$CONF_DIR/logs" 700
assert_mode "$DATA_PARENT" 700
assert_mode "$DATA_DIR" 700
assert_mode "$REPO_DB" 600
assert_mode "$CONF_DIR/seafile.ini" 600
assert_mode "$DATA_DIR/id" 600

write_token_conf "$TOKEN"
assert_mode "$TOKEN_CONF" 600
[[ $TOKEN_CONF == "$LOG_DIR"/token.* ]] || die "token file is not under the private log directory"
python3 - "$TOKEN_CONF" "$TMP/token-value" <<'PY'
import sys
from configparser import ConfigParser
from pathlib import Path
path, secret_path = sys.argv[1:]
token = Path(secret_path).read_text(encoding="utf-8")
raw = Path(path).read_text(encoding="utf-8")
if token in raw:
    print("FAIL: token file stores an unescaped token", file=sys.stderr)
    raise SystemExit(1)
cfg = ConfigParser()
cfg.read(path)
got = cfg.get("account", "token")
if got != token:
    print("FAIL: ConfigParser did not round-trip the token", file=sys.stderr)
    raise SystemExit(1)
if not cfg.sections() or cfg.sections()[0] != "account":
    print("FAIL: token file section is not account", file=sys.stderr)
    raise SystemExit(1)
PY

mkdir -p "$TMP/bin" "$TMP/folder"
cat >"$TMP/bin/seaf-cli" <<'PY'
#!/usr/bin/env python3
"""Stand-in seaf-cli. Records the process list view, then exits."""
import json
import os
import sys
from configparser import ConfigParser
from pathlib import Path

def cmdline(pid):
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return ""
    return raw.replace(b"\x00", b" ").decode("utf-8", "replace")

def parent(pid):
    try:
        text = Path(f"/proc/{pid}/status").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 0
    for line in text.splitlines():
        if line.startswith("PPid:"):
            return int(line.split()[1])
    return 0

ancestors = []
pid = os.getpid()
for _ in range(8):
    if pid <= 1:
        break
    ancestors.append(cmdline(pid))
    nxt = parent(pid)
    if nxt == pid:
        break
    pid = nxt

argv = list(sys.argv)
stdin = ""
if any(arg in ("sync", "download") for arg in argv):
    stdin = sys.stdin.read()

loaded = None
if "-C" in argv:
    idx = argv.index("-C")
    if idx + 1 < len(argv):
        cfg = ConfigParser()
        cfg.read(argv[idx + 1])
        if cfg.sections() and cfg.sections()[0] == "account" and cfg.has_option("account", "token"):
            loaded = cfg.get("account", "token")

environ = Path("/proc/self/environ").read_bytes().replace(b"\x00", b"\n").decode("utf-8", "replace")
record = {
    "argv": argv,
    "ancestors": ancestors,
    "stdin": stdin,
    "loaded_token": loaded,
    "environ": environ,
}
log_path = Path(os.environ["STUB_LOG"])
fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
with os.fdopen(fd, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
sys.stdout.write("loaded:%s\nstdin:%s\n" % (loaded or "", stdin))
if any(arg in ("sync", "download") for arg in argv) and stdin == "":
    sys.stderr.write("Enter password for the library:\nEOFError\n")
    raise SystemExit(1)
raise SystemExit(0)
PY
chmod 700 "$TMP/bin/seaf-cli"
export PATH="$TMP/bin:$PATH"
export STUB_LOG=$TMP/stub.jsonl
: >"$STUB_LOG"
chmod 600 "$STUB_LOG"

AUTH_TOKEN=$TOKEN
# Product path: no -T. Also prove a hostile -T/-e on the function is stripped
# before exec, so it never becomes process argv.
run_seaf_capture "List remote libraries" "${SEAF[@]}" list-remote \
  -s "https://seafile.example.test" -u "user@example.test" --json
run_seaf_capture "Hostile flags" "${SEAF[@]}" list-remote \
  -s "https://seafile.example.test" -u "user@example.test" \
  -T "$TOKEN" -e "$LIBPASS" --json

prompt_library_password() {
  printf '%s' "$LIBPASS"
}
if ! run_seaf_allow_libpass "Sync library" "${SEAF[@]}" sync \
  -l "11111111-2222-3333-4444-555555555555" \
  -s "https://seafile.example.test" \
  -u "user@example.test" \
  -d "$TMP/folder"; then
  die "encrypted-library retry did not succeed"
fi

python3 - "$STUB_LOG" "$TMP/token-value" "$TMP/libpass-value" "$TMP/account-pass" "$TMP/tfa-code" <<'PY'
import json
import sys
from pathlib import Path

log_path, token_path, lib_path, acct_path, tfa_path = sys.argv[1:]
secrets = [
    Path(token_path).read_text(encoding="utf-8"),
    Path(lib_path).read_text(encoding="utf-8"),
    Path(acct_path).read_text(encoding="utf-8"),
    Path(tfa_path).read_text(encoding="utf-8"),
]
rows = [json.loads(line) for line in Path(log_path).read_text(encoding="utf-8").splitlines() if line]
if len(rows) < 3:
    print("FAIL: expected list-remote, hostile, and sync records", file=sys.stderr)
    raise SystemExit(1)

def blob(row):
    return "\n".join(row["ancestors"]) + "\n" + "\n".join(row["argv"]) + "\n" + row["environ"]

for row in rows:
    text = blob(row)
    for secret in secrets:
        if secret and secret in text:
            print("FAIL: secret appeared in seaf-cli argv or environment", file=sys.stderr)
            raise SystemExit(1)
    argv = row["argv"]
    if "-T" in argv or "--token" in argv or "-e" in argv or "--libpasswd" in argv:
        print("FAIL: credential flag reached seaf-cli argv", file=sys.stderr)
        raise SystemExit(1)
    if "-C" not in argv:
        print("FAIL: seaf-cli was not given -C", file=sys.stderr)
        raise SystemExit(1)
    if row["loaded_token"] not in secrets[:1]:
        print("FAIL: -C file did not yield the account token", file=sys.stderr)
        raise SystemExit(1)

sync_rows = [row for row in rows if "sync" in row["argv"]]
if len(sync_rows) != 2:
    print("FAIL: expected a failed sync and a stdin retry", file=sys.stderr)
    raise SystemExit(1)
if sync_rows[0]["stdin"] != "":
    print("FAIL: first sync attempt should not read a library password", file=sys.stderr)
    raise SystemExit(1)
libpass = secrets[1]
if sync_rows[1]["stdin"] != libpass + "\n":
    print("FAIL: library password was not delivered on stdin", file=sys.stderr)
    raise SystemExit(1)
PY

assert_file_lacks_secrets "$LOG_FILE" "setup log"
assert_file_lacks_secrets "$TOKEN_CONF" "token file raw check skipped"
# The token file intentionally contains the escaped token. Re-check only the
# library password, account password, and 2FA code.
python3 - "$TOKEN_CONF" "$TMP/libpass-value" "$TMP/account-pass" "$TMP/tfa-code" <<'PY'
import sys
from pathlib import Path
raw = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
for path in sys.argv[2:]:
    secret = Path(path).read_text(encoding="utf-8")
    if secret and secret in raw:
        print("FAIL: token file contains another secret", file=sys.stderr)
        raise SystemExit(1)
PY

# Login posts the account password and 2FA code through the environment of one
# python process, never as argv. A bash -x trace must not print them either.
mkdir -p "$TMP/pybin"
cat >"$TMP/pybin/python3" <<'PY'
#!/usr/bin/env bash
set +x
if [[ -n ${PASSWORD+x} ]]; then
  /usr/bin/python3 - <<'EOF'
import os
from pathlib import Path
def cmdline(pid):
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\x00", b" ").decode("utf-8", "replace")
    except OSError:
        return ""
self_cmd = cmdline("self")
parent_cmd = cmdline(os.getppid())
grand = ""
try:
    status = Path(f"/proc/{os.getppid()}/status").read_text(encoding="utf-8", errors="replace")
    ppid = next(int(line.split()[1]) for line in status.splitlines() if line.startswith("PPid:"))
    grand = cmdline(ppid)
except (OSError, StopIteration):
    pass
blob = "\n".join((self_cmd, parent_cmd, grand))
password = os.environ.get("PASSWORD", "")
tfa = os.environ.get("TFA", "")
leaked = bool(password and password in blob) or bool(tfa and tfa in blob)
Path(os.environ["LEAK_FLAG"]).write_text("leaked\n" if leaked else "clean\n", encoding="utf-8")
print("OK\tstub-login-token")
EOF
  exit $?
fi
exec /usr/bin/python3 "$@"
PY
chmod 700 "$TMP/pybin/python3"

TRACE=$TMP/xtrace.txt
: >"$TRACE"
chmod 600 "$TRACE"
# The -c script does not contain the secret values; they are read from files.
set +e
bash -x -c '
source "$1"
LOG_DIR=$2
LOG_FILE=$2/setup.log
CONF_DIR=$2/ccnet
DATA_PARENT=$2/client
DATA_DIR=$2/client/seafile-data
REPO_DB=$DATA_DIR/repo.db
mkdir -p "$LOG_DIR" "$DATA_DIR"
export PATH="$3:$PATH"
export LEAK_FLAG=$4
password=$(cat "$5")
tfa=$(cat "$6")
obtain_token_checked "https://seafile.example.test" "user@example.test" "$password" "$tfa"
cp -- "$TOKEN_CONF" "$2/saved-token"
chmod 600 "$2/saved-token"
stat -c %a "$TOKEN_CONF" >"$2/token-mode"
unset password tfa
if [[ -n ${PASSWORD+x} || -n ${password+x} ]]; then
  echo "password still set" >&2
  exit 1
fi
export -p >"$2/exports.txt"
' _ "$ROOT/scripts/setup.sh" "$TMP/login" "$TMP/pybin" "$TMP/leak-flag" \
  "$TMP/account-pass" "$TMP/tfa-code" >"$TMP/login.out" 2>"$TRACE"
login_rc=$?
set -e
[[ $login_rc -eq 0 ]] || die "login helper invocation failed (rc=$login_rc)"
[[ $(cat "$TMP/leak-flag") == clean ]] || die "account password or 2FA code appeared in argv"
assert_file_lacks_secrets "$TRACE" "bash -x trace"
assert_file_lacks_secrets "$TMP/login/setup.log" "login setup log"
python3 - "$TMP/login/exports.txt" "$TMP/account-pass" "$TMP/tfa-code" "$TMP/token-value" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
for path in sys.argv[2:]:
    secret = Path(path).read_text(encoding="utf-8")
    if secret and secret in text:
        print("FAIL: a secret was exported", file=sys.stderr)
        raise SystemExit(1)
if "declare -x PASSWORD" in text or "declare -x TFA" in text:
    print("FAIL: PASSWORD or TFA was exported", file=sys.stderr)
    raise SystemExit(1)
PY
# The acquired token is the stub's fixed placeholder, not the account password.
[[ $(cat "$TMP/login/token-mode") == 600 ]] || die "login token file mode is not 600"
if grep -q -F 'stub-login-token' "$TMP/login/setup.log"; then
  die "login log contains the acquired token"
fi
python3 - "$TMP/login/saved-token" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
if "acct-pass%word" in text or "tfa-placeholder-9" in text:
    print("FAIL: login secret stored in the token file", file=sys.stderr)
    raise SystemExit(1)
if "stub-login-token" not in text:
    print("FAIL: login did not store the acquired token", file=sys.stderr)
    raise SystemExit(1)
PY

# xtrace of the token writer itself.
TRACE2=$TMP/xtrace-token.txt
bash -x -c '
source "$1"
LOG_DIR=$2
LOG_FILE=$2/setup.log
CONF_DIR=$2/ccnet
DATA_PARENT=$2/client
DATA_DIR=$2/client/seafile-data
REPO_DB=$DATA_DIR/repo.db
mkdir -p "$LOG_DIR"
token=$(cat "$3")
write_token_conf "$token"
stat -c %a "$TOKEN_CONF" >"$2/token-mode"
' _ "$ROOT/scripts/setup.sh" "$TMP/token-x" "$TMP/token-value" >"$TMP/token-x.out" 2>"$TRACE2"
assert_file_lacks_secrets "$TRACE2" "token writer xtrace"
[[ $(cat "$TMP/token-x/token-mode") == 600 ]] || die "token writer file mode is not 600"

# Repair keeps the leftover server URL unless the user opts to edit it.
# Default gum confirm answer is No (--default=No).
bash -c '
source "$1"
gum() {
  case "$1" in
    confirm) return 1 ;;
    *) echo "unexpected gum: $*" >&2; return 99 ;;
  esac
}
server=""
accept_repair_server "https://seafile.example.test"
[[ $server == "https://seafile.example.test" ]] || exit 2
' _ "$ROOT/scripts/setup.sh" || die "accept_repair_server should keep the saved HTTPS URL by default"

bash -c '
source "$1"
gum() {
  case "$1" in
    confirm) return 0 ;;
    input)
      # Return an edited URL when repair opts into Change server URL.
      printf "%s\n" "https://other.example.test"
      ;;
    *) echo "unexpected gum: $*" >&2; return 99 ;;
  esac
}
server=""
accept_repair_server "https://seafile.example.test"
[[ $server == "https://other.example.test" ]] || exit 2
' _ "$ROOT/scripts/setup.sh" || die "accept_repair_server should apply an edited URL when confirmed"

# Invalid leftover URL must force an edit prompt (no silent hard-fail).
# https:// alone normalizes/validates as missing host.
bash -c '
source "$1"
gum() {
  case "$1" in
    confirm)
      echo "confirm should not run when saved URL is invalid" >&2
      return 99
      ;;
    input)
      printf "%s\n" "https://fixed.example.test"
      ;;
    *) echo "unexpected gum: $*" >&2; return 99 ;;
  esac
}
server=""
accept_repair_server "https://"
[[ $server == "https://fixed.example.test" ]] || exit 2
' _ "$ROOT/scripts/setup.sh" || die "accept_repair_server should force edit for an invalid saved URL"

say "argv secret checks passed"
