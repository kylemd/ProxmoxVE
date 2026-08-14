#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2026 kylemd
# Author: kylemd
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/dylantmoore/google-recorder-cli
# Canonical script ID: googlerecorderworker (matches generated update wrappers).

APP="Google Recorder Worker"
var_tags="${var_tags:-automation;audio}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function wait_for_worker_effective_limit() {
  local expected_limit="$1" health_response effective_limit

  for _ in {1..15}; do
    if health_response="$(curl -fsS http://127.0.0.1:8787/health)"; then
      effective_limit="$(sed -nE 's/.*"worker_max_list_limit"[[:space:]]*:[[:space:]]*(1000|100).*/\1/p' <<<"$health_response")"
      if [[ "$effective_limit" == "$expected_limit" ]]; then
        printf '%s\n' "$effective_limit"
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /etc/systemd/system/google-recorder-worker.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  msg_info "Repairing Worker Limit Control"
  cat <<'EOF' >/opt/google-recorder-worker/server.mjs
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { createReadStream, promises as fs } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const host = process.env.WORKER_HOST || '0.0.0.0';
const port = Number(process.env.WORKER_PORT || 8787);
const token = process.env.WORKER_TOKEN;
const cli = '/usr/local/bin/google-recorder-run';
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const workerMaxListLimit = parseWorkerMaxListLimit(process.env.WORKER_MAX_LIST_LIMIT);
let queue = Promise.resolve();

if (!token) throw new Error('WORKER_TOKEN is required');

function parseWorkerMaxListLimit(value) {
  const limit = Number(value);
  return Number.isSafeInteger(limit) && (limit === 100 || limit === 1000) ? limit : 100;
}

function sendJson(response, statusCode, body) {
  const payload = Buffer.from(JSON.stringify(body));
  response.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Content-Length': payload.length,
    'Cache-Control': 'no-store',
  });
  response.end(payload);
}

function isAuthorized(request) {
  return request.headers.authorization === `Bearer ${token}`;
}

function serialized(task) {
  const next = queue.then(task, task);
  queue = next.catch(() => {});
  return next;
}

async function runCli(args, timeout = 120000) {
  return serialized(() => execFileAsync(cli, args, {
    timeout,
    maxBuffer: 8 * 1024 * 1024,
    env: {
      ...process.env,
      GOOGLE_RECORDER_NO_AUTO_LOGIN: '1',
    },
  }));
}

function authFailure(error) {
  const detail = `${error?.stderr || ''}\n${error?.stdout || ''}\n${error?.message || ''}`;
  return /Authentication expired|Not authenticated|No API key configured|sign in again|Session expired/i.test(detail);
}

async function checkAuth() {
  try {
    await runCli(['list', '--limit', '1', '--json']);
    return { authenticated: true, reauth_required: false };
  } catch (error) {
    return {
      authenticated: false,
      reauth_required: authFailure(error),
      error: authFailure(error) ? 'Google Recorder requires reauthentication' : 'Recorder authentication check failed',
    };
  }
}

