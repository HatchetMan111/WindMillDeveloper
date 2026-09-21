#!/usr/bin/env bash
#
# Windmill Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:     Windmill – Developer platform for APIs, background jobs, workflows and UIs
#          (Rust-Backend + Svelte-Frontend + Postgres, Web UI :80 via Caddy)
# Upstream: https://github.com/windmill-labs/windmill
# Läuft:   vollständig lokal im LXC (Docker Compose), keine Cloud nötig
# Host:    DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WindMillDeveloper/main/install/windmill.sh)"
#   CT_ID=101 CORES=4 RAM=8192 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WindMillDeveloper/main/install/windmill.sh)"
#   bash windmill.sh --ctid 101 --cores 4 --memory 8192 --disk 20 --bridge vmbr0 --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="windmill"                                # Container-Hostname + Service-Name
APP_PORT="80"                                 # Windmill Web UI Port (Caddy, Upstream-Default)
UPSTREAM_REPO="windmill-labs/windmill"        # Quelle für docker-compose.yml / Caddyfile / .env
UPSTREAM_REF="main"                           # Upstream-Branch/Tag für die 3 Compose-Dateien
WM_IMAGE_DEFAULT="ghcr.io/windmill-labs/windmill:latest"
# Hinweis: Upstream-.env nutzt ':main' (rolling). ':latest' ist die stabilere Wahl;
# per WINDMILL_IMAGE=... bzw. --wm-image überstimmbar (z. B. Tag v1.5xx oder -ee Image).

DEFAULT_CORES="4"                             # Windmill braucht mehr als 1–2 vCPU
DEFAULT_RAM="8192"                            # Server + 3 Worker + DB + Caddy (MB)
DEFAULT_SWAP="1024"                           # Swap (MB)
DEFAULT_DISK="20"                             # Images (~3 GB) + DB + Cache (GB)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie (12 = stabil getestet)
UNPRIVILEGED="1"
FEATURES="nesting=1"                          # Pflicht für Docker-in-LXC

# Umgebungs-Overrides erlauben: CT_ID=101 CORES=4 RAM=8192 DISK=20 ./windmill.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
WINDMILL_IMAGE_OVERRIDE="${WINDMILL_IMAGE:-}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe zusätzlich ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash windmill.sh [OPTIONEN]
  CT_ID=101 bash windmill.sh
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/WindMillDeveloper/main/install/windmill.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --wm-image IMAGE     Windmill-Image (Default: ${WM_IMAGE_DEFAULT})
  --ref REF            Upstream-Ref für Compose-Dateien (Default: ${UPSTREAM_REF})
  --debug, -x          set -x + maximale Fehlermeldungskette
  --help, -h           diese Hilfe

Nach der Installation: http://<LXC-IP>  (Login: admin@windmill.dev / changeme)
EOF
}

# ---------------------------------------------------------------------------
# Debugging: komplette Fehlermeldungskette (Stacktrace, stderr/stdout, Exit-Code, Logs)
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +x
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $SCRIPT_ARGS"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Stacktrace (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  # Kontext: was gibt es her?
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]]; then
    msg_error "--- pct config ${CTID} ---"
    pct config "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- pct status ${CTID} ---"
    pct status "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- systemctl status windmill im Container ---"
    pct exec "${CTID}" -- systemctl status "${APP}" --no-pager --full 2>&1 || true
    echo ""
    msg_error "--- journalctl -u windmill (letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- journalctl -u "${APP}" --no-pager -n 100 2>&1 || true
    echo ""
    msg_error "--- journalctl -u docker (letzte 50 Zeilen) ---"
    pct exec "${CTID}" -- journalctl -u docker --no-pager -n 50 2>&1 || true
    echo ""
    msg_error "--- docker compose ps / logs (Tail 100) ---"
    pct exec "${CTID}" -- docker compose -f /opt/windmill/docker-compose.yml ps 2>&1 || true
    pct exec "${CTID}" -- docker compose -f /opt/windmill/docker-compose.yml logs --tail=100 2>&1 || true
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  # shellcheck disable=SC2086
  msg_error "  bash -x windmill.sh $SCRIPT_ARGS"
  msg_error "  oder: DEBUG=1 bash windmill.sh $SCRIPT_ARGS"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CT_ID_ARG"
