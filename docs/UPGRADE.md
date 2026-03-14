# Keycloak HA Setup – Upgrade-Verfahren

## Keycloak-Version upgraden

### Vorbereitung

1. **Release Notes lesen:** Breaking Changes, DB-Migration-Hinweise
2. **DB-Backup erstellen** (auf db01):
   ```bash
   sudo -u postgres pg_dump keycloak | gzip > /backup/keycloak-pre-upgrade-$(date +%Y%m%d).sql.gz
   ```
3. **Neue Version in `.env` eintragen:**
   ```bash
   KC_VERSION=26.x.y  # neue Version
   ```

### Upgrade-Ablauf (Rolling Upgrade)

```bash
# 1. kc02 stoppen (kc01 übernimmt den Traffic)
ssh kc02 "sudo systemctl stop keycloak"

# 2. Upgrade auf kc01 ausführen (DB-Migration findet hier statt)
ssh kc01 "sudo scripts/02-setup-keycloak.sh"

# 3. kc01 warten bis ready
until curl -sf http://<KC_NODE1_IP>:9000/health/ready; do
    echo "Warte auf kc01..."; sleep 10
done
echo "kc01 ist ready"

# 4. Upgrade auf kc02 ausführen
ssh kc02 "sudo scripts/02-setup-keycloak.sh"
```

**Wichtig:** DB-Schema-Migrationen werden automatisch beim ersten Start ausgeführt. Erst nach erfolgreichem kc01-Start kc02 starten – verhindert Race-Conditions.

### Rollback nach fehlgeschlagenem Upgrade

Siehe `docs/ROLLBACK.md` – Abschnitt "Keycloak-Version Rollback".

## PostgreSQL-Version upgraden

PostgreSQL-Major-Version-Upgrades (z.B. 16 → 17) erfordern `pg_upgrade`:

```bash
# Auf db01:
# 1. Keycloak auf kc01 und kc02 stoppen
ssh kc01 "sudo systemctl stop keycloak"
ssh kc02 "sudo systemctl stop keycloak"

# 2. Neue PostgreSQL-Version installieren
apt-get install postgresql-17 postgresql-client-17

# 3. pg_upgrade ausführen (Cluster-Migration)
systemctl stop postgresql@16-main postgresql@17-main
sudo -u postgres /usr/lib/postgresql/17/bin/pg_upgrade \
    -b /usr/lib/postgresql/16/bin \
    -B /usr/lib/postgresql/17/bin \
    -d /var/lib/postgresql/16/main \
    -D /var/lib/postgresql/17/main

# 4. Neue Version starten, alte stoppen
systemctl start postgresql@17-main

# 5. PG_VERSION im Setup-Skript auf 17 anpassen und erneut ausführen.
#    Hinweis: PG_VERSION ist in 01-setup-db.sh als readonly-Konstante
#    definiert und kann nicht per Env-Variable überschrieben werden.
#    Vor dem Ausführen die Zeile im Skript ändern:
#      readonly PG_VERSION=16  →  readonly PG_VERSION=17
sudo scripts/01-setup-db.sh

# 6. Keycloak-Nodes wieder starten (kc01 zuerst)
ssh kc01 "sudo systemctl start keycloak"
until curl -sf http://<KC_NODE1_IP>:9000/health/ready; do sleep 5; done
ssh kc02 "sudo systemctl start keycloak"
```

## Nginx / Certbot upgraden

Nginx und Certbot werden über das Standard-apt-Upgrade aktualisiert:

```bash
apt-get update && apt-get upgrade nginx certbot python3-certbot-nginx
systemctl reload nginx
```

Nach dem Upgrade Konfiguration validieren: `nginx -t`

## Java upgraden (Temurin)

```bash
# Neue Version in .env eintragen
JAVA_VERSION=21  # oder neue LTS-Version

# Skript auf kc01 und kc02 erneut ausführen
# Das Skript erkennt die neue Version und führt automatisch kc.sh build aus
sudo scripts/02-setup-keycloak.sh
```

## TLS-Zertifikat manuell erneuern

Normalerweise erfolgt die Erneuerung automatisch via systemd-Timer. Manuell:

```bash
# Dry-Run (Test ohne echte Anfrage)
certbot renew --dry-run

# Echtlauf
certbot renew

# Nginx neu laden nach Erneuerung
systemctl reload nginx
```

Certbot konfiguriert den Nginx-Reload-Hook automatisch.

## Monitoring-Komponenten upgraden

### Prometheus / Alertmanager / Grafana (Debian-Pakete)

```bash
# Auf mon01:
apt-get update && apt-get upgrade prometheus prometheus-alertmanager grafana

# Configs prüfen und Services neu laden
promtool check config /etc/prometheus/prometheus.yml
systemctl reload prometheus
systemctl restart grafana-server
```

### postgres_exporter upgraden (db01)

Die Version ist in `05-setup-monitoring.sh` als `PG_EXPORTER_VERSION` definiert.

```bash
# Version in scripts/05-setup-monitoring.sh anpassen, dann:
sudo scripts/05-setup-monitoring.sh db
```

Das Skript erkennt die Versionsänderung, lädt die neue Binary herunter und
startet den Service neu.

### nginx-prometheus-exporter upgraden (lb01)

Analog zu postgres_exporter: `NGINX_EXPORTER_VERSION` in
`05-setup-monitoring.sh` anpassen und erneut ausführen.

```bash
sudo scripts/05-setup-monitoring.sh lb
```

### node_exporter upgraden (alle VMs)

node_exporter wird als Debian-Paket (`prometheus-node-exporter`) installiert:

```bash
apt-get update && apt-get upgrade prometheus-node-exporter
```

---

## OS-Updates (Debian)

```bash
apt-get update && apt-get upgrade
# Reboot-Bedarf prüfen
test -f /var/run/reboot-required && echo "REBOOT ERFORDERLICH"
```

Bei Kernel-Updates: VM neu starten, dabei kc01 und kc02 einzeln (nicht gleichzeitig) neu starten, um Downtime zu minimieren.
