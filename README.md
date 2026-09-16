# OpenVAS / Greenbone Community Edition für Proxmox (LXC)

Greenbone Community Edition (vollständiger Stack: Scanner + Manager + Web-UI) als unprivilegierter LXC auf Proxmox VE. Ein Befehl auf dem Host, Rest läuft automatisch im Container per Docker Compose. Reboot-sicher via systemd.

> `greenbone/openvas-scanner` allein hat **keine Web-UI**. Dieses Repo installiert den kompletten offiziellen Stack per Docker Compose — die einzige wartbare Methode im LXC (Source-Build dauert Stunden und bricht oft ab).

## Was wird installiert

| Komponente | Container | Zweck |
|---|---|---|
| openvas-scanner / openvasd / ospd-openvas | `openvas`, `openvasd`, `ospd-openvas` | Scan-Engine + Notus |
| gvmd | `gvmd` | Manager (User, Tasks, Feed-Import) |
| gsad + gsa | `gsad`, `gsa` | Web-Daemon + Web-UI |
| nginx | `nginx` | TLS-Reverse-Proxy, Ports **443 + 9392** (auf `0.0.0.0` geöffnet für LAN) |
| postgres | `pg-gvm`, `pg-gvm-migrator` | Datenbank |
| redis | `redis-server` | Task-Queue |
| Feed-Loader | `vulnerability-tests`, `scap-data`, `cert-bund-data`, `dfn-cert-data`, `data-objects`, `notus-data`, `report-formats`, `gpg-data`, `gvm-config`, `configure-openvas`, `gvm-tools` | NVTs, SCAP, CERT, Notus (Feed + Images: ~15–25 GB) |

Installationspfad im CT: `/opt/greenbone/compose.yaml`, systemd-Unit: `greenbone-openvas.service`, Zugangsdaten: `/opt/greenbone/.admin_user` / `.admin_pass` (600).

## Voraussetzungen

- Proxmox VE 8.x, Internet (Docker Hub + `registry.community.greenbone.net` + Greenbone-Feed erreichbar)
- Template `debian-12-standard` (wird automatisch geladen, wenn fehlend)
- **Minimum: 2 vCPU / 4 GB RAM / 40 GB Disk.** Unter 4 GB RAM sterben Postgres/gvmd per OOM; unter ~15 GB freier Platte bricht Docker per `no space left on device` ab (Images + Feed brauchen ~15–25 GB). Produktiv: 4 vCPU / 8 GB / 60 GB.
- LXC braucht `nesting=1` + `keyctl=1` (setzt das Skript automatisch) für Docker.
- CT-ID frei, Bridge `vmbr0`, Storage `local-lvm` (alles per Env überschreibbar).

## Schnellstart (Proxmox-Host, als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenVAS-Proxmox/main/install/openvas.sh)"
```

Mit Debug-Trace und Voll-Log (bei Fehlern **immer** so starten):

```bash
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenVAS-Proxmox/main/install/openvas.sh)"
# Voll-Log: /tmp/openvas-install-*.log (Pfad steht zu Beginn der Ausgabe)
```

### Beispiele

```bash
# Produktiv-Profil (4 CPU / 8 GB / 60 GB):
PROFILE=produktiv bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenVAS-Proxmox/main/install/openvas.sh)"

# Statische IP:
CTID=150 IP_MODE=192.168.1.50/24 GW=192.168.1.1 \
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenVAS-Proxmox/main/install/openvas.sh)"

# Eigenes Admin-Passwort (sonst zufällig generiert + am Ende angezeigt):
ADMIN_PASS='MeinStarkesPass!' bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenVAS-Proxmox/main/install/openvas.sh)"
```

### Alle Variablen

| Var | Default | Bedeutung |
|---|---|---|
| `PROFILE` | `sparsam` (2 CPU / 4096 MB / 40 GB) | `produktiv` = 4 CPU / 8192 MB / 60 GB |
| `CPU` / `RAM` / `DISK` | s. Profil | Direkt-Override schlägt `PROFILE`. **RAM nie unter 4096!** |
| `CTID` | nächste freie ID (`pvesh get /cluster/nextid`) | Container-ID |
| `HOSTNAME` | `openvas` | CT-Hostname |
| `STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | LXC-Disk- bzw. Template-Storage |
| `BRIDGE` | `vmbr0` | Netzwerk-Bridge |
| `IP_MODE` / `GW` | `dhcp` / leer | Statisch z. B. `IP_MODE=192.168.1.50/24 GW=192.168.1.1` |
| `WEB_PORT` | `9392` | Web-UI-Port (nginx lauscht zusätzlich auf 443) |
| `ADMIN_USER` / `ADMIN_PASS` | `admin` / zufällig (16 Zeichen) | Web-UI-Login |
| `INSTALL_DIR` | `/opt/greenbone` | Pfad im CT |
| `COMPOSE_URL` | Greenbone-Docs `compose.yaml` | Nur bei Bedarf überschreiben (Version pinnen) |

