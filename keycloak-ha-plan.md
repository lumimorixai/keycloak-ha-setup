# Keycloak HA-Cluster – Projekt- und Umsetzungsplan

## 1. Ziel-Architektur

### Übersicht

4 VMs, alle Debian 13 (Trixie), saubere Rollentrennung:

```
                    ┌─────────────────────┐
                    │   Internet / User    │
                    └──────────┬──────────┘
                               │ HTTPS :443
                    ┌──────────▼──────────┐
                    │      lb01           │
                    │  Nginx + Certbot    │
                    │  Let's Encrypt TLS  │
                    └──┬──────────────┬───┘
                       │              │
              HTTP :8080        HTTP :8080
                       │              │
              ┌────────▼───┐  ┌───────▼────────┐
              │    kc01    │  │      kc02      │
              │ Keycloak   │  │   Keycloak     │
              │ 26.5.5     │  │   26.5.5       │
              │ JDK 21     │  │   JDK 21       │
              └────┬───────┘  └───────┬────────┘
                   │   JDBC_PING2     │
                   │   (Discovery     │
                   │    über DB)      │
              ┌────▼──────────────────▼────┐
              │           db01             │
              │     PostgreSQL 16          │
              └────────────────────────────┘
```

### VM-Sizing (Minimum-Empfehlung)

| VM   | vCPU | RAM  | Disk  | Rolle                          |
|------|------|------|-------|--------------------------------|
| db01 | 2    | 4 GB | 50 GB | PostgreSQL 16                  |
| kc01 | 2    | 4 GB | 20 GB | Keycloak 26.5.5 + JDK 21      |
| kc02 | 2    | 4 GB | 20 GB | Keycloak 26.5.5 + JDK 21      |
| lb01 | 1    | 1 GB | 10 GB | Nginx + Certbot                |

### Netzwerk-Anforderungen

