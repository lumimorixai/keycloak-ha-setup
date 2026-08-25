# Keycloak HA Setup – Alerting-Runbook

Dieses Runbook beschreibt fuer jeden Prometheus-Alert die Ursache, Auswirkung
und die empfohlenen Massnahmen. Alerts sind nach Severity sortiert.

---

## Critical Alerts (sofortige Reaktion erforderlich)

### KCNodeDown

| | |
|---|---|
| **Bedingung** | `up{job="keycloak"} == 0` fuer > 2min |
| **Bedeutung** | Ein Keycloak-Node antwortet nicht mehr auf Metriken-Anfragen |
| **Auswirkung** | Halbierte Kapazitaet. Bei ip_hash kann ein Teil der User nicht mehr zugreifen |

**Massnahmen:**

1. SSH auf den betroffenen Node (kc01 oder kc02):
   ```bash
   sudo systemctl status keycloak
   sudo journalctl -u keycloak --since "10 min ago" --no-pager | tail -50
   ```
2. Wenn Service gestoppt: `sudo systemctl start keycloak`
3. Wenn Service crasht (OOM, StackOverflow): JVM-Logs pruefen, ggf. Heap erhoehen in `.env` (`JAVA_OPTS`)
4. Wenn VM nicht erreichbar: VM-Konsole im Hosting-Panel pruefen
5. Nach Wiederherstellung: `curl -sf http://localhost:9000/health/ready` pruefen

---

### AlleKCNodesDown

| | |
|---|---|
| **Bedingung** | `count(up{job="keycloak"} == 1) == 0` fuer > 1min |
| **Bedeutung** | Beide Keycloak-Nodes sind gleichzeitig ausgefallen |
| **Auswirkung** | **Kompletter Service-Ausfall** – kein Login, keine Token-Validierung |

**Massnahmen:**

1. Sofort beide Nodes pruefen (Reihenfolge beachten!):
   ```bash
   ssh kc01 "sudo systemctl status keycloak"
   ssh kc02 "sudo systemctl status keycloak"
   ```
2. kc01 zuerst starten (fuehrt ggf. DB-Migration durch):
   ```bash
   ssh kc01 "sudo systemctl start keycloak"
   until curl -sf http://<KC_NODE1_IP>:9000/health/ready; do sleep 5; done
   ssh kc02 "sudo systemctl start keycloak"
   ```
3. Ursache klaren: War es ein gemeinsamer Ausloeser? (DB-Ausfall, Netzwerk, Update)
4. Cluster-Status pruefen: `scripts/99-healthcheck.sh keycloak`

---

### KCClusterMembershipBroken

| | |
|---|---|
| **Bedingung** | `keycloak_cluster_nodes != 2` fuer > 2min |
| **Bedeutung** | Ein Node sieht nicht mehr beide Cluster-Mitglieder (Split-Brain oder Node-Ausfall) |
| **Auswirkung** | Sessions werden nicht repliziert, Failover funktioniert nicht |

**Massnahmen:**

1. Pruefen welcher Node betroffen ist:
   ```bash
   curl -s http://kc01:9000/health | jq '.checks[].data.numberOfNodes'
   curl -s http://kc02:9000/health | jq '.checks[].data.numberOfNodes'
   ```
2. Wenn ein Node `numberOfNodes=1` meldet: JGroups-Port 7800 pruefen:
   ```bash
   ss -tlnp | grep 7800
   sudo ufw status | grep 7800
   ```
3. Wenn beide Nodes `numberOfNodes=1` melden (Split-Brain):
   ```bash
   # Recovery-Prozedur (siehe ROLLBACK.md → Cluster-Split-Brain Recovery)
   ssh kc02 "sudo systemctl stop keycloak"
   ssh kc01 "sudo systemctl stop keycloak"
   ssh kc01 "sudo systemctl start keycloak"
   until curl -sf http://<KC_NODE1_IP>:9000/health/ready; do sleep 5; done
   ssh kc02 "sudo systemctl start keycloak"
   ```

---

### PostgreSQLDown

| | |
|---|---|
| **Bedingung** | `pg_up == 0` fuer > 1min |
| **Bedeutung** | postgres_exporter kann keine Verbindung zur Datenbank herstellen |
| **Auswirkung** | Keycloak kann keine Daten lesen/schreiben – Logins schlagen fehl |

