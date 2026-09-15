#!/usr/bin/env bash
# Homedex – LXC-Installer (läuft IM Container)
# Wird vom Host-Script (ct/homedex.sh) via build_container aufgerufen.
# Kann auch manuell in einem frischen Debian-/Ubuntu-LXC oder einer VM
# als root ausgeführt werden:
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main/install/homedex-install.sh -o /tmp/homedex-install.sh
#   bash /tmp/homedex-install.sh
#
# Ergebnis:
#   - Homedex-Binary (Backend + eingebettete Svelte-Web-UI) in /opt/homedex
#   - systemd-Service homedex.service auf Port 7377 (alle Interfaces)
#   - Daten (SQLite) in /var/lib/homedex
#   - Aufruf im LAN: http://<LXC-IP>:7377/ (Setup-Wizard beim ersten Aufruf)

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
# Fallback, falls das Script manuell (ohne build_container) in einem
# bestehenden LXC / einer VM als root ausgeführt wird:
if ! command -v setting_up_container >/dev/null 2>&1; then
  STD=""
  TAB="  "
  GN="\e[1;92m"
  CL="\e[0m"
  msg_info() { echo -e "${TAB}$1..."; }
  msg_ok() { echo -e "${TAB}\e[1;92mOK\e[0m $1"; }
  msg_warn() { echo -e "${TAB}\e[1;93mWARN\e[0m $1"; }
  msg_error() { echo -e "${TAB}\e[1;91mFEHLER\e[0m $1"; }
  setting_up_container() { :; }
  network_check() { command -v curl >/dev/null || (apt-get update && apt-get install -y curl ca-certificates); }
  update_os() { apt-get update && apt-get -y upgrade; }
  motd_ssh() { :; }
  customize() { :; }
  cleanup_lxc() { apt-get -y autoremove && apt-get -y autoclean; }
  verb_ip6() { :; }
  color() { :; }
  catch_errors() { set -Eeuo pipefail; }
fi
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ---------- 1. Konfiguration ----------
REPO="${HOMEDEX_REPO:-HarshShah0203/homedex}"
PORT="${var_homedex_port:-${HOMEDEX_PORT:-7377}}"
# Gepinntes Release als Override (z. B. HOMEDEX_VERSION=v0.1.4 oder var_homedex_version).
# Leer = neuestes Release via GitHub-API.
PINNED_VERSION="${var_homedex_version:-${HOMEDEX_VERSION:-}}"
# Docker im gleichen LXC installieren, damit der Wizard direkt
# unix:///var/run/docker.sock nutzen kann (0/empty zum Überspringen).
INSTALL_DOCKER="${var_docker:-${HOMEDEX_INSTALL_DOCKER:-1}}"
# Optionaler Sicherheitsmodus: lokaler Socket-Proxy (Upstream-Modell) statt
# rohem Unix-Socket. Dann im Wizard tcp://127.0.0.1:2375 eintragen.
# Aktivieren mit var_docker_proxy=1 (braucht Docker).
INSTALL_PROXY="${var_docker_proxy:-${HOMEDEX_INSTALL_PROXY:-0}}"
PROXY_IMAGE="${HOMEDEX_PROXY_IMAGE:-tecnativa/docker-socket-proxy:v0.4.2}"
PROXY_PORT="${HOMEDEX_PROXY_PORT:-2375}"
INSTALL_DIR="/opt/homedex"
DATA_DIR="${HOMEDEX_DATA_DIR:-/var/lib/homedex}"
SERVICE_USER="homedex"

# ---------- 1b. Preflight: alles prüfen, BEVOR etwas verändert wird ----------
if [[ "$(id -u)" -ne 0 ]]; then
  msg_error "Bitte als root ausführen."
  exit 1
fi
# Sperre: Installer gehört IN den LXC/die VM – niemals auf den Proxmox-Host.
if command -v pveversion >/dev/null 2>&1; then
  msg_error "pveversion gefunden – das sieht nach dem Proxmox-HOST aus. Dieses Script läuft IM LXC/Container (ct/homedex.sh erstellt ihn). Abbruch, keine Änderung vorgenommen."
  exit 1
fi
FREE_MB="$(df -m --output=avail / 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"
if [[ "${FREE_MB:-0}" -lt 2048 ]]; then
  msg_error "Zu wenig freier Plattenplatz auf / (${FREE_MB} MB, min. 2048 MB). Abbruch vor jeder Änderung."
  exit 1
