# Keycloak HA Setup

Reproduzierbares, idempotentes Setup für Keycloak 26 in HA-Konfiguration auf 4 Debian 13 (Trixie) VMs.

## Architektur

```
Internet → lb01 (Nginx :443 TLS)
              ├── kc01 (Keycloak :8080)
              └── kc02 (Keycloak :8080)
                    beide → db01 (PostgreSQL :5432)
           kc01 ↔ kc02 (JGroups TCP :7800)
```

Cluster-Discovery via JDBC_PING2 (PostgreSQL), kein Multicast erforderlich.

## Voraussetzungen

**Infrastruktur**

| VM | Rolle | Empf. RAM | Empf. CPU |
|----|-------|-----------|-----------|
| db01 | PostgreSQL 16 | 2 GB | 2 vCPU |
| kc01 | Keycloak | 4 GB | 2 vCPU |
| kc02 | Keycloak | 4 GB | 2 vCPU |
| lb01 | Nginx + Certbot | 1 GB | 1 vCPU |

**Voraussetzungen auf dem Deployment-Rechner / jeder VM**

- Debian 13 (Trixie) auf allen VMs
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

# 4. Validierung
scripts/99-healthcheck.sh
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

> **Warnung:** SSH-Port wird auf `SSH_PORT` aus `.env` gesetzt und
> `PasswordAuthentication` deaktiviert. SSH-Key muss vorher hinterlegt sein.

---

### Schritt 5: Validierung

```bash
scripts/99-healthcheck.sh
```

Prüft: Keycloak `/health/ready` auf beiden Nodes, HTTPS via lb01,
Cluster-Membership (2 Nodes), pg_isready, TLS-Zertifikat-Gültigkeit.

Ausgabe als farbige Zusammenfassung. Exit-Code 0 = alles OK.

---

## Idempotenz

Alle Skripte können mehrfach ausgeführt werden. Ein erneuter Lauf ohne
Änderungen an `.env` oder Templates ist ein No-op (keine Service-Neustarts,
keine Backups, keine Änderungen an Konfigurationsdateien).

## Verzeichnisstruktur

```
├── .env.example          Vorlage für Konfiguration (kopieren → .env)
├── scripts/
│   ├── 00-common.sh      Shared-Funktionen (source, nicht direkt ausführen)
│   ├── 01-setup-db.sh    PostgreSQL – auf db01
│   ├── 02-setup-keycloak.sh  Keycloak – auf kc01 und kc02
│   ├── 03-setup-nginx.sh Nginx + Certbot – auf lb01
│   ├── 04-harden.sh      Hardening – auf allen VMs
│   └── 99-healthcheck.sh Validierung – von lb01 oder extern
├── configs/
│   ├── keycloak/         keycloak.conf.tpl, keycloak.service
│   ├── nginx/            keycloak.conf.tpl (vHost)
│   └── postgresql/       pg_hba.conf.tpl
└── docs/
    ├── ARCHITECTURE.md   Architektur und Design-Entscheidungen
    ├── ROLLBACK.md       Rollback-Verfahren pro Komponente
    └── UPGRADE.md        Upgrade-Verfahren (Keycloak, PostgreSQL, Nginx, Java)
```

## Weiterführende Dokumentation

- [Architektur & Design-Entscheidungen](docs/ARCHITECTURE.md)
- [Rollback-Verfahren](docs/ROLLBACK.md)
- [Upgrade-Verfahren](docs/UPGRADE.md)
- [Keycloak 26 Release Notes](https://www.keycloak.org/docs/latest/release_notes/)
