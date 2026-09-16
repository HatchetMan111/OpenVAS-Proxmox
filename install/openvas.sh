#!/usr/bin/env bash
# ============================================================================
# OpenVAS / Greenbone Community Edition - Proxmox LXC Einzeiler-Installer
# ----------------------------------------------------------------------------
# WICHTIG: Das Repo greenbone/openvas-scanner enthaelt NUR den Scanner,
# keine Web-UI. Darum installiert dieses Script den kompletten offiziellen
# Greenbone-Stack (gvmd + gsad + gsa + ospd-openvas + openvas-scanner +
# openvasd + redis + postgres + nginx) per Docker Compose im LXC.
# Ergebnis: Web-UI auf http://<LXC-IP>:9392 (und https://<LXC-IP>), alles
# lokal, reboot-sicher via systemd.
#
# Einzeiler (auf dem Proxmox-Host als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenVAS-Proxmox/main/install/openvas.sh)"
# Debug bei Fehlern:
#   bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenVAS-Proxmox/main/install/openvas.sh)"
#
# Getestet auf: Proxmox VE 8.x, LXC Template debian-12-standard
# Profile: SPARSAM (Default zum Ausprobieren) = 2 CPU / 4 GB RAM / 20 GB.
#   Das ist das dokumentierte Greenbone-Minimum - darunter (z.B. 2 GB) stirbt
#   Postgres/gvmd per OOM, Feed-Sync schlaegt fehl. Nicht weiter abspecken!
#   PRODUKTIV: PROFILE=produktiv (4 CPU / 8 GB / 30 GB, Feed: 60 GB empfohlen).
# Enterprise-Alternative (kostenpflichtig/Trial, kein Community-Build):
#   OPENVAS SCAN Appliance unterstuetzt seit 12/2025 offiziell Proxmox VE
#   (.zst-Backup via /var/lib/vz/dump restoren), braucht aber 2 vCPU /
#   12 GB RAM / 500 GB Disk - also NICHT sparsam. Siehe README.
# Copyright (c) 2026 - MIT License
# Quelle: https://github.com/greenbone/openvas-scanner
# Doku:   https://greenbone.github.io/docs/latest/22.4/container/
# ============================================================================
set -euo pipefail

# ---------------- Variablen (oben, anpassbar) ----------------
APP="${APP:-openvas}"
CTID="${CTID:-}"                          # leer = naechste freie ID via pvesh
HOSTNAME="${HOSTNAME:-openvas}"
PROFILE="${PROFILE:-sparsam}"             # sparsam | produktiv
# Sparsam-Default (Greenbone-Minimum zum Ausprobieren). Override z.B.:
#   PROFILE=produktiv  -> 4 CPU / 8 GB / 30 GB
#   oder direkt CPU=4 RAM=8192 DISK=30
if [[ "$PROFILE" == "produktiv" ]]; then
  CPU="${CPU:-4}"
  RAM="${RAM:-8192}"                      # MB
  DISK="${DISK:-30}"                      # GB
else
  CPU="${CPU:-2}"
  RAM="${RAM:-4096}"                      # MB, NICHT kleiner (OOM-Gefahr!)
  DISK="${DISK:-20}"                      # GB
fi
SWAP="${SWAP:-512}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-debian-12-standard_12.7-1_amd64.tar.zst}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_MODE="${IP_MODE:-dhcp}"                # dhcp oder z.B. 192.168.1.50/24
GW="${GW:-}"                              # z.B. 192.168.1.1 (nur bei statischer IP)
NAMESERVER="${NAMESERVER:-1.1.1.1}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
ONBOOT="${ONBOOT:-1}"
NESTING="${NESTING:-1}"                   # Pflicht fuer Docker im LXC
WEB_PORT="${WEB_PORT:-9392}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"              # leer = zufaellig generieren
COMPOSE_URL="${COMPOSE_URL:-https://greenbone.github.io/docs/latest/_static/compose.yaml}"
INSTALL_DIR="${INSTALL_DIR:-/opt/greenbone}"
LOG_FILE="${LOG_FILE:-/tmp/${APP}-install-$(date +%Y%m%d_%H%M%S).log}"

# ---------------- Debugging: volle Fehlerkette ----------------
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[LOG] Voll-Log: $LOG_FILE (bei Fehlern: Log + 'bash -x' Output posten)"