fi
TOTAL_RAM_MB="$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo 0)"
if [[ "${TOTAL_RAM_MB:-0}" -lt 512 ]]; then
  msg_warn "Wenig RAM (${TOTAL_RAM_MB} MB) – Homedex + Docker brauchen min. ca. 512 MB."
fi
# Port-Konflikt früh erkennen (ss oder /dev/tcp-Fallback, kein Abbruch bei fehlendem ss).
# Die /dev/tcp-Probe in eigener Subshell mit stderr auf /dev/null, sonst meldet
# bash bei freiem Port "connect: Connection refused" ins Log (harmlos, aber noisy).
PORT_IN_USE=0
if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE ":${PORT}[[:space:]]"; then
  PORT_IN_USE=1
elif (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
  PORT_IN_USE=1
fi
if [[ "$PORT_IN_USE" == "1" ]]; then
  # Falls nur ein alter Homedex auf dem Port läuft, ist das beim Update ok.
  if ! systemctl is-active --quiet homedex 2>/dev/null; then
    msg_error "Port ${PORT} ist bereits belegt (ss/lsof prüfen). Mit var_homedex_port=<frei> erneut starten."
    exit 1
  fi
  msg_warn "Port ${PORT} belegt – läuft dort bereits Homedex (Update-Pfad)? Weiter."
fi

msg_info "Homedex-Installation (Port ${PORT}, Daten ${DATA_DIR})"

# ---------- 2. Architektur auflösen ----------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)   DEB_ARCH="x86_64" ;;
  aarch64|arm64)  DEB_ARCH="arm64" ;;
  armv7l|armv7)   DEB_ARCH="armv7" ;;
  *) msg_error "Architektur ${ARCH} wird nicht unterstützt (x86_64/arm64/armv7)"; exit 1 ;;
esac
msg_ok "Architektur: ${ARCH} -> ${DEB_ARCH}"

# ---------- 3. Neuestes Release ermitteln ----------
msg_info "Ermittle Homedex-Release"
if [[ -n "${PINNED_VERSION:-}" ]]; then
  VERSION="$PINNED_VERSION"
  [[ "$VERSION" != v* ]] && VERSION="v$VERSION"
  msg_ok "Gepinntes Release ${VERSION} (HOMEDEX_VERSION/var_homedex_version)"
else
  VERSION="$(curl -fsSL --retry 3 --max-time 20 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)"
  if [[ -z "${VERSION:-}" ]]; then
    msg_warn "GitHub-API nicht erreichbar – Fallback v0.1.4"
    VERSION="v0.1.4"
  fi
fi
FILE_VERSION="${VERSION#v}"
TARBALL="homedex_${FILE_VERSION}_linux_${DEB_ARCH}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${TARBALL}"
CHECKSUM_URL="https://github.com/${REPO}/releases/download/${VERSION}/checksums.txt"
msg_ok "Release ${VERSION} (${TARBALL})"

# ---------- 4. Dependencies ----------
msg_info "Installing Dependencies"
$STD apt-get install -y curl ca-certificates tar sqlite3
msg_ok "Installed Dependencies"

# ---------- 5. Binary herunterladen (mit Checksummen-Prüfung) ----------
msg_info "Lade Homedex ${VERSION} herunter"
mkdir -p "$INSTALL_DIR"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
TARBALL_PATH="$TMPDIR/$TARBALL"
if ! curl -fsSL --retry 3 --max-time 120 "$URL" -o "$TARBALL_PATH"; then
  msg_error "Download fehlgeschlagen: $URL"
  exit 1
