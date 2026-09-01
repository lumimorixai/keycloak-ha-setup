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
| Fail2ban-Metriken (textfile) | alle | – | `fail2ban_banned_current` via Cronjob (2min) |
| Cluster-Membership (textfile) | kc01, kc02 | – | `keycloak_cluster_nodes` via Cronjob (1min) |
| User-Bestand (textfile) | kc01, kc02 | – | `keycloak_users_total` via Cronjob (5min) |

### Komponenten auf mon01

| Komponente | Port | Zweck |
|---|---|---|
| Prometheus | 9090 | Scraping + Speicherung + Alerting-Rules |
| Grafana | 3000 | Dashboards + Alert-Notifications |
| Alertmanager | 9093 | Alert-Routing (E-Mail, Slack, Webhook) |
| Blackbox-Exporter | 9115 | TLS-Zertifikatsprüfung (Probe gegen KC_DOMAIN und, falls gesetzt, KC_ADMIN_DOMAIN) |

---

## KPIs und Metriken

### 1. Keycloak-Metriken (via `/metrics` Endpoint, Prometheus-Format)

Keycloak 26 liefert mit `metrics-enabled=true` automatisch Micrometer-Metriken.

#### User-bezogen

> **Wichtig:** User-Events erfordern zusaetzlich `event-metrics-user-enabled=true`
> in `keycloak.conf` (plus `kc.sh build` + Neustart). `metrics-enabled=true` allein
> liefert nur JVM-, HTTP- und Datasource-Metriken.
>
> Alle User-Events landen in **einer** Metrik. Die frueher hier dokumentierten Namen
> (`keycloak_successful_login`, `keycloak_failed_login_attempts`, ...) stammen aus der
> Wildfly-Extension `keycloak-metrics-spi` und existieren in der Quarkus-Distribution nicht.

| Metrik | Typ | Was sie zeigt |
|---|---|---|
| `keycloak_user_events_total` | Counter | Alle User-Events, unterschieden ueber Labels |

Labels: `realm`, `event` (z.B. `login`, `logout`, `register`, `refresh_token`, `code_to_token`),
`error` (Fehlercode oder leer bei Erfolg), sowie `client_id` und `idp` – letztere beide nur
wenn via `event-metrics-user-tags=realm,clientId,idp` aktiviert.

| Frage | PromQL |
|---|---|
| Logins pro Sekunde | `sum(rate(keycloak_user_events_total{event="login", error=""}[5m]))` |
| Fehlgeschlagene Logins | `sum(rate(keycloak_user_events_total{event=~"login\|login_error", error!=""}[5m]))` |
| Neue User (letzte Stunde) | `sum(increase(keycloak_user_events_total{event="register", error=""}[1h]))` |
| Aktive Sessions (Indikator) | `sum(rate(keycloak_user_events_total{event="refresh_token"}[5m]))` |
| Logins nach Client | `sum by (client_id) (rate(keycloak_user_events_total{event="login", error=""}[5m]))` |

#### End-User-Logins von Admin-Logins trennen

Anmeldungen an der Keycloak-Verwaltung sind ganz normale User-Events – sie unterscheiden
sich nur ueber die Labels `realm` und `client_id`:

| Vorgang | Labels |
|---|---|
| Admin-Console-Login | `realm="master"`, `client_id="security-admin-console"` |
| End-User-Login in einer Anwendung | `realm="<dein-realm>"`, `client_id="<dein-client>"` |
| Self-Service (Account-Console) | `client_id="account-console"` |

| Frage | PromQL |
|---|---|
| Nur End-User-Logins (ohne Verwaltung) | `sum(rate(keycloak_user_events_total{event="login", error="", client_id!="security-admin-console"}[5m]))` |
| Logins eines bestimmten Realms | `sum(rate(keycloak_user_events_total{event="login", error="", realm="kunden"}[5m]))` |
| Alles ausser dem master-Realm | `sum by (realm) (rate(keycloak_user_events_total{event="login", error="", realm!="master"}[5m]))` |
| Welche Anwendung wird genutzt? | `sum by (client_id) (rate(keycloak_user_events_total{event="login", error=""}[5m]))` |
| User-Bestand ohne Admin-Accounts | `sum(keycloak_users_total{realm!="master"})` |

