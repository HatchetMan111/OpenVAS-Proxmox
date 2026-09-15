#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Greenbone-Proxmox-Installer
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/greenbone/openvas-scanner
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="OpenVAS"
var_tags="security;scanner;vuln-management"
var_cpu="2"
var_ram="4096"
var_disk="20"
var_os="debian"
var_version="12"
var_unprivileged="1"
var_nesting="1"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /opt/greenbone/compose.yaml ]]; then
    msg_error "Keine OpenVAS-Installation gefunden (/opt/greenbone/compose.yaml fehlt)!"
    exit 1
  fi
  msg_info "Update Greenbone Images"
  cd /opt/greenbone
  $STD docker compose pull
  $STD docker compose up -d
  msg_ok "Update abgeschlossen. Web-UI: http://$(hostname -I | awk '{print $1}'):9392"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:9392${CL}"
echo -e "${TAB}${GATEWAY}${BGN}https://${IP}${CL}"
echo -e "${INFO} Login: admin (Passwort siehe Install-Log im Container: cat /opt/greenbone/.admin_pass)${CL}"
echo -e "${INFO} Hinweis: Feed-Sync dauert 30 Min - 2h bis zum ersten Scan.${CL}"