fi
# checksums.txt verifizieren, wenn verfügbar (Upstream liefert SHA256 + SBOM).
# Wichtig: exakt EINE Zeile matchen ("  <dateiname>" am Zeilenende), sonst wird
# auch die .sbom.json-Zeile geprüft und schlägt fehl. Datei liegt unter ihrem
# Originalnamen ($TARBALL) in $TMPDIR, daher passt sha256sum -c direkt.
if curl -fsSL --retry 2 --max-time 30 "$CHECKSUM_URL" -o "$TMPDIR/checksums.txt" 2>/dev/null; then
  CHECK_LINE="$(grep -F "  $TARBALL" "$TMPDIR/checksums.txt" 2>/dev/null | grep -vE '\.sbom\.json$' || true)"
  if [[ -z "${CHECK_LINE:-}" ]]; then
    # Fallback: strikter Match mit Zeilenende-Anker (falls Format abweicht).
    CHECK_LINE="$(grep -E "  ${TARBALL}\$" "$TMPDIR/checksums.txt" 2>/dev/null || true)"
  fi
  if [[ -n "${CHECK_LINE:-}" ]]; then
    if (cd "$TMPDIR" && echo "$CHECK_LINE" | sha256sum -c - >/dev/null 2>&1); then
      msg_ok "Checksumme ok (${TARBALL})"
    else
      msg_error "Checksummen-Fehlschlag für ${TARBALL} – Abbruch."
      exit 1
    fi
  else
    msg_warn "Tarball nicht in checksums.txt – Prüfung übersprungen."
  fi
else
  msg_warn "checksums.txt nicht verfügbar – Prüfung übersprungen."
fi
tar -xzf "$TARBALL_PATH" -C "$TMPDIR"
BIN_SRC="$(find "$TMPDIR" -maxdepth 2 -type f -name homedex | head -1)"
if [[ -z "${BIN_SRC:-}" ]]; then
  msg_error "Binary 'homedex' nicht im Archiv gefunden"
  exit 1
fi

# Update-Pfad: Service stoppen, Binary ersetzen, Daten behalten
if systemctl is-active --quiet homedex 2>/dev/null; then
  msg_info "Stoppe laufenden homedex-Service für Update"
  systemctl stop homedex
fi

install -m 0755 "$BIN_SRC" "$INSTALL_DIR/homedex"
# Installer-Kopie für späteren Update-Lauf ablegen
cp -f "${BASH_SOURCE[0]:-$0}" "$INSTALL_DIR/homedex-install.sh" 2>/dev/null || true
"$INSTALL_DIR/homedex" --version 2>/dev/null || "$INSTALL_DIR/homedex" -version 2>/dev/null || true
msg_ok "Binary installiert: $INSTALL_DIR/homedex"

# ---------- 6. User + Datenverzeichnis ----------
# Hinweis: DB enthält Session-Hashes + verschlüsselte Connector-Secrets,
# inkl. instance.key – Verzeichnis daher 0700 (Upstream: MkdirAll 0700).
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
mkdir -p "$DATA_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
chmod 0700 "$DATA_DIR"
msg_ok "User + Datenverzeichnis bereit (0700)"

# ---------- 6b. Docker (für lokales Discovery per Unix-Socket) ----------
# Muss VOR dem Service-Start passieren, damit die docker-Gruppe für homedex gilt.
# Absichtlich ausfallsicher: Scheitert Docker, läuft Homedex trotzdem weiter
# (Docker-Quelle dann remote per tcp:// oder SSH-Host im Wizard einbinden).
DOCKER_OK=0
if [[ "$INSTALL_DOCKER" == "1" || "$INSTALL_DOCKER" == "true" || "$INSTALL_DOCKER" == "yes" ]]; then
  msg_info "Installiere Docker (Wizard-Endpoint: unix:///var/run/docker.sock)"
  if $STD apt-get install -y --no-install-recommends docker.io; then
    systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true
    if getent group docker >/dev/null 2>&1 && usermod -aG docker "$SERVICE_USER"; then
      DOCKER_OK=1
    else
      msg_warn "docker-Gruppe fehlt oder usermod scheiterte – Homedex läuft ohne lokale Docker-Quelle weiter."
    fi
  else
    msg_warn "Docker-Installation fehlgeschlagen – Homedex läuft ohne lokale Docker-Quelle weiter."
  fi
  if [[ "$DOCKER_OK" == "1" ]] && docker version >/dev/null 2>&1; then
    msg_ok "Docker läuft (Server $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo ok))"
  elif [[ "$DOCKER_OK" == "1" ]]; then
    DOCKER_OK=0
    msg_warn "Docker startet nicht – Host-Features prüfen (nesting=1,keyctl=1), dann Container neu starten."
  fi
else
  msg_info "Docker-Installation übersprungen (Remote-Docker per tcp:// oder SSH im Wizard eintragen)"
fi

