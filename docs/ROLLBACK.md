# Keycloak HA Setup – Rollback-Verfahren

Alle Setup-Skripte legen vor jeder Änderung ein Backup an
(`*.bak.YYYYMMDD-HHMMSS` via `backup_file()` aus `00-common.sh`).
Dieser Mechanismus gilt für jede Konfigurationsdatei, die `deploy_config()`
durchläuft.

**Backup-Dateien finden:**
```bash
find /etc /opt/keycloak -name '*.bak.*' 2>/dev/null | sort
```

---

## Keycloak

### Konfiguration zurücksetzen (keycloak.conf)

```bash
# Auf kc01 oder kc02:
ls /opt/keycloak/conf/keycloak.conf.bak.*

# Backup einspielen
systemctl stop keycloak
cp /opt/keycloak/conf/keycloak.conf.bak.YYYYMMDD-HHMMSS \
   /opt/keycloak/conf/keycloak.conf

# Build mit alter Konfiguration (Pflicht nach jeder conf-Änderung)
sudo -u keycloak /opt/keycloak/bin/kc.sh build

systemctl start keycloak
curl -sf "http://localhost:9000/health/ready"
```

### Version zurücksetzen

> **Voraussetzung:** Die alte Version muss noch unter `/opt/keycloak-<version>`
> vorhanden sein. Das Skript entfernt alte Versionen nicht automatisch.
>
> **Einschränkung:** Nach einer DB-Migration ist ein Downgrade auf die
> Vorversion **nicht möglich** ohne DB-Restore. Immer zuerst DB-Backup erstellen.

```bash
# Auf kc01 und kc02 (kc02 zuerst stoppen, kc01 zuletzt):
systemctl stop keycloak

# Symlink auf Vorversion zurücksetzen
ln -sfn /opt/keycloak-26.5.4 /opt/keycloak   # Beispiel

# Build mit alter Version
sudo -u keycloak /opt/keycloak/bin/kc.sh build

# kc01 zuerst starten
systemctl start keycloak
until curl -sf "http://localhost:9000/health/ready"; do sleep 5; done

# Dann kc02 starten (auf kc02 ausführen)
systemctl start keycloak
```

### EnvironmentFile zurücksetzen (/etc/keycloak/env)

```bash
ls /etc/keycloak/env.bak.*
cp /etc/keycloak/env.bak.YYYYMMDD-HHMMSS /etc/keycloak/env
systemctl restart keycloak
```

---

## PostgreSQL

### pg_hba.conf zurücksetzen

Reload ohne Verbindungsunterbrechung:

```bash
# Auf db01:
ls /etc/postgresql/16/main/pg_hba.conf.bak.*

cp /etc/postgresql/16/main/pg_hba.conf.bak.YYYYMMDD-HHMMSS \
   /etc/postgresql/16/main/pg_hba.conf

systemctl reload postgresql@16-main
```

### Datenbankinhalt wiederherstellen (pg_dump-Backup)

> Erforderlich nach fehlgeschlagener Keycloak-DB-Migration oder Datenverlust.
> **Alle Keycloak-Nodes müssen gestoppt sein.**

```bash
# Auf kc01 und kc02:
systemctl stop keycloak

# Auf db01:
sudo -u postgres psql -c "DROP DATABASE keycloak;"
sudo -u postgres psql -c \
  "CREATE DATABASE keycloak OWNER keycloak ENCODING 'UTF8' TEMPLATE template0;"

zcat /backup/keycloak-YYYYMMDD-HHMMSS.sql.gz \
    | sudo -u postgres psql keycloak

# kc01 zuerst starten, dann kc02
# (auf kc01):
systemctl start keycloak
until curl -sf "http://localhost:9000/health/ready"; do sleep 5; done
# (auf kc02):
systemctl start keycloak
```

---

## Nginx

### vHost-Konfiguration zurücksetzen

```bash
# Auf lb01:
ls /etc/nginx/conf.d/keycloak.conf.bak.*

cp /etc/nginx/conf.d/keycloak.conf.bak.YYYYMMDD-HHMMSS \
   /etc/nginx/conf.d/keycloak.conf

nginx -t && systemctl reload nginx
```

---

## TLS-Zertifikat (Certbot)

