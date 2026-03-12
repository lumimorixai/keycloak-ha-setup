# Keycloak HA Setup – Projekt-Kontext

## Ziel

Reproduzierbares HA-Keycloak-Setup via idempotenter Shell-Skripte für 4 Ubuntu 24.04 LTS VMs.
Der vollständige Architektur- und Umsetzungsplan liegt in `docs/PLAN.md`.

## Stack

| Komponente   | Version / Variante          | Hinweis                                      |
|--------------|-----------------------------|----------------------------------------------|
| Keycloak     | 26.5.5 (Quarkus-Distro)    | Pinned in `.env` als `KC_VERSION`            |
| PostgreSQL   | 16 (offizielles pgdg-Repo) | Mindestversion für KC 26.4+ ist PG 13        |
| Java         | OpenJDK 21 (Adoptium Temurin) | Adoptium statt Ubuntu-Paket – besser getestet mit Quarkus |
| Nginx        | Aktuell (offizielles Repo)  | TLS-Terminierung + Reverse Proxy             |
| Certbot      | Aktuell                     | Let's Encrypt ACME, Auto-Renewal via Cron    |
| OS           | Ubuntu 24.04 LTS            | Auf allen 4 VMs                              |

## Architektur

```
Internet → lb01 (Nginx + TLS :443)
              ├── kc01 (Keycloak :8080)
              └── kc02 (Keycloak :8080)
                    beide → db01 (PostgreSQL :5432)
           kc01 ↔ kc02 (JGroups TCP :7800)
```

- **4 VMs:** db01 (PostgreSQL), kc01 + kc02 (Keycloak HA), lb01 (Nginx + Certbot)
- **Cluster-Discovery:** JDBC_PING2 über gemeinsame PostgreSQL-DB (kein Multicast)
- **Cluster-Traffic:** JGroups TCP auf Port 7800 direkt zwischen kc01 ↔ kc02
- **TLS-Terminierung:** Am Nginx. Keycloak hört nur HTTP, nutzt `proxy-headers=xforwarded`
- **Session-Stickiness:** Nginx `ip_hash` (späteres Upgrade auf Cookie-basiert möglich)

## Repository-Struktur

```
keycloak-ha-setup/
├── CLAUDE.md                   ← diese Datei
├── README.md
├── .env.example
├── .gitignore                  # enthält: .env, *.bak
├── scripts/
│   ├── 00-common.sh            # Shared Functions, .env-Loader, Idempotenz-Helpers
│   ├── 01-setup-db.sh          # PostgreSQL – Ausführung auf db01
│   ├── 02-setup-keycloak.sh    # JDK + Keycloak – Ausführung auf kc01 und kc02
│   ├── 03-setup-nginx.sh       # Nginx + Certbot – Ausführung auf lb01
│   ├── 04-harden.sh            # UFW + SSH + Fail2ban – Ausführung auf allen VMs
│   └── 99-healthcheck.sh       # Validierung – Ausführung von lb01 oder extern
├── configs/
│   ├── keycloak/
│   │   ├── keycloak.conf.tpl   # Keycloak-Server-Config (Template)
│   │   └── keycloak.service    # systemd Unit-File
│   ├── nginx/
│   │   └── keycloak.conf.tpl   # Nginx vHost (Template)
│   └── postgresql/
│       └── pg_hba.conf.tpl     # PostgreSQL-Zugriff (Template)
└── docs/
    ├── PLAN.md                 # Detaillierter Umsetzungsplan mit Config-Spezifikationen
    ├── ARCHITECTURE.md
    ├── ROLLBACK.md
    └── UPGRADE.md
```

## Konventionen für alle Skripte

### Idempotenz (PFLICHT)

Jeder Installationsschritt prüft zuerst den Ist-Zustand. Erneutes Ausführen darf nichts verändern, wenn der Zielzustand bereits erreicht ist. Muster:

- Pakete: `dpkg -s <paket> &>/dev/null || apt install -y <paket>`
- DB/User: `SELECT 1 FROM pg_database WHERE datname = '...'` vor `CREATE DATABASE`
- Dateien: Backup anlegen, dann nur deployen wenn Inhalt abweicht
- Services: `systemctl is-active --quiet <svc> || systemctl start <svc>`

### Shell-Qualität

