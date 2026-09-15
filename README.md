# Homedex für Proxmox VE (LXC) – eigenständiges Repo

Installiert [Homedex](https://github.com/HarshShah0203/homedex) (Go-Backend + eingebettete Svelte-Web-UI)
als LXC auf Proxmox VE – im Stil der Proxmox Community-Scripts.

Am Ende: `http://<LXC-IP>:7377/` mit Setup-Wizard beim ersten Aufruf (Admin-Passwort anlegen),
danach sofort nutzbar (Services-, Ports-, Routen-, Expiry-Übersicht nach erstem Scan).

Im Wizard unter **First source → Docker source** eintragen:
`Source name=Local Docker`, `Read-only endpoint=unix:///var/run/docker.sock`
(Compose-Prefill `tcp://docker-socket-proxy:2375` NICHT übernehmen),
optional `Host name=docker-local`, `Host address=127.0.0.1` →
**Test connection** → **Save and run first scan**.

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

Mit Socket-Proxy (Upstream-Sicherheitsmodell, POST=0-Filter statt rohem Socket):

```bash
var_docker_proxy=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main/ct/homedex.sh)"
# danach im Wizard: tcp://127.0.0.1:2375
```

Release pinnen (statt neuestes):

```bash
var_homedex_version=v0.1.4 bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/HomeDEX-Proxmox/main/ct/homedex.sh)"
```

## Struktur

```
ct/homedex.sh              # Host-Script: erstellt LXC (Debian 12, nativ, ohne Docker-Pflicht)
install/homedex-install.sh # läuft IM Container: Release-Binary + systemd-Service
```

Stack in `/opt/homedex`:
- `homedex` (Release-Binary von GitHub, enthält die gebaute Web-UI, `:7377`, SHA256-geprüft via `checksums.txt`)
- Daten (SQLite + `instance.key`) in `/var/lib/homedex` (0700, `homedex:homedex`)
- Service `homedex.service` mit `HOMEDEX_LISTEN=:7377` (alle Interfaces → LAN erreichbar),
  `SupplementaryGroups=docker`, `After=docker.service`
- Docker (`docker.io`) wird automatisch mitinstalliert, der `homedex`-User landet
  in der `docker`-Gruppe → im Setup-Wizard als erste Quelle einfach
  `unix:///var/run/docker.sock` eintragen, testen, speichern, scannen.
  (`tcp://docker-socket-proxy:2375` aus der Homedex-Doku gilt nur für deren
  Compose-Stack und funktioniert hier nicht.)

## Erste Quelle im Wizard (Schritt für Schritt)

1. Homedex-UI öffnen → Admin-Passwort anlegen.
2. **Sources → First source**: Name z. B. `Local Docker`.
3. **Read-only endpoint**: exakt `unix:///var/run/docker.sock` (3 Slashes) eintragen –
   NICHT den vorausgefüllten Compose-Wert `tcp://docker-socket-proxy:2375` übernehmen.
4. Optional: Host name `docker-local`, Host address `127.0.0.1` (hilft der Routen-Auflösung).
5. **Test connection** → muss `OK` zeigen → **Save and run first scan**.
6. Nach ca. 1 Minute: Services-, Ports-, Routen-, Expiry-Übersicht.

Hintergrund: Homedex ruft nur GET auf (`/version`, `/info`, Container-Liste inkl.
gestoppt, Container-Inspect), liest nie `Config.Env` und hat keine
Start/Stop/Deploy-Endpoints. Der rohe Unix-Socket ist trotzdem privilegiert
(`:ro` schützt nur die Socket-Datei, nicht die Docker-API – siehe
[Upstream](https://github.com/HarshShah0203/homedex/blob/main/docs/DOCKER_SOCKET_PROXY.md)).
Wer das Compose-Sicherheitsmodell will: mit `var_docker_proxy=1` installieren,
dann steht ein lokaler Proxy mit `POST=0` auf `127.0.0.1:2375` bereit und im
Wizard wird `tcp://127.0.0.1:2375` eingetragen.

## Troubleshooting: Docker-Quelle

**Fehler:**
`error during connect: Get "http://docker-socket-proxy:2375/v1.47/version": dial tcp: lookup docker-socket-proxy on 192.168.178.111:53: no such host`

Ursache: Der vorausgefüllte Compose-Endpoint wurde übernommen. `docker-socket-proxy`
existiert nur im Homedex-Compose-Netzwerk, nicht im LXC → DNS `no such host` ist erwartet.

Fix:
- Endpoint auf `unix:///var/run/docker.sock` ändern, erneut **Test connection**.
- Im LXC prüfen:
  ```bash
  systemctl status homedex docker --no-pager
  ls -l /var/run/docker.sock; id homedex
  curl -fsS --unix-socket /var/run/docker.sock http://localhost/version
  curl -fsS http://127.0.0.1:7377/api/health
  journalctl -u homedex -e --no-pager
  ```
- Falls `homedex kann /var/run/docker.sock nicht lesen`: `systemctl restart homedex`
  (Gruppe greift erst nach Neustart), LXC-Features `nesting=1,keyctl=1` prüfen.
- Proxy-Modus: `curl -fsS http://127.0.0.1:2375/version`, Container
  `docker ps | grep homedex-socket-proxy`.
- Remote-Docker ohne lokalen Daemon: `tcp://IP:2375` (nur privates Netz, kein Auth),
  TLS `https://IP:2376` mit CA/Client-Zert, oder `ssh://user@host` (siehe
  [Connectors](https://github.com/HarshShah0203/homedex/blob/main/docs/CONNECTORS.md)).

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
cat /opt/homedex/README.txt   # Wizard-Endpoint + Version für diesen LXC
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
  Oder gezielt: `pct exec <CTID> -- bash /opt/homedex/homedex-install.sh`.
  Gepinnt: `HOMEDEX_VERSION=v0.1.4 bash /opt/homedex/homedex-install.sh` im Container.
- Backup: `/var/lib/homedex` (inkl. `instance.key`) in Proxmox-Backup einschließen.
  Konsistent: `systemctl stop homedex` → Verzeichnis als tar sichern → `systemctl start homedex`.
  Nur `homedex.db` bei laufendem Dienst kopieren kann WAL-Daten verlieren. Vor dem Ersetzen die
  [Backup-Hinweise](https://github.com/HarshShah0203/homedex/blob/main/docs/BACKUP_AND_DATA.md) lesen.
  `HOMEDEX_SECRET`-Rotation wird von Upstream v0.1 nicht unterstützt – Key behalten.