const server = createServer(async (request, response) => {
  const requestUrl = new URL(request.url || '/', `http://${request.headers.host || 'localhost'}`);

  if (request.method === 'GET' && requestUrl.pathname === '/health') {
    return sendJson(response, 200, {
      status: 'ok',
      worker_max_list_limit: workerMaxListLimit,
    });
  }

  if (!isAuthorized(request)) {
    return sendJson(response, 401, { error: 'unauthorized' });
  }

  try {
    if (request.method === 'GET' && requestUrl.pathname === '/v1/auth/status') {
      const status = await checkAuth();
      return sendJson(response, status.authenticated ? 200 : 401, status);
    }

    if (request.method === 'POST' && requestUrl.pathname === '/v1/auth/start') {
      await fs.writeFile('/var/lib/google-recorder/auth.request', `${Date.now()}\n`, { mode: 0o600 });
      return sendJson(response, 202, {
        status: 'started',
        console_url: process.env.REAUTH_CONSOLE_URL || null,
      });
    }

    if (request.method === 'GET' && requestUrl.pathname === '/v1/recordings') {
      const requestedLimit = Number(requestUrl.searchParams.get('limit') || 25);
      const limit = Math.max(1, Math.min(workerMaxListLimit, Number.isSafeInteger(requestedLimit) ? requestedLimit : 25));
      try {
        const { stdout } = await runCli(['list', '--limit', String(limit), '--json']);
        return sendJson(response, 200, { recordings: JSON.parse(stdout) });
      } catch (error) {
        if (authFailure(error)) {
          return sendJson(response, 401, {
            error: 'Google Recorder requires reauthentication',
            reauth_required: true,
          });
        }
        throw error;
      }
    }

    const audioMatch = requestUrl.pathname.match(/^\/v1\/recordings\/([^/]+)\/audio$/);
    if (request.method === 'GET' && audioMatch) {
      const recordingId = audioMatch[1];
      if (!uuidPattern.test(recordingId)) {
        return sendJson(response, 400, { error: 'invalid recording id' });
      }

      const outputPath = `/var/lib/google-recorder/tmp/${randomUUID()}.m4a`;
      try {
        await runCli(['audio', recordingId, '--output', outputPath], 900000);
        const stat = await fs.stat(outputPath);
        response.writeHead(200, {
          'Content-Type': 'audio/mp4',
          'Content-Length': stat.size,
          'Content-Disposition': `attachment; filename="${recordingId}.m4a"`,
          'Cache-Control': 'no-store',
        });
        const stream = createReadStream(outputPath);
        stream.on('close', () => fs.unlink(outputPath).catch(() => {}));
        stream.on('error', (error) => response.destroy(error));
        stream.pipe(response);
        return;
      } catch (error) {
        await fs.unlink(outputPath).catch(() => {});
        if (authFailure(error)) {
          return sendJson(response, 401, {
            error: 'Google Recorder requires reauthentication',
            reauth_required: true,
          });
        }
        throw error;
      }
    }

    return sendJson(response, 404, { error: 'not found' });
  } catch (error) {
    console.error(error);
    return sendJson(response, 500, { error: 'internal worker error' });
  }
});

server.listen(port, host, () => {
  console.log(`Google Recorder worker listening on ${host}:${port}`);
});
EOF
  cat <<'EOF' >/usr/local/sbin/googlerecorderworker-limit
#!/usr/bin/env bash
set -euo pipefail

limit="${1:-}"
env_file="/etc/google-recorder-worker/worker.env"
service="google-recorder-worker"

if [[ "$#" -ne 1 || ( "$limit" != "100" && "$limit" != "1000" ) ]]; then
  printf 'Usage: %s {100|1000}\n' "${0##*/}" >&2
  exit 64
fi

if [[ ! -f "$env_file" ]]; then
  printf 'Google Recorder worker environment is missing.\n' >&2
  exit 1
fi

read_effective_limit() {
  local health_response effective_limit
  health_response="$(curl -fsS http://127.0.0.1:8787/health)" || return 1
  effective_limit="$(sed -nE 's/.*"worker_max_list_limit"[[:space:]]*:[[:space:]]*(1000|100).*/\1/p' <<<"$health_response")"
  [[ "$effective_limit" == "100" || "$effective_limit" == "1000" ]] || return 1
  printf '%s\n' "$effective_limit"
}