HOSTNAME_ARG="$APP"
CORES="$CORES_ARG"
RAM="$RAM_ARG"
DISK="$DISK_ARG"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
ROOT_PASSWORD=""
SSH_KEY=""
WM_IMAGE="$WINDMILL_IMAGE_OVERRIDE"
UPSTREAM_REF_ARG="$UPSTREAM_REF"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)            CTID="${2:?--ctid braucht einen Wert}"; shift 2 ;;
    --hostname)        HOSTNAME_ARG="${2:?--hostname braucht einen Wert}"; shift 2 ;;
    --cores)           CORES="${2:?}"; shift 2 ;;
    --memory)          RAM="${2:?}"; shift 2 ;;
    --disk)            DISK="${2:?}"; shift 2 ;;
    --storage)         STORAGE_ARG="${2:?}"; shift 2 ;;
    --template-store)  TEMPLATE_STORE="${2:?}"; shift 2 ;;
    --bridge)          BRIDGE="${2:?}"; shift 2 ;;
    --password)        ROOT_PASSWORD="${2:?}"; shift 2 ;;
    --ssh-key)         SSH_KEY="${2:?}"; shift 2 ;;
    --wm-image)        WM_IMAGE="${2:?}"; shift 2 ;;
    --ref)             UPSTREAM_REF_ARG="${2:?}"; shift 2 ;;
    --debug|-x)        DEBUG="1"; set -x; shift ;;
    --help|-h)         usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done
[[ -z "$WM_IMAGE" ]] && WM_IMAGE="$WM_IMAGE_DEFAULT"

# Trap NACH dem Parsen setzen, damit SCRIPT_ARGS die echten Args enthält
# shellcheck disable=SC2064
trap "on_error \$? \$LINENO \"\$BASH_COMMAND\"" ERR

# ---------------------------------------------------------------------------
# Pre-Checks (muss auf dem Proxmox-Host als root laufen)
# ---------------------------------------------------------------------------
msg_info "Prüfe Voraussetzungen (Proxmox-Host, root, Tools) ..."
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  msg_error "Bitte als root auf dem Proxmox-Host ausführen (sudo -i)."
  exit 1
fi
for bin in pct pveam pvesh pvesm wget curl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    msg_error "Benötigtes Tool fehlt: $bin – läuft das Skript wirklich auf einem Proxmox-VE-Host?"
    exit 1
  fi
done
msg_ok "Host-Checks bestanden."

# ---------------------------------------------------------------------------
# CT-ID: immer die nächste freie ID nehmen (außer explizit gesetzt)
# ---------------------------------------------------------------------------
if [[ -z "$CTID" ]]; then
  msg_info "Ermittle nächste freie CT-ID ..."
  CTID="$(pvesh get /cluster/nextid)"
  msg_ok "Nächste freie CT-ID: $CTID"
else
  msg_info "CT-ID vorgegeben: $CTID"
fi

HOSTNAME_FINAL="$HOSTNAME_ARG"
if [[ ! "$HOSTNAME_FINAL" =~ ^[a-zA-Z0-9-]+$ ]]; then
  msg_error "Ungültiger Hostname: $HOSTNAME_FINAL (nur Buchstaben, Zahlen, Bindestrich)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Storage-Erkennung (idempotent: vorhandene Storages nutzen)
# ---------------------------------------------------------------------------
detect_storage() {
  local s
  # pvesm status: Spalten "Name Type Status ..." – Status-Spalte enthält "active"
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | grep -x "local-lvm" || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | head -n1 || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  echo "local-lvm"
}
if [[ -z "$STORAGE_ARG" ]]; then
  STORAGE_ARG="$(detect_storage)"
  msg_info "RootFS-Storage (auto): $STORAGE_ARG"
else
  msg_info "RootFS-Storage (vorgegeben): $STORAGE_ARG"
fi

# ---------------------------------------------------------------------------
# Template sicherstellen
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Template-Liste (pveam update) ..."
pveam update

msg_info "Suche neuestes ${DEFAULT_OS}-Template auf ${TEMPLATE_STORE} ..."
TEMPLATE_FILE="$(pveam available --section system 2>/dev/null \
  | grep -o "${DEFAULT_OS}[^ ]*\\.tar\\.zst" | sort -V | tail -n1 || true)"
if [[ -z "$TEMPLATE_FILE" ]]; then
  msg_error "Kein Template für ${DEFAULT_OS} gefunden. Verfügbare Debian-Templates:"
  pveam available --section system 2>&1 | grep -i debian || true
  exit 1
fi
TEMPLATE_REF="${TEMPLATE_STORE}:vztmpl/${TEMPLATE_FILE}"
msg_info "Template: $TEMPLATE_REF"
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE_FILE"; then
  msg_info "Lade Template herunter (kann dauern) ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_FILE"
