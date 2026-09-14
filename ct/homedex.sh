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
# var_skip_storage_check=1 überspringt den Storage-Preflight (nicht empfohlen).
var_skip_storage_check="${var_skip_storage_check:-0}"
export var_homedex_port var_docker var_skip_storage_check

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

# Storage-Preflight (Host): erkennt verwaiste LVM-Prozesse, hängende LVM-Locks
# und volle Thin-Pools, BEVOR build_container einen halbfertigen Container
# (lock: create in der Config) hinterlässt und lvs/vgs/pvesm/GUI blockieren.
# Hintergrund: ein verwaistes lvcreate (PPID 1, hängt in semop) hält den
# V_pve-Lock – danach warten alle LVM-Aufrufe ewig, GUI/API/Shell fallen um.
# Hier wird nie automatisch gekillt – nur kontrolliert abgebrochen mit Anleitung.
function storage_preflight() {
  command -v pveversion >/dev/null 2>&1 || return 0
  if [[ "${var_skip_storage_check:-0}" == "1" ]]; then
    msg_warn "Storage-Preflight übersprungen (var_skip_storage_check=1)"
    return 0
  fi
  msg_info "Storage-Preflight (LVM-Health)"

  # 1. Hängende LVM-Prozesse: lvcreate & Co. in D-State oder >10 Min Laufzeit.
  STUCK_PIDS="$(ps -eo pid,ppid,etimes,stat,args 2>/dev/null | awk '$5 ~ /(^|\/)(lvcreate|lvremove|lvconvert|lvresize|lvextend|pvmove|vzcreate)/ && ($3 > 600 || $4 ~ /D/) {print "PID "$1" (PPID "$2", "$3"s, state "$4"): "$5}' || true)"
  if [[ -n "${STUCK_PIDS:-}" ]]; then
    msg_error "Hängende LVM-Prozesse gefunden (blockieren den V_pve-Lock):"
    echo "$STUCK_PIDS"
    echo -e "${INFO}Bereinigen, dann Script erneut starten:${CL}"
    echo -e "${TAB}kill -9 <PID>  # verwaistes lvcreate töten – gibt den Lock sofort frei"
    echo -e "${TAB}timeout 10 vgs  # muss danach sofort antworten"
    echo -e "${TAB}pct unlock <CTID> / pct destroy <CTID>  # halb erstellten Container aufräumen"
    exit 1
  fi
  msg_ok "Keine hängenden LVM-Prozesse"

  # 2. Antwortet LVM überhaupt? (hängt bei gehaltenem Lock ewig → mit timeout testen)
  if ! timeout 25 vgs --noheadings >/dev/null 2>&1; then
    msg_error "LVM antwortet nicht (timeout 25s bei 'vgs') – vermutlich gehaltener V_pve-Lock. Prüfen: ps aux | grep -E 'lvcreate|vzcreate' (D-State?). Abbruch vor der Container-Erstellung."
    exit 1
  fi
  msg_ok "LVM antwortet"

  # 3. Thin-Pool-Füllstand: voller Pool → lvcreate hängt/failed (Bsp: got unexpected control message).
  POOLS="$(timeout 25 lvs --noheadings --separator '|' -o vg_name,pool_lv,data_percent,metadata_percent 2>/dev/null || true)"
  POOL_ABORT=0
  while IFS='|' read -r VG POOL DATA META _REST; do
    VG="$(echo "$VG" | tr -d ' ')"
    POOL="$(echo "$POOL" | tr -d ' ')"
    [[ -z "${POOL:-}" ]] && continue
    DATA_NUM="$(echo "${DATA:-0}" | tr -d ' %')"
    META_NUM="$(echo "${META:-0}" | tr -d ' %')"
    if awk "BEGIN {exit !((${DATA_NUM:-0} >= 98) || (${META_NUM:-0} >= 90))}"; then
      msg_error "Thin-Pool ${VG}/${POOL} kritisch voll (data ${DATA}%, meta ${META}%) – lvcreate würde hängen/fehlschlagen. Pool erweitern/aufräumen, dann erneut starten."
      POOL_ABORT=1
    elif awk "BEGIN {exit !((${DATA_NUM:-0} >= 90) || (${META_NUM:-0} >= 75))}"; then
      msg_warn "Thin-Pool ${VG}/${POOL} stark gefüllt (data ${DATA}%, meta ${META}%) – im Auge behalten."
    fi
  done <<<"$POOLS"
  if [[ "$POOL_ABORT" == "1" ]]; then
    exit 1
  fi
  msg_ok "Thin-Pools ok"

  # 4. Alte Container-Locks (lock: create/...) – nur Hinweis, kein Abbruch.
  STALE_LOCKS="$(grep -l '^lock:' /etc/pve/nodes/*/lxc/*.conf /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null || true)"
  if [[ -n "${STALE_LOCKS:-}" ]]; then
    msg_warn "Alte Container-Locks gefunden (ggf. Reste früherer Abbrüche):"
    echo "$STALE_LOCKS" | while read -r f; do echo -e "${TAB}${f}: $(grep '^lock:' "$f")"; done
    echo -e "${TAB}Aufräumen z. B. mit: pct unlock <CTID>"
  fi
}

storage_preflight

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
