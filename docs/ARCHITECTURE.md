# Keycloak HA Setup – Architektur

## Übersicht

```
Internet
    │
    ▼
lb01 (Nginx + Certbot)
  :443 TLS-Terminierung
  :80  ACME Challenge + /nginx_status (stub_status)
    │
    │ ip_hash Session-Stickiness
    ├──────────────────┐
    ▼                  ▼
kc01 (:8080)      kc02 (:8080)
Keycloak          Keycloak
  :9000 /metrics    :9000 /metrics
    │    JGroups TCP :7800    │
    └──────────────────────────┘
    │                  │
    └────────┬──────────┘
             ▼
         db01 (:5432)
         PostgreSQL 16

         mon01 (Monitoring)
         ┌──────────────────────┐
         │ Prometheus    :9090  │
         │ Grafana       :3000  │
         │ Alertmanager  :9093  │
         └──────────┬───────────┘
                    │ Scraping
        ┌───────┬───┼──────┬──────┐
        ▼       ▼   ▼      ▼      ▼
    kc*:9000  db01  lb01  alle   mon01
    /metrics  :9187 :9113 :9100  :9100
                                blackbox
                                :9115
```

## Komponenten

### lb01 – Load Balancer

- **Nginx**: TLS-Terminierung, Reverse Proxy, ip_hash Session-Stickiness
- **stub_status**: `/nginx_status` (nur localhost) für nginx-prometheus-exporter
- **Certbot**: Let's Encrypt ACME-Client, Auto-Renewal via systemd-Timer
- **nginx-prometheus-exporter**: Nginx-Metriken auf :9113 (installiert via `05-setup-monitoring.sh lb`)
- **node_exporter**: System-Metriken auf :9100
- **Fail2ban**: Schutz gegen Brute-Force (SSH + Nginx-Jails)
- **UFW**: Erlaubt 80/tcp, 443/tcp, SSH; bei MON_HOST: 9100/9113 von mon01

### kc01 / kc02 – Keycloak-Nodes

- **Keycloak 26.5.5**: Quarkus-Distribution, `--optimized` Start nach Build
- **Adoptium Temurin JDK 21**: Bessere Quarkus-Kompatibilität als Debian-Paket
- **Metriken**: `metrics-enabled=true` – Micrometer/Prometheus-Format auf :9000 `/metrics`
- **JGroups TCP**: Cluster-Datentransport direkt zwischen kc01 und kc02 (Port 7800)
- **JDBC_PING2**: Cluster-Discovery via PostgreSQL (kein Multicast benötigt)
- **node_exporter**: System-Metriken auf :9100
- **UFW**: Erlaubt 8080/tcp von lb01, 9000/tcp von lb01+mon01, 7800/tcp zwischen kc01↔kc02, SSH
- **Fail2ban**: SSH-Schutz

### db01 – Datenbank

- **PostgreSQL 16**: Quell-Repo von postgresql.org (pgdg), nicht Debian-Paket
- **pg_hba.conf**: scram-sha-256 Auth, Zugriff nur von kc01 und kc02
- **postgres_exporter**: DB-Metriken auf :9187 (installiert via `05-setup-monitoring.sh db`)
- **node_exporter**: System-Metriken auf :9100
- **UFW**: Erlaubt 5432/tcp nur von KC-Node-IPs, SSH; bei MON_HOST: 9100/9187 von mon01

### mon01 – Monitoring

- **Prometheus**: Scraping + Speicherung + Alert-Rules auf :9090
- **Grafana**: Dashboards auf :3000 (Prometheus als auto-provisionierte Datasource + Dashboards)
- **Alertmanager**: Alert-Routing auf :9093 (E-Mail, Webhook, optional Zabbix)
- **Blackbox-Exporter**: TLS-Zertifikatsprüfung auf :9115 (Probe gegen `KC_DOMAIN`)
- **node_exporter**: System-Metriken auf :9100 (Self-Monitoring)
- **UFW**: Erlaubt 3000/tcp (Grafana) für alle; 9090/9093 eingeschränkt auf ADMIN_IPS
- **Fail2ban**: SSH-Schutz

### Textfile-Collector-Metriken (alle VMs)

Zusätzlich zu den Exportern werden auf allen VMs Metriken via node_exporter
Textfile-Collector bereitgestellt:

- **Fail2ban-Metriken** (`fail2ban_banned_current`): Cronjob alle 2 Minuten,
  schreibt nach `/var/lib/prometheus/node-exporter/fail2ban.prom`
- **Keycloak Cluster-Membership** (`keycloak_cluster_nodes`): Nur auf kc01/kc02,
  Cronjob jede Minute, schreibt nach `/var/lib/prometheus/node-exporter/keycloak_cluster.prom`

Details zu KPIs, Dashboards und Alerting: [MONITORING.md](MONITORING.md)

## Design-Entscheidungen

### JDBC_PING2 statt Multicast

Viele Cloud-/Hosting-Umgebungen blockieren UDP-Multicast. JDBC_PING2 nutzt die bereits vorhandene PostgreSQL-Datenbank für die Node-Discovery – keine zusätzliche Infrastruktur erforderlich.

**Wichtig:** JDBC_PING2 übernimmt nur die Discovery (wer ist im Cluster?). Der eigentliche Cluster-Datenaustausch (Sessions, Caches) läuft über JGroups TCP Port 7800. Bei blockiertem Port 7800 laufen die Nodes isoliert – ohne sichtbaren Fehler, nur mit Log-Warnung.

### TLS-Terminierung am Load Balancer

Keycloak hört intern auf HTTP (:8080). TLS-Terminierung erfolgt am Nginx. Keycloak bekommt via `proxy-headers=xforwarded` die echten Client-IPs und das ursprüngliche HTTPS-Protokoll.

**Warum kein End-to-End TLS?** Vereinfachung: Intern sind alle VMs im selben privaten Netzwerk. Let's Encrypt Zertifikate werden nur an einem Punkt verwaltet.

### ip_hash Session-Stickiness

Keycloak-Sessions sind an einen Node gebunden während einer Auth-Flow-Phase. ip_hash garantiert, dass ein Client immer zum gleichen Backend-Node gelangt.

**Upgrade-Pfad:** Cookie-basiertes Stickiness (`sticky` via Nginx-Modul) ist präziser, erfordert aber zusätzliche Module.

### Proxy-Buffer-Konfiguration

```nginx
proxy_buffer_size   128k;
proxy_buffers       4 256k;
```

Keycloak-JWT-Token mit vielen Realm-Rollen können sehr groß werden. Ohne ausreichende Buffer-Konfiguration liefert Nginx 502-Fehler zurück.

### Keycloak Build-Artefakt

Die Quarkus-Distribution von Keycloak erfordert einen expliziten Build-Schritt (`kc.sh build`), der die Konfiguration in das ausführbare Artefakt kompiliert. Der Service startet dann mit `--optimized` ohne zusätzliche Analysephase.

Der Build-Hash-Mechanismus in `02-setup-keycloak.sh` stellt sicher, dass der Build nur bei tatsächlichen Konfigurationsänderungen ausgeführt wird.

## Monitoring

Das Monitoring folgt einem Pull-Modell: Prometheus auf mon01 scraped alle Exporter
in konfigurierbarem Intervall (Standard: 15s). Kein Agent auf den Ziel-VMs nötig
außer den leichtgewichtigen Exportern.

Die Alert-Rules sind in `configs/monitoring/alert-rules.yml` definiert und enthalten
sowohl technische Alerts (Node Down, Disk Full) als auch fachliche Alerts (Login-Fehlerrate,
Token-Latenz). Alerts mit Label `zabbix: "true"` können via Alertmanager-Webhook an
ein bestehendes Zabbix-System weitergeleitet werden.

Setup-Details: [MONITORING.md](MONITORING.md) | Alarm-Handbuch: [ALERTING-RUNBOOK.md](ALERTING-RUNBOOK.md)

## Skalierung

Das Setup ist auf zwei Keycloak-Nodes ausgelegt. Für weitere Nodes:

1. Neue VM mit `02-setup-keycloak.sh` einrichten
2. Neue Node-IP in `KC_NODE*_IP` Variablen und Nginx-Upstream ergänzen
3. UFW-Regeln auf db01 und bestehenden KC-Nodes anpassen
4. `03-setup-nginx.sh` und `04-harden.sh keycloak` erneut ausführen
5. Exporter installieren: `05-setup-monitoring.sh keycloak` auf neuer Node
6. Prometheus-Config anpassen (neue Targets in `prometheus.yml.tpl`)
