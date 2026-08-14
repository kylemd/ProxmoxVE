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
printf '%s\n' 'check_for_gh_release "Pinned App" "example/pinned-repo" "v1.0.5" "held for verification"' >"$ARTIFACT/ct/pinned-service.sh"
printf '%s\n' 'check_for_gh_release "Dynamic App" "example/dynamic-repo" "$DYNAMIC_PIN"' >"$ARTIFACT/ct/dynamic-service.sh"
printf '%s\n' '# cloudflared is reported through the configured APT source' >"$ARTIFACT/ct/cloudflared.sh"
printf '%s\n' '# n8n is reported through global npm latest' >"$ARTIFACT/ct/n8n.sh"
printf '%s\n' '# deliberately unsupported update metadata' >"$ARTIFACT/ct/unsupported.sh"

cat >"$BIN/pct" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$PHS_TEST_CALLS"
case "$1" in
list) printf 'VMID NAME STATUS\n101 test running\n102 stopped stopped\n' ;;
config) printf 'tags: community-script\nostype: debian\n' ;;
  status)
    printf 'status:%s\n' "$2" >>"$PHS_TEST_CALLS"
    if [[ "$2" == "${PHS_TEST_STATUS_ERROR_VMID:-}" ]]; then
      printf 'container status is unavailable\n' >&2
      exit 88
    fi
    [[ "$2" == 102 ]] && printf 'status: stopped\n' || printf 'status: running\n'
    ;;
pull)
  printf '%s\n' "$2" >>"$PHS_TEST_PULLS"
  printf '#!/usr/bin/env bash https://example.invalid/ct/%s.sh\n' "${PHS_TEST_SERVICE:-test-service}" >"$4"
  ;;
exec)
  case "$*" in
  *dpkg-query*) [[ -n "${PHS_TEST_APT_CURRENT:-}" ]] || exit 73; printf '%s\n' "$PHS_TEST_APT_CURRENT" ;;
  *apt-cache\ policy*) [[ -n "${PHS_TEST_APT_CANDIDATE:-}" ]] || exit 74; printf 'Installed: %s\nCandidate: %s\n' "${PHS_TEST_APT_CURRENT:-}" "$PHS_TEST_APT_CANDIDATE" ;;
  *n8n\ --version*) [[ -n "${PHS_TEST_NPM_CURRENT:-}" ]] || exit 75; printf '%s\n' "$PHS_TEST_NPM_CURRENT" ;;
  *bash\ -c*) [[ -n "${PHS_TEST_GH_CURRENT:-1.0.0}" ]] || exit 76; printf '%s\n' "${PHS_TEST_GH_CURRENT:-1.0.0}" ;;
  *) printf 'unexpected pct exec: %s\n' "$*" >&2; exit 97 ;;
  esac
  ;;
*) printf 'unexpected pct command: %s\n' "$1" >&2; exit 97 ;;
esac
EOF
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*registry.npmjs.org/n8n/latest*)
  printf '%s\n' 'registry n8n latest' >>"$PHS_TEST_REGISTRY_CALLS"
  [[ "${PHS_TEST_NPM_FAIL:-no}" != yes ]] || exit 77
  [[ -n "${PHS_TEST_NPM_LATEST:-}" ]] || exit 78
  printf '{"version":"%s"}\n' "$PHS_TEST_NPM_LATEST"
  ;;
*api.github.com/repos/*/releases/tags/v1.0.5*)
  printf '%s\n' "$*" >>"$PHS_TEST_GH_RELEASE_CALLS"
  printf '%s\n' '{"tag_name":"v1.0.5"}'
  ;;
*api.github.com/repos/*/releases/latest*)
  printf '%s\n' "$*" >>"$PHS_TEST_GH_RELEASE_CALLS"
  printf '%s\n' '{"tag_name":"v1.1.0"}'
  ;;
*) printf 'unexpected curl: %s\n' "$*" >&2; exit 98 ;;
esac
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
  for path in misc/core.func misc/api.func ct/test-service.sh ct/pinned-service.sh ct/dynamic-service.sh ct/cloudflared.sh ct/n8n.sh ct/unsupported.sh; do
    sha256sum "$ARTIFACT/$path" | awk -v p="$path" '{print $1 "  " p}' >>"$ARTIFACT/manifest.sha256"
  done
}

