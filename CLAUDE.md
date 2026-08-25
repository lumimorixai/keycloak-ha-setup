# Keycloak HA Setup – Projekt-Kontext

## Ziel

Reproduzierbares HA-Keycloak-Setup via idempotenter Shell-Skripte für 5 Debian 13 (Trixie) VMs (4 Kern + 1 Monitoring).
Der vollständige Architektur- und Umsetzungsplan liegt in `docs/PLAN.md`.

## Stack

| Komponente   | Version / Variante          | Hinweis                                      |
|--------------|-----------------------------|----------------------------------------------|
| Keycloak     | 26.5.5 (Quarkus-Distro)    | Pinned in `.env` als `KC_VERSION`            |
| PostgreSQL   | 16 (offizielles pgdg-Repo) | Mindestversion für KC 26.4+ ist PG 13        |
| Java         | OpenJDK 21 (Adoptium Temurin) | Adoptium statt Debian-Paket – besser getestet mit Quarkus |
| Nginx        | Aktuell (offizielles Repo)  | TLS-Terminierung + Reverse Proxy             |
| Certbot      | Aktuell                     | Let's Encrypt ACME, Auto-Renewal via systemd-Timer (apt-daily-upgrade.timer) |
| Prometheus   | Aktuell (Debian-Paket)    | Scraping + Alert-Rules auf mon01              |
| Grafana      | Aktuell (offizielles Repo)| Dashboards auf mon01                          |
| OS           | Debian 13 (Trixie)        | Auf allen 5 VMs                               |

## Architektur

```
Internet → lb01 (Nginx + TLS :443)
              ├── kc01 (Keycloak :8080, Metrics :9000)
              └── kc02 (Keycloak :8080, Metrics :9000)
                    beide → db01 (PostgreSQL :5432)
           kc01 ↔ kc02 (JGroups TCP :7800)

mon01 (Prometheus :9090, Grafana :3000, Alertmanager :9093)
  └── scrapes: kc*:9000, alle:9100, db01:9187, lb01:9113
```

