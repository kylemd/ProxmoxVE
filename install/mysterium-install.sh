#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: kylemd
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/MysteriumNetwork/node

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing dependencies"
$STD apt install -y \
  ca-certificates \
  curl
msg_ok "Installed dependencies"

msg_info "Preserving resolver configuration"
RESOLVER_SNAPSHOT=$(mktemp)
awk '/^(nameserver|search|domain)[[:space:]]/ { print }' /etc/resolv.conf >"$RESOLVER_SNAPSHOT"
msg_ok "Preserved resolver configuration"

msg_info "Disabling Mysterium provider mode"
systemctl mask mysterium-node.service mysterium-consumer.service >/dev/null 2>&1 || true
msg_ok "Disabled Mysterium provider mode"

fetch_and_deploy_gh_release "myst" "MysteriumNetwork/node" "binary" "latest" "/opt/myst" "myst_linux_amd64.deb"

msg_info "Configuring the container runtime"
systemctl mask mysterium-node.service >/dev/null 2>&1 || true
systemctl mask --now \
  systemd-networkd.service \
  systemd-networkd.socket \
  systemd-networkd-wait-online.service \
  systemd-logind.service >/dev/null 2>&1 || true

if [[ -s "$RESOLVER_SNAPSHOT" && -d /etc/resolvconf/resolv.conf.d ]]; then
  install -m 0644 "$RESOLVER_SNAPSHOT" /etc/resolvconf/resolv.conf.d/base
  resolvconf -u
fi
rm -f "$RESOLVER_SNAPSHOT"

sed -i \
  's|^DAEMON_OPTS=.*|DAEMON_OPTS="--keystore.lightweight --log-level=warn --ui.enable=false --tequilapi.address=127.0.0.1 --proxy.bind.address=127.0.0.1"|' \
  /etc/default/mysterium-node
systemctl reset-failed
msg_ok "Configured the container runtime"

systemctl unmask mysterium-consumer.service >/dev/null 2>&1
systemctl enable -q --now mysterium-consumer.service
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:4050/healthcheck >/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:4050/healthcheck >/dev/null

motd_ssh
customize
cleanup_lxc