error_trap() {
  local ec=$?
  local cmd="${BASH_COMMAND:-unbekannt}"
  echo ""
  echo "==================== FEHLER ====================" >&2
  echo "Exit-Code : $ec" >&2
  echo "Befehl    : $cmd" >&2
  echo "Funktion  : ${FUNCNAME[1]:-main} (Zeile ${BASH_LINENO[0]:-?})" >&2
  echo "Stacktrace:" >&2
  local i=0
  while caller $i >&2; do ((i++)) || true; done
  echo "------------------------------------------------" >&2
  echo "Relevante Logs (Host):" >&2
  pct list 2>&1 | tail -n 20 >&2 || true
  if [[ -n "${CTID:-}" ]] && pct status "$CTID" >/dev/null 2>&1; then
    echo "--- pct exec Status im CT $CTID ---" >&2
    pct exec "$CTID" -- systemctl --no-pager --failed 2>&1 | tail -n 30 >&2 || true
    pct exec "$CTID" -- docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1 | tail -n 30 >&2 || true
    # Greenbone-spezifisch: compose-Status + gvmd-Logs (Feed braucht 30 Min - 2h,
    # Container im Status "Created" sind normal solange Feed-Daten laden -> health: starting)
    pct exec "$CTID" -- bash -c 'cd /opt/greenbone 2>/dev/null && docker compose ps 2>&1 | tail -n 30; echo "--- gvmd logs (tail 30) ---"; docker compose logs --tail=30 gvmd 2>&1 | tail -n 30' >&2 || true
    pct exec "$CTID" -- journalctl -u greenbone-openvas --no-pager -n 50 2>&1 | tail -n 50 >&2 || true
  fi
  echo "Tipp: erneut mit 'bash -x' starten fuer Zeilen-Trace." >&2
  echo "=================================================" >&2
  exit "$ec"
}
trap error_trap ERR
trap 'ec=$?; trap - ERR; exit $ec' INT TERM

msg()  { echo -e "[*] $*"; }
ok()   { echo -e "[OK] $*"; }
warn() { echo -e "[WARN] $*" >&2; }

# ---------------- Checks (Proxmox-Host) ----------------
[[ "$(id -u)" -eq 0 ]] || { echo "Bitte als root auf dem Proxmox-Host starten." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct nicht gefunden - kein Proxmox-Host?" >&2; exit 1; }
command -v pvesh >/dev/null || { echo "pvesh nicht gefunden - kein Proxmox-Host?" >&2; exit 1; }

if [[ -z "$CTID" ]]; then
  CTID="$(pvesh get /cluster/nextid)"
  msg "CTID automatisch: $CTID"
fi
if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT $CTID existiert bereits. Loeschen oder CTID=xyz setzen. Status:" >&2
  pct status "$CTID" >&2
  exit 1
fi

# Template sicherstellen
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$(echo "$TEMPLATE" | cut -d_ -f1)"; then
  msg "Aktualisiere Template-Liste + lade $TEMPLATE ..."
  pveam update
  # Fallback: neuestes debian-12-standard Template nehmen
  LATEST="$(pveam available --section system 2>/dev/null | grep -o 'debian-12-standard_[^ ]*amd64.tar.[a-z0-9.]*' | sort -u | tail -n1 || true)"
  if [[ -n "$LATEST" ]]; then TEMPLATE="$LATEST"; msg "Nutze Template: $TEMPLATE"; fi
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
else
  ok "Template vorhanden: $TEMPLATE"
fi

if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 16)"
  msg "Admin-Passwort generiert (wird am Ende angezeigt)."
fi
export ADMIN_PASS  # fuer pct exec Umgebung

# ---------------- LXC erstellen ----------------
msg "Erstelle LXC $CTID ($HOSTNAME): ${CPU}vCPU / ${RAM}MB / ${DISK}GB, $TEMPLATE ..."
NETSTR="name=eth0,bridge=${BRIDGE},ip=${IP_MODE}"
[[ -n "$GW" ]] && NETSTR="${NETSTR},gw=${GW}"

pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CPU" --memory "$RAM" --swap "$SWAP" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "$NETSTR" --nameserver "$NAMESERVER" \
  --onboot "$ONBOOT" --start 0 \
  --unprivileged "$UNPRIVILEGED" \
  --features "nesting=${NESTING},keyctl=1" \
  --tags "community-script;openvas;greenbone;vuln-scanner"

pct start "$CTID"
ok "Container gestartet, warte auf Netzwerk ..."
for i in $(seq 1 30); do
  pct exec "$CTID" -- ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && break
  sleep 4
  [[ "$i" -eq 30 ]] && { echo "Kein Netzwerk im CT nach 120s." >&2; exit 1; }
