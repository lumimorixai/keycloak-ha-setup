#!/usr/bin/env bash
# ==============================================================================
# keycloak-user-metrics.sh – User-Bestand fuer Prometheus Textfile-Collector
#
# Installiert via 05-setup-monitoring.sh keycloak → /usr/local/bin/keycloak-user-metrics.sh
# Ausfuehrung via Cron (alle 5 Minuten).
#
# Keycloak exportiert KEINE Metrik fuer die Anzahl vorhandener User –
# keycloak_user_events_total{event="register"} zaehlt nur Neuzugaenge, nie den
# Bestand und nie Loeschungen. Dieses Skript liest den Bestand direkt aus der
# Keycloak-Datenbank (Tabelle user_entity) und stellt ihn als Gauge bereit.
#
# Service-Accounts (Clients mit Service-Account) werden ausgeschlossen –
# gezaehlt werden nur echte User.
#
# Benoetigt: postgresql-client (psql), Env-Datei /etc/default/keycloak-user-metrics
# ==============================================================================

set -euo pipefail

TEXTFILE_DIR="/var/lib/prometheus/node-exporter"
PROM_FILE="${TEXTFILE_DIR}/keycloak_users.prom"
TMP_FILE="${PROM_FILE}.$$"
ENV_FILE="/etc/default/keycloak-user-metrics"

QUERY="SELECT r.name, COUNT(u.id)
       FROM realm r
       LEFT JOIN user_entity u
         ON u.realm_id = r.id
        AND u.service_account_client_link IS NULL
       GROUP BY r.name
       ORDER BY r.name;"

mkdir -p "${TEXTFILE_DIR}"

{
    printf '# HELP keycloak_users_total Number of users per realm (from user_entity, service accounts excluded)\n'
    printf '# TYPE keycloak_users_total gauge\n'
} > "${TMP_FILE}"

rows=""

if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"

    if command -v psql &>/dev/null; then
        rows="$(PGPASSWORD="${KC_USER_DB_PASS}" psql \
            -h "${KC_USER_DB_HOST}" \
            -p 5432 \
            -U "${KC_USER_DB_USER}" \
            -d "${KC_USER_DB_NAME}" \
            -tAF '|' -c "${QUERY}" 2>/dev/null || echo "")"
    fi
fi

while IFS='|' read -r realm count; do
    [[ -n "${realm}" ]] || continue
    [[ "${count}" =~ ^[0-9]+$ ]] || continue
    # Label-Wert escapen: Backslash und doppelte Anfuehrungszeichen
    realm_escaped="${realm//\\/\\\\}"
    realm_escaped="${realm_escaped//\"/\\\"}"
    printf 'keycloak_users_total{realm="%s"} %s\n' "${realm_escaped}" "${count}" >> "${TMP_FILE}"
done <<< "${rows}"

mv "${TMP_FILE}" "${PROM_FILE}"
