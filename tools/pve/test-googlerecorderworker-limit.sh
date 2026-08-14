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
INSTALLER_SERVER="$TEST_ROOT/installer-server.mjs"
UPDATER_SERVER="$TEST_ROOT/updater-server.mjs"
UPDATER_EFFECTIVE_LIMIT_HELPER="$TEST_ROOT/updater-effective-limit.sh"
CALLS="$TEST_ROOT/calls"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$BIN"

extract_heredoc() {
  local source="$1" marker="$2"
  awk -v marker="$marker" '
    $0 ~ "^[[:space:]]*" marker "$" { capture=1; next }
    capture && $0 ~ "^[[:space:]]*EOF$" { exit }
    capture { print }
  ' "$source"
}

extract_heredoc "$INSTALLER" "cat <<'EOF' >/usr/local/sbin/googlerecorderworker-limit" >"$INSTALLER_HELPER"
extract_heredoc "$UPDATER" "cat <<'EOF' >/usr/local/sbin/googlerecorderworker-limit" >"$UPDATER_HELPER"
cmp -s "$INSTALLER_HELPER" "$UPDATER_HELPER"
extract_heredoc "$INSTALLER" "cat <<'EOF' >/opt/google-recorder-worker/server.mjs" >"$INSTALLER_SERVER"
extract_heredoc "$UPDATER" "cat <<'EOF' >/opt/google-recorder-worker/server.mjs" >"$UPDATER_SERVER"
cmp -s "$INSTALLER_SERVER" "$UPDATER_SERVER"
grep -Fqx '      worker_max_list_limit: workerMaxListLimit,' "$INSTALLER_SERVER"
if command -v node >/dev/null 2>&1; then
  node --input-type=module --check <"$INSTALLER_SERVER"
  node --input-type=module --check <"$UPDATER_SERVER"
elif command -v node.exe >/dev/null 2>&1; then
  node.exe --input-type=module --check <"$INSTALLER_SERVER"
  node.exe --input-type=module --check <"$UPDATER_SERVER"
fi

grep -qx 'WORKER_MAX_LIST_LIMIT=100' "$INSTALLER"
[[ $(grep -c '^WORKER_MAX_LIST_LIMIT=100$' "$INSTALLER") -eq 1 ]]
[[ -f "$UPDATER" ]]
[[ ! -e "$ROOT_DIR/ct/google-recorder-worker.sh" ]]

# An update supplies the normal ceiling only when the setting is absent. The
# existing-setting branch must preserve an operator-selected ceiling and verify
# the effective value exposed by the non-sensitive health contract.
update_limit_block=$(awk '
  /if ! grep -q '\''\^WORKER_MAX_LIST_LIMIT='\''/ { capture=1 }
  capture { print }
  capture && /msg_ok "Repaired Worker Limit Control"/ { exit }
' "$UPDATER")
grep -Fq "if ! grep -q '^WORKER_MAX_LIST_LIMIT=' /etc/google-recorder-worker/worker.env; then" <<<"$update_limit_block"
grep -Fq '/usr/local/sbin/googlerecorderworker-limit 100' <<<"$update_limit_block"
grep -Fq 'else' <<<"$update_limit_block"
grep -Fq 'systemctl restart google-recorder-worker' <<<"$update_limit_block"
grep -Fq 'wait_for_worker_effective_limit "$configured_limit"' <<<"$update_limit_block"
grep -Fq 'Verified Worker List Ceiling: ${effective_limit}' <<<"$update_limit_block"
! grep -Fq 'curl -fsS http://127.0.0.1:8787/health >/dev/null' <<<"$update_limit_block"

awk '
  /^function wait_for_worker_effective_limit\(\)/ { capture=1 }
  capture {
    print
    opened=gsub(/\{/, "{")
    closed=gsub(/\}/, "}")
    depth+=opened-closed
    if (depth == 0) exit
  }
' "$UPDATER" >"$UPDATER_EFFECTIVE_LIMIT_HELPER"
grep -Fqx 'function wait_for_worker_effective_limit() {' "$UPDATER_EFFECTIVE_LIMIT_HELPER"

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
set -euo pipefail

case "${PHS_TEST_HEALTH_MODE:-match}" in
  match)
    effective_limit="$(awk -F= '/^WORKER_MAX_LIST_LIMIT=/ { value=$2 } END { print value }' "${PHS_TEST_ENV_FILE:?}")"
    ;;
  mismatch)
    # A requested 1000 remains reported as 100 until the rollback restores 100.
    effective_limit=100
    ;;
  unavailable)
    exit 22
    ;;
  *)
    exit 64
    ;;