Certbot versioniert Zertifikate unter `/etc/letsencrypt/archive/<domain>/`.
Die Symlinks in `/etc/letsencrypt/live/<domain>/` zeigen auf die aktuelle
Version. Bei Problemen nach einer Erneuerung lassen sich die Symlinks auf
die Vorversion zurücksetzen.

```bash
# Auf lb01:
domain="auth.example.com"   # KC_DOMAIN aus .env

# Verfügbare Versionen anzeigen
ls -la /etc/letsencrypt/archive/"${domain}"/

# Aktuelle Symlinks prüfen (zeigen z.B. auf cert3.pem)
ls -la /etc/letsencrypt/live/"${domain}"/

# Symlinks auf Vorversion zurücksetzen (Beispiel: zurück auf Version 2)
cd /etc/letsencrypt/live/"${domain}"
ln -sfn ../../archive/"${domain}"/cert2.pem     cert.pem
ln -sfn ../../archive/"${domain}"/chain2.pem    chain.pem
ln -sfn ../../archive/"${domain}"/fullchain2.pem fullchain.pem
ln -sfn ../../archive/"${domain}"/privkey2.pem  privkey.pem

nginx -t && systemctl reload nginx

# Zertifikat prüfen
echo Q | openssl s_client -connect "${domain}:443" -servername "${domain}" \
    2>/dev/null | openssl x509 -noout -dates
```

---

## UFW / Fail2ban

### Fail2ban-Konfiguration zurücksetzen

```bash
# Backup einspielen
ls /etc/fail2ban/jail.local.bak.*
cp /etc/fail2ban/jail.local.bak.YYYYMMDD-HHMMSS /etc/fail2ban/jail.local
systemctl restart fail2ban
```

### UFW-Regeln zurücksetzen und neu anwenden

```bash
# Notfall: UFW komplett deaktivieren (SSH bleibt offen, alle Ports erreichbar)
ufw disable

# Alle Regeln löschen und neu aufbauen
ufw reset
# vm-typ: db | keycloak | lb | mon
sudo scripts/04-harden.sh <vm-typ>
```

---

## SSH-Hardening

### SSH-Konfiguration zurücksetzen

Die Drop-in-Datei in `sshd_config.d/` kann einfach entfernt werden, um den
Ausgangszustand wiederherzustellen.

```bash
# Backup einspielen (empfohlen)
ls /etc/ssh/sshd_config.d/99-keycloak-hardening.conf.bak.*
cp /etc/ssh/sshd_config.d/99-keycloak-hardening.conf.bak.YYYYMMDD-HHMMSS \
   /etc/ssh/sshd_config.d/99-keycloak-hardening.conf

# Oder: Drop-in komplett entfernen (stellt Debian-Defaults wieder her)
rm /etc/ssh/sshd_config.d/99-keycloak-hardening.conf

# Konfiguration validieren und SSH neu laden
sshd -t && systemctl reload ssh
```

> **Wichtig:** Vor dem Reload sicherstellen, dass eine aktive SSH-Session
> offen ist, um eine versehentliche Aussperrung abfangen zu können.

---

## Vollständiges Rollback (Neuinstallation)

Falls mehrere Komponenten betroffen sind und ein sauberer Neustart einfacher
ist als selektive Rollbacks.

```bash
# === kc01 und kc02 ===
systemctl stop keycloak
systemctl disable keycloak
rm -f /etc/systemd/system/keycloak.service
systemctl daemon-reload
rm -rf /opt/keycloak* /etc/keycloak
# Dann: sudo scripts/02-setup-keycloak.sh

# === db01 (ACHTUNG: Datenverlust) ===
# Erst DB-Backup sicherstellen!
systemctl stop postgresql@16-main
apt-get purge --autoremove postgresql-16 postgresql-client-16
rm -rf /var/lib/postgresql/16
# Dann: sudo scripts/01-setup-db.sh

# === lb01 ===
systemctl stop nginx
apt-get purge --autoremove nginx
rm -f /etc/nginx/conf.d/keycloak.conf
# TLS-Zertifikate bleiben erhalten (Certbot-Limit beachten)
# Dann: sudo scripts/03-setup-nginx.sh
```

---

## Monitoring

### Prometheus-Konfiguration zurücksetzen

