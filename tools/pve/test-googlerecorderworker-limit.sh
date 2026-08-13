#!/usr/bin/env bash
# Local contract harness for the Google Recorder worker list-ceiling helper.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
INSTALLER="$ROOT_DIR/install/googlerecorderworker-install.sh"
UPDATER="$ROOT_DIR/ct/googlerecorderworker.sh"
TEST_ROOT=$(mktemp -d)
BIN="$TEST_ROOT/bin"
ENV_FILE="$TEST_ROOT/worker.env"
HELPER="$TEST_ROOT/googlerecorderworker-limit"
INSTALLER_HELPER="$TEST_ROOT/installer-helper"
UPDATER_HELPER="$TEST_ROOT/updater-helper"
CALLS="$TEST_ROOT/calls"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$BIN"

extract_limit_helper() {
  local source="$1"
  awk -v marker="cat <<'EOF' >/usr/local/sbin/googlerecorderworker-limit" '
    $0 ~ "^[[:space:]]*" marker "$" { capture=1; next }
    capture && $0 ~ "^[[:space:]]*EOF$" { exit }
    capture { print }
  ' "$source"
}

extract_limit_helper "$INSTALLER" >"$INSTALLER_HELPER"
extract_limit_helper "$UPDATER" >"$UPDATER_HELPER"
cmp -s "$INSTALLER_HELPER" "$UPDATER_HELPER"

grep -qx 'WORKER_MAX_LIST_LIMIT=100' "$INSTALLER"
[[ $(grep -c '^WORKER_MAX_LIST_LIMIT=100$' "$INSTALLER") -eq 1 ]]
[[ -f "$UPDATER" ]]
[[ ! -e "$ROOT_DIR/ct/google-recorder-worker.sh" ]]

# An update supplies the normal ceiling only when the setting is absent. The
# existing-setting branch restarts the worker without invoking the helper, so
# an operator-selected 1000 ceiling survives an in-place Community Script update.
update_limit_block=$(awk '
  /if ! grep -q '\''\^WORKER_MAX_LIST_LIMIT='\''/ { capture=1 }
  capture { print }
  capture && /msg_ok "Repaired Worker Limit Control"/ { exit }
' "$UPDATER")
grep -Fq "if ! grep -q '^WORKER_MAX_LIST_LIMIT=' /etc/google-recorder-worker/worker.env; then" <<<"$update_limit_block"
grep -Fq '/usr/local/sbin/googlerecorderworker-limit 100' <<<"$update_limit_block"
grep -Fq 'else' <<<"$update_limit_block"
grep -Fq 'systemctl restart google-recorder-worker' <<<"$update_limit_block"

sed \
  -e "s|/etc/google-recorder-worker/worker.env|$ENV_FILE|g" \
  -e 's|service="google-recorder-worker"|service="test-google-recorder-worker"|' \
  "$INSTALLER_HELPER" >"$HELPER"
chmod +x "$HELPER"

cat >"$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${PHS_TEST_CALLS:?}"
[[ "$#" -eq 2 && "$1" == "restart" && "$2" == "test-google-recorder-worker" ]]
EOF
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
[[ "${PHS_TEST_HEALTH:-ok}" == "ok" ]]
EOF
cat >"$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$BIN/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/systemctl" "$BIN/curl" "$BIN/sleep" "$BIN/chown"

write_env() {
  printf '%s\n' \
    'WORKER_TOKEN=preserved-test-token' \
    'UNRELATED_SETTING=keep-me' \
    'WORKER_MAX_LIST_LIMIT=100' \
    'REAUTH_CONSOLE_URL=http://127.0.0.1:6080/vnc.html' \
    >"$ENV_FILE"
}

assert_env() {
  local expected_limit="$1"
  [[ $(grep -c '^WORKER_MAX_LIST_LIMIT=' "$ENV_FILE") -eq 1 ]]
  grep -qx "WORKER_MAX_LIST_LIMIT=$expected_limit" "$ENV_FILE"
  grep -qx 'WORKER_TOKEN=preserved-test-token' "$ENV_FILE"
  grep -qx 'UNRELATED_SETTING=keep-me' "$ENV_FILE"
  grep -qx 'REAUTH_CONSOLE_URL=http://127.0.0.1:6080/vnc.html' "$ENV_FILE"
}

run_helper() {
  PATH="$BIN:$PATH" PHS_TEST_CALLS="$CALLS" PHS_TEST_HEALTH="${PHS_TEST_HEALTH:-ok}" \
    "$HELPER" "$@"
}

write_env
: >"$CALLS"
output=$(run_helper 1000)
grep -qx 'Google Recorder worker list ceiling: 1000' <<<"$output"
assert_env 1000
grep -qx 'restart test-google-recorder-worker' "$CALLS"

output=$(run_helper 100)
grep -qx 'Google Recorder worker list ceiling: 100' <<<"$output"
assert_env 100
[[ $(wc -l <"$CALLS") -eq 2 ]]

before_invalid=$(sha256sum "$ENV_FILE" | awk '{print $1}')
before_calls=$(wc -l <"$CALLS")
if run_helper 500 >/dev/null 2>&1; then
  printf '%s\n' 'expected unsupported limit to fail' >&2
  exit 1
fi
if run_helper 100 extra >/dev/null 2>&1; then
  printf '%s\n' 'expected extra argument to fail' >&2
  exit 1
fi
[[ $(sha256sum "$ENV_FILE" | awk '{print $1}') == "$before_invalid" ]]
[[ $(wc -l <"$CALLS") -eq "$before_calls" ]]

PHS_TEST_HEALTH=fail
if run_helper 1000 >/dev/null 2>&1; then
  printf '%s\n' 'expected health failure to return non-success' >&2
  exit 1
fi
assert_env 100
[[ $(wc -l <"$CALLS") -eq 4 ]]
[[ $(grep -c '^restart test-google-recorder-worker$' "$CALLS") -eq 4 ]]

printf '%s\n' 'Google Recorder worker limit contract tests passed'
