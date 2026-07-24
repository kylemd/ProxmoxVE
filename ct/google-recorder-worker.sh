#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2026 kylemd
# Author: kylemd
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/dylantmoore/google-recorder-cli

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

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /etc/systemd/system/google-recorder-worker.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

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
