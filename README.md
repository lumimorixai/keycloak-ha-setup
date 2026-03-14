# Keycloak HA Setup

Reproduzierbares, idempotentes Setup für Keycloak 26 in HA-Konfiguration auf Debian 13 (Trixie) VMs.
Produktiv-Setup: 5 VMs (db01, kc01, kc02, lb01, mon01). DEV-Setup: 2 VMs (siehe [DEV-SETUP](docs/DEV-SETUP.md)).

## Architektur

```
Internet → lb01 (Nginx :443 TLS)
              ├── kc01 (Keycloak :8080, Metrics :9000)
              └── kc02 (Keycloak :8080, Metrics :9000)
                    beide → db01 (PostgreSQL :5432)
           kc01 ↔ kc02 (JGroups TCP :7800)

mon01 (Prometheus :9090, Grafana :3000, Alertmanager :9093)
  └── scrapes: kc*:9000, alle:9100, db01:9187, lb01:9113
```

Cluster-Discovery via JDBC_PING2 (PostgreSQL), kein Multicast erforderlich.
Monitoring via Prometheus + Grafana auf dedizierter VM (mon01).

## Voraussetzungen

**Infrastruktur**

| VM | Rolle | Empf. RAM | Empf. CPU |
|----|-------|-----------|-----------|
| db01 | PostgreSQL 16 | 2 GB | 2 vCPU |
| kc01 | Keycloak | 4 GB | 2 vCPU |
| kc02 | Keycloak | 4 GB | 2 vCPU |
| lb01 | Nginx + Certbot | 1 GB | 1 vCPU |
| mon01 | Prometheus + Grafana + Alertmanager | 2 GB | 2 vCPU |

**Voraussetzungen auf dem Deployment-Rechner / jeder VM**

