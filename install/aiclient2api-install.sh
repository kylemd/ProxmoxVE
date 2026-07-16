#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Kyle (kyle)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/justlovemaki/AIClient2API

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

NODE_VERSION="22" setup_nodejs
fetch_and_deploy_gh_release "aiclient2api" "justlovemaki/AIClient2API" "tarball" "latest" "/opt/aiclient2api"

msg_info "Configuring AIClient2API"
umask 077
mkdir -p /opt/aiclient2api-data/configs /opt/aiclient2api-data/plugins-user /opt/aiclient2api-data/logs
cp -a /opt/aiclient2api/configs/. /opt/aiclient2api-data/configs/
API_KEY="$(openssl rand -hex 32)"
UI_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
cat <<EOF >/opt/aiclient2api-data/configs/config.json
{
  "REQUIRED_API_KEY": "${API_KEY}",
  "SERVER_PORT": 3000,
  "HOST": "0.0.0.0",
  "MODEL_PROVIDER": "auto",
  "PROMPT_LOG_MODE": "none",
  "LOG_ENABLED": false,
  "TLS_SIDECAR_ENABLED": false,
  "UI_ENABLED": true
}
EOF
cat <<EOF >/opt/aiclient2api-data/configs/pwd
${UI_PASSWORD}
EOF
cat <<EOF >~/aiclient2api.creds
AIClient2API Web UI password: ${UI_PASSWORD}
AIClient2API API key: ${API_KEY}
EOF
chmod 700 /opt/aiclient2api-data /opt/aiclient2api-data/configs /opt/aiclient2api-data/plugins-user /opt/aiclient2api-data/logs
chmod 600 /opt/aiclient2api-data/configs/config.json /opt/aiclient2api-data/configs/pwd ~/aiclient2api.creds
rm -rf /opt/aiclient2api/configs /opt/aiclient2api/src/plugins-user /opt/aiclient2api/logs
ln -s /opt/aiclient2api-data/configs /opt/aiclient2api/configs
ln -s /opt/aiclient2api-data/plugins-user /opt/aiclient2api/src/plugins-user
ln -s /opt/aiclient2api-data/logs /opt/aiclient2api/logs
msg_ok "Configured AIClient2API"

msg_info "Installing AIClient2API"
cd /opt/aiclient2api
$STD npm ci --omit=dev
msg_ok "Installed AIClient2API"

msg_info "Creating Service"
cat <<'EOF' >/etc/systemd/system/aiclient2api.service
[Unit]
Description=AIClient2API Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/aiclient2api
Environment=NODE_ENV=production
ExecStart=/usr/bin/node /opt/aiclient2api/src/core/master.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now aiclient2api
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