**Massnahmen:**

1. Auf db01 pruefen:
   ```bash
   sudo systemctl status postgresql@16-main
   sudo journalctl -u postgresql@16-main --since "10 min ago" --no-pager | tail -30
   ```
2. Disk voll? `df -h /var/lib/postgresql`
3. Connections erschoepft? `sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity;"`
4. Wenn Service gestoppt: `sudo systemctl start postgresql@16-main`
5. Nach Wiederherstellung: Keycloak-Nodes pruefen (starten sich ggf. automatisch neu)

---

### NginxDown

| | |
|---|---|
| **Bedingung** | `nginx_up == 0` fuer > 1min |
| **Bedeutung** | nginx-prometheus-exporter kann Nginx nicht erreichen |
| **Auswirkung** | **Kein externer Zugriff** auf Keycloak (TLS-Terminierung faellt aus) |

**Massnahmen:**

1. Auf lb01 pruefen:
   ```bash
   sudo systemctl status nginx
   sudo nginx -t  # Konfiguration validieren
   ```
2. Wenn Konfiguration fehlerhaft: Backup einspielen (siehe ROLLBACK.md → Nginx)
3. Wenn Service gestoppt: `sudo systemctl start nginx`
4. Port-Konflikt? `ss -tlnp | grep ':80\|:443'`

---

### TLSCertExpiryCritical

| | |
|---|---|
| **Bedingung** | TLS-Zertifikat laeuft in weniger als 7 Tagen ab |
| **Bedeutung** | Certbot Auto-Renewal hat versagt |
| **Auswirkung** | Nach Ablauf: Browser-Warnungen, API-Clients verweigern Verbindung |

**Massnahmen:**

1. Auf lb01 manuell erneuern:
   ```bash
   sudo certbot renew --dry-run   # Erst testen
   sudo certbot renew             # Echte Erneuerung
   sudo systemctl reload nginx
   ```
2. Wenn Dry-Run fehlschlaegt:
   - DNS pruefen: `dig +short <KC_DOMAIN>` muss auf lb01 zeigen
   - Port 80 offen? `sudo ufw status | grep 80`
   - Certbot-Logs: `sudo journalctl -u certbot --since "1 day ago"`
3. Timer pruefen: `systemctl list-timers | grep certbot`

---

### TLSProbeFailure

| | |
|---|---|
| **Bedingung** | `probe_success{job="blackbox-tls"} == 0` fuer > 5min |
| **Bedeutung** | Blackbox-Exporter kann KC_DOMAIN nicht per HTTPS erreichen |
| **Auswirkung** | Externer HTTPS-Zugriff ist wahrscheinlich gestoert |

**Massnahmen:**

1. Manuell testen:
   ```bash
   curl -vI https://<KC_DOMAIN> 2>&1 | head -20
   ```
2. Nginx laeuft? `sudo systemctl status nginx`
3. DNS korrekt? `dig +short <KC_DOMAIN>`
4. Zertifikat gueltig? `echo Q | openssl s_client -connect <KC_DOMAIN>:443 2>/dev/null | openssl x509 -noout -dates`

---

## Warning Alerts (zeitnah bearbeiten)

### TLSCertExpiringSoon

| | |
|---|---|
| **Bedingung** | TLS-Zertifikat laeuft in weniger als 14 Tagen ab |
| **Bedeutung** | Auto-Renewal hat noch nicht gegriffen, aber es ist noch Zeit |

**Massnahmen:**

1. Certbot-Timer pruefen: `systemctl list-timers | grep certbot`
2. Wenn Timer inaktiv: `sudo systemctl enable --now certbot.timer`
3. Manueller Dry-Run: `sudo certbot renew --dry-run`
4. Wenn alles OK: Abwarten – Certbot erneuert standardmaessig 30 Tage vor Ablauf

---

### LoginFehlerrateHoch

