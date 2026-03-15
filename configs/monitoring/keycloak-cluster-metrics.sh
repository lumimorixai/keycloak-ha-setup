#!/usr/bin/env bash
# ==============================================================================
# keycloak-cluster-metrics.sh – Cluster-Membership fuer Prometheus Textfile-Collector
#
# Installiert via 05-setup-monitoring.sh keycloak → /usr/local/bin/keycloak-cluster-metrics.sh
# Ausfuehrung via Cron (jede Minute).
#
# Fragt /health auf localhost:9000 ab und extrahiert numberOfNodes.
# Schreibt das Ergebnis als Gauge in eine .prom-Datei, die vom
# node_exporter Textfile-Collector gelesen wird.
# ==============================================================================

set -euo pipefail

TEXTFILE_DIR="/var/lib/prometheus/node-exporter"
PROM_FILE="${TEXTFILE_DIR}/keycloak_cluster.prom"
TMP_FILE="${PROM_FILE}.$$"
KC_HEALTH_URL="http://localhost:9000/health"

mkdir -p "${TEXTFILE_DIR}"

node_count=0
if response="$(curl -sf --max-time 5 "${KC_HEALTH_URL}" 2>/dev/null)"; then
    if command -v jq &>/dev/null; then
        extracted="$(printf '%s' "${response}" \
            | jq -r '[.checks[].data.numberOfNodes // empty] | first // 0' 2>/dev/null || echo 0)"
    else
        extracted="$(printf '%s' "${response}" \
            | grep -oP '"numberOfNodes"\s*:\s*\K[0-9]+' | head -1 || echo 0)"
    fi
    if [[ "${extracted}" =~ ^[0-9]+$ ]]; then
        node_count="${extracted}"
    fi
fi

cat > "${TMP_FILE}" <<EOF
# HELP keycloak_cluster_nodes Number of nodes in the Keycloak cluster as seen by this node
# TYPE keycloak_cluster_nodes gauge
keycloak_cluster_nodes ${node_count}
EOF

mv "${TMP_FILE}" "${PROM_FILE}"
