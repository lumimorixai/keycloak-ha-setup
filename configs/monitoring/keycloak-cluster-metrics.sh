#!/usr/bin/env bash
# ==============================================================================
# keycloak-cluster-metrics.sh – Cluster-Membership fuer Prometheus Textfile-Collector
#
# Installiert via 05-setup-monitoring.sh keycloak → /usr/local/bin/keycloak-cluster-metrics.sh
# Ausfuehrung via Cron (jede Minute).
#
# Liest die Anzahl registrierter Cluster-Nodes aus der JDBC_PING2-Tabelle
# (jgroups_ping) in PostgreSQL. Diese Methode ist unabhaengig von Aenderungen
# am Keycloak Health-Endpoint-Format.
#
# Schreibt das Ergebnis als Gauge in eine .prom-Datei, die vom
# node_exporter Textfile-Collector gelesen wird.
#
# Benoetigt: postgresql-client (psql), Env-Datei /etc/default/keycloak-cluster-metrics
# ==============================================================================

set -euo pipefail

TEXTFILE_DIR="/var/lib/prometheus/node-exporter"
PROM_FILE="${TEXTFILE_DIR}/keycloak_cluster.prom"
TMP_FILE="${PROM_FILE}.$$"
ENV_FILE="/etc/default/keycloak-cluster-metrics"

mkdir -p "${TEXTFILE_DIR}"

node_count=0

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"

    if command -v psql &>/dev/null; then
        extracted="$(PGPASSWORD="${KC_CLUSTER_DB_PASS}" psql \
            -h "${KC_CLUSTER_DB_HOST}" \
            -p 5432 \
            -U "${KC_CLUSTER_DB_USER}" \
            -d "${KC_CLUSTER_DB_NAME}" \
            -tAc "SELECT COUNT(DISTINCT address) FROM jgroups_ping;" 2>/dev/null || echo 0)"
        if [[ "${extracted}" =~ ^[0-9]+$ ]]; then
            node_count="${extracted}"
        fi
    fi
fi

cat > "${TMP_FILE}" <<EOF
# HELP keycloak_cluster_nodes Number of nodes in the Keycloak cluster (from JDBC_PING2 table)
# TYPE keycloak_cluster_nodes gauge
keycloak_cluster_nodes ${node_count}
EOF

mv "${TMP_FILE}" "${PROM_FILE}"