## Nach der Installation

1. **Web-UI öffnen:** `https://<LXC-IP>:9392/login` (Fallback `https://<LXC-IP>/login`). Zertifikatswarnung bestätigen (selbstsigniert). Login: `admin` + Passwort aus der Abschlussausgabe (oder `pct exec <CTID> -- cat /opt/greenbone/.admin_pass`).
2. **Feed abwarten:** 30 Min – 2 h bis zum ersten Scan! Status:
   ```bash
   pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose ps && docker compose logs -f gvmd'
   ```
3. **Reboot-Test:**
   ```bash
   pct reboot <CTID> && sleep 60
   pct exec <CTID> -- systemctl is-active docker greenbone-openvas
   curl -sk -o /dev/null -w "%{http_code}\n" https://<LXC-IP>:9392/login  # 200/302 = ok
   ```
4. **Skalieren ohne Neuinstallation:** `pct set <CTID> --cores 4 --memory 8192` + CT-Neustart; Platte: `pct resize <CTID> rootfs +30G` (geht auch nachträglich, ohne Datenverlust).

Sparsam-Tipps: max. 1–2 Ziele, 1 paralleler Scan, kein Full-Port-Range beim ersten Test.

## Fehlerbehebung (häufige Fälle)

### `no space left on device` (Platte voll — häufigster echter Abbruch)

**Was man sieht:** `Error response from daemon: failed to set up container networking: ... no space left on device`, das Skript bricht sofort ab (kein Retry — bei voller Platte zwecklos).

**Ursache:** 20-GB-Disks aus älteren installs reichen nicht: Docker-Images + Greenbone-Feed brauchen **~15–25 GB frei**. Der Preflight-Check meldet unter 15 GB frei ebenfalls sofort.

**Soforthilfe (CT bleibt erhalten, keine Neuinstallation):**

```bash
# 1. Platte vergroessern (Host, geht live, ohne Datenverlust):
pct resize <CTID> rootfs +30G   # auf 40-60 GB gesamt

# 2a. Einfach Installer erneut laufen lassen (idempotent, setzt beim Pull/up fort):
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenVAS-Proxmox/main/install/openvas.sh)"
# 2b. Oder manuell im CT aufraeumen + starten:
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker system prune -f && docker compose up -d'
```

Hinweis: `docker system prune -f` löscht nur ungenutzte Images/Container, **keine Volumes** (Feed-Daten bleiben). Bestehende 20-GB-CTs per `pct resize` retten; neue CTs bekommen automatisch 40 GB (sparsam) bzw. 60 GB (`PROFILE=produktiv`).

### `dependency failed to start: ... scap-data-1 is unhealthy` (häufigster Abbruch)

**Was man sieht:** `docker compose up -d` bricht ab, `gvmd/gsad/nginx` bleiben auf `Created`, `scap-data` steht auf `(unhealthy)`, `vulnerability-tests` auf `(health: starting)`.

**Ursache:** Der SCAP/VT-Feed-Download läuft noch (30 Min – 2 h beim ersten Mal), der eingebaute Healthcheck von `scap-data` schlägt in der Zwischenzeit fehl. Compose verweigert deshalb den Start aller abhängigen Dienste. **Kein Defekt** — nur zu früh.

**Lösung (seit Fix):** Das Skript versucht `up -d` bis zu 60 Min alle 2 Min neu (mit `scap-data`-Logs + Platte/RAM-Diagnose alle 10 Min) und wartet danach noch bis 30 Min auf gvmd. Bleibt der Feed störrisch, startet es den Kern-Stack (`gvmd`, `gsad`, `gsa`, `nginx`, `ospd-openvas`, …) per `--no-deps`, damit Web-UI + Admin trotzdem angelegt werden — der Feed sync im Hintergrund weiter. Erkennbar an der Warnung `Fallback-Modus aktiv`. Nach fertigem Feed einmal im CT:

```bash
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose up -d && systemctl restart greenbone-openvas'
```

Manuell derselbe Weg:

```bash
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose logs --tail=30 scap-data && df -h /var/lib/docker && free -m'
# Abwarten bis scap-data healthy, dann:
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose up -d'
```