wait_for_effective_limit() {
  local expected_limit="$1" effective_limit
  for _ in {1..15}; do
    if effective_limit="$(read_effective_limit)" && [[ "$effective_limit" == "$expected_limit" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

prior_effective_limit=""
if prior_effective_limit="$(read_effective_limit)"; then
  :
else
  prior_effective_limit=""
fi

temp_file="$(mktemp "${env_file}.new.XXXXXX")"
rollback_file="$(mktemp "${env_file}.rollback.XXXXXX")"
trap 'rm -f "$temp_file" "$rollback_file"' EXIT
cp -p -- "$env_file" "$rollback_file"

awk -v value="$limit" '
  /^WORKER_MAX_LIST_LIMIT=/ {
    if (!updated++) print "WORKER_MAX_LIST_LIMIT=" value
    next
  }
  { print }
  END {
    if (!updated) print "WORKER_MAX_LIST_LIMIT=" value
  }
' "$env_file" >"$temp_file"

chown root:google-recorder "$temp_file"
chmod 0640 "$temp_file"
mv "$temp_file" "$env_file"

restore_prior_state() {
  local restore_status=0
  if ! mv "$rollback_file" "$env_file"; then
    printf 'Google Recorder worker ceiling rollback could not restore the previous environment.\n' >&2
    return 1
  fi
  if ! systemctl restart "$service"; then
    printf 'Google Recorder worker ceiling rollback could not restart the worker.\n' >&2
    return 1
  fi
  if [[ -n "$prior_effective_limit" ]]; then
    if wait_for_effective_limit "$prior_effective_limit"; then
      printf 'Google Recorder worker previous effective ceiling restored: %s\n' "$prior_effective_limit" >&2
    else
      printf 'Google Recorder worker ceiling rollback restarted the worker but could not confirm the previous effective ceiling.\n' >&2
      restore_status=1
    fi
  fi
  return "$restore_status"
}

if systemctl restart "$service" && wait_for_effective_limit "$limit"; then
  rm -f "$rollback_file"
  printf 'Google Recorder worker list ceiling: %s\n' "$limit"
  exit 0
fi

printf 'Google Recorder worker requested ceiling was not confirmed; restoring the previous configuration.\n' >&2
restore_prior_state || true
exit 1
EOF
  chmod 0755 /usr/local/sbin/googlerecorderworker-limit
  chown root:root /usr/local/sbin/googlerecorderworker-limit
  ln -sfn /usr/local/sbin/googlerecorderworker-limit /usr/local/bin/googlerecorderworker-limit
  chown root:root /opt/google-recorder-worker/server.mjs
  chmod 0644 /opt/google-recorder-worker/server.mjs

  if ! grep -q '^WORKER_MAX_LIST_LIMIT=' /etc/google-recorder-worker/worker.env; then
    /usr/local/sbin/googlerecorderworker-limit 100
  else
    configured_limit="$(sed -nE 's/^WORKER_MAX_LIST_LIMIT=(1000|100)$/\1/p' /etc/google-recorder-worker/worker.env)"
    if [[ "$configured_limit" != "100" && "$configured_limit" != "1000" ]]; then
      msg_error "Google Recorder worker configured list ceiling is invalid"
      exit 1
    fi
    systemctl restart google-recorder-worker
    if ! effective_limit="$(wait_for_worker_effective_limit "$configured_limit")"; then
      msg_error "Google Recorder worker effective list ceiling check failed"
      exit 1
    fi
    msg_ok "Verified Worker List Ceiling: ${effective_limit}"
  fi
  msg_ok "Repaired Worker Limit Control"

  if check_for_gh_release "google-recorder-cli" "kylemd/google-recorder-cli"; then
    msg_info "Updating ${APP}"
    systemctl stop google-recorder-worker
    rm -rf /opt/google-recorder-cli
    fetch_and_deploy_gh_release "google-recorder-cli" "kylemd/google-recorder-cli" "tarball" "latest" "/opt/google-recorder-cli"
    $STD npm ci --prefix /opt/google-recorder-cli
    $STD npm run build --prefix /opt/google-recorder-cli
    $STD npm prune --omit=dev --prefix /opt/google-recorder-cli
    chown -R google-recorder:google-recorder /opt/google-recorder-cli
    systemctl start google-recorder-worker
    for _ in {1..15}; do
      if curl -fsS http://127.0.0.1:8787/health >/dev/null; then
        break
      fi
      sleep 1
    done
    if ! curl -fsS http://127.0.0.1:8787/health >/dev/null; then
      msg_error "Google Recorder worker health check failed"
      exit 1
    fi
    msg_ok "Updated ${APP}"
  fi
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Worker API:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8787${CL}"
echo -e "${INFO}${YW}LAN-only reauthentication console:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:6080/vnc.html?autoconnect=true&resize=remote${CL}"
