#!/usr/bin/env bash
# Regression harness for the Reitti nginx tile-cache TLS SNI repair.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
TARGET="$ROOT_DIR/ct/reitti.sh"
TEST_ROOT=$(mktemp -d)
CONFIG="$TEST_ROOT/nginx.conf"
FUNCTION="$TEST_ROOT/repair.sh"
BIN="$TEST_ROOT/bin"
CALLS="$TEST_ROOT/calls"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$BIN"

awk '
  /^function repair_nginx_tile_cache_sni\(\)/ { capture=1 }
  capture {
    print
    opened=gsub(/\{/, "{")
    closed=gsub(/\}/, "}")
    depth+=opened-closed
    if (depth == 0) exit
  }
' "$TARGET" >"$FUNCTION"
grep -Fqx 'function repair_nginx_tile_cache_sni() {' "$FUNCTION"

cat >"$BIN/nginx" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-t" ]]
EOF
cat >"$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PHS_TEST_CALLS:?}"
[[ "$*" == "reload nginx" ]]
EOF
chmod +x "$BIN/nginx" "$BIN/systemctl"

cat >"$CONFIG" <<'EOF'
http {
  server {
    location /custom/ {
      proxy_set_header User-Agent "Reitti/1.0";
      proxy_cache tiles;
    }
  }
}
EOF

run_repair() {
  PATH="$BIN:$PATH" PHS_TEST_CALLS="$CALLS" REITTI_NGINX_CONFIG="$CONFIG" \
    bash -c 'msg_info(){ :; }; msg_ok(){ :; }; source "$1"; repair_nginx_tile_cache_sni' -- "$FUNCTION"
}

: >"$CALLS"
run_repair
grep -qx '      proxy_ssl_server_name on;' "$CONFIG"
grep -Fqx '      proxy_ssl_name $proxy_host;' "$CONFIG"
grep -qx 'reload nginx' "$CALLS"

# Re-running an already-repaired v5 configuration is a no-op: no duplicate
# directives and no unnecessary nginx reload.
: >"$CALLS"
run_repair
[[ $(grep -c '^[[:space:]]*proxy_ssl_server_name on;' "$CONFIG") -eq 1 ]]
[[ $(grep -c '^[[:space:]]*proxy_ssl_name \$proxy_host;' "$CONFIG") -eq 1 ]]
[[ ! -s "$CALLS" ]]

printf '%s\n' 'Reitti nginx tile-cache SNI repair tests passed'