esac
printf '{"status":"ok","worker_max_list_limit":%s}\n' "$effective_limit"
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

run_update_effective_limit_check() {
  PATH="$BIN:$PATH" PHS_TEST_ENV_FILE="$ENV_FILE" PHS_TEST_HEALTH_MODE="${1:?health mode required}" \
    bash -c 'source "$1"; wait_for_worker_effective_limit "$2"' -- "$UPDATER_EFFECTIVE_LIMIT_HELPER" "${2:?limit required}"
}

write_env() {
  printf '%s\n' \
    'WORKER_TOKEN=preserved-test-token' \
    'UNRELATED_SETTING=keep-me' \
    'WORKER_MAX_LIST_LIMIT=100' \
    'REAUTH_CONSOLE_URL=http://127.0.0.1:6080/vnc.html' \
    >"$ENV_FILE"
  if [[ "${1:-}" == "duplicate" ]]; then
    printf '%s\n' 'WORKER_MAX_LIST_LIMIT=1000' >>"$ENV_FILE"
  fi
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
  PATH="$BIN:$PATH" PHS_TEST_CALLS="$CALLS" PHS_TEST_ENV_FILE="$ENV_FILE" \
    PHS_TEST_HEALTH_MODE="${1:?health mode required}" \
    "$HELPER" "${@:2}"
}

write_env duplicate
: >"$CALLS"
[[ "$(run_update_effective_limit_check match 1000)" == 1000 ]]
if run_update_effective_limit_check mismatch 1000 >/dev/null 2>&1; then
  printf '%s\n' 'expected update effective-ceiling mismatch to fail' >&2
  exit 1
fi
: >"$CALLS"
output=$(run_helper match 1000)
grep -qx 'Google Recorder worker list ceiling: 1000' <<<"$output"
assert_env 1000
grep -qx 'restart test-google-recorder-worker' "$CALLS"

output=$(run_helper match 100)
grep -qx 'Google Recorder worker list ceiling: 100' <<<"$output"
assert_env 100
[[ $(wc -l <"$CALLS") -eq 2 ]]

before_invalid=$(sha256sum "$ENV_FILE" | awk '{print $1}')
before_calls=$(wc -l <"$CALLS")
if run_helper match 500 >/dev/null 2>&1; then
  printf '%s\n' 'expected unsupported limit to fail' >&2
  exit 1
fi
if run_helper match 100 extra >/dev/null 2>&1; then
  printf '%s\n' 'expected extra argument to fail' >&2
  exit 1
fi
[[ $(sha256sum "$ENV_FILE" | awk '{print $1}') == "$before_invalid" ]]
[[ $(wc -l <"$CALLS") -eq "$before_calls" ]]

write_env
: >"$CALLS"
if mismatch_output=$(run_helper mismatch 1000 2>&1); then
  printf '%s\n' 'expected effective-ceiling mismatch to fail' >&2
  exit 1
fi
grep -Fq 'requested ceiling was not confirmed' <<<"$mismatch_output"
grep -Fq 'previous effective ceiling restored: 100' <<<"$mismatch_output"
assert_env 100
[[ $(wc -l <"$CALLS") -eq 2 ]]
[[ $(grep -c '^restart test-google-recorder-worker$' "$CALLS") -eq 2 ]]

write_env
: >"$CALLS"
if run_helper unavailable 1000 >/dev/null 2>&1; then
  printf '%s\n' 'expected health failure to return non-success' >&2
  exit 1
fi
assert_env 100
[[ $(wc -l <"$CALLS") -eq 2 ]]
[[ $(grep -c '^restart test-google-recorder-worker$' "$CALLS") -eq 2 ]]

printf '%s\n' 'Google Recorder worker limit contract tests passed'