done
ok "Netzwerk OK."

# ---------------- App im Container installieren ----------------
# Idempotent: laeuft auch bei Re-Run.
# WICHTIG: ADMIN_PASS wird explizit per env uebergeben - pct exec
# vererbt die Host-Umgebung NICHT automatisch.
# Das CT-Skript wird per pct push als Datei uebertragen (statt stdin-Heredoc),
# damit die Fehlerausgabe die kurze Befehlszeile zeigt statt 100+ Zeilen.
msg "Installiere Docker + Greenbone-Stack im Container (Pull 10-30 Min, Feed-Sync 30 Min - 2h) ..."
INNER_TMP="$(mktemp /tmp/greenbone-inner-XXXXXX.sh)"
cat > "$INNER_TMP" <<'INNER_SCRIPT_EOF'
set -euo pipefail
WEB_PORT="$1"; ADMIN_USER="$2"; INSTALL_DIR="$3"; COMPOSE_URL="$4"
ADMIN_PASS="${ADMIN_PASS:?ADMIN_PASS fehlt (Host: pct exec vererbt kein env - Skriptfehler, bitte Issue melden)}"

diag() {
  echo "----- Diagnose -----" >&2
  docker compose -f "$INSTALL_DIR/compose.yaml" ps 2>&1 | tail -n 25 >&2 || true
  echo "--- scap-data logs (tail 20) ---" >&2
  docker compose -f "$INSTALL_DIR/compose.yaml" logs --tail=20 scap-data 2>&1 | tail -n 20 >&2 || true
  echo "--- vulnerability-tests logs (tail 10) ---" >&2
  docker compose -f "$INSTALL_DIR/compose.yaml" logs --tail=10 vulnerability-tests 2>&1 | tail -n 10 >&2 || true
  echo "--- Platte / RAM ---" >&2
  df -h /var/lib/docker 2>/dev/null >&2 || df -h >&2 || true
  free -m >&2 || true
}

echo "[CT] Debian aktualisieren ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl

echo "[CT] Docker installieren (falls fehlt) ..."
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  systemctl enable --now docker
fi
docker --version
docker compose version

echo "[CT] Greenbone-Verzeichnis: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
# compose.yaml: neu laden wenn fehlend, leer oder ohne gvmd-Service (veraltete Datei).
if [[ ! -s compose.yaml ]] || ! grep -q "^\s*gvmd:" compose.yaml 2>/dev/null; then
  echo "[CT] Lade offizielles compose.yaml ..."
  curl -fSL "$COMPOSE_URL" -o compose.yaml
else
  echo "[CT] compose.yaml vorhanden ($(wc -l < compose.yaml) Zeilen), kein Re-Download."
fi

echo "[CT] Ports auf 0.0.0.0 oeffnen (LAN-Zugriff statt nur localhost) ..."
# Offizielles compose bindet nginx auf 127.0.0.1:443 + 127.0.0.1:9392 -> auf 0.0.0.0 umbiegen
sed -i -E 's/127\.0\.0\.1:(443|9392)/0.0.0.0:\1/g' compose.yaml
grep -n "9392\|443" compose.yaml | head -n 10
if ! grep -q "0.0.0.0:${WEB_PORT}" compose.yaml; then
  echo "[CT] WARN: Port-Bindung 0.0.0.0:${WEB_PORT} nicht gefunden - nginx evtl. nur via localhost erreichbar." >&2
fi

echo "[CT] systemd-Unit greenbone-openvas.service anlegen ..."
DOCKER_BIN="$(command -v docker)"
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
WorkingDirectory=$INSTALL_DIR
ExecStart=${DOCKER_BIN} compose -f $INSTALL_DIR/compose.yaml up -d
ExecStop=${DOCKER_BIN} compose -f $INSTALL_DIR/compose.yaml down
ExecReload=${DOCKER_BIN} compose -f $INSTALL_DIR/compose.yaml pull
Restart=no

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable greenbone-openvas.service

echo "[CT] Images ziehen ..."
docker compose -f "$INSTALL_DIR/compose.yaml" pull

