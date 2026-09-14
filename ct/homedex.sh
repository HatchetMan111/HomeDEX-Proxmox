#!/usr/bin/env bash
# Homedex – Proxmox VE Helper-Script (LXC)
# Läuft auf dem Proxmox-Host (PVE-Shell). Erstellt einen LXC-Container,
# in dem Homedex (Go-Backend + eingebettete Svelte-Web-UI) nativ per
# systemd auf Port 7377 läuft – ohne Docker-Pflicht.
#
# Verwendung (Proxmox-Host als root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main/ct/homedex.sh)"
# Optional mit Vorgaben:
#   var_cpu=2 var_ram=1024 var_disk=4 bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main/ct/homedex.sh)"
#
# Am Ende: Web-UI (Setup-Wizard beim ersten Aufruf) auf http://<LXC-IP>:7377
#
# Quellen:
#   Backend + Web-UI: https://github.com/HarshShah0203/homedex
#   Release-Binary enthält die bereits gebaute Web-UI (kein Node-Build nötig).

# Eigenes Repo als Script-Basis: ohne das sucht die Engine install/*.sh im
# Community-Repo statt in diesem Fork (404). Muss VOR dem Laden des Cores stehen.
COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main}"
export COMMUNITY_SCRIPTS_URL

# Community-Scripts-Core laden (Standard-Vorgehen der Proxmox Community-Scripts)
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
# shellcheck disable=SC1090,SC1091
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 tteck
# License: MIT
# Source: https://github.com/HarshShah0203/homedex

APP="Homedex"
var_hostname="${var_hostname:-homedex}"
var_tags="${var_tags:-homelab;inventory;homedex}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_arch="${var_arch:-amd64}"
var_unprivileged="${var_unprivileged:-1}"
# nesting+keyctl: erlaubt Docker im LXC (für lokales Discovery per Unix-Socket).
var_features="${var_features:-nesting=1,keyctl=1}"

var_homedex_port="${var_homedex_port:-7377}"
# var_docker=0 überspringt die automatische Docker-Installation im LXC
# (dann Remote-Docker per tcp:// oder SSH-Host im Wizard eintragen).
var_docker="${var_docker:-1}"
export var_homedex_port var_docker

header_info "$APP"
variables
color
catch_errors

# Host-Preflight: früh abbrechen, bevor ein halbfertiger Container entsteht.
if command -v pveversion >/dev/null 2>&1; then
  FREE_HOST_MB="$(df -m --output=avail / 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"
  if [[ "${FREE_HOST_MB:-0}" -lt 1024 ]]; then
    msg_error "Host-/: nur ${FREE_HOST_MB} MB frei (min. 1024 MB). Bitte aufräumen, dann erneut starten. Keine Änderung vorgenommen."
    exit 1
  fi
  FREE_RAM_MB="$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}' || echo 0)"
  if [[ "${FREE_RAM_MB:-0}" -lt 512 ]]; then
    msg_warn "Host hat nur ${FREE_RAM_MB} MB freien RAM – LXC-Erstellung läuft trotzdem, kann aber langsam sein."
  fi
fi

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -x /opt/homedex/homedex ]]; then
    msg_error "Keine Homedex-Installation in /opt/homedex gefunden!"
    exit 1
  fi
  msg_info "Aktualisiere Homedex auf das neueste Release"
  export HOMEDEX_PORT="$var_homedex_port"
  # Gleicher Installer wie bei der Erstinstallation (idempotent, Daten bleiben erhalten)
  source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
  color
  catch_errors
  setting_up_container
  network_check
  update_os
  # Installer erneut holen: läuft bereits IM Container, daher direkt ausführen
  if [[ -f /opt/homedex/homedex-install.sh ]]; then
    bash /opt/homedex/homedex-install.sh
  else
    msg_error "Installer /opt/homedex/homedex-install.sh nicht gefunden."
    exit 1
  fi
  msg_ok "Update abgeschlossen – Daten in /var/lib/homedex bleiben erhalten."
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Web-UI (beim ersten Aufruf Setup-Wizard für Admin-Passwort):${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:${var_homedex_port}${CL}"
echo -e "${INFO}${YW}Health-Check:${CL} http://${IP}:${var_homedex_port}/api/health"
echo -e "${INFO}Daten (SQLite) im Container: /var/lib/homedex – z. B. per Proxmox-Backup sichern.${CL}"
