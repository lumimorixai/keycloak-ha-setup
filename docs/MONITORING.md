# Monitoring-Konzept für Keycloak HA Setup

## Architektur

```
                         mon01 (dedizierte Monitoring-VM)
                         ┌──────────────────────────┐
                         │  Prometheus :9090         │
                         │  Grafana    :3000         │
                         │  Alertmanager :9093       │
                         └────────┬─────────────────┘
                                  │ Scraping
              ┌───────────┬───────┼───────────┬──────────┐
              ▼           ▼       ▼           ▼          ▼
         kc01:9000   kc02:9000  db01:9187  lb01:9113  alle:9100
         /metrics    /metrics   pg_export  nginx_exp  node_exp

                              Optional:
                         ┌──────────────────┐
                         │  Zabbix (RZ)     │◄── Alertmanager Webhook
                         └──────────────────┘    (nur critical Alerts)
```

**Monitoring-VM (mon01):** Dedizierte 5. VM fuer Prometheus + Grafana + Alertmanager.
Trennung von Produktiv-Last, eigene Firewall-Regeln.

**Zabbix-Anbindung (optional):** Das RZ betreibt ein eigenes Zabbix. Die Integration
erfolgt ausschliesslich ueber den Alertmanager-Webhook – kein direktes Scraping durch
Zabbix, keine Zabbix-Agents auf den VMs. Siehe Abschnitt
[Optionale Zabbix-Anbindung](#optionale-zabbix-anbindung).

### Komponenten auf den Ziel-VMs

| Komponente | VM | Port | Zweck |
|---|---|---|---|
| Keycloak Metrics (built-in) | kc01, kc02 | 9000 `/metrics` | KC-Metriken (Logins, Sessions, JVM) |
| node_exporter | alle | 9100 | CPU, RAM, Disk, Netzwerk |
| postgres_exporter | db01 | 9187 | DB-Metriken |
| nginx-prometheus-exporter | lb01 | 9113 | Request-Rate, Status-Codes |

### Komponenten auf mon01

| Komponente | Port | Zweck |
|---|---|---|
| Prometheus | 9090 | Scraping + Speicherung + Alerting-Rules |
| Grafana | 3000 | Dashboards + Alert-Notifications |
| Alertmanager | 9093 | Alert-Routing (E-Mail, Slack, Webhook) |

---

## KPIs und Metriken

### 1. Keycloak-Metriken (via `/metrics` Endpoint, Prometheus-Format)

Keycloak 26 liefert mit `metrics-enabled=true` automatisch Micrometer-Metriken.

#### User-bezogen

| Metrik | Typ | Was sie zeigt |
|---|---|---|
| `keycloak_registrations` | Counter | Neue User-Registrierungen (pro Realm, Client) |
| `keycloak_login_attempts` | Counter | Login-Versuche gesamt |
| `keycloak_successful_login` | Counter | Erfolgreiche Logins |
| `keycloak_failed_login_attempts` | Counter | Fehlgeschlagene Logins (Brute-Force-Indikator) |
| `keycloak_refresh_tokens` | Counter | Token-Refreshes (Indikator fuer aktive Sessions) |
| `keycloak_client_initiated_account_linking` | Counter | Account-Linking-Events |
| `keycloak_code_to_tokens` | Counter | Authorization-Code zu Token Exchanges |

**Wie viele User neu dazugekommen?** `rate(keycloak_registrations[1h])` in Prometheus/Grafana.

**Wie viele Logins?** `rate(keycloak_successful_login[5m])` fuer Logins/Sekunde.

**Wie viele User weg?** Keycloak liefert keine Delete-Metrik out-of-the-box. Siehe Abschnitt [User-Abgaenge tracken](#user-abgaenge-tracken).

#### Performance / Latenz

| Metrik | Typ | Was sie zeigt |
|---|---|---|
| `http_server_requests_seconds` | Histogram | Request-Latenz nach Endpoint, Methode, Status |
| `http_server_requests_seconds_count` | Counter | Gesamtzahl Requests |
| `http_server_requests_seconds_sum` | Counter | Kumulative Request-Dauer |

**KPI:** p95-Latenz fuer `/realms/{realm}/protocol/openid-connect/token` (Token-Endpoint) sollte < 200ms sein.

#### JVM / Infrastruktur

| Metrik | Typ | Was sie zeigt |
|---|---|---|
| `jvm_memory_used_bytes` | Gauge | Heap/Non-Heap-Verbrauch |
| `jvm_gc_pause_seconds` | Summary | GC-Pausen (> 500ms = Problem) |
| `jvm_threads_live_threads` | Gauge | Aktive Threads |
| `process_cpu_usage` | Gauge | CPU-Auslastung des KC-Prozesses |
| `hikaricp_connections_active` | Gauge | Aktive DB-Connections im Pool |
| `hikaricp_connections_pending` | Gauge | Wartende DB-Connections (> 0 = Pool zu klein) |
| `hikaricp_connections_timeout_total` | Counter | Connection-Timeouts (> 0 = Problem) |

#### Cluster

| Metrik | Was sie zeigt |
|---|---|
| `/health` -> `numberOfNodes` | Cluster-Membership (muss 2 sein) |
| Infinispan-Cache-Metriken | Session-Replikation, Cache-Hits/Misses |

### 2. PostgreSQL-Metriken (via postgres_exporter)

| Metrik | Was sie zeigt |
|---|---|
| `pg_stat_activity_count` | Aktive Connections (nach State) |
| `pg_stat_database_tup_inserted/updated/deleted` | DML-Operationen |
| `pg_stat_database_deadlocks` | Deadlocks (sollte 0 sein) |
| `pg_stat_database_blk_hit_ratio` | Cache-Hit-Ratio (sollte > 99%) |
| `pg_settings_max_connections` | Max Connections vs. aktuelle |
| `pg_replication_lag` | Falls Streaming-Replication kommt |

### 3. Nginx-Metriken (via nginx-prometheus-exporter)

| Metrik | Was sie zeigt |
|---|---|
| `nginx_http_requests_total` | Request-Rate |
| `nginx_connections_active` | Aktive Verbindungen |
| `nginx_up` | Nginx erreichbar (0/1) |
| HTTP-Status-Verteilung (aus Access-Log) | 2xx/4xx/5xx-Ratio |

### 4. System-Metriken (via node_exporter, alle VMs)

| Metrik | Alert-Schwelle |
|---|---|
| CPU-Auslastung | > 80% sustained 5min |
| RAM-Nutzung | > 90% |
| Disk-Nutzung | > 85% |
| Disk I/O Wait | > 20% |
| Network Errors | > 0 |
| Systemd-Unit-Status | != active |

---

## Alerting-Empfehlungen

Umsetzbar via Prometheus Alertmanager oder Grafana Alerts.

| Alert | Bedingung | Severity |
|---|---|---|
| KC Node Down | `up{job="keycloak"} == 0` fuer > 1min | critical |
| Cluster Split-Brain | `numberOfNodes != 2` fuer > 2min | critical |
| Login-Fehlerrate hoch | `rate(keycloak_failed_login_attempts[5m]) > 10` | warning |
| Token-Endpoint langsam | `p95(http_server_requests_seconds{uri="/token"}) > 0.5` | warning |
| DB Connection Pool erschoepft | `hikaricp_connections_pending > 0` fuer > 1min | warning |
| DB Connections nah am Limit | `pg_stat_activity_count / pg_settings_max_connections > 0.8` | warning |
| TLS-Zertifikat laeuft ab | < 14 Tage bis Ablauf | warning |
| Disk > 85% | `node_filesystem_avail_bytes / total < 0.15` | warning |
| PostgreSQL Down | `pg_up == 0` | critical |
| Nginx Down | `nginx_up == 0` | critical |
| Hohe GC-Pausen | `jvm_gc_pause_seconds_max > 0.5` | warning |

---

## User-Abgaenge tracken

Keycloak liefert keine Built-in-Metrik fuer geloeschte User. Empfehlung: zwei Ansaetze kombinieren.

### 1. Admin-Events aktivieren

In der Realm-Config `eventsEnabled=true` und `adminEventsEnabled=true` setzen.
`DELETE_USER` Events tauchen im Event-Log auf und koennen via Log-Parsing oder
Admin-API abgefragt werden.

### 2. Periodischer User-Count

Cronjob auf mon01, der `GET /admin/realms/{realm}/users/count` abfragt und als
Prometheus-Gauge exposed (via Textfile-Collector in node_exporter).
Delta zum Vortag = Netto-Veraenderung.

---

## Deployment auf bestehendes System

Monitoring in ein laufendes Keycloak HA-Setup integrieren. Alle Schritte sind
idempotent – erneutes Ausfuehren ist sicher.

**Voraussetzung:** 5. VM (mon01) mit Debian 13 bereitstellen, Repo klonen.

### Phase 0: `.env` auf allen VMs aktualisieren

```bash
# Auf ALLEN VMs (.env oeffnen und ergaenzen):
MON_HOST=<IP-von-mon01>
```

### Phase 1: Keycloak Metriken aktivieren (kc01, dann kc02)

`metrics-enabled` wurde in `keycloak.conf.tpl` auf `true` geaendert. Das erfordert
einen `kc.sh build` + Neustart. Das Setup-Skript erkennt die Config-Aenderung
automatisch und fuehrt den Build aus.

```bash
# Auf kc01 (ZUERST – Startup-Reihenfolge beachten!):
sudo scripts/02-setup-keycloak.sh

# Warten bis kc01 ready:
until curl -sf http://localhost:9000/health/ready; do sleep 5; done

# Auf kc02:
sudo scripts/02-setup-keycloak.sh
```

**Auswirkung:** Kurze Downtime pro Node waehrend Build+Restart (~30s).
Bei kc01+kc02 nacheinander bleibt der Service via lb01 erreichbar.

### Phase 2: Nginx stub_status aktivieren (lb01)

Die nginx-Config hat jetzt eine `/nginx_status` Location fuer den Exporter.

```bash
# Auf lb01:
sudo scripts/03-setup-nginx.sh
```

**Auswirkung:** Nginx-Reload (keine Downtime).

### Phase 3: Exporter auf Ziel-VMs installieren

```bash
# Auf db01:
sudo scripts/05-setup-monitoring.sh db

# Auf kc01:
sudo scripts/05-setup-monitoring.sh keycloak

# Auf kc02:
sudo scripts/05-setup-monitoring.sh keycloak

# Auf lb01:
sudo scripts/05-setup-monitoring.sh lb
```

Installiert pro Rolle:
- **Alle:** `prometheus-node-exporter` (:9100)
- **db:** `postgres_exporter` (:9187) – GitHub-Release, systemd-Unit
- **lb:** `nginx-prometheus-exporter` (:9113) – GitHub-Release, systemd-Unit
- **keycloak:** Keine zusaetzlichen Exporter (Metriken built-in auf :9000)

### Phase 4: Firewall-Regeln fuer Monitoring (alle VMs)

```bash
# Auf db01:
sudo scripts/04-harden.sh db

# Auf kc01:
sudo scripts/04-harden.sh keycloak

# Auf kc02:
sudo scripts/04-harden.sh keycloak

# Auf lb01:
sudo scripts/04-harden.sh lb
```

Wenn `MON_HOST` gesetzt ist, werden automatisch die Scraping-Ports
(9100, 9187, 9113, 9000) von mon01 freigeschaltet. Bestehende Regeln
bleiben erhalten (UFW ist idempotent).

### Phase 5: Monitoring-Stack auf mon01

```bash
# Auf mon01:
sudo scripts/06-setup-mon-vm.sh
sudo scripts/04-harden.sh mon
```

Installiert und konfiguriert:
- **Prometheus** (:9090) mit Scrape-Config und Alert-Rules
- **Alertmanager** (:9093) mit Routing-Config
- **Grafana** (:3000) mit auto-provisionierter Prometheus-Datasource
- **node_exporter** (:9100) fuer Self-Monitoring

### Phase 6: Validierung

```bash
# Auf mon01:
scripts/99-healthcheck.sh mon

# Metriken-Endpoint erreichbar?
curl -s http://<KC_NODE1_IP>:9000/metrics | head -5

# Prometheus-Targets alle UP?
curl -s http://mon01:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {instance, health}'

# Grafana erreichbar?
curl -sf http://mon01:3000/api/health

# Alert-Rules geladen?
curl -s http://mon01:9090/api/v1/rules \
  | jq '.data.groups[].rules[] | {name, state}'
```

### Zusammenfassung Ausfuehrungsreihenfolge

```
Phase 0:  alle VMs    → .env: MON_HOST ergaenzen
Phase 1:  kc01 → kc02 → sudo 02-setup-keycloak.sh  (Metriken aktivieren)
Phase 2:  lb01        → sudo 03-setup-nginx.sh      (stub_status)
Phase 3:  db01, kc*, lb01 → sudo 05-setup-monitoring.sh <rolle>  (Exporter)
Phase 4:  db01, kc*, lb01 → sudo 04-harden.sh <rolle>  (UFW fuer Monitoring)
Phase 5:  mon01       → sudo 06-setup-mon-vm.sh + 04-harden.sh mon
Phase 6:  mon01       → scripts/99-healthcheck.sh mon  (Validierung)
```

---

## Netzwerk-Ports (Erweiterung)

| Von   | Nach  | Port | Zweck                          |
|-------|-------|------|--------------------------------|
| mon01 | kc*   | 9000 | Keycloak-Metriken scrapen      |
| mon01 | alle  | 9100 | node_exporter scrapen          |
| mon01 | db01  | 9187 | postgres_exporter scrapen      |
| mon01 | lb01  | 9113 | nginx-exporter scrapen         |
| Admin | mon01 | 3000 | Grafana UI                     |
| Admin | mon01 | 9090 | Prometheus UI (optional)       |
| mon01 | Zabbix-Server | 10051 | zabbix_sender (optional)  |

---

## Grafana-Dashboards (Empfehlung)

| Dashboard | Inhalt |
|---|---|
| Keycloak Overview | Login-Rate, Registrierungen, Fehler, Token-Latenz, aktive Sessions |
| Keycloak JVM | Heap, GC-Pausen, Threads, CPU, HikariCP Connection Pool |
| Infrastruktur | CPU, RAM, Disk, Netzwerk pro VM (node_exporter) |
| PostgreSQL | Connections, Cache-Hit-Ratio, DML-Rate, Deadlocks |
| Nginx | Request-Rate, Status-Code-Verteilung, Active Connections |
| Cluster Health | numberOfNodes, JGroups-Status, Split-Brain-Erkennung |

---

## Optionale Zabbix-Anbindung

### Design-Prinzip

Zabbix wird **nicht** als primaeres Monitoring verwendet, sondern empfaengt nur
eskalationswuerdige Alerts vom Alertmanager. Das haelt die Integration schlank:

- Kein Zabbix-Agent auf den VMs noetig
- Kein direktes Scraping durch Zabbix
- Alertmanager pushed per Webhook an Zabbix
- Nur Signale, die eine Reaktion des RZ-Betreibers erfordern

### Anbindung: Alertmanager Webhook an Zabbix

Zabbix ab Version 4.0 unterstuetzt Webhooks als Media-Type. Der Alertmanager
sendet Alerts per HTTP POST an den Zabbix-Webhook-Receiver.

**Alertmanager-Config (`alertmanager.yml`):**

```yaml
receivers:
  - name: 'zabbix-escalation'
    webhook_configs:
      - url: 'http://<ZABBIX_SERVER>/api_jsonrpc.php'
        # Alternativ: custom Webhook-Relay (siehe unten)
        send_resolved: true

route:
  receiver: 'default'
  routes:
    # Nur critical + zabbix-relevante Alerts an Zabbix weiterleiten
    - match:
        zabbix: 'true'
      receiver: 'zabbix-escalation'
```

**Pragmatischer Ansatz:** Ein kleines Relay-Skript auf mon01, das Alertmanager-
Webhooks empfaengt und per `zabbix_sender` an den Zabbix-Server weiterleitet.
Das ist robuster als die direkte Zabbix-API-Anbindung:

```bash
# Beispiel: zabbix_sender fuer einen Alert
zabbix_sender \
  -z <ZABBIX_SERVER> \
  -s "keycloak-ha" \
  -k "keycloak.alert" \
  -o "PROBLEM: KC Node kc01 Down seit 2min"
```

### Alerts fuer Zabbix (nur eskalationswuerdige Signale)

Diese Alerts erhalten das Label `zabbix: "true"` in den Prometheus Alert-Rules
und werden damit an Zabbix weitergeleitet:

| Alert | Kategorie | Beschreibung | Zabbix-Severity |
|---|---|---|---|
| KC Node Down | Ausfall | Keycloak-Node antwortet nicht (> 2min) | High |
| Cluster Split-Brain | Ausfall | Nodes sehen sich nicht mehr (numberOfNodes != 2, > 3min) | Disaster |
| PostgreSQL Down | Ausfall | Datenbank nicht erreichbar (> 1min) | Disaster |
| Nginx Down | Ausfall | Load Balancer ausgefallen | Disaster |
| Brute-Force erkannt | Angriff | Failed Logins > 50/min (deutlich ueber normalem Rauschen) | High |
| TLS-Zertifikat kritisch | Massnahme | Zertifikat laeuft in < 7 Tagen ab | High |
| Disk kritisch | Massnahme | Disk-Nutzung > 95% auf einer VM | High |
| DB Connections erschoepft | Massnahme | Connection-Pool bei > 95% Auslastung | High |
| Alle KC Nodes Down | Ausfall | Beide Keycloak-Nodes gleichzeitig nicht erreichbar | Disaster |
| SSH-Bans uebermaessig | Angriff | Fail2ban hat > 20 IPs in der letzten Stunde gebannt | Average |

### Prometheus Alert-Rules mit Zabbix-Label

```yaml
# Beispiel: alerts.yml (Auszug)
groups:
  - name: zabbix-escalation
    rules:
      - alert: KCNodeDown
        expr: up{job="keycloak"} == 0
        for: 2m
        labels:
          severity: critical
          zabbix: "true"
        annotations:
          summary: "Keycloak Node {{ $labels.instance }} ist ausgefallen"

      - alert: ClusterSplitBrain
        expr: keycloak_cluster_node_count != 2
        for: 3m
        labels:
          severity: critical
          zabbix: "true"
        annotations:
          summary: "Keycloak-Cluster hat {{ $value }} statt 2 Nodes"

      - alert: BruteForceDetected
        expr: rate(keycloak_failed_login_attempts[5m]) * 60 > 50
        for: 2m
        labels:
          severity: warning
          zabbix: "true"
        annotations:
          summary: "Brute-Force vermutet: {{ $value | humanize }} fehlgeschlagene Logins/min"
```

### Netzwerk-Voraussetzungen

| Von   | Nach          | Port  | Zweck                          |
|-------|---------------|-------|--------------------------------|
| mon01 | Zabbix-Server | 10051 | zabbix_sender (Active Trapper) |

Nur ein einziger Port von mon01 zum Zabbix-Server – kein Zugriff von Zabbix auf
die Produktiv-VMs noetig.

### Zabbix-seitige Konfiguration (durch RZ-Betreiber)

1. **Host anlegen:** `keycloak-ha` mit Interface-Typ "Agent" (IP von mon01)
2. **Items vom Typ "Zabbix trapper"** fuer jeden Alert anlegen (Key: `keycloak.alert`)
3. **Trigger:** Auf Trapper-Item-Werte reagieren (PROBLEM/RESOLVED)
4. **Media-Type:** Optional Webhook statt zabbix_sender (wenn Zabbix >= 5.0)

---

## Verifikation

```bash
# Metriken-Endpoint erreichbar? (nach metrics-enabled=true)
curl -s http://kc01:9000/metrics | head -20

# Prometheus-Targets healthy?
curl -s http://mon01:9090/api/v1/targets | jq '.data.activeTargets[] | {instance, health}'

# Grafana erreichbar?
curl -sf http://mon01:3000/api/health

# Alert-Rules geladen?
curl -s http://mon01:9090/api/v1/rules | jq '.data.groups[].rules[] | {name, state}'
```