echo "[CT] Stack starten ..."
echo "[CT] Hinweis: 'Created' / 'health: starting' bei gvmd/gsad/nginx ist NORMAL solange scap-data/vulnerability-tests laden."
echo "[CT] 'scap-data is unhealthy' kurz nach dem Start ist meist transient (Feed-Download laeuft noch) - es wird bis zu 60 Min neu versucht."
UP_OK=0
for i in $(seq 1 30); do
  if docker compose -f "$INSTALL_DIR/compose.yaml" up -d 2>&1 | tail -n 5; then UP_OK=1; break; fi
  echo "[CT] 'up -d' Versuch $i/30 fehlgeschlagen (Feed laedt evtl. noch), warte 120s ..." >&2
  sleep 120
  if (( i % 5 == 0 )); then
    echo "[CT] ... noch am Warten ($((i*2)) / 60 Min)." >&2
    diag
  fi
done
FALLBACK=0
if [[ "$UP_OK" -ne 1 ]]; then
  echo "[CT] WARN: 'up -d' nach 60 Min weiterhin fehlerhaft - Fallback: Kern-Stack ohne Feed-Abhaengigkeiten starten," >&2
  echo "[CT] damit Web-UI + Admin trotzdem angelegt werden (Feed-Sync laeuft im Hintergrund weiter)." >&2
  diag
  docker compose -f "$INSTALL_DIR/compose.yaml" up -d --no-deps pg-gvm redis-server gvmd gsad gsa nginx ospd-openvas openvasd openvas gvm-tools || true
  FALLBACK=1
fi
systemctl start greenbone-openvas.service || true
echo "greenbone-fallback=$FALLBACK" > "$INSTALL_DIR/.fallback"
echo "[CT] Aktueller Stack-Status:"
docker compose -f "$INSTALL_DIR/compose.yaml" ps || docker ps -a --format 'table {{.Names}}\t{{.Status}}'

echo "[CT] Warte auf gvmd (max 30 Min, Feed-Wait lief bereits beim Stack-Start) ..."
for i in $(seq 1 180); do
  if docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --get-users >/dev/null 2>&1; then
    echo "[CT] gvmd antwortet nach ca. $((i*10))s."
    break
  fi
  if (( i % 30 == 0 )); then
    echo "[CT] ... noch am Warten ($((i*10))s / 1800s). Status:"
    docker compose -f "$INSTALL_DIR/compose.yaml" ps 2>&1 | tail -n 25 || true
  fi
  sleep 10
  if [[ "$i" -eq 180 ]]; then
    echo "[CT] FEHLER: gvmd antwortet nach 30 Min nicht. Diagnose:" >&2
    diag
    echo "[CT] Skript erneut laufen lassen ist idempotent und setzt fort." >&2
  fi
done

echo "[CT] Admin-User setzen: $ADMIN_USER ..."
# create-user schlaegt fehl wenn User existiert -> ok (|| true).
docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --create-user="$ADMIN_USER" 2>/dev/null || true
# Passwort setzen mit Retry (gvmd braucht nach Start ein paar Sekunden).
PASS_OK=0
for i in $(seq 1 12); do
  if docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --user="$ADMIN_USER" --new-password="$ADMIN_PASS" 2>&1; then PASS_OK=1; break; fi
  echo "[CT] Passwort-Setzen Versuch $i/12 fehlgeschlagen, warte 10s ..." >&2
  sleep 10
done
if [[ "$PASS_OK" -ne 1 ]]; then
  echo "[CT] FEHLER: Konnte Passwort fuer '$ADMIN_USER' nicht setzen. gvmd-Logs:" >&2
  docker compose -f "$INSTALL_DIR/compose.yaml" logs --tail=50 gvmd >&2 || true
  exit 1
fi
# Feed-Owner auf Admin setzen (UUID 78eceaec-... = "Feed Import Owner").
# Getrennt in zwei Schritten, damit set -e bei leerer UUID nicht abbricht.
FEED_OWNER="$(docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --get-users --verbose 2>/dev/null | awk -v u="$ADMIN_USER" '$0~u{print $2; exit}' || true)"
if [[ -n "${FEED_OWNER:-}" ]]; then
  docker compose -f "$INSTALL_DIR/compose.yaml" exec -u gvmd -T gvmd gvmd --modify-setting 78eceaec-3385-11ea-b237-28d24461215b --value "$FEED_OWNER" || true
else
  echo "[CT] WARN: Feed-Owner-UUID nicht gefunden, überspringe modify-setting." >&2
fi

