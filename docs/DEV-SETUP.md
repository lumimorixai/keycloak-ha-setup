# Keycloak DEV Setup – 2-Node-Deployment

## Architektur

```
VM 1 (app01):               VM 2 (lb01):
  PostgreSQL  :5432           Nginx        :443/:80
  Keycloak    :8080  <----    Reverse Proxy
              :9000           Certbot (Let's Encrypt)
  node_exp    :9100           Prometheus   :9090
  pg_exp      :9187           Grafana      :3000
                              Alertmanager :9093
                              nginx_exp    :9113
                              node_exp     :9100
```

**Kein Clustering:** Einzelne Keycloak-Instanz (kein JGroups, kein JDBC_PING2).
DB und KC co-located auf app01. Monitoring auf lb01 statt separater mon01.

## Unterschiede zu Prod

| Aspekt | Prod (4 VMs) | DEV (2 VMs) |
|---|---|---|
| VMs | db01, kc01, kc02, lb01 (+mon01) | app01, lb01 |
| Keycloak | 2 Nodes, HA-Cluster | 1 Node, kein Cluster |
| PostgreSQL | Eigene VM (db01) | Co-located auf app01 |
| JGroups | TCP :7800 zwischen kc01↔kc02 | Nicht benötigt |
| Monitoring | Dedizierte mon01 | Co-located auf lb01 |
| JVM Heap | `-Xms512m -Xmx2048m` | `-Xms256m -Xmx1024m` |
| DB-Zugriff | Remote (kc01/kc02 → db01) | Lokal (127.0.0.1) |

## Voraussetzungen

- 2 VMs mit Debian 13 (Trixie)
- SSH-Zugang auf beide VMs (Public-Key-Auth empfohlen)
- DNS-Eintrag für `KC_DOMAIN` zeigt auf lb01 (vor Schritt 3 erforderlich)
- Repo geklont auf beiden VMs (oder via rsync übertragen)

## Deployment

### Schritt 1: `.env` vorbereiten

```bash
cp .env.dev.example .env
```

Pflichtfelder ausfüllen:
- `KC_NODE1_IP` und `KC_NODE2_IP`: Beide auf die IP von app01 setzen
- `LB_HOST`: IP von lb01
- `DB_PASSWORD`: `openssl rand -base64 24`
- `KC_ADMIN_PASSWORD`: `openssl rand -base64 24`
- `KC_DOMAIN`: Gewünschter FQDN
- `ACME_EMAIL`: Gültige E-Mail

### Schritt 2: app01 einrichten

```bash
# Auf app01 – alle Befehle als root/sudo:

# PostgreSQL installieren und konfigurieren
sudo scripts/01-setup-db.sh

# Keycloak installieren (erkennt sich als "Node 1" via KC_NODE1_IP)
sudo scripts/02-setup-keycloak.sh

# Warten bis Keycloak ready:
until curl -sf http://127.0.0.1:9000/health/ready; do sleep 5; done

# Hardening: Erst DB-Regeln, dann KC-Regeln
sudo scripts/04-harden.sh db
sudo scripts/04-harden.sh keycloak
```

### Schritt 3: lb01 einrichten

```bash
# Auf lb01 – DNS muss bereits auf lb01 zeigen:

sudo scripts/03-setup-nginx.sh
sudo scripts/04-harden.sh lb
```

### Schritt 4: Monitoring (optional)

Keycloak-Metriken sind bereits aktiviert (`metrics-enabled=true` in keycloak.conf).

**Auf app01:**

```bash
# Exporter installieren (node_exporter + postgres_exporter)
sudo scripts/05-setup-monitoring.sh db
sudo scripts/05-setup-monitoring.sh keycloak
```

**Auf lb01:**

```bash
# Monitoring-Stack (Prometheus + Grafana + Alertmanager)
sudo scripts/06-setup-mon-vm.sh

# Exporter installieren (node_exporter + nginx-prometheus-exporter)
sudo scripts/05-setup-monitoring.sh lb

# Firewall: Monitoring-Ports freigeben (optional, wenn MON_HOST gesetzt)
# Im DEV-Setup läuft Monitoring auf lb01 selbst → localhost braucht kein UFW
```

Prometheus-Targets werden automatisch konfiguriert:
app01:9000, app01:9100, app01:9187, localhost:9113, localhost:9100.

Details zu KPIs, Dashboards und Alerting siehe [MONITORING.md](MONITORING.md).

### Schritt 5: Validierung

```bash
# Auf app01:
sudo scripts/99-healthcheck.sh db
sudo scripts/99-healthcheck.sh keycloak

# Auf lb01:
sudo scripts/99-healthcheck.sh lb
```

**Hinweis:** Der Cluster-Check in `99-healthcheck.sh keycloak` meldet `numberOfNodes=1`.
Das ist im DEV-Setup korrekt – es läuft nur eine Instanz.

## Netzwerk-Ports

| Von | Nach | Port | Zweck |
|---|---|---|---|
| User | lb01 | 443 | HTTPS (Keycloak UI/API) |
| User | lb01 | 80 | HTTP (ACME Challenge only) |
| lb01 | app01 | 8080 | Reverse Proxy → Keycloak |
| lb01 | app01 | 9000 | Health-Check (Management) |
| app01 | localhost | 5432 | PostgreSQL (lokal) |

Port 7800 (JGroups) wird im DEV-Setup nicht benötigt.

### Zusätzliche Monitoring-Ports

| Von | Nach | Port | Zweck |
|---|---|---|---|
| lb01 | app01 | 9100 | node_exporter scrapen |
| lb01 | app01 | 9187 | postgres_exporter scrapen |
| lb01 | app01 | 9000 | Keycloak-Metriken scrapen |
| Admin | lb01 | 3000 | Grafana UI |
| Admin | lb01 | 9090 | Prometheus UI (optional) |

## Bekannte Einschränkungen

- **Kein HA:** Einzelne Keycloak-Instanz – Ausfall von app01 = kompletter Ausfall.
- **Single-Node-Warning:** Keycloak loggt eine Warnung, weil `cache=ispn` ohne zweiten
  Cluster-Node konfiguriert ist. Das ist funktional harmlos.
- **Nginx Upstream:** Der Upstream enthält 2x denselben Backend-Server (da `KC_NODE1_IP == KC_NODE2_IP`).
  Nginx behandelt das korrekt, `ip_hash` hat keinen Effekt bei nur einem realen Backend.
- **Kein Failover:** Bei Wartungsarbeiten an app01 ist Keycloak nicht erreichbar.
- **Monitoring co-located:** Prometheus/Grafana auf lb01 konkurrieren mit Nginx um Ressourcen.
  Für die DEV-Umgebung ist das akzeptabel.
