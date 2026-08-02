#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: kylemd
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/MysteriumNetwork/node

APP="Mysterium"
var_tags="${var_tags:-vpn;proxy;network}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-6}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-1}"
var_tun="${var_tun:-yes}"
var_nesting="${var_nesting:-0}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -x /usr/bin/myst ]]; then
    msg_error "No ${APP} installation found!"
    exit
  fi

  if check_for_gh_release "myst" "MysteriumNetwork/node"; then
    msg_info "Stopping Mysterium consumer"
    systemctl stop mysterium-consumer.service
    systemctl mask mysterium-node.service mysterium-consumer.service >/dev/null 2>&1 || true
    msg_ok "Stopped Mysterium consumer"

    fetch_and_deploy_gh_release "myst" "MysteriumNetwork/node" "binary" "latest" "/opt/myst" "myst_linux_amd64.deb"

    msg_info "Restoring consumer-only mode"
    systemctl mask mysterium-node.service >/dev/null 2>&1 || true
    systemctl unmask mysterium-consumer.service >/dev/null 2>&1
    systemctl enable -q --now mysterium-consumer.service
    msg_ok "Restored consumer-only mode"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} consumer setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}TequilAPI is available only inside the container at:${CL}"
echo -e "${GATEWAY}${BGN}http://127.0.0.1:4050${CL}"
echo -e "${INFO}${YW}Review relay trust, logging, availability, and account-security risks before routing application traffic.${CL}"
