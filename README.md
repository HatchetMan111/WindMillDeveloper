# Windmill auf Proxmox LXC – Einzeiler-Installation

> **Hinweis: Das ist NICHT das Windmill-App-Repository.**
> Dieses Repo enthält **nur den Proxmox-LXC-Installer** für Windmill — keinen App-Code.
> Die eigentliche Anwendung liegt bei Upstream:
> `https://github.com/windmill-labs/windmill`. Das Install-Script lädt deren
> offizielle `docker-compose.yml` / `Caddyfile` / `.env` und die Images
> (`ghcr.io/windmill-labs/windmill`) direkt von dort.
läuft vollständig lokal in einem unprivilegierten LXC-Container:
Docker + Compose aus den offiziellen Repos, Web UI auf Port **80** (Caddy),
systemd-Service mit `Restart=always`, Container mit `onboot=1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `windmill` |
| Tech-Stack | Rust-Backend + Svelte-Frontend + Postgres (via Docker Compose) |
| Web UI | `http://<LXC-IP>` (Caddy auf Port 80, bind `0.0.0.0`) |
| API-Check | `http://<LXC-IP>:8000/api/version` nur **im** Container; von außen: `http://<LXC-IP>/` |
| Standard-Login | `admin@windmill.dev` / `changeme` (nach erstem Login ändern!) |
| Standard-Ressourcen | 4 vCPU / 8192 MB RAM / 20 GB Disk |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |

> **Warum 4 CPU / 8 GB / 20 GB statt 1–2 / 1–2 GB?**
> Upstream-Compose startet Postgres + Server + 3 Worker + Native-Worker + Caddy.
> Faustregel von Windmill: 1 Worker pro vCPU, 1–2 GB RAM pro Worker.
> Mit 2 CPU / 4 GB bootet die UI zwar, echte Workflows laufen aber ins OOM —
> daher sind 4/8/20 der Standard; per Flags jederzeit anpassbar.

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

Einfach kopieren und auf dem Proxmox-Host als `root` einfügen
(Community-Scripts-Stil, keine weitere Datei nötig):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WindMillDeveloper/main/install/windmill.sh)"
```

Anpassungen wahlweise per Umgebungsvariable oder Flag:

```bash
CT_ID=101 CORES=4 RAM=8192 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WindMillDeveloper/main/install/windmill.sh)"
bash windmill.sh --ctid 101 --cores 4 --memory 8192 --disk 20 --bridge vmbr0 --storage local-lvm
bash windmill.sh --wm-image ghcr.io/windmill-labs/windmill:v1.500.0  # Version pinnen
bash windmill.sh --debug   # = bash -x, maximale Fehlermeldungskette
```

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools, nimmt die nächste freie CT-ID,
2. erkennt RootFS-Storage (bevorzugt `local-lvm`), lädt das neueste
   `debian-12-standard`-Template falls nötig,
3. erstellt den LXC `windmill` (`onboot: 1`, unprivilegiert, `nesting=1` für Docker),
4. installiert im Container Docker CE + Compose-Plugin (offizielles Docker-APT-Repo),
   legt `/opt/windmill/{docker-compose.yml,Caddyfile,.env}` von Upstream ab
   (dabei `WM_IMAGE` auf `ghcr.io/windmill-labs/windmill:latest` gepinnt),
   schreibt die systemd-Unit, `systemctl enable --now windmill`,
5. verifiziert `systemctl is-active windmill` + `curl http://127.0.0.1/` +
   `:8000/api/version` und gibt die finale URL `http://<LXC-IP>` aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active windmill = active).
[OK]    Web UI antwortet (HTTP-Check auf localhost:80/).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Windmill – APIs, Workflows & UIs
  Container    : CT 100 (Hostname: windmill, onboot=1)
  Ressourcen   : 4 vCPU / 8192 MB RAM / 20 GB Disk
  Image        : ghcr.io/windmill-labs/windmill:latest (Upstream-Ref: main)
  Web UI       : http://192.168.1.100
  Login        : admin@windmill.dev / changeme (nach erstem Login ändern!)
  API-Check    : im Container: curl -fs http://127.0.0.1:8000/api/version
  Root-Passwort: aB3... (nur jetzt angezeigt – sicher ablegen!)
  Service      : systemctl status windmill  (im Container via: pct enter 100)
  Update       : Skript erneut laufen lassen (idempotent)
  Deinstall    : pct stop 100 && pct destroy 100
  Reboot-Test  : pct reboot 100 && sleep 60 && curl -fs http://192.168.1.100/
  Log          : /tmp/windmill-install-2026-....log