else
  msg_ok "Template bereits vorhanden – Download übersprungen (idempotent)."
fi

# ---------------------------------------------------------------------------
# Container erstellen (idempotent: existiert die CT-ID schon, wiederverwenden)
# ---------------------------------------------------------------------------
CREATED_NOW=0
GENERATED_PW=0
if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "Container $CTID existiert bereits – wird wiederverwendet (idempotent, kein Neu-Erstellen)."
  EXISTING_HOST="$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}' || true)"
  msg_info "Bestehender Hostname: ${EXISTING_HOST:-unbekannt}"
else
  if [[ -z "$ROOT_PASSWORD" ]]; then
    ROOT_PASSWORD="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    GENERATED_PW=1
  fi
  msg_info "Erstelle LXC $CTID (hostname=${HOSTNAME_FINAL}, cores=${CORES}, ram=${RAM}MB, disk=${DISK}G) ..."
  CREATE_ARGS=(
    "$CTID" "$TEMPLATE_REF"
    --hostname "$HOSTNAME_FINAL"
    --cores "$CORES"
    --memory "$RAM"
    --swap "$DEFAULT_SWAP"
    --rootfs "${STORAGE_ARG}:${DISK}"
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
    --ostype debian
    --unprivileged "$UNPRIVILEGED"
    --features "$FEATURES"
    --onboot 1
    --start 0
    --password "$ROOT_PASSWORD"
  )
  if [[ -n "$SSH_KEY" ]]; then
    if [[ ! -f "$SSH_KEY" ]]; then msg_error "SSH-Key nicht gefunden: $SSH_KEY"; exit 1; fi
    CREATE_ARGS+=(--ssh-public-keys "$SSH_KEY")
  fi
  pct create "${CREATE_ARGS[@]}"
  # onboot explizit sicherstellen (Reboot-sicher)
  pct set "$CTID" --onboot 1
  CREATED_NOW=1
  msg_ok "Container $CTID erstellt (Name: $HOSTNAME_FINAL, onboot=1)."
fi

msg_info "Starte Container $CTID ..."
if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
  pct start "$CTID"
fi
# Warten bis pct exec geht
for i in $(seq 1 30); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
  if [[ "$i" -eq 30 ]]; then msg_error "Container $CTID reagiert nicht auf 'pct exec'."; exit 1; fi
done
msg_ok "Container $CTID läuft."

# Debian-Template braucht nach Start kurz Netzwerk/DNS
sleep 5

# ---------------------------------------------------------------------------
# Installation IM Container (idempotentes Setup-Skript via pct push + exec)
# ---------------------------------------------------------------------------
msg_info "Installiere ${APP} im Container (Docker + Upstream Compose, systemd-Service) ..."

# systemd-Unit-Vorlage (identisch zu systemd/windmill.service im Repo)
read -r -d '' UNIT_FILE <<'UNIT_EOF' || true
[Unit]
Description=Windmill - Developer platform for APIs, workflows and UIs (Docker Compose)
Documentation=https://www.windmill.dev/docs/advanced/self_host
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/windmill
ExecStart=/usr/bin/docker compose -f /opt/windmill/docker-compose.yml up
ExecStop=/usr/bin/docker compose -f /opt/windmill/docker-compose.yml stop
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_EOF

# Setup-Skript lokal bauen (Host-Variablen werden HIER expandiert,
# Container-Variablen sind mit \$ escaped und werden ERST im LXC expandiert).
TMP_SETUP="$(mktemp /tmp/windmill-setup.XXXXXX.sh)"
cat > "$TMP_SETUP" <<SETUP_EOF
#!/usr/bin/env bash
set -euo pipefail
APP="${APP}"
APP_PORT="${APP_PORT}"
UPSTREAM_REPO="${UPSTREAM_REPO}"
UPSTREAM_REF="${UPSTREAM_REF_ARG}"
WM_IMAGE="${WM_IMAGE}"

echo "[LXC] apt update + Basis-Pakete ..."
export DEBIAN_FRONTEND=noninteractive
# Locale-Warnungen ("Cannot set LC_ALL") in minimalen Debian-Templates unterdruecken
export LC_ALL=C LANG=C
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates gnupg lsb-release iproute2 procps

echo "[LXC] Docker CE + Compose-Plugin sicherstellen (idempotent) ..."
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  CODENAME=\$(lsb_release -cs 2>/dev/null || true)
  if [[ -z "\$CODENAME" ]]; then CODENAME="\$(. /etc/os-release; echo \$VERSION_CODENAME)"; fi
  echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \$CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "[LXC] Docker bereits vorhanden: \$(docker --version)"
