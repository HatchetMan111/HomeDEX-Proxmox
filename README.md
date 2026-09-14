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

## Wenn die Container-Erstellung hängt (LVM-Lock auf dem Host)

Symptom: `vzcreate` stirbt mit `got unexpected control message`, Config enthält nur
`lock: create`, danach hängen `lvs`/`vgs`/`pvesm` ewig, GUI zeigt keine Namen mehr,
API → 596, Shell/Console → exit code 1. Ursache ist Host-seitig: ein verwaistes
`lvcreate --name vm-<CTID>-disk-0` (PPID 1, hängt in `semop`) hält den `V_pve`-Lock.
Das ct-Script erkennt das seit dem Storage-Preflight vorab und bricht kontrolliert ab.

Manuelle Bergung (Host-Shell als root):

```bash
ps aux | grep -E 'lvcreate|vzcreate'   # D-State / hohe Laufzeit / PPID 1 suchen
timeout 10 vgs                          # muss sofort antworten – sonst Lock gehalten
kill -9 <lvcreate-PID>                  # gibt den Lock sofort frei
timeout 10 vgs && lvs                   # Kontrolle: antwortet wieder
pct unlock <CTID>                       # ggf. lock: create entfernen
pct destroy <CTID>                      # halb erstellten Container entsorgen
pvesm status                            # Kontrolle: antwortet wieder
lvs -o vg_name,pool_lv,data_percent,metadata_percent  # Thin-Pool-Füllstand prüfen
```

Danach Host-Script erneut laufen lassen.

## Ressourcen

- Default: 2 CPU / 1 GB RAM / 8 GB Disk (8 GB wegen Docker-Overlay).
- Update: Host-Script erneut laufen lassen (Binary wird ersetzt, `/var/lib/homedex` bleibt).
- Backup: `/var/lib/homedex` in Proxmox-Backup einschließen. Vor dem Ersetzen die
  [Backup-Hinweise](https://github.com/HarshShah0203/homedex/blob/main/docs/BACKUP_AND_DATA.md) lesen.