══════════════════════════════════════════════════════════
```

## 2. Reboot-Test (Reboot-sicher belegen)

Erst-Boot nach Reboot dauert länger (Docker + Image-Start + DB-Recovery, ~60 s einplanen):

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active windmill   # muss: active
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):80/
pct config $CT | grep -i onboot              # muss: onboot: 1
```

## 3. Update (idempotent – einfach erneut laufen lassen)

```bash
bash windmill.sh --ctid 100
# lädt Compose-Dateien neu, 'docker compose pull', danach 'systemctl restart windmill'.
# Neue Version anheften:
bash windmill.sh --ctid 100 --wm-image ghcr.io/windmill-labs/windmill:v1.500.0
```

Manuell im Container:

```bash
pct enter 100
docker compose -f /opt/windmill/docker-compose.yml ps
docker compose -f /opt/windmill/docker-compose.yml pull
systemctl restart windmill && systemctl status windmill --no-pager --full
curl -fs http://127.0.0.1:8000/api/version
```

## 4. Deinstallation

```bash
pct stop 100 && pct destroy 100
```

## 5. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/windmill-install-<Datum>.log`.
- Bei Fehlern druckt das Skript: Befehl, Zeile, Exit-Code, Stacktrace
  (`caller`), `pct config`/`pct status`, `systemctl status windmill`,
  `journalctl -u windmill`, `journalctl -u docker`,
  `docker compose ps` + `logs --tail=100` – niemals nur die letzte Zeile.
- Re-run mit Trace:

```bash
bash -x windmill.sh --ctid 100
DEBUG=1 bash windmill.sh --ctid 100
# Log mitschicken:
tail -n 200 /tmp/windmill-install-*.log
pct exec 100 -- journalctl -u windmill --no-pager -n 100
pct exec 100 -- docker compose -f /opt/windmill/docker-compose.yml logs --tail=100
```

## 6. Dateien in diesem Paket

```text
windmill-proxmox/              # dieses Repo: NUR Proxmox-Installer, kein App-Code
├── install/windmill.sh       # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── systemd/windmill.service  # systemd-Unit (Restart=always, After=docker.service + network-online.target)
└── README.md                 # diese Datei
```

`install/windmill.sh` bettet die Unit-Vorlage aus `systemd/windmill.service` ein,
damit der Einzeiler ohne weitere Dateien auskommt (1:1 identisch).

## 7. Hinweise

- **Erster Start dauert:** Image-Pull (~2–3 GB) + Postgres-Init — der Health-Poll
  wartet bis zu ~300 s. Einfach laufen lassen, nicht abbrechen.
- **Login:** `admin@windmill.dev` / `changeme` — sofort nach erstem Login ändern
  (Superadmin → Settings). SMTP/SSO/OAuth ebenfalls dort konfigurierbar.
- **Port belegt?** Falls Port 80 auf der Container-IP kollidiert, im Container
  `/opt/windmill/docker-compose.yml` (`80:80` → `8080:80`) und `BASE_URL` in der
  Caddy-Sektion anpassen, dann `systemctl restart windmill`.
- **LXC-Rechte:** unprivilegiert + `nesting=1` reicht für Docker-in-LXC.
  Der Windmill-Worker läuft compose-intern ohnehin `privileged: true`
  (Upstream-Default für nsjail/PID-Isolation) — das ist Container-in-Container
  und braucht **keine** privilegierte LXC-Konfiguration.
- **VM statt LXC?** Nur nötig, wenn der Host kein `nesting` erlaubt oder eigene
  Kernel-Module verlangt werden (hier nicht der Fall). Falls doch:
  Debian-12-VM erstellen, dort ab „Docker CE + Compose-Plugin sicherstellen“
  denselben Ablauf fahren (`/opt/windmill` + Unit aus `systemd/`).
- **DHCP-Hinweis:** Ändert sich die Container-IP (neues Lease), ändert sich nur
  die aufgerufene URL — die Unit enthält keine IP und muss nicht neu geschrieben
  werden. Für eine stabile URL DHCP-Reservierung oder statische IP einrichten.
- **Daten:** Postgres-Volume `db_data`, Worker-Cache/Logs als Docker-Volumes.
  Backup via `docker compose` bzw. Proxmox-Backup (CT-Backup enthält alles).
