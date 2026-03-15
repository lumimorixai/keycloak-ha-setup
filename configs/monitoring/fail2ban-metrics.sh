#!/usr/bin/env bash
# ==============================================================================
# fail2ban-metrics.sh – Fail2ban-Metriken fuer Prometheus Textfile-Collector
#
# Installiert via 05-setup-monitoring.sh → /usr/local/bin/fail2ban-metrics.sh
# Ausfuehrung via Cron (alle 2 Minuten).
#
# Schreibt aktuell gebannte IPs als Gauge in eine .prom-Datei, die vom
# node_exporter Textfile-Collector gelesen wird.
# ==============================================================================

set -euo pipefail

TEXTFILE_DIR="/var/lib/prometheus/node-exporter"
PROM_FILE="${TEXTFILE_DIR}/fail2ban.prom"
TMP_FILE="${PROM_FILE}.$$"

mkdir -p "${TEXTFILE_DIR}"

banned=0
if command -v fail2ban-client &>/dev/null; then
    banned="$(fail2ban-client status sshd 2>/dev/null \
        | grep -oP 'Currently banned:\s+\K[0-9]+' || echo 0)"
fi

cat > "${TMP_FILE}" <<EOF
# HELP fail2ban_banned_current Currently banned IPs in sshd jail
# TYPE fail2ban_banned_current gauge
fail2ban_banned_current{jail="sshd"} ${banned}
EOF

mv "${TMP_FILE}" "${PROM_FILE}"
