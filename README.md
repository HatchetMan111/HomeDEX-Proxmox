# Homedex für Proxmox VE (LXC) – eigenständiges Repo

Installiert [Homedex](https://github.com/HarshShah0203/homedex) (Go-Backend + eingebettete Svelte-Web-UI)
als LXC auf Proxmox VE – im Stil der Proxmox Community-Scripts.

Am Ende: `http://<LXC-IP>:7377/` mit Setup-Wizard beim ersten Aufruf (Admin-Passwort anlegen),
danach sofort nutzbar (Services-, Ports-, Routen-, Expiry-Übersicht nach erstem Scan).

Hat nichts mit Valhalla/Routing zu tun – eigenes Projekt, eigenes Repo.

## Install (Proxmox-Host als root)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main/ct/homedex.sh)"
```

Mit Vorgaben (ohne Menü):

```bash
var_cpu=2 var_ram=1024 var_disk=8 var_homedex_port=7377 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main/ct/homedex.sh)"
```

Ohne automatische Docker-Installation (nur Homedex, Remote-Quellen per Hand):

```bash
var_docker=0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main/ct/homedex.sh)"
```

## Struktur

```
ct/homedex.sh              # Host-Script: erstellt LXC (Debian 12, nativ, ohne Docker-Pflicht)
install/homedex-install.sh # läuft IM Container: Release-Binary + systemd-Service
```

Stack in `/opt/homedex`:
- `homedex` (Release-Binary von GitHub, enthält die gebaute Web-UI, `:7377`)
- Daten (SQLite) in `/var/lib/homedex`
- Service `homedex.service` mit `HOMEDEX_LISTEN=:7377` (alle Interfaces → LAN erreichbar)
- Docker (`docker.io`) wird automatisch mitinstalliert, der `homedex`-User landet
  in der `docker`-Gruppe → im Setup-Wizard als erste Quelle einfach
  `unix:///var/run/docker.sock` eintragen, testen, speichern, scannen.
  (`tcp://docker-socket-proxy:2375` aus der Homedex-Doku gilt nur für deren
  Compose-Stack und funktioniert hier nicht.)

## Manuell in bestehendem LXC / VM (Debian/Ubuntu, als root)

```bash
curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main/install/homedex-install.sh -o /tmp/homedex-install.sh
bash /tmp/homedex-install.sh
```

## Nützliches im LXC

```bash
systemctl status homedex
journalctl -u homedex -f
curl http://127.0.0.1:7377/api/health
```

## Ressourcen

- Default: 2 CPU / 1 GB RAM / 8 GB Disk (8 GB wegen Docker-Overlay).
- Update: Host-Script erneut laufen lassen (Binary wird ersetzt, `/var/lib/homedex` bleibt).
- Backup: `/var/lib/homedex` in Proxmox-Backup einschließen. Vor dem Ersetzen die
  [Backup-Hinweise](https://github.com/HarshShah0203/homedex/blob/main/docs/BACKUP_AND_DATA.md) lesen.
