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

msg_info "Disk check (Images + Feed brauchen ~15-25 GB frei)"
DATA_DIR="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
FREE_GB="$(df -BG "$DATA_DIR" 2>/dev/null | awk 'NR==2{sub(/G/,"",$4); print $4+0}')"
msg_info "Frei auf $DATA_DIR: ${FREE_GB:-?} GB"
if [[ "${FREE_GB:-0}" -lt 15 ]]; then
  msg_error "Nur ${FREE_GB:-?} GB frei - min. 15 GB noetig! Abhilfe: CT-Platte vergroessern (z.B. pct resize <CTID> rootfs +30G auf 40-60 GB) und erneut laufen lassen."
  exit 1
elif [[ "$FREE_GB" -lt 25 ]]; then
  msg_info "WARN: Weniger als 25 GB frei - kann waehrend Feed-Sync knapp werden."
fi

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

diag() {
  docker compose -f "$INSTALL_DIR/compose.yaml" ps 2>&1 | tail -n 25 || true
  echo "--- scap-data logs (tail 20) ---"
  docker compose -f "$INSTALL_DIR/compose.yaml" logs --tail=20 scap-data 2>&1 | tail -n 20 || true
  echo "--- vulnerability-tests logs (tail 10) ---"
  docker compose -f "$INSTALL_DIR/compose.yaml" logs --tail=10 vulnerability-tests 2>&1 | tail -n 10 || true
  echo "--- Platte / RAM ---"
  df -h /var/lib/docker 2>/dev/null || df -h || true
  free -m || true
}

$STD docker compose -f "$INSTALL_DIR/compose.yaml" pull
msg_info "Starting stack (Retry bis 60 Min: 'scap-data unhealthy' direkt nach Start ist meist transient, Feed laedt noch)"
UP_OK=0
for i in $(seq 1 30); do
  if UP_LOG="$(docker compose -f "$INSTALL_DIR/compose.yaml" up -d 2>&1)"; then UP_OK=1; break; fi
  echo "$UP_LOG" | tail -n 5 || true
  if echo "$UP_LOG" | grep -qi "no space left on device"; then
    msg_error "Platte voll ('no space left on device') - Abbruch. Abhilfe: pct resize <CTID> rootfs +30G (auf 40-60 GB), dann erneut laufen lassen oder 'docker system prune -f && docker compose up -d' im CT."
    diag || true
    exit 1
  fi
  msg_info "'up -d' Versuch $i/30 fehlgeschlagen, warte 120s ..."
  sleep 120
  (( i % 5 == 0 )) && diag || true
done
FALLBACK=0
if [[ "$UP_OK" -ne 1 ]]; then
  msg_info "WARN: 'up -d' nach 60 Min fehlerhaft - Fallback: Kern-Stack ohne Feed-Abhaengigkeiten (Feed sync weiter im Hintergrund)"
  diag || true
  docker compose -f "$INSTALL_DIR/compose.yaml" up -d --no-deps pg-gvm redis-server gvmd gsad gsa nginx ospd-openvas openvasd openvas gvm-tools || true
  FALLBACK=1
fi
systemctl start greenbone-openvas.service || true
echo "greenbone-fallback=$FALLBACK" > "$INSTALL_DIR/.fallback"
docker compose -f "$INSTALL_DIR/compose.yaml" ps || true

msg_info "Waiting for gvmd (max 30 Min, Feed-Wait lief bereits beim Stack-Start)"
GVMD_OK=0
for i in $(seq 1 180); do
  docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --get-users >/dev/null 2>&1 && { GVMD_OK=1; break; }
  (( i % 30 == 0 )) && docker compose -f "$INSTALL_DIR/compose.yaml" ps || true
  sleep 10
done
if [[ "$GVMD_OK" -ne 1 ]]; then
  msg_error "gvmd antwortet nach 30 Min nicht. Diagnose: docker compose -f $INSTALL_DIR/compose.yaml ps + docker compose logs gvmd"
  diag || true
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
msg_ok "Deployed Stack"
echo "### Web-UI Login: https://<CT-IP>/ | User: $ADMIN_USER | Pass: $ADMIN_PASS (auch in $INSTALL_DIR/.admin_pass) ###"

msg_info "Verifying Installation"
systemctl is-active --quiet docker || { msg_error "docker.service nicht aktiv!"; journalctl -u docker --no-pager -n 50; exit 1; }
if systemctl is-active --quiet greenbone-openvas; then
  msg_ok "greenbone-openvas.service laeuft"
else
  msg_info "WARN: greenbone-openvas.service (noch) nicht aktiv - meist Feed noch unvollstaendig (Fallback-Modus). Entscheidend ist der Web-UI-Check."
fi
if [[ "$(cat "$INSTALL_DIR/.fallback" 2>/dev/null || echo none)" == "greenbone-fallback=1" ]]; then
  msg_info "WARN: Fallback-Modus - nach fertigem Feed einmal 'docker compose up -d && systemctl restart greenbone-openvas' im CT ausfuehren."
fi
# nginx: 443 = TLS-App (GSA unter "/", 200), WEB_PORT (9392) = Plain-HTTP,
# nur 301-Redirect auf https:443. 404 zaehlt NICHT als Erfolg (gsad-API!).
WEB_OK=0
for i in $(seq 1 24); do
  if curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1:443/" 2>/dev/null | grep -Eq "200|302"; then WEB_OK=1; break; fi
  if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null | grep -Eq "301|302"; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" -eq 1 ]] || msg_error "Web-UI antwortet noch nicht. Logs pruefen: docker compose -f $INSTALL_DIR/compose.yaml logs nginx gsad"
msg_ok "Web-UI erreichbar (https://<CT-IP>/, Redirect http://<CT-IP>:${WEB_PORT}/)"

motd_ssh
customize
cleanup_lxc
