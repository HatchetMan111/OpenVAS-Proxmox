# OpenVAS / Greenbone Community Edition für Proxmox (LXC, Community-Scripts-Stil)

Installiert den **kompletten Greenbone-Stack** (openvas-scanner + gvmd + gsad + gsa + ospd-openvas + redis + postgres + nginx) als LXC auf Proxmox. Am Ende: Web-UI im LAN, alles einstellbar, reboot-sicher.

> Hinweis: `greenbone/openvas-scanner` allein hat **keine Web-UI**. Darum nutzt dieses Script die offiziellen Greenbone-Container (einzige wartbare Methode im LXC; Source-Build dauert Stunden und bricht oft).

## Einzeiler (Proxmox-Host, als root)

Eigenes Repo (Platzhalter `USER/REPO` ersetzen):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/REPO/main/install/openvas.sh)"
```

Debug mit Trace + Voll-Log:

```bash
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/USER/REPO/main/install/openvas.sh)"
# Log liegt danach unter /tmp/openvas-install-*.log (Pfad steht zu Beginn der Ausgabe)
```

### Parameter (optional, vorangestellt)

```bash
# Sparsam-Test (Default, 2 CPU / 4 GB / 20 GB):
bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/REPO/main/install/openvas.sh)"

# Produktiv (4 CPU / 8 GB / 30 GB):
PROFILE=produktiv bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/REPO/main/install/openvas.sh)"

# statische IP:
CTID=150 IP_MODE=192.168.1.50/24 GW=192.168.1.1 \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/USER/REPO/main/install/openvas.sh)"

# eigenes Admin-Passwort:
ADMIN_PASS='MeinStarkesPass!' bash -c "$(wget -qLO - .../openvas.sh)"
```

| Var | Default (sparsam) | Bedeutung |
|---|---|---|
| `PROFILE` | sparsam (2 / 4096 MB / 20 GB) | `produktiv` = 4 / 8192 MB / 30 GB |
| `CPU/RAM/DISK` | 2 / 4096 MB / 20 GB | Direkt-Override schlägt `PROFILE`; **RAM nicht unter 4096** (Postgres/gvmd OOM, Feed-Sync bricht) |
| `CTID` | nächste freie ID | Container-ID |
| `STORAGE` | local-lvm | LXC-Disk-Storage |
| `TEMPLATE_STORAGE` | local | Template-Storage |
| `BRIDGE` | vmbr0 | Netzwerk-Bridge |
| `IP_MODE/GW` | dhcp | oder statisch `IP_MODE=192.168.1.50/24 GW=192.168.1.1` |
| `WEB_PORT` | 9392 | Web-UI-Port |
| `ADMIN_USER/ADMIN_PASS` | admin / zufällig | Login Web-UI |

Voraussetzungen: Proxmox VE 8.x, Internet (Feed + Docker-Hub + `registry.community.greenbone.net`), Template `debian-12-standard` (wird auto geladen).

## Nach der Installation

- Web-UI: `http://<LXC-IP>:9392` (ggf. auch `https://<LXC-IP>` / `https://<LXC-IP>:9392`, je nach nginx-Template) — bind `0.0.0.0`, Login `admin` + angezeigtes Passwort.
- Feed-Sync dauert **30 Min – 2 h**: erst danach scannen! Status:
  ```bash
  pct exec <CTID> -- docker compose -f /opt/greenbone/compose.yaml logs -f gvmd
  ```
- Reboot-Test:
  ```bash
  pct reboot <CTID>
  sleep 60
  pct exec <CTID> -- systemctl is-active docker greenbone-openvas
  curl -sk -o /dev/null -w "%{http_code}\n" https://<LXC-IP>:9392/login
  ```

## Sparsam testen: was geht, was nicht

- Sparsam-Profil = Greenbone-Minimum (2 CPU / 4 GB / 20 GB). Darunter bitte nicht gehen: Postgres + gvmd brauchen ~2–3 GB allein, Feed-Sync (VTs, SCAP, CERT, Notus) belegt ~10–15 GB Platte und dauert beim ersten Mal 30 Min–2 h.
- Sparsam-Tipps: nur 1–2 Scan-Ziele gleichzeitig, max. 1 paralleler Scan, keine Full-Port-Range beim ersten Test.
- Hochskalieren jederzeit ohne Neuinstallation: `pct set <CTID> --cores 4 --memory 8192`, dann CT neu starten. Platte ggf. `pct resize <CTID> rootfs +20G`.

## Alternativen aus deinen Links (berücksichtigt)

- **Enterprise OPENVAS SCAN Appliance (Greenbone-Blog, 12/2025):** offiziell Proxmox-VE-fähig, `.zst`-Backup nach `/var/lib/vz/dump` kopieren → in Proxmox unter Storage → Backups → Restore. Aber: 2 vCPU / **12 GB RAM / 500 GB Disk**, Lizenz/Trial via Greenbone-Vertrieb — also das Gegenteil von sparsam. Für „läuft es überhaupt?" ist der Community-LXC hier sinnvoller.
- **Altes Forum (2020, GCE-ISO auf Proxmox-VM):** Workaround damals war VMware-PVSCSI + VMXNET3 statt E1000/IDE, weil GCE die Proxmox-Defaults nicht erkannte. Heute: nimm bei einer **VM**-Variante VirtIO-SCSI + VirtIO-Net (Paravirtualisiert) + `qemu-guest-agent`, BIOS OVMF nur wenn nötig. Für unseren **LXC** irrelevant (keine emulierte HW), nur wichtig falls du später auf VM wechselst.

## Community-Scripts-Variante (2 Dateien, für ProxmoxVE-Fork/PR)

- `ct/openvas.sh` — Einstieg (sourced `build.func`, definiert `APP`, Ressourcen, `update_script()`), starten via `bash ct/openvas.sh`
- `install/openvas-install.sh` — läuft im Container (nutzt `$FUNCTIONS_FILE_PATH`, installiert Docker, deployed Stack, systemd, Verifikation mit vollem `journalctl`/`docker logs` bei Fehlern)

## Update / Deinstall

```bash
# Update (im LXC):
pct exec <CTID> -- bash -c 'cd /opt/greenbone && docker compose pull && docker compose up -d'

# Deinstall:
pct stop <CTID> && pct destroy <CTID>
```

## Struktur

```
install/openvas.sh          <- Standalone-Einzeiler (Host: pct create + pct exec)
ct/openvas.sh               <- Community-Scripts CT-Einstieg
install/openvas-install.sh  <- Community-Scripts Install-Teil (im CT)
greenbone-openvas.service   <- systemd-Unit (Referenz, wird vom Script angelegt)
README.md
```

## Fehler melden

Immer beilegen: komplettes Log `/tmp/openvas-install-*.log`, Exit-Code, `bash -x`-Ausschnitt, Ausgabe von `pct exec <CTID> -- systemctl --failed`, `docker ps -a`, `journalctl -u greenbone-openvas -n 50`. Niemals nur die letzte Zeile.