| | |
|---|---|
| **Bedingung** | `sum by (realm) (rate(keycloak_user_events_total{event=~"login\|login_error", error!=""}[5m])) > 10` fuer > 2min |
| **Bedeutung** | Ungewoehnlich viele fehlgeschlagene Login-Versuche |
| **Auswirkung** | Moeglicherweise Brute-Force-Angriff oder fehlerhafte Client-Konfiguration |

**Massnahmen:**

1. Keycloak Admin-Console pruefen: Events → Login Events → Filter auf "LOGIN_ERROR"
2. Quelle identifizieren: Kommen die Versuche von einer IP oder vielen?
3. Wenn einzelne IP: Fail2ban greift automatisch; pruefen mit `sudo fail2ban-client status sshd`
4. Wenn Client-Fehler: Client-Secret oder Redirect-URI falsch konfiguriert?
5. Realm Brute-Force-Protection in Keycloak aktivieren (Realm Settings → Security Defenses)

---

### BruteForceVerdacht

| | |
|---|---|
| **Bedingung** | `sum by (realm) (rate(keycloak_user_events_total{event=~"login\|login_error", error!=""}[5m])) * 60 > 50` fuer > 2min |
| **Bedeutung** | Mehr als 50 fehlgeschlagene Logins pro Minute – starker Brute-Force-Verdacht |
| **Auswirkung** | Angriff laeuft aktiv, Accounts koennten kompromittiert werden |

**Massnahmen:**

1. Sofort pruefen ob Keycloak Brute-Force-Protection aktiv ist
2. IP-Adressen der Angreifer identifizieren (Keycloak Events oder Nginx Access-Log):
   ```bash
   # Auf lb01:
   grep "POST.*token\|POST.*login" /var/log/nginx/access.log | awk '{print $1}' | sort | uniq -c | sort -rn | head -20
   ```
3. IPs ggf. manuell in UFW blockieren:
   ```bash
   sudo ufw deny from <ANGREIFER_IP>
   ```
4. Keycloak Realm-Settings pruefen: Max Login Failures, Wait Increment, Lock Duration

---

### TokenEndpointLangsam

| | |
|---|---|
| **Bedingung** | Token-Endpoint p95-Latenz > 500ms fuer > 5min |
| **Bedeutung** | Token-Ausstellung ist ungewoehnlich langsam |
| **Auswirkung** | Langsame Logins, Timeouts bei API-Clients |

**Massnahmen:**

1. CPU/Memory des KC-Nodes pruefen (Grafana Dashboard "Keycloak JVM")
2. GC-Pausen pruefen: `jvm_gc_pause_seconds_max` – wenn > 500ms, Heap zu klein
3. DB-Performance pruefen: `pg_stat_activity_count` hoch? Deadlocks?
4. Heap erhoehen in `.env`: `JAVA_OPTS="-Xms1024m -Xmx4096m"`
5. Nach Aenderung: `sudo scripts/02-setup-keycloak.sh` auf betroffendem Node

---

### DBConnectionPoolErschoepft

| | |
|---|---|
| **Bedingung** | `hikaricp_connections_pending > 0` fuer > 1min |
| **Bedeutung** | Alle DB-Connections im Pool belegt, Requests warten |
| **Auswirkung** | Steigende Latenz, Timeouts bei DB-Operationen |

**Massnahmen:**

1. Aktive Connections pruefen (Grafana Dashboard "Keycloak JVM" → HikariCP):
   - `hikaricp_connections_active` vs. `hikaricp_connections` (Pool-Maximum)
2. Auf db01: Langlaeufer identifizieren:
   ```bash
   sudo -u postgres psql -c "SELECT pid, now()-query_start AS duration, query FROM pg_stat_activity WHERE state='active' ORDER BY duration DESC LIMIT 10;"
   ```
3. Pool-Groesse erhoehen in `keycloak.conf.tpl` (Standard: 32)
4. Langfristig: DB-Performance optimieren (Indizes, Vacuum)

---

### DBConnectionsNahAmLimit

| | |
|---|---|
| **Bedingung** | `pg_stat_activity_count / pg_settings_max_connections > 0.8` fuer > 5min |
| **Bedeutung** | Mehr als 80% der PostgreSQL max_connections belegt |
| **Auswirkung** | Neue Verbindungen koennten bald abgelehnt werden |

**Massnahmen:**