# ---------- 6c. Optionaler Socket-Proxy (Upstream-Sicherheitsmodell) ----------
# Roh-Socket (unix://) ist bequem, aber privilegiert: :ro schützt nur die
# Socket-Datei, nicht die Docker-API. Der Proxy filtert POST=0 und legt nur
# GET-Pfade (CONTAINERS/IMAGES/INFO/NETWORKS/VERSION) frei – wie im
# Homedex-Compose-Stack. Opt-in via var_docker_proxy=1.
PROXY_OK=0
if [[ "$INSTALL_PROXY" == "1" || "$INSTALL_PROXY" == "true" || "$INSTALL_PROXY" == "yes" ]]; then
  if [[ "$DOCKER_OK" != "1" ]]; then
    msg_warn "Socket-Proxy gewünscht, aber Docker läuft nicht – Proxy übersprungen."
  elif ! docker version >/dev/null 2>&1; then
    msg_warn "Docker-Daemon antwortet nicht – Proxy übersprungen."
  else
    msg_info "Starte Docker-Socket-Proxy (${PROXY_IMAGE}, POST=0) auf 127.0.0.1:${PROXY_PORT}"
    docker rm -f homedex-socket-proxy >/dev/null 2>&1 || true
    if docker run -d --name homedex-socket-proxy --restart unless-stopped \
      -p "127.0.0.1:${PROXY_PORT}:2375" \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      --cap-drop ALL --security-opt no-new-privileges:true --read-only \
      --tmpfs /run --tmpfs /tmp \
      -e CONTAINERS=1 -e IMAGES=1 -e INFO=1 -e NETWORKS=1 -e VERSION=1 \
      -e POST=0 -e ALLOW_START=0 -e ALLOW_STOP=0 -e ALLOW_RESTARTS=0 \
      "$PROXY_IMAGE" >/dev/null; then
      sleep 3
      if curl -fsS --max-time 10 "http://127.0.0.1:${PROXY_PORT}/version" >/dev/null 2>&1; then
        PROXY_OK=1
        msg_ok "Socket-Proxy antwortet auf 127.0.0.1:${PROXY_PORT} (Wizard: tcp://127.0.0.1:${PROXY_PORT})"
      else
        msg_warn "Socket-Proxy antwortet nicht – Wizard nutzt weiter unix:///var/run/docker.sock."
      fi
    else
      msg_warn "Socket-Proxy startet nicht (Image/Pull prüfen) – weiter ohne Proxy."
    fi
  fi
fi

# ---------- 7. systemd-Service ----------
# SupplementaryGroups=docker nur wenn die Gruppe existiert (var_docker=0
# ohne Docker würde systemd sonst den Start verweigern). After/Wants auf
# docker.service ist mit Wants harmlos, auch wenn Docker fehlt.
msg_info "Richte systemd-Service ein (Port ${PORT})"
SUPP_GROUPS_LINE=""
if getent group docker >/dev/null 2>&1; then
  SUPP_GROUPS_LINE="SupplementaryGroups=docker"
fi
cat <<EOF >/etc/systemd/system/homedex.service
[Unit]
Description=Homedex – Homelab Inventory (Go + embedded Web-UI)
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
${SUPP_GROUPS_LINE}
WorkingDirectory=${DATA_DIR}
ExecStart=${INSTALL_DIR}/homedex
Environment=HOMEDEX_DATA_DIR=${DATA_DIR}
Environment=HOMEDEX_LISTEN=:${PORT}
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now homedex
# Gruppenmitgliedschaft greift erst nach (Re-)Start des Services.
systemctl restart homedex 2>/dev/null || true
msg_ok "Service homedex aktiviert + gestartet"

# ---------- 8. Warten auf API ----------
msg_info "Warte auf Homedex-Web-UI (Port ${PORT})"
READY=0
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
LOCAL_IP="${LOCAL_IP:-<LXC-IP>}"

if [[ "$READY" == "1" ]]; then
  msg_ok "Homedex-Web-UI antwortet auf :${PORT}"
else
  msg_warn "Web-UI antwortet noch nicht – prüfe: systemctl status homedex / journalctl -u homedex -e"
fi