```bash
# Auf mon01:
ls /etc/prometheus/prometheus.yml.bak.*

cp /etc/prometheus/prometheus.yml.bak.YYYYMMDD-HHMMSS \
   /etc/prometheus/prometheus.yml

systemctl reload prometheus
```

### Alert-Rules zurücksetzen

```bash
# Auf mon01:
ls /etc/prometheus/alert-rules.yml.bak.*

cp /etc/prometheus/alert-rules.yml.bak.YYYYMMDD-HHMMSS \
   /etc/prometheus/alert-rules.yml

systemctl reload prometheus
```

### Alertmanager-Konfiguration zurücksetzen

```bash
# Auf mon01:
ls /etc/prometheus/alertmanager.yml.bak.*

cp /etc/prometheus/alertmanager.yml.bak.YYYYMMDD-HHMMSS \
   /etc/prometheus/alertmanager.yml

systemctl reload prometheus-alertmanager
```

### Exporter deinstallieren

```bash
# node_exporter (alle VMs):
systemctl stop prometheus-node-exporter
apt-get purge prometheus-node-exporter

# postgres_exporter (db01):
systemctl stop postgres-exporter
rm -f /usr/local/bin/postgres_exporter
rm -f /etc/systemd/system/postgres-exporter.service
rm -f /etc/default/postgres_exporter
systemctl daemon-reload

# nginx-prometheus-exporter (lb01):
systemctl stop nginx-exporter
rm -f /usr/local/bin/nginx-prometheus-exporter
rm -f /etc/systemd/system/nginx-exporter.service
systemctl daemon-reload
```

### Blackbox-Exporter deinstallieren (mon01)

```bash
systemctl stop prometheus-blackbox-exporter
apt-get purge prometheus-blackbox-exporter
rm -f /etc/prometheus/blackbox.yml
```

### Fail2ban-Metriken entfernen (alle VMs)

```bash
rm -f /etc/cron.d/fail2ban-metrics
rm -f /usr/local/bin/fail2ban-metrics.sh
rm -f /var/lib/prometheus/node-exporter/fail2ban.prom
```

### Keycloak Cluster-Metriken entfernen (kc01/kc02)

```bash
rm -f /etc/cron.d/keycloak-cluster-metrics
rm -f /usr/local/bin/keycloak-cluster-metrics.sh
rm -f /var/lib/prometheus/node-exporter/keycloak_cluster.prom
```

### Grafana-Dashboards entfernen (mon01)

```bash
rm -rf /var/lib/grafana/dashboards/
rm -f /etc/grafana/provisioning/dashboards/dashboards.yml
systemctl restart grafana-server
```

### Monitoring-Stack komplett entfernen (mon01)

```bash
systemctl stop prometheus grafana-server prometheus-alertmanager prometheus-blackbox-exporter
apt-get purge prometheus prometheus-alertmanager grafana prometheus-blackbox-exporter
rm -f /etc/prometheus/prometheus.yml /etc/prometheus/alert-rules.yml
rm -f /etc/prometheus/alertmanager.yml /etc/prometheus/blackbox.yml
rm -f /etc/grafana/provisioning/datasources/prometheus.yml
rm -f /etc/grafana/provisioning/dashboards/dashboards.yml
rm -rf /var/lib/grafana/dashboards/
```

---

## Cluster-Split-Brain Recovery

Falls kc01 und kc02 nach einem Netzwerkausfall isoliert liefen und inkonsistente
Cache-Zustände haben (erkennbar: `99-healthcheck.sh` meldet `1/2 Nodes im Cluster`):

```bash
# Beide Nodes stoppen
ssh kc01 "sudo systemctl stop keycloak"
ssh kc02 "sudo systemctl stop keycloak"

# kc01 zuerst starten (übernimmt DB als autoritativen Zustand)
ssh kc01 "sudo systemctl start keycloak"
until curl -sf "http://${KC_NODE1_IP}:9000/health/ready"; do sleep 5; done

# Dann kc02 starten (verbindet sich mit kc01 über JGroups TCP :7800)
ssh kc02 "sudo systemctl start keycloak"

# Cluster-Status prüfen (numberOfNodes muss 2 sein)
scripts/99-healthcheck.sh
```