- Alle Skripte MÜSSEN `shellcheck --severity=warning` bestehen
- Shebang: `#!/usr/bin/env bash`
- `set -euo pipefail` am Anfang jedes Skripts
- Alle Variablen in doppelten Anführungszeichen: `"${VAR}"`
- Kein `cd` ohne Fehlerbehandlung

### 00-common.sh Helper-Funktionen

Jedes Skript beginnt mit `source "$(dirname "$0")/00-common.sh"`. Verfügbare Funktionen:

| Funktion            | Zweck                                                         |
|---------------------|---------------------------------------------------------------|
| `load_env`          | Lädt `.env`, prüft Pflichtfelder, bricht bei Fehler ab        |
| `require_root`      | Prüft root/sudo, bricht ab falls nicht                        |
| `ensure_package`    | apt install nur wenn nicht installiert                         |
| `deploy_config`     | Template → Ziel via envsubst, Backup falls Ziel existiert     |
| `ensure_service`    | systemctl enable + start nur wenn nicht bereits aktiv          |
| `backup_file`       | Timestamped Backup (.bak.YYYYMMDD-HHMMSS)                    |
| `log_info`          | `[INFO] timestamp message` auf stdout                         |
| `log_warn`          | `[WARN] timestamp message` auf stderr                         |
| `log_err`           | `[ERR]  timestamp message` auf stderr                         |

### Konfigurationen

- Alle Configs als `.tpl`-Templates mit `${VARIABLE}`-Platzhaltern
- Platzhalter werden via `envsubst` zur Deployment-Zeit ersetzt
- Variablen-Quelle ist ausschließlich `.env` (geladen über `load_env`)
- Passwörter NIEMALS im Repo – nur in `.env` (steht in `.gitignore`)

## Nicht-Offensichtliches (wichtig beim Generieren)

- **Keycloak Build-Step:** Nach jeder Änderung an `keycloak.conf` muss `kc.sh build` ausgeführt werden, BEVOR der Service mit `--optimized` gestartet wird. Ohne Build startet Keycloak mit alter Config.
- **Admin-User nur beim ersten Start:** `KEYCLOAK_ADMIN` und `KEYCLOAK_ADMIN_PASSWORD` als Environment-Variablen werden nur beim allerersten Start ausgewertet, wenn noch kein Admin existiert. Danach ignoriert Keycloak sie.
- **Startup-Reihenfolge:** kc01 zuerst starten und warten bis `/health/ready` 200 liefert, dann kc02. Verhindert Race-Condition bei DB-Migration.
- **JDBC_PING2 ≠ kein JGroups:** JDBC_PING2 nutzt die DB NUR für Node-Discovery. Der eigentliche Cluster-Datenaustausch läuft über JGroups TCP (Port 7800). Wenn 7800 blockiert ist, laufen die Nodes isoliert – ohne Fehler, nur mit Warnung im Log.
- **Nginx Proxy-Buffer:** Keycloak-Token können sehr groß werden (viele Realm-Rollen). Ohne `proxy_buffer_size 128k` und `proxy_buffers 4 256k` kommen 502-Fehler.
- **Let's Encrypt Staging:** Beim Testen immer `--staging` nutzen. Produktiv-Rate-Limit: max 5 Zertifikate pro Domain pro Woche.
- **PostgreSQL Auth:** `scram-sha-256` bevorzugen statt `md5` in pg_hba.conf.
- **Keycloak Download:** SHA512-Checksum gegen `https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/keycloak-${KC_VERSION}.tar.gz.sha512` verifizieren.

## Netzwerk-Ports (Referenz für Firewall-Regeln)

| Von   | Nach  | Port | Zweck                        |
|-------|-------|------|------------------------------|
| User  | lb01  | 443  | HTTPS (Keycloak UI/API)      |
| User  | lb01  | 80   | HTTP (ACME Challenge only)   |
| lb01  | kc*   | 8080 | Reverse Proxy → Keycloak     |
| kc*   | db01  | 5432 | PostgreSQL                   |
| kc01  | kc02  | 7800 | JGroups TCP (bidirektional)  |

## Validierung nach Code-Generierung

Nach dem Erstellen jeder Datei:

1. **Shell-Skripte:** `shellcheck --severity=warning scripts/*.sh`
2. **Templates:** Prüfe, dass jede `${VARIABLE}` in `.env.example` definiert ist und umgekehrt
3. **systemd Unit:** `systemd-analyze verify` (falls lokal verfügbar)
4. **Nginx Config:** `nginx -t` (nach envsubst auf einer Test-Config)
