#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Greenbone-Proxmox-Installer
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/greenbone/openvas-scanner
# Laeuft IM Container, Funktionen kommen via $FUNCTIONS_FILE_PATH (build.func).
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Sparsam-Hinweis: unter ~3.5 GB RAM wird der Stack instabil (Postgres/gvmd OOM).
MEM_MB="$(free -m | awk '/^Mem:/{print $2}')"
if [[ "$MEM_MB" -lt 3500 ]]; then
  msg_error "Nur ${MEM_MB} MB RAM erkannt - Greenbone braucht min. 4096 MB. CT stoppen, RAM erhoehen, neu starten."
fi

WEB_PORT="9392"
INSTALL_DIR="/opt/greenbone"
COMPOSE_URL="https://greenbone.github.io/docs/latest/_static/compose.yaml"
ADMIN_USER="${var_admin_user:-admin}"
ADMIN_PASS="${var_admin_pass:-}"

msg_info "Installing Dependencies (Docker)"
$STD apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list
  $STD apt-get update
  $STD apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
msg_ok "Installed Dependencies"

msg_info "Deploying Greenbone Community Edition (openvas-scanner Stack)"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
if [[ ! -s compose.yaml ]] || ! grep -q "^\s*gvmd:" compose.yaml 2>/dev/null; then
  curl -fSL "$COMPOSE_URL" -o compose.yaml
fi
# LAN-Zugriff: 127.0.0.1 -> 0.0.0.0
sed -i -E 's/127\.0\.0\.1:(443|9392)/0.0.0.0:\1/g' compose.yaml

if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16)"
fi

cat > /etc/systemd/system/greenbone-openvas.service <<EOF
[Unit]
Description=Greenbone Community Edition (OpenVAS) - docker compose
Documentation=https://greenbone.github.io/docs/latest/22.4/container/
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=$(command -v docker) compose -f ${INSTALL_DIR}/compose.yaml up -d
ExecStop=$(command -v docker) compose -f ${INSTALL_DIR}/compose.yaml down
ExecReload=$(command -v docker) compose -f ${INSTALL_DIR}/compose.yaml pull
Restart=no

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable greenbone-openvas.service

$STD docker compose -f "$INSTALL_DIR/compose.yaml" pull
$STD docker compose -f "$INSTALL_DIR/compose.yaml" up -d
systemctl start greenbone-openvas.service || true
docker compose -f "$INSTALL_DIR/compose.yaml" ps || true

msg_info "Waiting for gvmd (Feed-Sync: 30 Min - 2h, max 60 Min Wait)"
msg_info "Hinweis: 'Created' bei gvmd/gsad/nginx ist normal solange Feed-Daten laden (health: starting)"
GVMD_OK=0
for i in $(seq 1 360); do
  docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --get-users >/dev/null 2>&1 && { GVMD_OK=1; break; }
  (( i % 30 == 0 )) && docker compose -f "$INSTALL_DIR/compose.yaml" ps || true
  sleep 10
done
if [[ "$GVMD_OK" -ne 1 ]]; then
  msg_error "gvmd antwortet nach 60 Min nicht. Diagnose: docker compose -f $INSTALL_DIR/compose.yaml ps + docker compose logs gvmd"
  docker compose -f "$INSTALL_DIR/compose.yaml" ps || true
  docker compose -f "$INSTALL_DIR/compose.yaml" logs --tail=50 gvmd || true
  # Nicht sofort hart abbrechen: Admin-Anlage wird trotzdem versucht (idempotent bei Re-Run).
fi
docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --create-user="$ADMIN_USER" 2>/dev/null || true
PASS_OK=0
for i in $(seq 1 12); do
  docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --user="$ADMIN_USER" --new-password="$ADMIN_PASS" && { PASS_OK=1; break; }
  sleep 10
done
[[ "$PASS_OK" -eq 1 ]] || { msg_error "Passwort fuer '$ADMIN_USER' konnte nicht gesetzt werden (gvmd-Logs pruefen)."; docker compose -f "$INSTALL_DIR/compose.yaml" logs --tail=50 gvmd || true; exit 1; }
FEED_OWNER="$(docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --get-users --verbose 2>/dev/null | awk -v u="$ADMIN_USER" '$0~u{print $2; exit}' || true)"
[[ -n "${FEED_OWNER:-}" ]] && docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value "$FEED_OWNER" || true
echo "$ADMIN_USER" > "$INSTALL_DIR/.admin_user"
printf '%s' "$ADMIN_PASS" > "$INSTALL_DIR/.admin_pass"
chmod 600 "$INSTALL_DIR/.admin_pass"
msg_ok "Deployed Stack (Admin: $ADMIN_USER)"

msg_info "Verifying Installation"
systemctl is-active --quiet docker || { msg_error "docker.service nicht aktiv!"; journalctl -u docker --no-pager -n 50; exit 1; }
systemctl is-active --quiet greenbone-openvas || { msg_error "greenbone-openvas.service nicht aktiv!"; journalctl -u greenbone-openvas --no-pager -n 50; exit 1; }
WEB_OK=0
for i in $(seq 1 24); do
  for URL in "https://127.0.0.1:${WEB_PORT}/login" "https://127.0.0.1:443/login" "http://127.0.0.1:${WEB_PORT}/" "http://127.0.0.1:${WEB_PORT}/login"; do
    if curl -sk -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null | grep -Eq "200|302|404"; then WEB_OK=1; break 2; fi
  done
  sleep 10
done
[[ "$WEB_OK" -eq 1 ]] || msg_error "Web-UI antwortet noch nicht (Feed laedt evtl. noch). Fortfahren + Logs pruefen: docker compose -f $INSTALL_DIR/compose.yaml logs -f"
msg_ok "Web-UI erreichbar (https://<CT-IP>:${WEB_PORT}/login)"

motd_ssh
customize
cleanup_lxc