# Docker-Socket aus Sicht des homedex-Users prüfen (Wizard nutzt diesen Endpoint).
# Homedex ruft nur GET auf: /version, /info, Container-Liste (alle, inkl. gestoppt),
# Container-Inspect. Nie Config.Env, nie POST/start/stop (siehe Upstream docker.go).
WIZARD_ENDPOINT="unix:///var/run/docker.sock"
if [[ "$PROXY_OK" == "1" ]]; then
  WIZARD_ENDPOINT="tcp://127.0.0.1:${PROXY_PORT}"
fi
if [[ "$DOCKER_OK" == "1" && "$PROXY_OK" != "1" ]]; then
  if runuser -u "$SERVICE_USER" -g docker -- test -r /var/run/docker.sock 2>/dev/null \
    || runuser -u "$SERVICE_USER" -- test -r /var/run/docker.sock 2>/dev/null; then
    msg_ok "Wizard-Tipp: als Read-only endpoint ${WIZARD_ENDPOINT} eintragen"
  else
    msg_warn "homedex kann /var/run/docker.sock nicht lesen – prüfe: ls -l /var/run/docker.sock; id homedex; systemctl restart homedex"
  fi
  # Echter API-Check durch den Socket (entspricht Homedex-Test: GET /version).
  if curl -fsS --max-time 10 --unix-socket /var/run/docker.sock http://localhost/version >/dev/null 2>&1; then
    msg_ok "Docker-API über Unix-Socket erreichbar (GET /version ok)"
  else
    msg_warn "Docker-API über Unix-Socket antwortet nicht – läuft der Daemon? (docker version)"
  fi
elif [[ "$PROXY_OK" == "1" ]]; then
  msg_ok "Wizard-Tipp (Proxy-Modus): als Read-only endpoint ${WIZARD_ENDPOINT} eintragen"
fi
if [[ "$DOCKER_OK" != "1" && "$PROXY_OK" != "1" ]]; then
  msg_warn "Kein lokales Docker – im Wizard Remote per tcp://IP:2375 oder ssh://user@host einbinden."
fi
# Häufiger Fehler direkt abfangen: Compose-Prefill passt nicht zum LXC.
msg_info "Hinweis: tcp://docker-socket-proxy:2375 gilt nur für den Homedex-Compose-Stack – im LXC ${WIZARD_ENDPOINT} verwenden."

# ---------- 9. Kurzanleitung ----------
cat <<EOF >"$INSTALL_DIR/README.txt"
Homedex LXC – Kurzanleitung
===========================
Web-UI : http://${LOCAL_IP}:${PORT}/
Health : http://${LOCAL_IP}:${PORT}/api/health
Version: ${VERSION} (${TARBALL})

Erster Aufruf: Setup-Wizard im Browser legt das Admin-Passwort an.
Docker-Quelle (lokal): ${WIZARD_ENDPOINT}
  Name z. B. "Local Docker", Host-Name z. B. "docker-local",
  Test connection -> Save and run first scan.
  WICHTIG: tcp://docker-socket-proxy:2375 NICHT übernehmen (nur Compose-Stack).
  Fehler "lookup docker-socket-proxy: no such host" = genau dieser Fall.
Alternativ Remote-Docker (tcp://IP:2375), TLS (https://IP:2376),
SSH (ssh://user@host), Traefik, Caddy, NPM oder SSH-Host
unter Sources verbinden und ersten Scan starten.
Homedex liest nur Metadaten (version/info/list/inspect), nie Config.Env,
und führt keine Start/Stop/Deploy-Aktionen aus.

Daten (SQLite + instance.key): ${DATA_DIR} -> in Proxmox-Backup einschliessen.
  Konsistent sichern: systemctl stop homedex, Verzeichnis als tar sichern,
  systemctl start homedex. Nur homedex.db kopieren (bei laufendem Dienst)
  kann WAL-Daten verlieren.
Service: systemctl status homedex | journalctl -u homedex -f
Update: Host-Script erneut laufen lassen oder Installer erneut ausführen
        (Binary wird ersetzt, ${DATA_DIR} bleibt erhalten).
        Gepinnt: HOMEDEX_VERSION=vX.Y.Z bash homedex-install.sh
EOF

motd_ssh
customize
cleanup_lxc

echo -e "${TAB}Homedex-Web-UI: ${GN}http://${LOCAL_IP}:${PORT}/${CL}"
echo -e "${TAB}Beim ersten Aufruf erscheint der Setup-Wizard (Admin-Passwort anlegen) – danach sofort nutzbar.${CL}"