- **5 VMs:** db01 (PostgreSQL), kc01 + kc02 (Keycloak HA), lb01 (Nginx + Certbot), mon01 (Monitoring)
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
├── .gitignore                  # enthält: .env + .env.*, *.pem/key/crt, SSH-Keys, *.log, !.env.example
├── scripts/
│   ├── 00-common.sh            # Shared Functions, .env-Loader, Idempotenz-Helpers
│   ├── 01-setup-db.sh          # PostgreSQL – Ausführung auf db01
│   ├── 02-setup-keycloak.sh    # JDK + Keycloak – Ausführung auf kc01 und kc02
│   ├── 03-setup-nginx.sh       # Nginx + Certbot – Ausführung auf lb01
│   ├── 04-harden.sh            # UFW + SSH + Fail2ban + Unattended-Upgrades – Pflichtparameter: db|keycloak|lb|mon
│   ├── 05-setup-monitoring.sh  # Exporter auf Ziel-VMs – Pflichtparameter: db|keycloak|lb
│   ├── 06-setup-mon-vm.sh      # Prometheus + Grafana + Alertmanager – Ausführung auf mon01
│   └── 99-healthcheck.sh       # Validierung – Pflichtparameter: lb|keycloak|db|mon
├── configs/
│   ├── keycloak/
│   │   ├── keycloak.conf.tpl   # Keycloak-Server-Config (Template)
│   │   └── keycloak.service    # systemd Unit-File
│   ├── monitoring/
│   │   ├── prometheus.yml.tpl  # Prometheus Scrape-Config (Template)
│   │   ├── alertmanager.yml.tpl # Alertmanager Routing (Template)
│   │   ├── alert-rules.yml     # Prometheus Alert-Rules (statisch, 21 Alerts)
│   │   ├── blackbox.yml        # Blackbox-Exporter Config (TLS-Probe)
│   │   ├── grafana-datasource.yml # Grafana Datasource Auto-Provisioning
│   │   ├── grafana-dashboards.yml # Grafana Dashboard Auto-Provisioning
│   │   ├── fail2ban-metrics.sh    # Cronjob-Skript: Fail2ban → textfile collector
│   │   ├── keycloak-cluster-metrics.sh # Cronjob-Skript: Cluster-Membership → textfile collector
│   │   ├── keycloak-user-metrics.sh    # Cronjob-Skript: User-Bestand pro Realm → textfile collector
│   │   └── dashboards/
│   │       ├── keycloak-overview.json # Custom Keycloak Dashboard
│   │       └── keycloak-jvm.json      # Custom JVM Dashboard
│   ├── nginx/
│   │   └── keycloak.conf.tpl   # Nginx vHost (Template)
│   └── postgresql/
│       └── pg_hba.conf.tpl     # PostgreSQL-Zugriff (Template)
└── docs/
    ├── ALERTING-RUNBOOK.md     # Alarm-Handbuch für Administratoren
    ├── PLAN.md                 # Detaillierter Umsetzungsplan mit Config-Spezifikationen
    ├── ARCHITECTURE.md
    ├── DEV-SETUP.md            # 2-Node DEV-Umgebung Anleitung
    ├── MONITORING.md           # Monitoring-Konzept (KPIs, Dashboards, Alerting)
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
| `deploy_config`     | Template → Ziel via envsubst, Backup falls Ziel existiert; optionaler 5. Parameter: Variablenliste für envsubst (z.B. `'${KC_DOMAIN} ${KC_NODE1_IP}'`) – nötig wenn Template neben Shell-Variablen auch andere `$var`-Muster enthält (z.B. nginx-Variablen wie `$http_upgrade`) |
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
- **Keycloak Download:** SHA1-Checksum gegen `https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/keycloak-${KC_VERSION}.tar.gz.sha1` verifizieren (ab 26.x nur noch `.sha1`, kein `.sha512` mehr).
- **Nginx aus offiziellem Repo:** Das Debian-Paket ist oft zu alt. Keyring von `nginx.org/keys/nginx_signing.key` einrichten + Pin-Priority 901 via `/etc/apt/preferences.d/99nginx`, damit nginx.org Vorrang hat. Das nginx.org-Paket nutzt `/etc/nginx/conf.d/` (NICHT `sites-available/sites-enabled/` – das ist eine Debian-Paket-Konvention).
- **Certbot Henne-Ei-Problem:** Beim Erststart existiert noch kein TLS-Zertifikat, aber die nginx-Config referenziert es. Lösung: temporäre HTTP-only-Config deployen → nginx starten → Certbot → vollständige HTTPS-Config deployen.
- **envsubst und nginx-Variablen:** `envsubst` ohne Argumente ersetzt ALLE `$var`-Muster – auch nginx-interne Variablen wie `$http_upgrade`. `deploy_config` mit expliziter Variablenliste als 5. Parameter aufrufen: `'${KC_DOMAIN} ${KC_NODE1_IP} ${KC_NODE2_IP} ${KC_HTTP_PORT} ${KC_MGMT_PORT}'`.
- **WebSocket-Support Nginx:** Admin-Console nutzt WebSocket-Verbindungen. `proxy_set_header Connection ""` allein bricht WS ab. Zwingend einen `map $http_upgrade $connection_upgrade`-Block einsetzen und `proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade;` verwenden.
- **proxy_read_timeout für WebSocket:** 60s ist zu kurz – idle WS-Verbindungen der Admin-Console werden getrennt → UI-Fehler. Wert: 3600s.
- **KC_HTTPS_PORT nicht verwenden:** TLS terminiert am Nginx, Keycloak hört ausschließlich HTTP. `KC_HTTPS_PORT` existiert nicht in `.env.example` und soll auch nicht hinzugefügt werden.
- **Management-Port 9000:** Seit Keycloak 25+ laufen `/health/ready` und `/metrics` auf Port 9000 (Management-Interface), NICHT auf Port 8080. `curl http://<node>:9000/health/ready` für Health-Checks verwenden. Port 9000 muss in UFW für lb01 freigegeben sein.
- **04-harden.sh Pflichtparameter:** Das Skript akzeptiert `db|keycloak|lb|mon` als `$1`. IP-Autoerkennung wurde bewusst entfernt – sie schlägt bei Cloud-VMs mit NAT oder mehreren Interfaces lautlos fehl. Aufruf ohne Parameter bricht mit usage() ab.
- **99-healthcheck.sh Pflichtparameter:** Analog zu 04-harden.sh akzeptiert das Skript `lb|keycloak|db|mon` als `$1`. Jede Rolle prüft nur die für sie relevanten Checks: `lb` = nginx + KC-Nodes + HTTPS + TLS; `keycloak` = lokal + Peer + JGroups + DB; `db` = PostgreSQL + Verbindungen + jgroups_ping-Tabelle; `mon` = Prometheus + Grafana + Alertmanager + Scrape-Targets.
- **MON_HOST ist optional:** Die Variable steht in `.env.example`, aber NICHT in `required_vars` in `00-common.sh` – leerer Wert bedeutet keine Monitoring-Firewall-Regeln. Nie als Pflichtfeld hinzufügen.
- **05-setup-monitoring.sh Pflichtparameter:** Das Skript akzeptiert `db|keycloak|lb` als `$1`. Installiert node_exporter (alle Rollen) + Fail2ban-Metriken (textfile collector) plus rollenspezifische Exporter: postgres_exporter (db), nginx-prometheus-exporter (lb), Cluster-Membership- und User-Bestand-Metriken (keycloak).
- **Keycloak Metrics aktiviert:** `metrics-enabled=true` in keycloak.conf.tpl. Metriken sind auf Port 9000 `/metrics` verfügbar (Micrometer/Prometheus-Format).
- **User-Event-Metriken sind separat zu aktivieren:** `metrics-enabled=true` liefert NUR JVM-, HTTP- und Datasource-Metriken. Logins/Registrierungen erscheinen erst mit `event-metrics-user-enabled=true` (+ `event-metrics-user-tags=realm,clientId,idp`) in keycloak.conf.tpl – danach zwingend `kc.sh build` + Neustart.
- **Es gibt nur EINE User-Event-Metrik:** `keycloak_user_events_total{realm,event,error,client_id,idp}`. Erfolg = `error=""`, Fehlversuch = `error!=""`. Namen wie `keycloak_successful_login`, `keycloak_failed_login_attempts`, `keycloak_registrations` stammen aus der Wildfly-Extension `keycloak-metrics-spi` und existieren in der Quarkus-Distro NICHT – Queries damit liefern stillschweigend leere Panels und Alerts, die nie feuern.
- **Admin-Logins sind normale User-Events:** Anmeldungen an der Keycloak-Verwaltung erscheinen als `realm="master", client_id="security-admin-console"` in derselben Metrik wie End-User-Logins. Ohne Filter zählen Dashboards beides zusammen. `keycloak-overview.json` hat dafür die Variablen `$realm` und `$client_exclude` (Default: Admin-Console ausgeblendet).
- **Userzahl ist keine Keycloak-Metrik:** Weder Bestand noch Löschungen werden exportiert. Der Bestand kommt aus `configs/monitoring/keycloak-user-metrics.sh` (SQL auf `user_entity`, Textfile-Collector, alle 5min) als `keycloak_users_total{realm="..."}`. Nach KC-Major-Upgrades Schema-Annahme prüfen.
- **Nginx stub_status:** In der nginx-Config als `/nginx_status` Location (nur localhost). Wird vom nginx-prometheus-exporter gescraped.
- **Alert-Rules statisch:** `configs/monitoring/alert-rules.yml` ist KEIN Template – enthält Go-Template-Syntax (`{{ $labels.instance }}`), die envsubst zerstören würde. Wird direkt kopiert, nicht via deploy_config.
- **Grafana aus offiziellem Repo:** Das Debian-Paket existiert nicht. Keyring von `apt.grafana.com/gpg.key` einrichten.
- **Grafana-Dashboards auto-provisioniert:** `grafana-dashboards.yml` als Provisioning-Config, Community-Dashboards werden von grafana.com heruntergeladen, Custom-Dashboards aus `configs/monitoring/dashboards/` kopiert. Datasource-Referenz per Name (`"Prometheus"`), nicht per UID.
- **Blackbox-Exporter:** Debian-Paket `prometheus-blackbox-exporter`, Config in `configs/monitoring/blackbox.yml`. Probt TLS gegen `https://${KC_DOMAIN}`.
- **Textfile-Collector-Pattern:** Cronjob schreibt `.prom`-Datei nach `/var/lib/prometheus/node-exporter/`, node_exporter liest sie automatisch. Atomares Schreiben via tmpfile + mv.
- **UFW ist nativ idempotent:** `ufw allow` fügt dieselbe Regel nicht doppelt ein. Pre-Checks via `ufw status | grep ...` sind fehleranfällig (Formatabhängig) und unnötig.
- **grep -q in Pipes:** `grep -qF "${var}" | grep -q "${port}"` ist kaputt – `-q` unterdrückt stdout, der zweite grep prüft gegen leeren Stream. Stattdessen: `ufw allow` direkt aufrufen oder Prüfung ohne Pipe.
- **Template-Variablen grep:** Pattern `[A-Z_]+` erfasst keine Ziffern – `KC_NODE1_IP` wird nicht gefunden. Korrektes Pattern: `[A-Z0-9_]+`.
- **Cluster-Membership prüfen:** `/health` liefert pro Keycloak-Node `.checks[].data.numberOfNodes`. Wert muss 2 sein. `status=UP` allein erkennt keinen Split-Brain (jede Node sieht sich selbst als einziges Mitglied).
- **TLS-Check ohne root:** `openssl s_client -connect domain:443` statt lokale Zertifikatsdatei lesen – funktioniert von extern und ohne root-Rechte.
- **ADMIN_IPS ist optional:** Die Variable steht in `.env.example`, aber NICHT in `required_vars` in `00-common.sh` – leerer Wert bedeutet SSH-Zugriff von allen IPs. Nie als Pflichtfeld hinzufügen.