echo "$ADMIN_USER" > "$INSTALL_DIR/.admin_user"
printf '%s' "$ADMIN_PASS" > "$INSTALL_DIR/.admin_pass"
chmod 600 "$INSTALL_DIR/.admin_pass"
echo "[CT] Fertig. Feed-Sync laeuft ggf. im Hintergrund weiter (30 Min - 2h bis Scans stabil)."
INNER_SCRIPT_EOF
pct push "$CTID" "$INNER_TMP" /tmp/greenbone-install-inner.sh
pct exec "$CTID" -- chmod 700 /tmp/greenbone-install-inner.sh
rm -f "$INNER_TMP"
pct exec "$CTID" -- env ADMIN_PASS="$ADMIN_PASS" bash /tmp/greenbone-install-inner.sh "$WEB_PORT" "$ADMIN_USER" "$INSTALL_DIR" "$COMPOSE_URL"
ok "Installation im Container abgeschlossen."

# onboot sicherstellen (reboot-sicher)
pct set "$CTID" --onboot 1

# ---------------- Verifikation ----------------
msg "Verifiziere: Service + Web-UI ..."
pct exec "$CTID" -- systemctl is-active --quiet docker
ok "docker.service laeuft."
if pct exec "$CTID" -- systemctl is-active --quiet greenbone-openvas; then
  ok "greenbone-openvas.service laeuft."
else
  warn "greenbone-openvas.service (noch) nicht aktiv - meist Feed noch unvollstaendig (Fallback-Modus)."
  warn "Pruefen: pct exec $CTID -- systemctl status greenbone-openvas --no-pager ; entscheidend ist der Web-UI-Check unten."
fi
if [[ "$(pct exec "$CTID" -- cat "$INSTALL_DIR/.fallback" 2>/dev/null || echo none)" == "greenbone-fallback=1" ]]; then
  warn "Fallback-Modus aktiv: Kern-Stack ohne Feed-Abhaengigkeiten gestartet. Nach fertigem Feed einmal:"
  warn "  pct exec $CTID -- bash -c 'cd $INSTALL_DIR && docker compose up -d && systemctl restart greenbone-openvas'"
fi
CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
[[ -z "$CT_IP" ]] && CT_IP="(DHCP-IP via 'pct exec $CTID -- hostname -I' prüfen)"
msg "Container-IP: $CT_IP"

# HTTP(S)-Check im CT (nginx/gsad), Retry weil Feed-Load dauert.
# nginx lauscht nach compose-Template auf 443 + WEB_PORT (TLS). Aeltere
# Templates nutzten teils http - darum mehrere Kandidaten pruefen.
HTTP_OK=0
for i in $(seq 1 24); do
  for URL in "https://127.0.0.1:${WEB_PORT}/login" "https://127.0.0.1:443/login" "http://127.0.0.1:${WEB_PORT}/" "http://127.0.0.1:${WEB_PORT}/login"; do
    if pct exec "$CTID" -- curl -sk -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null | grep -Eq "200|302|404"; then HTTP_OK=1; break 2; fi
  done
  sleep 10
done
if [[ "$HTTP_OK" -eq 1 ]]; then
  ok "Web-UI antwortet (localhost:${WEB_PORT} im CT)."
else
  warn "Web-UI antwortet noch nicht - Feed lädt evtl. noch. Logs: pct exec $CTID -- docker compose -f $INSTALL_DIR/compose.yaml logs -f"
  warn "Trotzdem fortfahren, URL unten testen + Feed-Status pruefen."
fi

trap - ERR
echo ""
echo "================ FERTIG ================"
echo "Greenbone OpenVAS (Community Edition)"
echo "Container : $CTID ($HOSTNAME)"
echo "Web-UI    : https://$CT_IP:$WEB_PORT  (Login-Seite: https://$CT_IP:$WEB_PORT/login)"
echo "Fallback  : https://$CT_IP (Port 443, gleicher nginx) bzw. http://$CT_IP:$WEB_PORT bei alten Templates"
echo "Login     : $ADMIN_USER / $ADMIN_PASS"
echo "Feed-Sync : dauert 30 Min - 2h! Erst danach scannen."
echo "  Feed-Status: pct exec $CTID -- docker compose -f $INSTALL_DIR/compose.yaml logs -f gvmd"
echo "Reboot    : Container onboot=1, Stack via systemd (greenbone-openvas.service, Restart ueber Docker restart-policy)"
echo "Update    : pct exec $CTID -- bash -c 'cd $INSTALL_DIR && docker compose pull && docker compose up -d'"
echo "Deinstall : pct stop $CTID && pct destroy $CTID"
echo "Log       : $LOG_FILE"
echo "========================================"