| Von   | Nach  | Port      | Protokoll | Zweck                           |
|-------|-------|-----------|-----------|----------------------------------|
| User  | lb01  | 443       | HTTPS     | Zugriff auf Keycloak             |
| User  | lb01  | 80        | HTTP      | ACME Challenge (Let's Encrypt)   |
| lb01  | kc01  | 8080      | HTTP      | Reverse Proxy → Keycloak         |
| lb01  | kc02  | 8080      | HTTP      | Reverse Proxy → Keycloak         |
| kc01  | db01  | 5432      | TCP       | PostgreSQL-Verbindung            |
| kc02  | db01  | 5432      | TCP       | PostgreSQL-Verbindung            |
| kc01  | kc02  | 7800      | TCP       | JGroups Cluster-Kommunikation    |
| kc02  | kc01  | 7800      | TCP       | JGroups Cluster-Kommunikation    |

**Wichtig:** Zwischen kc01 und kc02 muss Port 7800 (JGroups TCP) offen sein.
JDBC_PING2 nutzt die DB nur für Discovery – der eigentliche Cluster-Traffic
läuft über JGroups TCP (Port 7800).

---

## 2. Repository-Struktur

```
keycloak-ha-setup/
│
├── CLAUDE.md                      # Projekt-Memory für Claude Code
├── README.md                      # Benutzer-Dokumentation
├── .env.example                   # Zentrale Konfiguration (Template)
├── .gitignore
│
├── scripts/
│   ├── 00-common.sh               # Shared: .env-Loader, Idempotenz-Helpers
│   ├── 01-setup-db.sh             # PostgreSQL 16: Install + DB + User + pg_hba
│   ├── 02-setup-keycloak.sh       # JDK 21 + Keycloak 26.5.5 + systemd
│   ├── 03-setup-nginx.sh          # Nginx + vHost + Certbot + Auto-Renewal
│   ├── 04-harden.sh               # UFW + Fail2ban + SSH-Hardening
│   └── 99-healthcheck.sh          # Validierung aller Dienste
│
├── configs/
│   ├── keycloak/
│   │   ├── keycloak.conf.tpl      # Keycloak-Config (Template mit Platzhaltern)
│   │   └── keycloak.service       # systemd Unit-File
│   ├── nginx/
│   │   └── keycloak.conf.tpl      # Nginx vHost Template
│   └── postgresql/
│       └── pg_hba.conf.tpl        # PostgreSQL-Zugriff Template
│
└── docs/
    ├── ARCHITECTURE.md             # Dieses Architektur-Dokument
    ├── ROLLBACK.md                 # Rollback-Prozeduren pro Komponente
    └── UPGRADE.md                  # Keycloak-Upgrade-Pfad
```

---

## 3. Datei-Spezifikationen

### 3.1 `.env.example`

Zentrale Konfigurationsdatei, die vor dem Deployment als `.env` kopiert und befüllt wird.

```
# === Domain & TLS ===
KC_DOMAIN=auth.example.com
ACME_EMAIL=admin@example.com

# === VM IPs ===
DB_HOST=10.0.1.10
KC_NODE1_IP=10.0.1.11
KC_NODE2_IP=10.0.1.12
LB_HOST=10.0.1.13

# === PostgreSQL ===
DB_NAME=keycloak
DB_USER=keycloak
DB_PASSWORD=                          # Generieren: openssl rand -base64 24

# === Keycloak ===
KC_VERSION=26.5.5
KC_ADMIN_USER=admin
KC_ADMIN_PASSWORD=                    # Generieren: openssl rand -base64 24
KC_HTTP_PORT=8080
KC_HTTPS_PORT=8443
KC_JGROUPS_PORT=7800

# === Java ===
JAVA_VERSION=21
JAVA_OPTS="-Xms512m -Xmx2048m"
```

### 3.2 `scripts/00-common.sh`

Enthält folgende Helper-Funktionen (alle idempotent):

| Funktion              | Zweck                                                  |
|-----------------------|--------------------------------------------------------|
| `load_env()`          | Lädt `.env`, prüft Pflichtfelder, bricht bei Fehler ab |
| `ensure_package()`    | `apt install` nur wenn Paket nicht installiert          |
| `deploy_config()`     | Kopiert Config-Template, ersetzt Platzhalter via `envsubst`, legt Backup an falls Zieldatei existiert |
| `ensure_service()`    | `systemctl enable + start` nur wenn nicht bereits aktiv |
| `log_info/warn/err()` | Einheitliches Logging mit Timestamp                    |
| `require_root()`      | Prüft sudo/root, bricht ab falls nicht                 |
| `backup_file()`       | Erstellt timestamped Backup vor Änderungen             |

**Idempotenz-Pattern:** Jeder Installationsschritt prüft vorher den Ist-Zustand.
Erneutes Ausführen ändert nichts, wenn der Zielzustand bereits erreicht ist.

### 3.3 `scripts/01-setup-db.sh`

Ausführung auf: **db01**

Schritte (in dieser Reihenfolge):

1. PostgreSQL 16 aus offiziellem PostgreSQL-APT-Repo installieren
   (Debian 13 (Trixie) liefert PostgreSQL 16 im main-Repo, aber das
   offizielle PGDG-Repo garantiert Patch-Aktualität)
2. Keycloak-Datenbank und DB-User anlegen (idempotent via
   `SELECT 1 FROM pg_database WHERE datname = ...`)
3. `pg_hba.conf` anpassen: md5/scram-sha-256 Zugriff für kc01 + kc02
4. `postgresql.conf` Tuning: `listen_addresses = '*'`,
   `max_connections = 200`, Shared-Buffer-Anpassung
5. Firewall: Port 5432 nur für KC-Node-IPs öffnen
6. PostgreSQL restart

**Rollback:** `apt purge postgresql-16`, Datenverzeichnis liegt unter
`/var/lib/postgresql/16/main/`.

### 3.4 `scripts/02-setup-keycloak.sh`

Ausführung auf: **kc01** und **kc02**

Schritte:

1. OpenJDK 21 installieren (`temurin-21-jdk` aus Adoptium-Repo empfohlen
   gegenüber Debian-Paket, da Keycloak Quarkus-basiert und Adoptium
   besser getestet ist)
2. Dedicated User `keycloak` anlegen (nologin-Shell)
3. Keycloak 26.5.5 herunterladen und nach `/opt/keycloak/` entpacken
   (SHA512 Checksum-Verifikation!)
4. `keycloak.conf` aus Template deployen
5. Keycloak Build-Step ausführen: `kc.sh build`
   (Quarkus ahead-of-time Compilation – nötig nach jeder Config-Änderung)
6. systemd Unit-File deployen
7. Firewall: Port 8080 nur von lb01, Port 7800 nur vom jeweils
   anderen KC-Node
8. Service starten

**Keycloak-Konfiguration (`keycloak.conf.tpl`) – Kernparameter:**

```properties
# --- Database ---
db=postgres
db-url=jdbc:postgresql://${DB_HOST}:5432/${DB_NAME}
db-username=${DB_USER}
db-password=${DB_PASSWORD}

# --- HTTP ---
http-enabled=true
http-port=${KC_HTTP_PORT}
http-host=0.0.0.0

# --- Hostname ---
hostname=${KC_DOMAIN}
hostname-strict=true
# TLS-Terminierung am Nginx → Keycloak hört nur HTTP
proxy-headers=xforwarded

# --- Cluster / Cache ---
cache=ispn
# JDBC_PING2: Node-Discovery über gemeinsame DB
# Kein Multicast nötig – ideal für Cloud-VMs
cache-stack=jdbc-ping-2

# --- Health ---
health-enabled=true
metrics-enabled=true

# --- Logging ---
log=console,file
log-file=/var/log/keycloak/keycloak.log
```

**Besonderheit JDBC_PING2:** Ab Keycloak 26.x ist `jdbc-ping-2` der empfohlene
Discovery-Mechanismus. Er speichert Node-Adressen in der Keycloak-DB
und braucht kein UDP-Multicast. Der eigentliche Cluster-Datenaustausch
läuft trotzdem über JGroups TCP (Port 7800) direkt zwischen den Nodes.

**systemd Unit-File (`keycloak.service`):**

```ini
[Unit]
Description=Keycloak Identity Provider
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=keycloak
Group=keycloak
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
WorkingDirectory=/opt/keycloak
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
Environment="JAVA_OPTS=${JAVA_OPTS}"

[Install]
WantedBy=multi-user.target
```

**`--optimized`:** Voraussetzung ist ein vorheriger `kc.sh build`.
Überspringt die Build-Phase beim Start → deutlich schnellerer Startup.

### 3.5 `scripts/03-setup-nginx.sh`

Ausführung auf: **lb01**

Schritte:

1. Nginx aus offiziellem Nginx-Repo installieren
2. Certbot + Certbot-Nginx-Plugin installieren
3. Nginx vHost aus Template deployen
4. Zertifikat via Certbot beziehen (interaktiv beim ersten Mal,
   Cron-Renewal automatisch)
5. Firewall: Port 80 + 443 offen, SSH nur für Admin-IPs

**Nginx vHost (`keycloak.conf.tpl`):**

```nginx
upstream keycloak_backend {
    # Sticky Sessions via Cookie – WICHTIG für Keycloak!
    # Keycloak kodiert die Node-Affinität im AUTH_SESSION_ID Cookie,
    # aber für Admin-Console und Nicht-OIDC-Flows braucht man
    # Session-Stickiness auf LB-Ebene.
    ip_hash;

    server ${KC_NODE1_IP}:${KC_HTTP_PORT} max_fails=3 fail_timeout=30s;
    server ${KC_NODE2_IP}:${KC_HTTP_PORT} max_fails=3 fail_timeout=30s;
}

server {
    listen 80;
    server_name ${KC_DOMAIN};

    # ACME Challenge für Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${KC_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${KC_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${KC_DOMAIN}/privkey.pem;

    # TLS Hardening
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    # Buffer-Sizes für Keycloak (große Token/Headers)
    proxy_buffer_size          128k;
    proxy_buffers              4 256k;
    proxy_busy_buffers_size    256k;
    large_client_header_buffers 4 16k;

    location / {
        proxy_pass http://keycloak_backend;
        proxy_set_header Host               $host;
        proxy_set_header X-Real-IP          $remote_addr;
        proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  $scheme;
        proxy_set_header X-Forwarded-Port   443;

        # WebSocket-Support (Admin Console)
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Health-Check Endpoint (nicht öffentlich exponieren)
    location /health {
        proxy_pass http://keycloak_backend;
        allow 127.0.0.1;
        allow ${KC_NODE1_IP};
        allow ${KC_NODE2_IP};
        deny all;
    }
}
```

**Warum `ip_hash` und nicht `route` basierend auf Cookie?**
Keycloak selbst verwaltet Session-Affinität via `AUTH_SESSION_ID` Cookie,
das den Node-Namen enthält. Für den Produktivbetrieb wäre
Cookie-basiertes Sticky-Session-Routing (z.B. mit `sticky cookie`)
besser, das erfordert allerdings das Nginx-Plus-Modul oder das
Open-Source-Modul `nginx-sticky-module`. `ip_hash` ist ein solider
Kompromiss für den Start – kann später umgestellt werden.

### 3.6 `scripts/04-harden.sh`

Ausführung auf: **allen VMs**

Maßnahmen:

1. **UFW Firewall:** Default deny incoming, rollenspezifische Regeln (s. Netzwerk-Tabelle oben)
2. **SSH-Hardening:** `PermitRootLogin no`, `PasswordAuthentication no` (nur Key-Auth), Port optional änderbar via `.env`
3. **Fail2ban:** SSH-Jail aktivieren
4. **Automatische Sicherheitsupdates:** `unattended-upgrades` konfigurieren
5. **Kernel-Parameter:** SYN-Cookies, IP-Spoofing-Schutz

### 3.7 `scripts/99-healthcheck.sh`

Ausführung auf: **lb01** (oder von extern)

Prüft:

- PostgreSQL erreichbar (pg_isready)
- Keycloak Health-Endpoints beider Nodes (`/health/ready`, `/health/live`)
- Nginx antwortet auf HTTPS
- TLS-Zertifikat gültig und nicht kurz vor Ablauf
- Keycloak-Cluster hat 2 Nodes (via Admin-API oder Infinispan-Health)
- DNS löst korrekt auf

---

## 4. Ausführungsreihenfolge

```
Schritt  VM     Skript                   Voraussetzung
─────────────────────────────────────────────────────────
  1      alle   (manuell)                Debian 13 (Trixie) frisch installiert,
                                         SSH-Zugriff, sudo-User vorhanden
  2      alle   .env.example → .env      Passwörter generieren, IPs eintragen
  3      db01   01-setup-db.sh           .env vorhanden
  4      kc01   02-setup-keycloak.sh     DB erreichbar
  5      kc02   02-setup-keycloak.sh     DB erreichbar, kc01 läuft (für Cluster-Test)
  6      lb01   03-setup-nginx.sh        Beide KC-Nodes laufen, DNS zeigt auf lb01
  7      alle   04-harden.sh             Alle Dienste laufen (Hardening zuletzt,
                                         damit Firewall-Regeln nicht blockieren)
  8      lb01   99-healthcheck.sh        Alles deployed
```

**Wichtig:** DNS muss vor Schritt 6 konfiguriert sein – Certbot braucht
einen gültigen A-Record auf lb01, um das Let's-Encrypt-Zertifikat
zu beziehen.

---

## 5. Claude Code – Workflow

### 5.1 Vorbereitung

```bash
# Repo anlegen
mkdir keycloak-ha-setup && cd keycloak-ha-setup
git init

# CLAUDE.md anlegen (s. Abschnitt 5.2)
# Dann Claude Code starten:
claude
```

### 5.2 CLAUDE.md – Inhalt

Die `CLAUDE.md` im Repo-Root dient als Projekt-Memory. Claude Code
liest diese Datei automatisch zu Beginn jeder Session. Empfohlener Inhalt:

```markdown
# Keycloak HA Setup – Projekt-Kontext

## Ziel
Reproduzierbares HA-Keycloak-Setup via Shell-Skripte für 4 Debian 13 (Trixie) VMs.

## Stack
- Keycloak 26.5.5 (Quarkus-Distribution)
- PostgreSQL 16
- Nginx (Reverse Proxy + TLS-Terminierung)
- Let's Encrypt (Certbot)
- JDK 21 (Adoptium Temurin)

## Architektur
4 VMs: db01 (PostgreSQL), kc01 + kc02 (Keycloak HA), lb01 (Nginx + Certbot)
Cluster-Discovery: JDBC_PING2 über gemeinsame DB.
TLS-Terminierung am Nginx, Keycloak hört nur HTTP.

## Konventionen
- Alle Skripte MÜSSEN idempotent sein (erneutes Ausführen = kein Effekt)
- Alle Skripte MÜSSEN shellcheck-clean sein (shellcheck --severity=warning)
- Skripte sourced 00-common.sh für gemeinsame Funktionen
- Konfigurationen als .tpl-Templates mit ${VARIABLE}-Platzhaltern
- Platzhalter werden via envsubst ersetzt
- Jede Dateiänderung erstellt vorher ein Backup mit Timestamp
- Logging: einheitlich über log_info/log_warn/log_err aus 00-common.sh
- Passwörter NIEMALS im Repo – nur in .env (die in .gitignore steht)

## Nicht-Offensichtliches
- Keycloak braucht nach Config-Änderung einen `kc.sh build` vor dem Start
- `--optimized` Flag beim Start setzt vorherigen Build voraus
- proxy-headers=xforwarded ist nötig, weil TLS am Nginx terminiert wird
- Nginx braucht große Buffer (proxy_buffer_size 128k) wegen Keycloak-Token-Größe
- JDBC_PING2 nutzt die DB nur für Discovery, JGroups TCP (7800) für Cluster-Traffic
- Admin-User wird nur beim ERSTEN Start erstellt (via Env-Vars)
```

### 5.3 Prompts für Claude Code (in dieser Reihenfolge)

Jeder Prompt = ein Git-Commit. Review nach jedem Schritt.

**Prompt 1 – Grundgerüst:**
> Lies CLAUDE.md. Erstelle die Verzeichnisstruktur (scripts/, configs/,
> docs/), .env.example mit allen Variablen und Kommentaren, .gitignore
> (muss .env und *.bak enthalten), und scripts/00-common.sh mit den
> idempotenten Helper-Funktionen. Validiere mit shellcheck.

**Prompt 2 – PostgreSQL:**
> Erstelle scripts/01-setup-db.sh und configs/postgresql/pg_hba.conf.tpl.
> Das Skript soll PostgreSQL 16 aus dem offiziellen pgdg-Repo installieren,
> den Keycloak-DB-User und die Datenbank anlegen (idempotent), pg_hba.conf
> deployen und PostgreSQL neustarten. Teste Idempotenz gedanklich durch.

**Prompt 3 – Keycloak:**
> Erstelle scripts/02-setup-keycloak.sh, configs/keycloak/keycloak.conf.tpl
> und configs/keycloak/keycloak.service. Download mit SHA512-Verifikation,
> Adoptium JDK 21, keycloak-User, Build-Step, systemd-Integration.
> Beachte: Admin-User nur beim ersten Start via KEYCLOAK_ADMIN env vars.

**Prompt 4 – Nginx + TLS:**
> Erstelle scripts/03-setup-nginx.sh und configs/nginx/keycloak.conf.tpl.
> Nginx aus offiziellem Repo, vHost mit ip_hash-Upstream, TLS via Certbot,
> große Proxy-Buffer für Keycloak-Token, WebSocket-Support für Admin-Console.

**Prompt 5 – Hardening:**
> Erstelle scripts/04-harden.sh. UFW mit rollenspezifischen Regeln
> (das Skript muss den VM-Typ als Parameter akzeptieren: db, keycloak, lb),
> SSH-Hardening, Fail2ban, unattended-upgrades.

**Prompt 6 – Healthcheck:**
> Erstelle scripts/99-healthcheck.sh. Prüfe: pg_isready, Keycloak
> /health/ready auf beiden Nodes, HTTPS auf lb01, TLS-Zertifikat-Gültigkeit,
> Cluster-Membership (2 Nodes). Output als farbige Zusammenfassung.

**Prompt 7 – Dokumentation:**
> Erstelle README.md (Quick-Start, Voraussetzungen, Schritt-für-Schritt),
> docs/ARCHITECTURE.md, docs/ROLLBACK.md (pro Komponente),
> docs/UPGRADE.md (Keycloak-Version-Upgrade-Prozedur).

**Prompt 8 – Review:**
> Führe shellcheck auf allen .sh-Dateien aus. Prüfe alle .tpl-Dateien
> auf konsistente Platzhalter-Nutzung. Prüfe, dass alle Variablen aus
> .env.example in den Templates referenziert werden und umgekehrt.

---

## 6. Risiken und Hinweise

### Sicherheit
- **Alle Passwörter** werden in `.env` verwaltet, niemals committed
- **Erster Keycloak-Admin** wird via `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`
  Environment-Variablen nur beim allerersten Start gesetzt –
  danach über Admin-Console verwalten
- **PostgreSQL:** scram-sha-256 bevorzugen gegenüber md5 in pg_hba.conf
- **JGroups:** Port 7800 nur zwischen kc01 ↔ kc02, nicht öffentlich

### Rollback
| Komponente  | Rollback-Verfahren                                          |
|-------------|--------------------------------------------------------------|
| PostgreSQL  | `apt purge postgresql-16`, Daten: `/var/lib/postgresql/16/`  |
| Keycloak    | `systemctl stop keycloak`, `/opt/keycloak/` löschen, User entfernen |
| Nginx       | `apt purge nginx`, Certbot-Zertifikate bleiben unter `/etc/letsencrypt/` |
| Firewall    | `ufw reset` setzt alle Regeln zurück                        |
| Config      | Jedes deploy_config() legt `.bak`-Dateien an                 |

### Bekannte Gotchas
- **Keycloak Startup-Reihenfolge:** Beim allerersten Start beider Nodes
  gleichzeitig kann es zu einem Race um die DB-Migration keben. →
  Empfehlung: kc01 zuerst starten, warten bis ready, dann kc02.
- **Let's Encrypt Rate Limits:** Max. 5 Zertifikate pro Domain pro Woche.
  Beim Testen `--staging` Flag nutzen.
- **JDBC_PING2 + Firewalls:** Wenn Port 7800 zwischen den KC-Nodes
  blockiert ist, bildet sich kein Cluster – die Nodes laufen dann
  als isolierte Standalone-Instanzen (kein Fehler, nur Warnung im Log).
- **Proxy-Buffer:** Ohne die vergrößerten Nginx-Buffer schlagen
  Logins mit vielen Realm-Rollen fehl (502 Bad Gateway durch
  zu große Response-Header).

---

## 7. Spätere Erweiterungen (out of scope, aber vorbereitet)

- **Monitoring:** Keycloak exponiert Prometheus-Metriken unter `/metrics`
  (bereits aktiviert via `metrics-enabled=true`)
- **Backup:** PostgreSQL `pg_dump` Cron-Job + Rotation
- **Keycloak Realm-Export:** Automatisierter Export via Admin-API
- **3. Keycloak-Node:** Einfach kc03 mit gleichem Skript deployen,
  Nginx-Upstream erweitern
- **Cookie-basiertes Sticky Routing:** nginx-sticky-module-ng als
  Replacement für ip_hash
