# Keycloak HA Setup – Detaillierter Umsetzungsplan

## Übersicht

Dieses Dokument beschreibt den vollständigen Deployment-Ablauf für das Keycloak HA-Setup auf 5 Debian 13 (Trixie) VMs (4 Kern-VMs + 1 Monitoring-VM). Alle Schritte sind idempotent – ein erneutes Ausführen ist sicher.

## Voraussetzungen

- 5 VMs mit Debian 13 (Trixie) (db01, kc01, kc02, lb01, mon01)
- SSH-Zugang auf alle VMs (Public-Key-Auth empfohlen)
- DNS-Eintrag für `KC_DOMAIN` zeigt auf lb01 (vor Schritt 3 erforderlich)
- Repo geklont auf jeder VM (oder via rsync übertragen)
- `.env` aus `.env.example` kopiert und befüllt

## Deployment-Reihenfolge

### Phase 1: Datenbank (db01)

```bash
sudo scripts/01-setup-db.sh
```

Richtet PostgreSQL 16 ein, legt DB-User und Datenbank an, deployt `pg_hba.conf`.

### Phase 2: Keycloak-Nodes (kc01, dann kc02)

**Wichtig: kc01 zuerst starten und auf `/health/ready` warten, dann kc02.**

```bash
# Auf kc01:
sudo scripts/02-setup-keycloak.sh

# Warten bis kc01 ready:
until curl -sf http://<KC_NODE1_IP>:9000/health/ready; do sleep 5; done

# Auf kc02:
sudo scripts/02-setup-keycloak.sh
```

Richtet JDK 21, Keycloak, systemd-Service und Cluster-Konfiguration ein.

### Phase 3: Load Balancer (lb01)

```bash
sudo scripts/03-setup-nginx.sh
```

Richtet Nginx mit TLS-Terminierung und Certbot ein. DNS muss vorher korrekt gesetzt sein.

### Phase 4: Hardening (alle VMs)

```bash
sudo scripts/04-harden.sh db        # auf db01
sudo scripts/04-harden.sh keycloak  # auf kc01 und kc02
sudo scripts/04-harden.sh lb        # auf lb01
```

Setzt UFW-Firewall-Regeln (rollenbasiert), SSH-Hardening und Fail2ban. Der VM-Typ ist ein Pflichtparameter. Wenn `MON_HOST` in `.env` gesetzt ist, werden zusätzlich Monitoring-Ports freigeschaltet.

### Phase 5: Monitoring (mon01 + Exporter auf allen VMs)

```bash
# Exporter auf Ziel-VMs installieren:
sudo scripts/05-setup-monitoring.sh db        # auf db01
sudo scripts/05-setup-monitoring.sh keycloak  # auf kc01 und kc02
sudo scripts/05-setup-monitoring.sh lb        # auf lb01

# Monitoring-Stack auf mon01:
sudo scripts/06-setup-mon-vm.sh               # auf mon01
sudo scripts/04-harden.sh mon                 # auf mon01
```

Installiert Prometheus, Grafana, Alertmanager und Blackbox-Exporter auf mon01 sowie
node_exporter (alle VMs), postgres_exporter (db01) und nginx-prometheus-exporter (lb01).
Zusaetzlich: Fail2ban-Metriken (textfile collector, alle VMs) und Keycloak Cluster-Membership
(textfile collector, kc01/kc02). Keycloak-Metriken sind built-in auf :9000 (metrics-enabled=true).
Grafana-Dashboards werden automatisch provisioniert (Community + Custom).
Details: [MONITORING.md](MONITORING.md) | [ALERTING-RUNBOOK.md](ALERTING-RUNBOOK.md).

### Phase 6: Validierung (auf jeder VM mit passender Rolle)

```bash
sudo scripts/99-healthcheck.sh db       # auf db01
sudo scripts/99-healthcheck.sh keycloak # auf kc01/kc02
sudo scripts/99-healthcheck.sh lb       # auf lb01
sudo scripts/99-healthcheck.sh mon      # auf mon01
```

Prüft je nach Rolle: PostgreSQL-Verbindungen, Keycloak Health + Cluster, Nginx + TLS,
Monitoring-Stack + Scrape-Targets.

## Konfigurationsspezifikationen

### PostgreSQL pg_hba.conf

- Authentifizierungsmethode: `scram-sha-256`
- Keycloak-Nodes können nur von `KC_NODE1_IP` und `KC_NODE2_IP` verbinden
- Lokale Verbindungen (`postgres`-User) via `peer`-Auth

### Keycloak keycloak.conf

| Parameter | Wert | Begründung |
|-----------|------|------------|
| `http-enabled` | `true` | TLS-Terminierung am Nginx |
| `proxy-headers` | `xforwarded` | Nginx sendet X-Forwarded-* Header |
| `cache` | `ispn` | Infinispan-Clustering via JGroups |
| `cache-stack` | `jdbc-ping` | JDBC_PING2 Discovery über PostgreSQL |
| `http-port` | `${KC_HTTP_PORT}` | Standard: 8080 |
| `http-management-port` | `${KC_MGMT_PORT}` | Standard: 9000 – Health/Metrics seit KC 25+ |

### JGroups / Cluster-Discovery

- Protokoll: JDBC_PING2 (Discovery via PostgreSQL)
- Transport: TCP direkt zwischen kc01 und kc02 (Port 7800)
- Bind-Address: IP der jeweiligen Node (in `/etc/keycloak/env` gesetzt)
- Bei blockiertem Port 7800: Nodes laufen isoliert, nur Warnung im Log

### Nginx Reverse Proxy

| Parameter | Wert | Begründung |
|-----------|------|------------|
| `proxy_buffer_size` | `128k` | Große JWT-Token mit vielen Rollen |
| `proxy_buffers` | `4 256k` | Verhindert 502-Fehler |
| `ip_hash` | aktiviert | Session-Stickiness |
| SSL-Protokolle | TLS 1.2 + 1.3 | Mozilla Intermediate |

## Netzwerk-Ports

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

## Build-Zyklus (Keycloak)

Nach jeder Änderung an `keycloak.conf` muss `kc.sh build` ausgeführt werden:

```bash
# Als keycloak-User:
sudo -u keycloak /opt/keycloak/bin/kc.sh build

# Danach Service neu starten:
systemctl restart keycloak
```

Das Skript `02-setup-keycloak.sh` übernimmt dies automatisch via Hash-Vergleich.

## Variablen-Referenz

Alle konfigurierbaren Werte sind in `.env` definiert. Siehe `.env.example` für vollständige Dokumentation. Pflichtfelder (ohne Defaults):

- `DB_PASSWORD` – PostgreSQL-Passwort
- `KC_ADMIN_PASSWORD` – Initialer Keycloak-Admin (nur beim ersten Start)