## Netzwerk-Ports (Referenz für Firewall-Regeln)

| Von   | Nach  | Port | Zweck                        |
|-------|-------|------|------------------------------|
| User  | lb01  | 443  | HTTPS (Keycloak UI/API)      |
| User  | lb01  | 80   | HTTP (ACME Challenge only)   |
| lb01  | kc*   | 8080 | Reverse Proxy → Keycloak     |
| lb01  | kc*   | 9000 | Health-Check (Management)    |
| kc*   | db01  | 5432 | PostgreSQL                   |
| kc01  | kc02  | 7800 | JGroups TCP (bidirektional)  |
| mon01 | kc*   | 9000 | Keycloak-Metriken scrapen    |
| mon01 | alle  | 9100 | node_exporter scrapen        |
| mon01 | db01  | 9187 | postgres_exporter scrapen    |
| mon01 | lb01  | 9113 | nginx-exporter scrapen       |
| mon01 | localhost | 9115 | Blackbox-Exporter (TLS-Probe)|
| Admin | mon01 | 3000 | Grafana UI                   |
| Admin | mon01 | 9090 | Prometheus UI (optional)     |

## Validierung nach Code-Generierung

Nach dem Erstellen jeder Datei:

1. **Shell-Skripte:** `shellcheck --severity=warning scripts/*.sh`
2. **Templates:** Prüfe, dass jede `${VARIABLE}` in `.env.example` definiert ist und umgekehrt. Grep-Pattern muss Ziffern einschließen: `grep -ohE '\$\{[A-Z0-9_]+\}'` (nicht `[A-Z_]+`, das übersieht z.B. `KC_NODE1_IP`)
3. **systemd Unit:** `systemd-analyze verify` (falls lokal verfügbar)
4. **Nginx Config:** `nginx -t` (nach envsubst auf einer Test-Config)