fi
systemctl enable --now docker
docker compose version

echo "[LXC] /opt/windmill mit Upstream Compose-Dateien bestuecken ..."
mkdir -p /opt/windmill
BASE="https://raw.githubusercontent.com/\$UPSTREAM_REPO/\$UPSTREAM_REF"
curl -fSL --retry 3 --max-time 120 -o /opt/windmill/docker-compose.yml "\$BASE/docker-compose.yml"
curl -fSL --retry 3 --max-time 120 -o /opt/windmill/Caddyfile "\$BASE/Caddyfile"
curl -fSL --retry 3 --max-time 120 -o /opt/windmill/.env "\$BASE/.env"
# Stabiles Image pinnen (Upstream-.env nutzt ':main' = rolling)
if grep -q "^WM_IMAGE=" /opt/windmill/.env; then
  sed -i "s|^WM_IMAGE=.*|WM_IMAGE=\$WM_IMAGE|" /opt/windmill/.env
else
  echo "WM_IMAGE=\$WM_IMAGE" >> /opt/windmill/.env
fi
grep -qxF "WM_IMAGE=\$WM_IMAGE" /opt/windmill/.env || {
  echo "[LXC][ERROR] WM_IMAGE konnte in /opt/windmill/.env nicht gesetzt werden." >&2
  cat /opt/windmill/.env >&2 || true
  exit 1
}
grep -q "80:80" /opt/windmill/docker-compose.yml || {
  echo "[LXC][WARN] Port-Mapping 80:80 nicht gefunden – Caddy-Block pruefen:"
  grep -n "ports:" -A4 /opt/windmill/docker-compose.yml || true
}

echo "[LXC] systemd-Unit windmill.service schreiben ..."
cat > /etc/systemd/system/windmill.service <<UNIT_INNER_EOF
${UNIT_FILE}
UNIT_INNER_EOF

systemctl daemon-reload
systemctl enable windmill
echo "[LXC] Images ziehen (kann beim ersten Mal mehrere Minuten dauern) ..."
docker compose -f /opt/windmill/docker-compose.yml pull || {
  echo "[LXC][WARN] 'docker compose pull' meldete Fehler – versuche trotzdem zu starten."
}
if systemctl is-active --quiet windmill; then
  systemctl restart windmill
else
  systemctl start windmill
fi

echo "[LXC] Warte auf Web UI (http://127.0.0.1:\$APP_PORT/, max ~300s, Erst-Pull + DB-Init brauchen Zeit) ..."
OK_WEB=0
OK_API=0
for i in \$(seq 1 60); do
  if curl -fsS --max-time 5 "http://127.0.0.1:\$APP_PORT/" >/dev/null 2>&1; then OK_WEB=1; fi
  if curl -fsS --max-time 5 "http://127.0.0.1:8000/api/version" >/dev/null 2>&1; then OK_API=1; fi
  if [[ "\$OK_WEB" == "1" && "\$OK_API" == "1" ]]; then break; fi
  if [[ \$((i % 6)) -eq 0 ]]; then
    echo "[LXC] ... noch nicht bereit nach \$((i * 5))s (Web=\$OK_WEB API=\$OK_API), docker compose ps:"
    docker compose -f /opt/windmill/docker-compose.yml ps || true
  fi
  sleep 5
done
if [[ "\$OK_WEB" != "1" ]]; then
  echo "[LXC][ERROR] Web UI antwortet nicht auf 127.0.0.1:\$APP_PORT" >&2
  echo "--- systemctl status windmill ---" >&2
  systemctl status windmill --no-pager --full >&2 || true
  echo "--- docker compose ps ---" >&2
  docker compose -f /opt/windmill/docker-compose.yml ps >&2 || true
  echo "--- docker compose logs (Tail 100) ---" >&2
  docker compose -f /opt/windmill/docker-compose.yml logs --tail=100 >&2 || true
  exit 1
fi
if [[ "\$OK_API" != "1" ]]; then
  echo "[LXC][WARN] Caddy antwortet, aber Backend :8000/api/version noch nicht – laeuft ggf. noch warm."
  docker compose -f /opt/windmill/docker-compose.yml ps || true
fi
echo "[LXC] Web UI antwortet (Version: \$(curl -fsS --max-time 5 http://127.0.0.1:8000/api/version || echo unbekannt))."
echo "[LXC] Service aktiv: \$(systemctl is-active windmill)"
SETUP_EOF

