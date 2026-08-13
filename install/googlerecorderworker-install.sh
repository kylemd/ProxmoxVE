#!/usr/bin/env bash

# Copyright (c) 2026 kylemd
# Author: kylemd
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/dylantmoore/google-recorder-cli

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  dbus-x11 \
  jq \
  openbox \
  openssl \
  websockify \
  x11vnc \
  xvfb
msg_ok "Installed Dependencies"

msg_info "Installing Chrome"
setup_deb822_repo \
  "google-chrome" \
  "https://dl.google.com/linux/linux_signing_key.pub" \
  "https://dl.google.com/linux/chrome/deb/" \
  "stable"
$STD apt-get update
$STD apt-get install -y google-chrome-stable
rm -f /etc/apt/sources.list.d/google-chrome.list
msg_ok "Installed Chrome"

NODE_VERSION="22" setup_nodejs

msg_info "Installing noVNC"
$STD apt-get install -y novnc
msg_ok "Installed noVNC"

msg_info "Creating Service Account"
useradd \
  --system \
  --create-home \
  --home-dir /var/lib/google-recorder \
  --shell /usr/sbin/nologin \
  google-recorder
install -d -m 0700 -o google-recorder -g google-recorder \
  /var/lib/google-recorder/.config/google-recorder \
  /var/lib/google-recorder/browser-profile \
  /var/lib/google-recorder/tmp
chown -R google-recorder:google-recorder /var/lib/google-recorder
install -d -m 0750 -o root -g google-recorder /etc/google-recorder-worker
msg_ok "Created Service Account"

fetch_and_deploy_gh_release \
  "google-recorder-cli" \
  "kylemd/google-recorder-cli" \
  "tarball" \
  "latest" \
  "/opt/google-recorder-cli"

msg_info "Installing Google Recorder CLI"
$STD npm ci --prefix /opt/google-recorder-cli
$STD npm run build --prefix /opt/google-recorder-cli
$STD npm prune --omit=dev --prefix /opt/google-recorder-cli
chown -R google-recorder:google-recorder /opt/google-recorder-cli
msg_ok "Installed Google Recorder CLI"

msg_info "Creating Worker API"
install -d -m 0755 /opt/google-recorder-worker
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
    return sendJson(response, 200, { status: 'ok' });
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

cat <<'EOF' >/opt/google-recorder-worker/sync-api-key.mjs
import { chromium } from '/opt/google-recorder-cli/node_modules/playwright-core/index.mjs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const profileDir = '/var/lib/google-recorder/browser-profile';
let apiKey = '';
const context = await chromium.launchPersistentContext(profileDir, {
  channel: 'chrome',
  headless: true,
  args: ['--disable-blink-features=AutomationControlled', '--profile-directory=Default'],
});

try {
  const page = context.pages()[0] || await context.newPage();
  page.on('request', request => {
    const candidate = request.headers()['x-goog-api-key'];
    if (candidate) apiKey = candidate;
  });
  await page.goto('https://recorder.google.com/', {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });
  await page.waitForTimeout(5000);
} finally {
  await context.close();
}

if (!apiKey) throw new Error('Could not observe the Recorder API key');
await execFileAsync('/usr/local/bin/google-recorder-run', ['auth', '--api-key', apiKey]);
await execFileAsync('/usr/local/bin/google-recorder-run', ['auth', '--check']);
EOF

cat <<'EOF' >/usr/local/bin/google-recorder-run
#!/usr/bin/env bash
set -euo pipefail
export HOME=/var/lib/google-recorder
export CLI_SHARED_CHROME_USER_DATA_DIR=/var/lib/google-recorder/browser-profile
export GOOGLE_RECORDER_NO_AUTO_LOGIN=1
exec /usr/bin/node /opt/google-recorder-cli/dist/cli.js "$@"
EOF

cat <<'EOF' >/usr/local/bin/google-recorder-interactive-auth
#!/usr/bin/env bash
set -euo pipefail
export HOME=/var/lib/google-recorder
export DISPLAY=:99
export CLI_SHARED_CHROME_USER_DATA_DIR=/var/lib/google-recorder/browser-profile
export GOOGLE_RECORDER_LOGIN_TIMEOUT_MS=0
unset GOOGLE_RECORDER_NO_AUTO_LOGIN
touch /var/lib/google-recorder/auth.in-progress
trap 'rm -f /var/lib/google-recorder/auth.in-progress' EXIT
/usr/bin/node /opt/google-recorder-cli/dist/cli.js auth
/usr/bin/node /opt/google-recorder-worker/sync-api-key.mjs
EOF

chmod 0755 \
  /usr/local/bin/google-recorder-run \
  /usr/local/bin/google-recorder-interactive-auth
