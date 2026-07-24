#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Kyle (kylemd)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/openbao/openbao

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

fetch_and_deploy_gh_release "openbao" "openbao/openbao" "binary" "latest" "/opt/openbao" "openbao_*_linux_amd64.deb"

get_lxc_ip

msg_info "Configuring OpenBao"
create_self_signed_cert "openbao"
mkdir -p /etc/openbao /opt/openbao/data
cat <<EOF >/etc/openbao/openbao.hcl
ui = true

cluster_name = "openbao"
api_addr = "https://${LOCAL_IP}:8200"
cluster_addr = "https://${LOCAL_IP}:8201"

storage "raft" {
  path = "/opt/openbao/data"
  node_id = "openbao-1"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file = "/etc/ssl/openbao/openbao.crt"
  tls_key_file = "/etc/ssl/openbao/openbao.key"
}
EOF
cat <<EOF >/etc/openbao/openbao.env
BAO_ADDR=https://${LOCAL_IP}:8200
BAO_CACERT=/etc/ssl/openbao/openbao.crt
VAULT_ADDR=https://${LOCAL_IP}:8200
VAULT_CACERT=/etc/ssl/openbao/openbao.crt
EOF
chown -R openbao:openbao /etc/openbao /opt/openbao /etc/ssl/openbao
chmod 700 /opt/openbao/data
chmod 600 /etc/ssl/openbao/openbao.key
chmod 644 /etc/ssl/openbao/openbao.crt
msg_ok "Configured OpenBao"

msg_info "Starting OpenBao"
systemctl enable -q --now openbao
msg_ok "Started OpenBao"

motd_ssh
customize
cleanup_lxc
