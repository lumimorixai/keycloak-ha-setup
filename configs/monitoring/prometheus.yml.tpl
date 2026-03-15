# ==============================================================================
# Prometheus – Scrape-Konfiguration (Template)
#
# Deployed via 06-setup-mon-vm.sh → /etc/prometheus/prometheus.yml
#
# Variablen (aus .env):
#   KC_DOMAIN, KC_NODE1_IP, KC_NODE2_IP, KC_MGMT_PORT, DB_HOST, LB_HOST
# ==============================================================================

global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/alert-rules.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - localhost:9093

scrape_configs:
  # --- Prometheus Self-Monitoring ---
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090

  # --- Keycloak Metrics (Micrometer auf Management-Port) ---
  - job_name: keycloak
    metrics_path: /metrics
    scrape_interval: 30s
    static_configs:
      - targets:
          - ${KC_NODE1_IP}:${KC_MGMT_PORT}
          - ${KC_NODE2_IP}:${KC_MGMT_PORT}

  # --- node_exporter (alle VMs) ---
  - job_name: node
    static_configs:
      - targets:
          - ${KC_NODE1_IP}:9100
          - ${KC_NODE2_IP}:9100
          - ${DB_HOST}:9100
          - ${LB_HOST}:9100
          - localhost:9100

  # --- postgres_exporter (DB-VM) ---
  - job_name: postgres
    static_configs:
      - targets:
          - ${DB_HOST}:9187

  # --- nginx-prometheus-exporter (LB-VM) ---
  - job_name: nginx
    static_configs:
      - targets:
          - ${LB_HOST}:9113

  # --- Blackbox TLS-Probe (Zertifikats-Ablauf) ---
  - job_name: blackbox-tls
    metrics_path: /probe
    params:
      module: [tls_probe]
    static_configs:
      - targets:
          - https://${KC_DOMAIN}
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: localhost:9115