chown -R root:root /opt/google-recorder-worker
chmod 0755 /opt/google-recorder-worker
chmod 0644 /opt/google-recorder-worker/*.mjs
msg_ok "Created Worker API"

msg_info "Creating Credentials"
worker_token="$(openssl rand -hex 32)"
vnc_password="$(openssl rand -hex 6)"
cat <<EOF >/etc/google-recorder-worker/worker.env
WORKER_HOST=0.0.0.0
WORKER_PORT=8787
WORKER_TOKEN=${worker_token}
WORKER_MAX_LIST_LIMIT=100
REAUTH_CONSOLE_URL=http://$(hostname -I | awk '{print $1}'):6080/vnc.html?autoconnect=true&resize=remote
EOF
chmod 0640 /etc/google-recorder-worker/worker.env
chown root:google-recorder /etc/google-recorder-worker/worker.env
x11vnc -storepasswd "$vnc_password" /etc/google-recorder-worker/vnc.pass >/dev/null
chmod 0640 /etc/google-recorder-worker/vnc.pass
chown root:google-recorder /etc/google-recorder-worker/vnc.pass
cat <<EOF >/root/google-recorder-worker-credentials
API token: ${worker_token}
VNC password: ${vnc_password}
EOF
chmod 0600 /root/google-recorder-worker-credentials
unset worker_token vnc_password
msg_ok "Created Credentials"

msg_info "Installing Worker Limit Control"
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

temp_file="$(mktemp "${env_file}.new.XXXXXX")"
rollback_file="$(mktemp "${env_file}.rollback.XXXXXX")"
trap 'rm -f "$temp_file" "$rollback_file"' EXIT
cp -- "$env_file" "$rollback_file"
chown root:google-recorder "$rollback_file"
chmod 0640 "$rollback_file"

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
trap - EXIT

if systemctl restart "$service"; then
  for _ in {1..15}; do
    if curl -fsS http://127.0.0.1:8787/health >/dev/null; then
      rm -f "$rollback_file"
      printf 'Google Recorder worker list ceiling: %s\n' "$limit"
      exit 0
    fi
    sleep 1
  done
fi

mv "$rollback_file" "$env_file"
chown root:google-recorder "$env_file"
chmod 0640 "$env_file"
if systemctl restart "$service"; then
  for _ in {1..15}; do
    if curl -fsS http://127.0.0.1:8787/health >/dev/null; then
      printf 'Google Recorder worker health check failed; previous ceiling configuration restored.\n' >&2
      exit 1
    fi
    sleep 1
  done
fi

printf 'Google Recorder worker health check failed and recovery health could not be confirmed; previous ceiling configuration was restored.\n' >&2
exit 1
EOF
chmod 0755 /usr/local/sbin/googlerecorderworker-limit
chown root:root /usr/local/sbin/googlerecorderworker-limit
ln -sfn /usr/local/sbin/googlerecorderworker-limit /usr/local/bin/googlerecorderworker-limit
msg_ok "Installed Worker Limit Control"

msg_info "Creating Services"
cat <<'EOF' >/etc/systemd/system/google-recorder-display.service
[Unit]
Description=Google Recorder virtual display
After=network.target

[Service]
Type=simple
User=google-recorder
Group=google-recorder
Environment=HOME=/var/lib/google-recorder
ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x800x24 -nolisten tcp
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' >/etc/systemd/system/google-recorder-window-manager.service
[Unit]
Description=Google Recorder window manager
Requires=google-recorder-display.service
After=google-recorder-display.service

[Service]
Type=simple
User=google-recorder
Group=google-recorder
Environment=HOME=/var/lib/google-recorder
Environment=DISPLAY=:99
ExecStart=/usr/bin/openbox
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' >/etc/systemd/system/google-recorder-vnc.service
[Unit]
Description=Google Recorder VNC server
Requires=google-recorder-display.service
After=google-recorder-display.service

[Service]
Type=simple
User=google-recorder
Group=google-recorder
ExecStart=/usr/bin/x11vnc -display :99 -rfbauth /etc/google-recorder-worker/vnc.pass -localhost -forever -shared
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' >/etc/systemd/system/google-recorder-novnc.service
[Unit]
Description=Google Recorder noVNC console
Requires=google-recorder-vnc.service
After=google-recorder-vnc.service

[Service]
Type=simple
User=google-recorder
Group=google-recorder
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 0.0.0.0:6080 127.0.0.1:5900
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' >/etc/systemd/system/google-recorder-auth.service
[Unit]
Description=Interactive Google Recorder authentication
Requires=google-recorder-display.service google-recorder-window-manager.service
After=google-recorder-display.service google-recorder-window-manager.service network-online.target

[Service]
Type=oneshot
User=google-recorder
Group=google-recorder
Environment=HOME=/var/lib/google-recorder
Environment=DISPLAY=:99
ExecStart=/usr/local/bin/google-recorder-interactive-auth
TimeoutStartSec=infinity
EOF

cat <<'EOF' >/etc/systemd/system/google-recorder-auth.path
[Unit]
Description=Watch for Google Recorder reauthentication requests

[Path]
PathChanged=/var/lib/google-recorder/auth.request
Unit=google-recorder-auth.service

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' >/etc/systemd/system/google-recorder-worker.service
[Unit]
Description=Google Recorder worker API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=google-recorder
Group=google-recorder
Environment=HOME=/var/lib/google-recorder
Environment=CLI_SHARED_CHROME_USER_DATA_DIR=/var/lib/google-recorder/browser-profile
Environment=GOOGLE_RECORDER_NO_AUTO_LOGIN=1
EnvironmentFile=/etc/google-recorder-worker/worker.env
WorkingDirectory=/opt/google-recorder-worker
ExecStart=/usr/bin/node /opt/google-recorder-worker/server.mjs
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/google-recorder

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable -q --now \
  google-recorder-display \
  google-recorder-window-manager \
  google-recorder-vnc \
  google-recorder-novnc \
  google-recorder-auth.path \
  google-recorder-worker
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
msg_ok "Created Services"

motd_ssh
customize
cleanup_lxc