chmod 0644 "$TMP_SETUP"
msg_info "Setup-Skript lokal: $TMP_SETUP (Kopie bleibt zur Fehlersuche erhalten)"
pct push "$CTID" "$TMP_SETUP" /tmp/windmill-setup.sh
pct exec "$CTID" -- bash /tmp/windmill-setup.sh
msg_ok "Installation im Container abgeschlossen."

# Unit-Guard vom Host aus
if ! pct exec "$CTID" -- grep -q "^ExecStart=/usr/bin/docker compose" /etc/systemd/system/windmill.service; then
  msg_error "Unit-Guard fehlgeschlagen: ExecStart fehlt in /etc/systemd/system/windmill.service"
  pct exec "$CTID" -- cat /etc/systemd/system/windmill.service || true
  exit 1
fi
msg_ok "Unit windmill.service ist gesetzt."

# ---------------------------------------------------------------------------
# Verifikation vom Host aus (Service + HTTP + IP)
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."

SERVICE_STATE="$(pct exec "$CTID" -- systemctl is-active "$APP" 2>&1 || true)"
if [[ "$SERVICE_STATE" != "active" ]]; then
  msg_error "Service-Check fehlgeschlagen: 'systemctl is-active $APP' = '$SERVICE_STATE' (erwartet: active)"
  pct exec "$CTID" -- systemctl status "$APP" --no-pager --full || true
  pct exec "$CTID" -- journalctl -u "$APP" --no-pager -n 100 || true
  pct exec "$CTID" -- docker compose -f /opt/windmill/docker-compose.yml ps || true
  exit 1
fi
msg_ok "Service läuft (systemctl is-active $APP = active)."

if ! pct exec "$CTID" -- curl -fsS --max-time 10 "http://127.0.0.1:${APP_PORT}/" >/dev/null; then
  msg_error "HTTP-Check fehlgeschlagen: http://127.0.0.1:${APP_PORT}/ antwortet nicht."
  pct exec "$CTID" -- docker compose -f /opt/windmill/docker-compose.yml logs --tail=100 || true
  exit 1
fi
msg_ok "Web UI antwortet (HTTP-Check auf localhost:${APP_PORT}/)."

CT_IP="$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
[[ -z "$CT_IP" ]] && CT_IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

echo ""
echo -e "${C_GREEN}${C_BOLD}════════════════ INSTALLATION ERFOLGREICH ════════════════${C_RESET}"
echo -e "  App          : ${C_BOLD}Windmill – APIs, Workflows & UIs${C_RESET}"
echo -e "  Container    : CT ${C_BOLD}${CTID}${C_RESET} (Hostname: ${C_BOLD}${HOSTNAME_FINAL}${C_RESET}, onboot=1)"
echo -e "  Ressourcen   : ${CORES} vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
echo -e "  Image        : ${WM_IMAGE} (Upstream-Ref: ${UPSTREAM_REF_ARG})"
if [[ -n "${CT_IP:-}" ]]; then
echo -e "  Web UI       : ${C_BOLD}http://${CT_IP}${C_RESET}"
else
echo -e "  Web UI       : ${C_BOLD}http://<LXC-IP>${C_RESET} (IP konnte nicht auto-ermittelt werden: pct exec $CTID -- ip a)"
fi
echo -e "  Login        : admin@windmill.dev / changeme (nach erstem Login ändern!)"
echo -e "  API-Check    : im Container: curl -fs http://127.0.0.1:8000/api/version"
if [[ "$CREATED_NOW" == "1" && "$GENERATED_PW" == "1" ]]; then
echo -e "  Root-Passwort: ${C_BOLD}${ROOT_PASSWORD}${C_RESET} (nur jetzt angezeigt – sicher ablegen!)"
fi
echo -e "  Service      : systemctl status ${APP}  (im Container via: pct enter ${CTID})"
echo -e "  Update       : Skript erneut laufen lassen (idempotent) – zieht neue Images + Compose-Dateien"
echo -e "  Deinstall    : pct stop ${CTID} && pct destroy ${CTID}"
echo -e "  Reboot-Test  : pct reboot ${CTID} && sleep 60 && curl -fs http://${CT_IP:-<LXC-IP>}/"
echo -e "  Log          : ${LOG_FILE}"
echo -e "  Setup-Kopie  : ${TMP_SETUP}"
if [[ "$DEBUG" != "1" ]]; then
echo -e "  Debug bei Fehlern: ${C_CYAN}bash -x windmill.sh --ctid ${CTID}${C_RESET}"
fi
echo -e "${C_GREEN}══════════════════════════════════════════════════════════${C_RESET}"