1. Auf db01 pruefen wer die Connections belegt:
   ```bash
   sudo -u postgres psql -c "SELECT usename, client_addr, state, count(*) FROM pg_stat_activity GROUP BY usename, client_addr, state ORDER BY count DESC;"
   ```
2. Idle Connections identifizieren und ggf. terminieren:
   ```bash
   sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state='idle' AND query_start < now() - interval '30 min';"
   ```
3. `max_connections` in `postgresql.conf` erhoehen (Standard: 100)
4. `sudo systemctl reload postgresql@16-main`

---

### DBDeadlocks

| | |
|---|---|
| **Bedingung** | `rate(pg_stat_database_deadlocks[5m]) > 0` fuer > 2min |
| **Bedeutung** | Deadlocks in der PostgreSQL-Datenbank |
| **Auswirkung** | Einzelne Transaktionen schlagen fehl, Retries erhoehen Last |

**Massnahmen:**

1. Deadlock-Details in PostgreSQL-Logs pruefen:
   ```bash
   sudo grep -i deadlock /var/log/postgresql/postgresql-16-main.log | tail -20
   ```
2. In der Regel selbstheilend – PostgreSQL bricht eine der beteiligten Transaktionen ab
3. Bei wiederholtem Auftreten: Keycloak-Realm-Konfiguration pruefen (parallele Session-Updates?)
4. Langfristig: Lock-Monitoring und ggf. Keycloak-Upgrade pruefen

---

### HoheGCPausen

| | |
|---|---|
| **Bedingung** | `jvm_gc_pause_seconds_max > 0.5` fuer > 2min |
| **Bedeutung** | JVM Garbage Collection dauert laenger als 500ms |
| **Auswirkung** | Keycloak "friert" waehrend GC ein – Requests werden verzoegert |

**Massnahmen:**

1. Heap-Auslastung pruefen (Grafana "Keycloak JVM" → Heap Used vs. Max)
2. Wenn Heap nahe am Maximum: Heap erhoehen in `.env`:
   ```bash
   JAVA_OPTS="-Xms1024m -Xmx4096m"
   ```
3. GC-Algorithmus pruefen (Keycloak 26 nutzt standardmaessig G1GC)
4. Nach Aenderung: `sudo scripts/02-setup-keycloak.sh` auf betroffendem Node
5. Langfristig: Memory-Leak ausschliessen (stetig steigender Heap ohne Rueckgang)

---

### HighCPU

| | |
|---|---|
| **Bedingung** | CPU > 80% fuer > 5min |
| **Bedeutung** | Dauerhaft hohe CPU-Last auf einer VM |

**Massnahmen:**

1. Top-Prozesse identifizieren:
   ```bash
   top -bn1 | head -15
   ```
2. Wenn Keycloak: Last reduzieren (Rate-Limiting, Client-Pruefung)
3. Wenn PostgreSQL: Langlaufende Queries identifizieren und optimieren
4. VM-Sizing pruefen – ggf. vCPUs erhoehen

---

### HighMemory

| | |
|---|---|
| **Bedingung** | RAM > 90% fuer > 5min |
| **Bedeutung** | Arbeitsspeicher fast erschoepft |

**Massnahmen:**

1. Memory-Verbraucher identifizieren:
   ```bash
   ps aux --sort=-%mem | head -10
   ```
2. Wenn Keycloak (JVM): Heap-Einstellungen pruefen, ggf. reduzieren wenn ueberdimensioniert
3. Wenn System-Caches: In der Regel harmlos (`free -h` zeigt "available")
4. Langfristig: VM-RAM erhoehen

---

### DiskFull (> 85%)

| | |
|---|---|
| **Bedingung** | Disk-Nutzung > 85% |
| **Bedeutung** | Plattenplatz wird knapp |

**Massnahmen:**

1. Groesste Verzeichnisse identifizieren:
   ```bash
   du -sh /* 2>/dev/null | sort -rh | head -10
   ```
2. Haeufige Ursachen:
   - `/var/log`: Logs rotieren mit `logrotate`
   - `/var/lib/postgresql`: DB Vacuum ausfuehren
   - `/var/lib/prometheus`: Retention-Period pruefen
   - `/opt/keycloak*`: Alte Versionen aufraumen
