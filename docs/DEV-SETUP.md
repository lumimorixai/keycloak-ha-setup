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
Blackbox-Exporter auf lb01 fuer TLS-Zertifikatsueberwachung.

## Unterschiede zu Prod

| Aspekt | Prod (4 VMs) | DEV (2 VMs) |
|---|---|---|
| VMs | db01, kc01, kc02, lb01 (+mon01) | app01, lb01 |
| Keycloak | 2 Nodes, HA-Cluster | 1 Node, kein Cluster |
| PostgreSQL | Eigene VM (db01) | Co-located auf app01 (DB_HOST = IP von app01) |
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
- `DB_HOST`: Ebenfalls IP von app01 (nicht `127.0.0.1` – Prometheus auf lb01 muss die DB-Exporter scrapen koennen)
- `LB_HOST`: IP von lb01
- `DB_PASSWORD`: `openssl rand -base64 24`
- `KC_ADMIN_PASSWORD`: `openssl rand -base64 24`
- `KC_DOMAIN`: Gewünschter FQDN
- `ACME_EMAIL`: Gültige E-Mail

Optional, für die Admin-Console auf eigener Domain:
- `KC_ADMIN_DOMAIN`: z.B. `kc-admin-dev.swl-innovation.de` – **eigener DNS-Eintrag
  auf lb01 nötig, bevor Schritt 3 läuft.** Leer lassen = Admin-Console bleibt
  unter `KC_DOMAIN` erreichbar (Verhalten wie bisher).
- `KC_ADMIN_ALLOW_IPS`: Komma-separierte IPs/CIDRs mit Zugriff auf die
  Admin-Domain. Leer = offen für alle.

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

Ist `KC_ADMIN_DOMAIN` gesetzt, beantragt das Skript ein **zweites** Zertifikat
für die Admin-Domain, legt `/etc/nginx/conf.d/keycloak-admin.conf` an und sperrt
`/admin/` auf der Login-Domain mit 403. Beide DNS-Einträge müssen vorher auf
lb01 zeigen. Zum Testen `CERTBOT_STAGING=1` setzen – Let's Encrypt erlaubt nur
5 Produktiv-Zertifikate pro Domain und Woche:

```bash
sudo CERTBOT_STAGING=1 scripts/03-setup-nginx.sh
```

Danach auf app01 einmal `sudo scripts/02-setup-keycloak.sh` ausführen, damit
Keycloak seine Admin-URLs mit der neuen Domain generiert (`hostname-admin`,
erfordert `kc.sh build` + Neustart, ~30s Downtime).

Abschalten: `KC_ADMIN_DOMAIN` leeren und beide Skripte erneut ausführen – der
Admin-vHost wird entfernt (Backup bleibt), `/admin/` ist wieder offen.

### Schritt 4: Monitoring (optional)

Keycloak-Metriken sind bereits aktiviert (`metrics-enabled=true` und
`event-metrics-user-enabled=true` in keycloak.conf). Wurde Keycloak vor dieser
Änderung installiert, zuerst auf app01 `sudo scripts/02-setup-keycloak.sh` erneut
ausführen – das Skript erkennt die geänderte Config, führt `kc.sh build` aus und
startet den Dienst neu (~30s Downtime).

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

**Zusätzlich installiert (automatisch via Exporter-Skripte):**
- Fail2ban-Metriken (textfile collector, alle Rollen) – Cronjob alle 2 Minuten
- Keycloak Cluster-Membership (textfile collector, keycloak-Rolle) – Cronjob jede Minute
- Keycloak User-Bestand (textfile collector, keycloak-Rolle) – Cronjob alle 5 Minuten
- Blackbox-Exporter auf lb01 (TLS-Zertifikatsprüfung via `06-setup-mon-vm.sh`)

**Hinweis:** Der Alert `KCClusterMembershipBroken` feuert im DEV-Setup dauerhaft
(siehe [Bekannte Einschränkungen](#bekannte-einschränkungen)).

**Test der Login-Metriken:** Ein Login an der Admin-Console zaehlt als
`realm="master", client_id="security-admin-console"` – gut um zu pruefen, *dass* die
Metrik fliesst, aber es ist kein End-User-Login. Fuer echte User-Events im Ziel-Realm
anmelden, z.B. ueber `https://<KC_DOMAIN>/realms/<realm>/account`.

Details zu KPIs, Dashboards und Alerting siehe [MONITORING.md](MONITORING.md).
Alarmbeschreibungen und Maßnahmen siehe [ALERTING-RUNBOOK.md](ALERTING-RUNBOOK.md).

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
| User | lb01 | 443 | HTTPS (Admin-Console, nur bei KC_ADMIN_DOMAIN) |
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
| lb01 | localhost | 9115 | Blackbox-Exporter (TLS-Probe) |
| Admin | lb01 | 3000 | Grafana UI |
| Admin | lb01 | 9090 | Prometheus UI (optional) |

## Bekannte Einschränkungen

- **Kein HA:** Einzelne Keycloak-Instanz – Ausfall von app01 = kompletter Ausfall.
- **Single-Node-Warning:** Keycloak loggt eine Warnung, weil `cache=ispn` ohne zweiten
  Cluster-Node konfiguriert ist. Das ist funktional harmlos.
- **Cluster-Membership-Alert feuert:** Der Alert `KCClusterMembershipBroken` (`keycloak_cluster_nodes != 2`)
  feuert dauerhaft, da im DEV-Setup nur eine Keycloak-Instanz läuft (`numberOfNodes=1`).
  Das ist erwartet und kann im Alertmanager via Silence stummgeschaltet werden:
  ```bash
  # Silence für DEV-Umgebung setzen (30 Tage):
  amtool silence add alertname=KCClusterMembershipBroken \
    --comment="DEV: Single-Node Setup, kein Cluster" \
    --duration=720h
  ```
- **Doppelte Prometheus-Targets:** Da `KC_NODE1_IP == KC_NODE2_IP`, enthält `prometheus.yml`
  doppelte Targets in den Jobs `keycloak` und `node`. Prometheus dedupliziert diese nicht,
  scraped die gleiche Instanz zweimal. Funktional harmlos, erzeugt aber doppelte Datenpunkte.
- **Nginx Upstream:** Der Upstream enthält 2x denselben Backend-Server (da `KC_NODE1_IP == KC_NODE2_IP`).
  Nginx behandelt das korrekt, `ip_hash` hat keinen Effekt bei nur einem realen Backend.
- **Kein Failover:** Bei Wartungsarbeiten an app01 ist Keycloak nicht erreichbar.
- **Monitoring co-located:** Prometheus/Grafana auf lb01 konkurrieren mit Nginx um Ressourcen.
  Für die DEV-Umgebung ist das akzeptabel.
