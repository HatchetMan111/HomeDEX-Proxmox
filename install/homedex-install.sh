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
INSTALL_DIR="/opt/homedex"
DATA_DIR="${HOMEDEX_DATA_DIR:-/var/lib/homedex}"
SERVICE_USER="homedex"

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
msg_info "Ermittle neuestes Homedex-Release"
VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)"
if [[ -z "${VERSION:-}" ]]; then
  msg_warn "GitHub-API nicht erreichbar – Fallback v0.1.4"
  VERSION="v0.1.4"
fi
FILE_VERSION="${VERSION#v}"
TARBALL="homedex_${FILE_VERSION}_linux_${DEB_ARCH}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${TARBALL}"
msg_ok "Release ${VERSION} (${TARBALL})"

# ---------- 4. Dependencies ----------
msg_info "Installing Dependencies"
$STD apt-get install -y curl ca-certificates tar sqlite3
msg_ok "Installed Dependencies"

# ---------- 5. Binary herunterladen ----------
msg_info "Lade Homedex ${VERSION} herunter"
mkdir -p "$INSTALL_DIR"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
if ! curl -fsSL "$URL" -o "$TMPDIR/homedex.tar.gz"; then
  msg_error "Download fehlgeschlagen: $URL"
  exit 1
fi
tar -xzf "$TMPDIR/homedex.tar.gz" -C "$TMPDIR"
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
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
mkdir -p "$DATA_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR"
chmod 0750 "$DATA_DIR"
msg_ok "User + Datenverzeichnis bereit"

# ---------- 7. systemd-Service ----------
msg_info "Richte systemd-Service ein (Port ${PORT})"
cat <<EOF >/etc/systemd/system/homedex.service
[Unit]
Description=Homedex – Homelab Inventory (Go + embedded Web-UI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
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

# ---------- 9. Kurzanleitung ----------
cat <<EOF >"$INSTALL_DIR/README.txt"
Homedex LXC – Kurzanleitung
===========================
Web-UI : http://${LOCAL_IP}:${PORT}/
Health : http://${LOCAL_IP}:${PORT}/api/health

Erster Aufruf: Setup-Wizard im Browser legt das Admin-Passwort an,
danach erste Quelle verbinden (z. B. Docker-Socket-Proxy
tcp://docker-socket-proxy:2375, Traefik, Caddy, NPM oder SSH-Host)
und ersten Scan starten – siehe Sources in der UI.

Daten (SQLite): ${DATA_DIR}  -> in Proxmox-Backup einschliessen.
Service: systemctl status homedex | journalctl -u homedex -f
Update: Host-Script erneut laufen lassen oder Installer erneut ausführen
        (Binary wird ersetzt, ${DATA_DIR} bleibt erhalten).
EOF

motd_ssh
customize
cleanup_lxc

echo -e "${TAB}Homedex-Web-UI: ${GN}http://${LOCAL_IP}:${PORT}/${CL}"
echo -e "${TAB}Beim ersten Aufruf erscheint der Setup-Wizard (Admin-Passwort anlegen) – danach sofort nutzbar.${CL}"
