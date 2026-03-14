# ==============================================================================
# Alertmanager – Routing-Konfiguration (Template)
#
# Deployed via 06-setup-mon-vm.sh → /etc/prometheus/alertmanager.yml
#
# Variablen (aus .env):
#   ACME_EMAIL – wird als Empfänger für E-Mail-Alerts verwendet
#
# Hinweis: E-Mail-Versand erfordert einen erreichbaren SMTP-Server.
# Ohne SMTP-Konfiguration werden Alerts nur im Alertmanager-UI angezeigt.
# Zabbix-Anbindung via Webhook: siehe docs/MONITORING.md
# ==============================================================================

global:
  resolve_timeout: 5m

route:
  receiver: default
  group_by:
    - alertname
    - instance
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: default
    # E-Mail-Empfänger (SMTP muss separat konfiguriert werden):
    # email_configs:
    #   - to: '${ACME_EMAIL}'
    #     send_resolved: true

inhibit_rules:
  # Unterdrücke warning-Alerts wenn critical für dieselbe Instanz feuert
  - source_matchers:
      - severity = critical
    target_matchers:
      - severity = warning
    equal:
      - alertname
      - instance