3. Alte Backups loeschen: `find / -name '*.bak.*' -mtime +30 -delete`

---

### DiskKritisch (> 95%)

| | |
|---|---|
| **Bedingung** | Disk-Nutzung > 95% |
| **Bedeutung** | **Kritisch** – Services koennen bald ausfallen |

**Massnahmen:**

1. Sofort Platz schaffen (wie DiskFull, aber dringend)
2. Wenn `/var/lib/postgresql` voll: PostgreSQL stoppt neue Schreiboperationen
3. Wenn `/var/log` voll: `sudo journalctl --vacuum-time=2d`
4. Notfall: Grosse Dateien identifizieren und temporaer verschieben

---

### SystemdUnitFailed

| | |
|---|---|
| **Bedingung** | Ein systemd-Service ist in den Zustand "failed" gewechselt |
| **Bedeutung** | Ein Service ist abgestuerzt und nicht automatisch neugestartet |

**Massnahmen:**

1. Betroffenen Service identifizieren:
   ```bash
   systemctl --failed
   ```
2. Logs pruefen:
   ```bash
   journalctl -u <service-name> --since "30 min ago" --no-pager
   ```
3. Service neustarten: `sudo systemctl restart <service-name>`
4. Wenn wiederholtes Scheitern: Ursache beheben, dann `sudo systemctl reset-failed`

---

### Fail2banExcessiveBans

| | |
|---|---|
| **Bedingung** | Mehr als 20 IPs gleichzeitig gebannt |
| **Bedeutung** | Ungewoehnlich viele SSH-Brute-Force-Versuche |
| **Auswirkung** | Kein direkter Service-Impact, aber Hinweis auf Angriff |

**Massnahmen:**

1. Gebannte IPs pruefen:
   ```bash
   sudo fail2ban-client status sshd
   ```
2. Wenn Angriff aus einem IP-Range: Ganzen Range in UFW blockieren:
   ```bash
   sudo ufw deny from <IP-RANGE>/24
   ```
3. SSH-Port aendern (in `.env` als `SSH_PORT`), dann `sudo scripts/04-harden.sh <rolle>`
4. Nur Key-Auth sicherstellen (ist Standard nach Hardening)

---

## Informational / Auto-Recovery

### DiskFull vs. DiskKritisch

DiskFull (85%) ist eine Fruehwarnung. DiskKritisch (95%) erfordert sofortiges Handeln.
Bei DiskKritisch wird der warning-Alert (DiskFull) automatisch unterdrueckt (Inhibit-Rule).

### Alert-Eskalation via Zabbix

Alerts mit Label `zabbix: "true"` werden – bei konfiguriertem Webhook – automatisch
an das RZ-Zabbix weitergeleitet. Dies betrifft:

- KCNodeDown, AlleKCNodesDown, KCClusterMembershipBroken
- PostgreSQLDown, NginxDown
- BruteForceVerdacht, Fail2banExcessiveBans
- TLSCertExpiryCritical, TLSProbeFailure
- DiskFull, DiskKritisch
- DBConnectionPoolErschoepft, DBConnectionsNahAmLimit

### Alertmanager-UI

Alle aktiven Alerts sind einsehbar unter:
- **Alertmanager:** `http://mon01:9093/#/alerts`
- **Grafana:** Alerting → Alert Rules
- **Prometheus:** `http://mon01:9090/alerts`

### Silence (Alert temporaer stumm schalten)

Bei geplanten Wartungsarbeiten koennen Alerts stumm geschaltet werden:

```bash
# Via Alertmanager-API (Beispiel: 2 Stunden Silence fuer kc01):
curl -X POST http://mon01:9093/api/v2/silences -H 'Content-Type: application/json' -d '{
  "matchers": [{"name": "instance", "value": "<KC_NODE1_IP>:9000", "isRegex": false}],
  "startsAt": "'$(date -u +%Y-%m-%dT%H:%M:%S)'Z",
  "endsAt": "'$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%S)'Z",
  "createdBy": "admin",
  "comment": "Geplante Wartung kc01"
}'
```

Oder ueber das Alertmanager-UI: `http://mon01:9093/#/silences` → New Silence.