- Debian 13 (Trixie) auf allen VMs (5 VMs für Prod, 2 für DEV)
- SSH-Zugang mit Public-Key-Auth (root oder sudo-fähiger User)
- Internetzugang auf allen VMs (Paket-Download, Let's Encrypt)
- DNS-Eintrag für `KC_DOMAIN` zeigt auf lb01 (**vor** Schritt 3 erforderlich)
- `git` zum Klonen dieses Repos

**Werkzeuge lokal (optional, für bequemeres Deployment)**

```bash
# Repo auf jede VM übertragen (alternativ: git clone direkt auf jeder VM)
rsync -av --exclude='.env' ./ user@vm:/opt/keycloak-ha-setup/
```

## Quick-Start

```bash
# 1. Repo klonen (auf jeder VM oder zentral und via rsync verteilen)
git clone <repo-url> /opt/keycloak-ha-setup
cd /opt/keycloak-ha-setup

# 2. .env anlegen und befüllen
cp .env.example .env
$EDITOR .env   # Pflichtfelder: DB_PASSWORD, KC_ADMIN_PASSWORD, IPs, Domain

# 3. Deployment in Reihenfolge (jedes Skript auf der zugehörigen VM ausführen)
ssh db01  "sudo /opt/keycloak-ha-setup/scripts/01-setup-db.sh"
ssh kc01  "sudo /opt/keycloak-ha-setup/scripts/02-setup-keycloak.sh"
# kc01 abwarten:
ssh kc01  "until curl -sf http://localhost:9000/health/ready; do sleep 5; done"
ssh kc02  "sudo /opt/keycloak-ha-setup/scripts/02-setup-keycloak.sh"
ssh lb01  "sudo /opt/keycloak-ha-setup/scripts/03-setup-nginx.sh"
# Hardening auf allen VMs:
ssh db01  "sudo /opt/keycloak-ha-setup/scripts/04-harden.sh db"
ssh kc01  "sudo /opt/keycloak-ha-setup/scripts/04-harden.sh keycloak"
ssh kc02  "sudo /opt/keycloak-ha-setup/scripts/04-harden.sh keycloak"
ssh lb01  "sudo /opt/keycloak-ha-setup/scripts/04-harden.sh lb"

# 4. Monitoring (optional, mon01 muss in .env als MON_HOST eingetragen sein)
ssh db01  "sudo /opt/keycloak-ha-setup/scripts/05-setup-monitoring.sh db"
ssh kc01  "sudo /opt/keycloak-ha-setup/scripts/05-setup-monitoring.sh keycloak"
ssh kc02  "sudo /opt/keycloak-ha-setup/scripts/05-setup-monitoring.sh keycloak"
ssh lb01  "sudo /opt/keycloak-ha-setup/scripts/05-setup-monitoring.sh lb"
ssh mon01 "sudo /opt/keycloak-ha-setup/scripts/06-setup-mon-vm.sh"
ssh mon01 "sudo /opt/keycloak-ha-setup/scripts/04-harden.sh mon"

# 5. Validierung (auf jeder VM mit passender Rolle)
ssh db01  "sudo /opt/keycloak-ha-setup/scripts/99-healthcheck.sh db"
ssh kc01  "sudo /opt/keycloak-ha-setup/scripts/99-healthcheck.sh keycloak"
ssh kc02  "sudo /opt/keycloak-ha-setup/scripts/99-healthcheck.sh keycloak"
ssh lb01  "sudo /opt/keycloak-ha-setup/scripts/99-healthcheck.sh lb"
ssh mon01 "sudo /opt/keycloak-ha-setup/scripts/99-healthcheck.sh mon"
```

## Schritt-für-Schritt

### Schritt 0: .env befüllen

```bash
cp .env.example .env
```

Pflichtfelder (ohne sinnvollen Default):

| Variable | Beschreibung |
|----------|--------------|
| `DB_PASSWORD` | PostgreSQL-Passwort – `openssl rand -base64 24` |
| `KC_ADMIN_PASSWORD` | Initialer Keycloak-Admin – `openssl rand -base64 24` |
| `DB_HOST` | Interne IP von db01 |
| `KC_NODE1_IP` | Interne IP von kc01 |
| `KC_NODE2_IP` | Interne IP von kc02 |
| `LB_HOST` | Interne IP von lb01 |
| `KC_DOMAIN` | Öffentlicher FQDN (z.B. `auth.example.com`) |
| `ACME_EMAIL` | E-Mail für Let's Encrypt |

> **Sicherheit:** `.env` steht in `.gitignore` und wird niemals committed.

---

### Schritt 1: PostgreSQL einrichten (auf db01)

```bash
sudo scripts/01-setup-db.sh
```

Richtet ein:
- PGDG-Repository (postgresql.org), PostgreSQL 16
- DB-User und Datenbank für Keycloak
- `pg_hba.conf` mit scram-sha-256, Zugriff nur von KC-Node-IPs

---

### Schritt 2: Keycloak einrichten (auf kc01, dann kc02)

> **Reihenfolge wichtig:** kc01 zuerst – es führt die DB-Migration durch.
> kc02 erst starten, wenn kc01 `/health/ready` liefert.

```bash
# Auf kc01:
sudo scripts/02-setup-keycloak.sh

# Warten bis kc01 bereit ist:
until curl -sf "http://${KC_NODE1_IP}:9000/health/ready"; do
    echo "Warte auf kc01..."; sleep 5
done

# Auf kc02:
sudo scripts/02-setup-keycloak.sh
```

Richtet ein:
- Adoptium Temurin JDK 21 (aus adoptium.net-Repo)
- Keycloak 26.5.5 (SHA1-verifiziert)
- systemd-Service mit `--optimized`-Flag nach `kc.sh build`
- JDBC_PING2-Clustering via PostgreSQL-Discovery

---

### Schritt 3: Nginx + Certbot einrichten (auf lb01)

> **Voraussetzung:** DNS für `KC_DOMAIN` muss auf lb01 zeigen.

```bash
sudo scripts/03-setup-nginx.sh
```

Richtet ein:
- Nginx aus offiziellem nginx.org-Repo
- vHost mit ip_hash-Upstream, TLS-Terminierung, WebSocket-Support
- Certbot Let's Encrypt-Zertifikat (Webroot-Methode)
- Automatisches Renewal via systemd-Timer

**Staging-Modus** (empfohlen beim ersten Test, vermeidet Rate-Limits):

```bash
CERTBOT_STAGING=1 sudo scripts/03-setup-nginx.sh
```

---

### Schritt 4: Hardening (auf allen VMs)

```bash
# Reihenfolge beliebig, VM-Typ als Pflichtparameter:
sudo scripts/04-harden.sh db        # auf db01
sudo scripts/04-harden.sh keycloak  # auf kc01 und kc02
sudo scripts/04-harden.sh lb        # auf lb01
```

Richtet ein:
- UFW mit rollenspezifischen Regeln (nur benötigte Ports offen)
- SSH-Hardening via Drop-in (`sshd_config.d/99-keycloak-hardening.conf`)
- Fail2ban (SSH überall; Nginx-Jails auf lb01)
- Unattended-Upgrades (nur Security-Updates, kein Auto-Reboot)

Wenn `MON_HOST` in `.env` gesetzt ist, werden zusätzlich die Monitoring-Ports
(9100, 9187, 9113, 9000) von mon01 freigeschaltet.

> **Warnung:** SSH-Port wird auf `SSH_PORT` aus `.env` gesetzt und
> `PasswordAuthentication` deaktiviert. SSH-Key muss vorher hinterlegt sein.

---

### Schritt 5: Monitoring einrichten (optional)

> **Voraussetzung:** `MON_HOST` in `.env` auf die IP von mon01 setzen.

```bash
# Exporter auf Ziel-VMs installieren:
sudo scripts/05-setup-monitoring.sh db        # auf db01
sudo scripts/05-setup-monitoring.sh keycloak  # auf kc01 und kc02
sudo scripts/05-setup-monitoring.sh lb        # auf lb01

# Monitoring-Stack auf mon01:
sudo scripts/06-setup-mon-vm.sh               # auf mon01
sudo scripts/04-harden.sh mon                 # auf mon01
```

Richtet ein:
- **Alle VMs:** `node_exporter` (:9100) für System-Metriken
- **db01:** `postgres_exporter` (:9187) für DB-Metriken
- **lb01:** `nginx-prometheus-exporter` (:9113) für Nginx-Metriken
- **kc01/kc02:** Keycloak-Metriken built-in auf :9000 (metrics-enabled=true)
- **mon01:** Prometheus (:9090), Grafana (:3000), Alertmanager (:9093)

Grafana-Login: `http://mon01:3000` (Standard: admin/admin).
Details: [Monitoring-Konzept](docs/MONITORING.md)

---

### Schritt 6: Validierung

```bash
# Auf jeder VM mit passender Rolle ausführen:
sudo scripts/99-healthcheck.sh db       # auf db01
sudo scripts/99-healthcheck.sh keycloak # auf kc01/kc02
sudo scripts/99-healthcheck.sh lb       # auf lb01
sudo scripts/99-healthcheck.sh mon      # auf mon01
```

Prüft je nach Rolle: PostgreSQL-Verbindungen (db), Keycloak Health + JGroups + DB (keycloak),
Nginx + HTTPS + TLS + KC-Nodes (lb), Prometheus + Grafana + Alertmanager + Scrape-Targets (mon).

Ausgabe als farbige Zusammenfassung. Exit-Code 0 = alles OK.

---

## Idempotenz

Alle Skripte können mehrfach ausgeführt werden. Ein erneuter Lauf ohne
Änderungen an `.env` oder Templates ist ein No-op (keine Service-Neustarts,
keine Backups, keine Änderungen an Konfigurationsdateien).

## Verzeichnisstruktur

```
├── .env.example              Vorlage für Prod-Konfiguration (4+1 VMs)
├── .env.dev.example          Vorlage für DEV-Konfiguration (2 VMs)
├── scripts/
│   ├── 00-common.sh          Shared-Funktionen (source, nicht direkt ausführen)
│   ├── 01-setup-db.sh        PostgreSQL – auf db01
│   ├── 02-setup-keycloak.sh  Keycloak – auf kc01 und kc02
│   ├── 03-setup-nginx.sh     Nginx + Certbot – auf lb01
│   ├── 04-harden.sh          Hardening – auf allen VMs (db|keycloak|lb|mon)
│   ├── 05-setup-monitoring.sh  Exporter – auf Ziel-VMs (db|keycloak|lb)
│   ├── 06-setup-mon-vm.sh    Prometheus + Grafana + Alertmanager – auf mon01
│   └── 99-healthcheck.sh     Validierung – auf jeder VM (db|keycloak|lb|mon)
├── configs/
│   ├── keycloak/             keycloak.conf.tpl, keycloak.service
│   ├── monitoring/           prometheus.yml.tpl, alertmanager.yml.tpl, alert-rules.yml
│   ├── nginx/                keycloak.conf.tpl (vHost)
│   └── postgresql/           pg_hba.conf.tpl
└── docs/
    ├── ARCHITECTURE.md       Architektur und Design-Entscheidungen
    ├── DEV-SETUP.md          2-Node DEV-Umgebung
    ├── MONITORING.md         Monitoring-Konzept (KPIs, Alerting, Deployment)
    ├── PLAN.md               Detaillierter Umsetzungsplan
    ├── ROLLBACK.md           Rollback-Verfahren pro Komponente
    └── UPGRADE.md            Upgrade-Verfahren
```

## Weiterführende Dokumentation

- [Architektur & Design-Entscheidungen](docs/ARCHITECTURE.md)
- [Monitoring-Konzept](docs/MONITORING.md)
- [DEV-Setup (2 VMs)](docs/DEV-SETUP.md)
- [Detaillierter Umsetzungsplan](docs/PLAN.md)
- [Rollback-Verfahren](docs/ROLLBACK.md)
- [Upgrade-Verfahren](docs/UPGRADE.md)
- [Keycloak 26 Release Notes](https://www.keycloak.org/docs/latest/release_notes/)
