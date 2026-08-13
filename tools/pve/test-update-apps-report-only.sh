#!/usr/bin/env bash
# Local harness for the report-only trust-root and zero-mutation contract.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET="$SCRIPT_DIR/update-apps.sh"
TEST_ROOT=$(mktemp -d)
ARTIFACT="$TEST_ROOT/artifacts"
BIN="$TEST_ROOT/bin"
CALLS="$TEST_ROOT/pct-calls"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$ARTIFACT/misc" "$ARTIFACT/ct" "$BIN"

printf '%s\n' \
  "BL=''; CL=''; YW=''; GN=''; RD=''; INFO=''; CROSS=''; HOLD=''; YWB=''" \
  'msg_info(){ :; }; msg_ok(){ :; }; msg_error(){ printf "%s\\n" "$*" >&2; }' \
  >"$ARTIFACT/misc/core.func"
printf '%s\n' '# report-only test api helper' >"$ARTIFACT/misc/api.func"
printf '%s\n' 'check_for_gh_release "Test App" "example/test-repo"' >"$ARTIFACT/ct/test-service.sh"

cat >"$BIN/pct" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$PHS_TEST_CALLS"
case "$1" in
list) printf 'VMID NAME STATUS\n101 test running\n102 stopped stopped\n' ;;
config) printf 'tags: community-script\nostype: debian\n' ;;
status) [[ "$2" == 101 ]] && printf 'status: running\n' || printf 'status: stopped\n' ;;
pull) printf '%s\n' '#!/usr/bin/env bash https://example.invalid/ct/test-service.sh' >"$4" ;;
exec) printf '1.0.0\n' ;;
*) printf 'unexpected pct command: %s\n' "$1" >&2; exit 97 ;;
esac
EOF
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"tag_name":"v1.1.0"}'
EOF
cat >"$BIN/mkdir" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'mkdir' >>"$PHS_TEST_CALLS"
exec /bin/mkdir "$@"
EOF
chmod +x "$BIN/pct" "$BIN/curl" "$BIN/mkdir"

write_manifest() {
  : >"$ARTIFACT/manifest.sha256"
  local path
  for path in misc/core.func misc/api.func ct/test-service.sh; do
    sha256sum "$ARTIFACT/$path" | awk -v p="$path" '{print $1 "  " p}' >>"$ARTIFACT/manifest.sha256"
  done
}

run_report() {
  PATH="$BIN:$PATH" PHS_TEST_CALLS="$CALLS" PHS_ARTIFACT_DIR="$ARTIFACT" \
    PHS_ARTIFACT_MANIFEST=manifest.sha256 var_container=101,102 var_skip_confirm=yes \
    var_report_only=yes bash "$TARGET"
}

run_legacy_dry_run() {
  PATH="$BIN:$PATH" PHS_TEST_CALLS="$CALLS" PHS_ARTIFACT_DIR="$ARTIFACT" \
    PHS_ARTIFACT_MANIFEST=manifest.sha256 var_container=101 var_skip_confirm=yes \
    var_dry_run=yes bash "$TARGET"
}

write_manifest
output=$(run_report)
grep -q 'REPORT-ONLY' <<<"$output"
grep -q 'SKIPPED (not running; it will not be started)' <<<"$output"
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push)$' "$CALLS"
! grep -qx 'mkdir' "$CALLS"
: >"$CALLS"
legacy_output=$(run_legacy_dry_run)
grep -q 'REPORT-ONLY' <<<"$legacy_output"
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push|mkdir)$' "$CALLS"

# Explicit unattended execution must fail before loading remote helpers or
# invoking pct. Interactive unattended selection is absent from the target.
: >"$CALLS"
if PATH="$BIN:$PATH" PHS_TEST_CALLS="$CALLS" var_container=101 \
  var_skip_confirm=yes var_unattended=yes bash "$TARGET" >/dev/null 2>&1; then
  printf '%s\n' 'expected unattended execution to fail closed' >&2
  exit 1
fi
[[ ! -s "$CALLS" ]]
! grep -q 'Run updates unattended?' "$TARGET"

# The report dispatch exits before the mutation-capable legacy path. Function
# definitions above it are inert; this asserts the executed dispatch block.
dispatch_block=$(awk '
  /^[[:space:]]*run_report_only$/ { in_dispatch=1 }
  in_dispatch { print }
  in_dispatch && /^[[:space:]]*exit "\$report_status"$/ { exit }
' "$TARGET")
grep -q 'exit "$report_status"' <<<"$dispatch_block"
! grep -Eq 'pct (start|stop|shutdown|reboot|set|restore|push)|vzdump|mkdir -p|update;' <<<"$dispatch_block"
! grep -Eq 'pct restore|restore --force' "$TARGET"

first_hash=$(awk 'NR == 1 {print substr($1, 1, 1)}' "$ARTIFACT/manifest.sha256")
[[ "$first_hash" == 0 ]] && replacement=1 || replacement=0
sed -i "1s/^./$replacement/" "$ARTIFACT/manifest.sha256"
if run_report >/dev/null 2>&1; then
  printf '%s\n' 'expected digest mismatch to fail' >&2
  exit 1
fi

write_manifest
printf '%s\n' "$(sha256sum "$ARTIFACT/misc/core.func" | awk '{print $1}')  ../misc/core.func" \
  >>"$ARTIFACT/manifest.sha256"
if run_report >/dev/null 2>&1; then
  printf '%s\n' 'expected traversal manifest entry to fail' >&2
  exit 1
fi

write_manifest
sed -n '1p' "$ARTIFACT/manifest.sha256" >>"$ARTIFACT/manifest.sha256"
if run_report >/dev/null 2>&1; then
  printf '%s\n' 'expected duplicate required manifest entry to fail' >&2
  exit 1
fi

write_manifest
sed -i '\|  ct/test-service.sh$|d' "$ARTIFACT/manifest.sha256"
if run_report >/dev/null 2>&1; then
  printf '%s\n' 'expected missing service manifest entry to fail' >&2
  exit 1
fi

write_manifest
mv "$ARTIFACT/misc/core.func" "$TEST_ROOT/core.outside"
ln -s "$TEST_ROOT/core.outside" "$ARTIFACT/misc/core.func"
sed -i "s|  misc/core.func$|  misc/core.func|" "$ARTIFACT/manifest.sha256"
sed -i "1s|^[0-9a-f]*|$(sha256sum "$TEST_ROOT/core.outside" | awk '{print $1}')|" "$ARTIFACT/manifest.sha256"
if run_report >/dev/null 2>&1; then
  printf '%s\n' 'expected symlink escape to fail' >&2
  exit 1
fi

printf '%s\n' 'report-only artifact and zero-mutation tests passed'