Erst wenn `scap-data` über **2 h** `unhealthy` bleibt, liegt ein echtes Problem vor (RAM < 4 GB, Registry/Feed nicht erreichbar — „Platte voll" bricht separat sofort ab, s. oben) — dann die drei Diagnosebefehle oben + `docker compose logs scap-data` sichern und melden.

### `Exit-Code 1` nach `Admin-User setzen` / `gvmd --get-users`

**Ursache:** gvmd läuft noch nicht, weil die Feed-Container (`vulnerability-tests`, `scap-data`: `health: starting`) 30 Min – 2 h laden. `docker ps` zeigt dann `Created` bei `gvmd/gsad/nginx` — **das ist normal**, kein Absturz. Das alte Skript wartete nur 5 Min und brach danach beim Passwort-Setzen ab.

**Lösung (seit Fix):** Skript wartet bis 60 Min mit Statusausgabe alle 5 Min, setzt das Passwort mit 12 Retries und gibt bei Fehlschlag `docker compose logs gvmd` aus. Einfach erneut starten (idempotent) oder manuell:

```bash
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose ps; docker compose logs --tail=50 gvmd'
# Warten bis gvmd antwortet, dann:
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose exec -u gvmd -T gvmd gvmd --get-users'
```

### `ADMIN_PASS fehlt (Host-Export)`

Ältere Version verließ sich auf `export ADMIN_PASS` — `pct exec` vererbt Host-Env aber nicht. Fix: Übergabe per `env ADMIN_PASS=...`. Falls der Fehler trotzdem kommt: Skript aus diesem Repo neu laden (nicht aus Cache/alter URL).

### Web-UI antwortet nicht / Verbindung verweigert

1. Bindung prüfen: `pct exec <CTID> -- grep -n "9392\|443" /opt/greenbone/compose.yaml` muss `0.0.0.0:9392` + `0.0.0.0:443` zeigen (Skript patcht `127.0.0.1` automatisch).
2. Immer **https** nutzen (`https://<IP>:9392/login`), nicht http.
3. Container-Status: `pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose ps'`.
4. Firewall/Reverse-Proxy vor Proxmox? Port 9392 + 443 freigeben.

### OOM / Feed bricht ab / Postgres stirbt

`pct exec <CTID> -- free -m` und `dmesg | grep -i oom` prüfen. Unter ~3,5 GB wird der Stack instabil → auf 4 GB+ erhöhen (`pct set <CTID> --memory 8192`, Neustart).

### Docker startet nicht im LXC

Features prüfen: `pct config <CTID> | grep features` muss `nesting=1,keyctl=1` zeigen. Unprivilegierter CT + nesting ist Pflicht. Danach `pct exec <CTID> -- systemctl status docker`.

## Update / Backup / Deinstall

```bash
# Update (im LXC):
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose pull && docker compose up -d'

# Backup (Host): Zugangsdaten + compose sichern, oder CT-Backup via Proxmox:
pct exec <CTID> -- cat /opt/greenbone/.admin_pass
vzdump <CTID> --storage local --mode snapshot

# Deinstall:
pct stop <CTID> && pct destroy <CTID>
```

## Struktur

```
install/openvas.sh          <- Standalone-Einzeiler (Host: pct create + pct exec + Verify)
ct/openvas.sh               <- Community-Scripts CT-Einstieg (build.func, APP, update_script)
install/openvas-install.sh  <- Community-Scripts Install-Teil (läuft IM CT)
greenbone-openvas.service   <- systemd-Unit (Referenz; Skript legt sie im CT an)
README.md
```

Community-Scripts-Variante: `ct/openvas.sh` via `build.func` (`start` → `build_container`), Update-Pfad über `update_script()`.

## Sicherheitshinweise

- Web-UI hängt nach dem Patch auf `0.0.0.0` — nur im vertrauenswürdigen LAN betreiben oder per Firewall/Reverse-Proxy absichern.
- Selbstsigniertes nginx-Zertifikat (Greenbone-Template generiert es automatisch). Für öffentlich erreichbare Setups eigenes Zertifikat hinterlegen.
- `.admin_pass` liegt mit 600 in `/opt/greenbone/` — nach dem Ablegen Passwort im Passwort-Manager speichern und bei Bedarf rotieren (`gvmd --user=admin --new-password=...`).
- Scanner mit `NET_ADMIN`/`NET_RAW` (Promiscuous Mode für Alive-Detection) — normal für OpenVAS, aber kein ungehärtetes WAN-Interface direkt an den CT hängen.

## Enterprise-Alternative (zum Einordnen)

Greenbone bietet seit 12/2025 eine Proxmox-fähige **Enterprise Appliance** (`.zst`-Backup → `/var/lib/vz/dump` → Restore): 2 vCPU / **12 GB RAM / 500 GB Disk**, Lizenz/Trial via Vertrieb. Für „läuft es überhaupt?" ist der Community-LXC hier sparsamer.

## Fehler melden

Immer beilegen: komplettes Log `/tmp/openvas-install-*.log`, Exit-Code, `bash -x`-Ausschnitt, dazu:

```bash
pct exec <CTID> -- systemctl --failed
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose ps'
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose logs --tail=50 gvmd gsad nginx'
pct exec <CTID> -- journalctl -u greenbone-openvas -n 50 --no-pager
```

Niemals nur die letzte Zeile posten.

## Quellen / Lizenz

- Greenbone Container-Doku: <https://greenbone.github.io/docs/latest/22.4/container/>
- Compose-File: <https://greenbone.github.io/docs/latest/_static/compose.yaml>
- Scanner-Repo: <https://github.com/greenbone/openvas-scanner>
- Lizenz dieses Repos: MIT