Welche `realm`/`client_id`-Kombinationen bei dir tatsaechlich auflaufen, zeigt am
schnellsten der Endpoint selbst:

```bash
curl -s localhost:9000/metrics | grep keycloak_user_events_total
```

Das Dashboard *Keycloak Overview* hat dafuer zwei Variablen: **Realm** (Mehrfachauswahl)
und **Client-Filter** (Default `Nur End-User` – blendet `security-admin-console` aus).

**Wie viele User gibt es insgesamt?** Keycloak liefert dafuer keine Metrik – weder Bestand
noch Loeschungen. Dieses Setup ergaenzt sie via Textfile-Collector: `keycloak_users_total{realm="..."}`
(siehe [User-Bestand und -Abgaenge tracken](#user-bestand-und--abgaenge-tracken)).

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

| Metrik | Typ | Was sie zeigt |
|---|---|---|
| `keycloak_cluster_nodes` | Gauge (textfile) | Cluster-Membership (muss 2 sein in Prod) |
| `/health` -> `numberOfNodes` | JSON-Feld | Quelle fuer `keycloak_cluster_nodes` (via Cronjob) |
| Infinispan-Cache-Metriken | Diverse | Session-Replikation, Cache-Hits/Misses |

> **Hinweis:** `keycloak_cluster_nodes` wird via Cronjob (`keycloak-cluster-metrics.sh`)
> aus dem Health-Endpoint extrahiert und als textfile-Collector-Metrik bereitgestellt.
> Installiert durch `05-setup-monitoring.sh keycloak`.

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

### 5. TLS-Zertifikat (via Blackbox-Exporter auf mon01)

Der Blackbox-Exporter fuehrt eine TLS-Probe gegen `https://${KC_DOMAIN}` durch.

| Metrik | Typ | Was sie zeigt |
|---|---|---|
| `probe_ssl_earliest_cert_expiry` | Gauge | Unix-Timestamp des Zertifikatsablaufs |
| `probe_success` | Gauge | 1 = Probe erfolgreich, 0 = fehlgeschlagen |

**KPI:** Zertifikat muss > 14 Tage gueltig sein (Warning), > 7 Tage (Critical).

### 6. Fail2ban-Metriken (via textfile collector, alle VMs)

| Metrik | Typ | Was sie zeigt |
|---|---|---|
| `fail2ban_banned_current{jail="sshd"}` | Gauge (textfile) | Aktuell gebannte IPs im SSH-Jail |

**KPI:** > 20 gebannte IPs deuten auf einen Angriff hin.

---

## Alerting-Empfehlungen

Alle Alerts sind in `configs/monitoring/alert-rules.yml` als Prometheus Alert-Rules
implementiert (21 Alerts in 6 Gruppen). Detaillierte Massnahmen pro Alert:
[ALERTING-RUNBOOK.md](ALERTING-RUNBOOK.md).

| Alert | Bedingung | Severity | Zabbix |
|---|---|---|---|
| KCNodeDown | `up{job="keycloak"} == 0` fuer 2min | critical | ja |
| LoginFehlerrateHoch | `sum by (realm) (rate(keycloak_user_events_total{event=~"login\|login_error", error!=""}[5m])) > 10` | warning | – |
| BruteForceVerdacht | `sum by (realm) (rate(keycloak_user_events_total{event=~"login\|login_error", error!=""}[5m])) * 60 > 50` | warning | ja |
| TokenEndpointLangsam | p95 Token-Latenz > 500ms fuer 5min | warning | – |
| DBConnectionPoolErschoepft | `hikaricp_connections_pending > 0` fuer 1min | warning | ja |
| HoheGCPausen | `jvm_gc_pause_seconds_max > 0.5` fuer 2min | warning | – |
| KCClusterMembershipBroken | `keycloak_cluster_nodes != 2` fuer 2min | critical | ja |
| PostgreSQLDown | `pg_up == 0` fuer 1min | critical | ja |
| DBConnectionsNahAmLimit | `pg_stat_activity_count / max_connections > 0.8` fuer 5min | warning | ja |
| DBDeadlocks | `rate(pg_stat_database_deadlocks[5m]) > 0` fuer 2min | warning | – |
| NginxDown | `nginx_up == 0` fuer 1min | critical | ja |
| HighCPU | CPU > 80% fuer 5min | warning | – |
| HighMemory | RAM > 90% fuer 5min | warning | – |
| DiskFull | Disk > 85% fuer 5min | warning | ja |
| DiskKritisch | Disk > 95% fuer 2min | critical | ja |
| SystemdUnitFailed | systemd-Unit fehlgeschlagen fuer 2min | warning | – |
| Fail2banExcessiveBans | > 20 gebannte IPs fuer 5min | warning | ja |
| TLSCertExpiringSoon | Zertifikat < 14 Tage gueltig | warning | – |
| TLSCertExpiryCritical | Zertifikat < 7 Tage gueltig | critical | ja |
| TLSProbeFailure | TLS-Probe fehlgeschlagen fuer 5min | critical | ja |
| AlleKCNodesDown | Alle KC-Nodes gleichzeitig nicht erreichbar fuer 1min | critical | ja |

---

## User-Bestand und -Abgaenge tracken

Keycloak liefert keine Built-in-Metrik fuer die Anzahl vorhandener oder geloeschter User.
`keycloak_user_events_total{event="register"}` zaehlt ausschliesslich Neuzugaenge.

### 1. User-Bestand via Textfile-Collector (implementiert)

`configs/monitoring/keycloak-user-metrics.sh` liest den Bestand alle 5 Minuten per SQL
aus der Keycloak-DB und schreibt ihn als Gauge:

```
keycloak_users_total{realm="master"} 3
```

Installiert durch `05-setup-monitoring.sh keycloak`. Service-Accounts werden
ausgeschlossen (`service_account_client_link IS NULL`), gezaehlt werden nur echte User.

Netto-Veraenderung pro Tag: `delta(keycloak_users_total[24h])` – negativer Wert = Abgaenge.

Warum SQL und nicht die Admin-API: kein Service-Account-Client, kein Token-Handling,
keine Credentials ueber HTTP – und der Wert bleibt auch dann korrekt, wenn Keycloak
gerade nicht laeuft. Preis: die Abfrage haengt am DB-Schema (`user_entity`), das sich
bei Major-Upgrades aendern kann. Nach jedem KC-Major-Upgrade einmal pruefen:
`cat /var/lib/prometheus/node-exporter/keycloak_users.prom`

### 2. Admin-Events aktivieren (optional, fuer Nachvollziehbarkeit)

In der Realm-Config `eventsEnabled=true` und `adminEventsEnabled=true` setzen.
`DELETE_USER` Events tauchen im Event-Log auf und koennen via Log-Parsing oder
Admin-API abgefragt werden – liefert das *Wer/Wann*, das ein Gauge nicht hat.

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

`metrics-enabled` und `event-metrics-user-enabled` wurden in `keycloak.conf.tpl` auf
`true` gesetzt. Das erfordert einen `kc.sh build` + Neustart. Das Setup-Skript erkennt
die Config-Aenderung automatisch und fuehrt den Build aus.

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
- **Alle:** `prometheus-node-exporter` (:9100) + Fail2ban-Metriken (textfile collector)
- **db:** `postgres_exporter` (:9187) – GitHub-Release, systemd-Unit
- **lb:** `nginx-prometheus-exporter` (:9113) – GitHub-Release, systemd-Unit
- **keycloak:** Cluster-Membership-Metriken (textfile collector, Cronjob jede Minute)

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
- **Prometheus** (:9090) mit Scrape-Config und 21 Alert-Rules (6 Gruppen)
- **Alertmanager** (:9093) mit Routing-Config (optional Zabbix-Webhook)
- **Grafana** (:3000) mit auto-provisionierter Datasource + 5 Dashboards
- **Blackbox-Exporter** (:9115) fuer TLS-Zertifikatsprüfung
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
| mon01 | localhost | 9115 | Blackbox-Exporter (TLS-Probe)  |
| mon01 | Zabbix-Server | 10051 | zabbix_sender (optional)  |

---

## Grafana-Dashboards (auto-provisioniert)

Dashboards werden automatisch via `06-setup-mon-vm.sh` provisioniert
(file-based provisioning nach `/var/lib/grafana/dashboards`).

| Dashboard | Quelle | Inhalt |
|---|---|---|
| Keycloak Overview | Custom (`keycloak-overview.json`) | Login-Rate, Registrierungen, Fehler, Aufschluesselung nach Realm/Client, User-Bestand, Token-Latenz, Cluster-Nodes, Target-Health |
| Keycloak JVM | Custom (`keycloak-jvm.json`) | Heap, GC-Pausen, Threads, CPU, HikariCP Connection Pool |
| Node Exporter Full | Community (ID 1860) | CPU, RAM, Disk, Netzwerk pro VM |
| PostgreSQL | Community (ID 9628) | Connections, Cache-Hit-Ratio, DML-Rate, Deadlocks |
| Nginx | Community (ID 12708) | Request-Rate, Status-Code-Verteilung, Active Connections |

*Keycloak Overview* hat drei Variablen: **instance** (KC-Node), **Realm** und
**Client-Filter**. Der Client-Filter steht per Default auf `Nur End-User` und blendet
`security-admin-console` aus – die Login-Panels zeigen damit ausschliesslich echte
Anmeldungen von Anwendern, keine Logins an der Keycloak-Verwaltung. Umschalten auf
`Alle Clients` zeigt beides.

Community-Dashboards werden beim ersten Ausfuehren von `06-setup-mon-vm.sh` von
`grafana.com` heruntergeladen. Die Custom-Dashboards liegen unter
`configs/monitoring/dashboards/`.

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
| KCNodeDown | Ausfall | Keycloak-Node antwortet nicht (> 2min) | High |
| KCClusterMembershipBroken | Ausfall | `keycloak_cluster_nodes != 2` (> 2min) | Disaster |
| PostgreSQLDown | Ausfall | Datenbank nicht erreichbar (> 1min) | Disaster |
| NginxDown | Ausfall | Load Balancer ausgefallen | Disaster |
| AlleKCNodesDown | Ausfall | Beide Keycloak-Nodes gleichzeitig nicht erreichbar | Disaster |
| BruteForceVerdacht | Angriff | Failed Logins > 50/min (> 2min) | High |
| Fail2banExcessiveBans | Angriff | > 20 gebannte IPs (> 5min) | Average |
| TLSCertExpiryCritical | Massnahme | Zertifikat laeuft in < 7 Tagen ab | High |
| TLSProbeFailure | Ausfall | TLS-Probe fehlgeschlagen (> 5min) | High |
| DiskKritisch | Massnahme | Disk-Nutzung > 95% auf einer VM | High |
| DBConnectionsNahAmLimit | Massnahme | DB-Connections bei > 80% des Limits | High |
| DBConnectionPoolErschoepft | Massnahme | HikariCP Pending Connections > 0 | High |

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

      - alert: KCClusterMembershipBroken
        expr: keycloak_cluster_nodes != 2
        for: 2m
        labels:
          severity: critical
          zabbix: "true"
        annotations:
          summary: "Keycloak Cluster-Mitgliedschaft gestoert: {{ $value }} Nodes (erwartet: 2)"

      - alert: BruteForceDetected
        expr: sum by (realm) (rate(keycloak_user_events_total{event=~"login|login_error", error!=""}[5m])) * 60 > 50
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