run_report() {
  PATH="$BIN:$PATH" PHS_TEST_CALLS="$CALLS" PHS_ARTIFACT_DIR="$ARTIFACT" \
    PHS_TEST_REGISTRY_CALLS="$TEST_ROOT/registry-calls" PHS_TEST_GH_RELEASE_CALLS="$TEST_ROOT/gh-release-calls" PHS_TEST_PULLS="$TEST_ROOT/pulls" \
    PHS_ARTIFACT_MANIFEST=manifest.sha256 \
    var_container="${1:-101,102}" var_skip_confirm=yes \
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

# A status lookup failure (including a missing guest) is not a skipped guest.
# Report-only stops before it can inspect a later requested container.
: >"$CALLS"
: >"$TEST_ROOT/pulls"
if status_error_output=$(PHS_TEST_STATUS_ERROR_VMID=101 run_report 101,103 2>&1); then
  printf '%s\n' 'expected container status lookup failure to fail closed' >&2
  exit 1
fi
grep -q 'FAILED (cannot determine container status)' <<<"$status_error_output"
grep -qx 'status:101' "$CALLS"
! grep -qx 'status:103' "$CALLS"
[[ ! -s "$TEST_ROOT/pulls" ]]
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push|mkdir)$' "$CALLS"
: >"$CALLS"
legacy_output=$(run_legacy_dry_run)
grep -q 'REPORT-ONLY' <<<"$legacy_output"
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push|mkdir)$' "$CALLS"

# GitHub release metadata is only successful when current and latest versions
# are both established. Unsupported metadata must fail and be recorded FAILED.
: >"$CALLS"
: >"$TEST_ROOT/pulls"
if unsupported_output=$(PHS_TEST_SERVICE=unsupported run_report 101,103 2>&1); then
  printf '%s\n' 'expected unsupported metadata to fail closed' >&2
  exit 1
fi
grep -q 'FAILED' <<<"$unsupported_output"
grep -q 'unsupported update metadata' <<<"$unsupported_output"
[[ "$(cat "$TEST_ROOT/pulls")" == 101 ]]
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push|mkdir)$' "$CALLS"

# Literal pinned release metadata must query that exact tag, not generic latest.
: >"$CALLS"
: >"$TEST_ROOT/gh-release-calls"
pinned_output=$(PHS_TEST_SERVICE=pinned-service run_report 101)
grep -q 'update available 1.0.0 → 1.0.5' <<<"$pinned_output"
grep -q 'releases/tags/v1.0.5' "$TEST_ROOT/gh-release-calls"
! grep -q 'releases/latest' "$TEST_ROOT/gh-release-calls"
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push|mkdir)$' "$CALLS"

# Dynamic pins cannot be evaluated without executing the service script, so
# report-only must reject them rather than falling back to generic latest.
: >"$CALLS"
if dynamic_output=$(PHS_TEST_SERVICE=dynamic-service run_report 101 2>&1); then
  printf '%s\n' 'expected dynamic GitHub release metadata to fail closed' >&2
  exit 1
fi
grep -q 'unsupported dynamic GitHub release metadata' <<<"$dynamic_output"
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push|mkdir)$' "$CALLS"

# Cloudflared is APT-managed: report guest current and configured-source
# candidate without apt update/install, and fail if either side is missing.
: >"$CALLS"
cloudflared_output=$(PHS_TEST_SERVICE=cloudflared PHS_TEST_APT_CURRENT=2026.7.2 PHS_TEST_APT_CANDIDATE=2026.8.0 run_report 101)
grep -q 'update available 2026.7.2 → 2026.8.0' <<<"$cloudflared_output"
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push|mkdir)$' "$CALLS"
: >"$CALLS"
if cloudflared_missing_output=$(PHS_TEST_SERVICE=cloudflared PHS_TEST_APT_CURRENT=2026.7.2 run_report 101 2>&1); then
  printf '%s\n' 'expected missing cloudflared candidate to fail closed' >&2
  exit 1
fi
grep -q 'FAILED' <<<"$cloudflared_missing_output"
grep -q 'cannot read cloudflared APT candidate' <<<"$cloudflared_missing_output"
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push|mkdir)$' "$CALLS"

# n8n is npm-managed: report guest n8n --version and use a cache-free registry
# GET for the latest version, avoiding npm's host cache/log writes.
: >"$CALLS"
: >"$TEST_ROOT/registry-calls"
n8n_output=$(PHS_TEST_SERVICE=n8n PHS_TEST_NPM_CURRENT=1.100.0 PHS_TEST_NPM_LATEST=1.101.0 run_report 101)
grep -q 'update available 1.100.0 → 1.101.0' <<<"$n8n_output"
grep -qx 'registry n8n latest' "$TEST_ROOT/registry-calls"
! grep -Eq '^(start|stop|shutdown|reboot|set|restore|push|mkdir)$' "$CALLS"
: >"$CALLS"
if n8n_failure_output=$(PHS_TEST_SERVICE=n8n PHS_TEST_NPM_CURRENT=1.100.0 PHS_TEST_NPM_LATEST=1.101.0 PHS_TEST_NPM_FAIL=yes run_report 101 2>&1); then
  printf '%s\n' 'expected n8n registry failure to fail closed' >&2
  exit 1
fi
grep -q 'FAILED' <<<"$n8n_failure_output"
grep -q 'cannot read latest n8n registry version' <<<"$n8n_failure_output"
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
