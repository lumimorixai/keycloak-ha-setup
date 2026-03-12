#!/usr/bin/env bash
# ==============================================================================
# 99-healthcheck.sh – Validierung des Keycloak HA-Setups
#
# Ausführung: von lb01 oder extern (nach vollständigem Deployment)
# Voraussetzung: .env im Repo-Root befüllt; curl und openssl vorhanden
#                jq optional (bessere Cluster-Auswertung)
#
# Was dieses Skript prüft:
#   1. Keycloak /health/ready auf kc01 und kc02 (direkt HTTP)
#   2. HTTPS-Endpunkt auf lb01 (https://${KC_DOMAIN}/health/ready)
#   3. HTTP→HTTPS-Redirect (301)
#   4. Cluster-Mitgliedschaft: beide Nodes melden numberOfNodes=2
#   5. pg_isready auf db01 (Fallback: TCP-Porttest)
#   6. TLS-Zertifikat: Handshake + Ablaufdatum (via openssl s_client)
#
# Exit-Code: 0 = alle Checks bestanden, 1 = mindestens ein FAIL
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/00-common.sh
source "${SCRIPT_DIR}/00-common.sh"

load_env

# ==============================================================================
# Farben (nur wenn stdout ein Terminal ist)
# ==============================================================================

if [[ -t 1 ]]; then
    C_GREEN='\033[0;32m'
    C_RED='\033[0;31m'
    C_YELLOW='\033[1;33m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_GREEN='' C_RED='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
fi

# ==============================================================================
# Ergebnis-Tracking
# ==============================================================================

check_errors=0
check_warns=0
# Jede Zeile: "STATUS\tLabel\tDetail"
check_log=''

readonly HTTP_TIMEOUT=10
readonly CERT_WARN_DAYS=30

# ==============================================================================
# Check-Funktionen (drucken sofort + akkumulieren für Zusammenfassung)
# ==============================================================================

_record() {
    local status="$1" label="$2" detail="$3"
    check_log="${check_log}${status}\t${label}\t${detail}\n"
}

check_ok() {
    local label="$1" detail="${2:-}"
    printf "${C_GREEN}[  OK  ]${C_RESET} ${C_BOLD}%-44s${C_RESET} ${C_DIM}%s${C_RESET}\n" \
        "${label}" "${detail}"
    _record "OK" "${label}" "${detail}"
}

check_fail() {
    local label="$1" detail="${2:-}"
    printf "${C_RED}[ FAIL ]${C_RESET} ${C_BOLD}%-44s${C_RESET} %s\n" \
        "${label}" "${detail}"
    _record "FAIL" "${label}" "${detail}"
    check_errors=$(( check_errors + 1 ))
}

check_warn() {
    local label="$1" detail="${2:-}"
    printf "${C_YELLOW}[ WARN ]${C_RESET} ${C_BOLD}%-44s${C_RESET} %s\n" \
        "${label}" "${detail}"
    _record "WARN" "${label}" "${detail}"
    check_warns=$(( check_warns + 1 ))
}

section() {
    printf '\n%s── %s%s\n' "${C_CYAN}${C_BOLD}" "$*" "${C_RESET}"
}

# ==============================================================================
# Header
# ==============================================================================

printf '\n%s%s Keycloak HA Healthcheck %s\n' \
    "${C_BOLD}" "══════════════════════" "══════════════════════${C_RESET}"
printf '  %s%-16s%s %s\n' "${C_DIM}" "Zeitpunkt:" "${C_RESET}" "$(date '+%Y-%m-%d %H:%M:%S')"
printf '  %s%-16s%s %s\n' "${C_DIM}" "Domain:" "${C_RESET}" "${KC_DOMAIN}"
printf '  %s%-16s%s %s / %s\n' "${C_DIM}" "KC-Nodes:" "${C_RESET}" \
    "${KC_NODE1_IP}:${KC_HTTP_PORT}" "${KC_NODE2_IP}:${KC_HTTP_PORT}"
printf '  %s%-16s%s %s / %s\n' "${C_DIM}" "KC-Mgmt:" "${C_RESET}" \
    "${KC_NODE1_IP}:${KC_MGMT_PORT}" "${KC_NODE2_IP}:${KC_MGMT_PORT}"
printf '  %s%-16s%s %s:5432 / %s\n\n' "${C_DIM}" "PostgreSQL:" "${C_RESET}" \
    "${DB_HOST}" "${DB_NAME}"

# ==============================================================================
# 1. Keycloak /health/ready direkt auf beiden Nodes
# ==============================================================================

section "Keycloak /health/ready (direkt)"

for node_ip in "${KC_NODE1_IP}" "${KC_NODE2_IP}"; do
    url="http://${node_ip}:${KC_MGMT_PORT}/health/ready"
    http_code="$(curl -sf --max-time "${HTTP_TIMEOUT}" \
        -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || echo "000")"

    label="Node ${node_ip}:${KC_MGMT_PORT} /health/ready"
    if [[ "${http_code}" == "200" ]]; then
        check_ok "${label}" "HTTP ${http_code}"
    else
        check_fail "${label}" "HTTP ${http_code} (erwartet: 200)"
    fi
done

# ==============================================================================
# 2. HTTPS-Endpunkt über Load Balancer
# ==============================================================================

section "HTTPS via Load Balancer"

lb_url="https://${KC_DOMAIN}/health/ready"
lb_code="$(curl -sf --max-time "${HTTP_TIMEOUT}" \
    -o /dev/null -w '%{http_code}' "${lb_url}" 2>/dev/null || echo "000")"

if [[ "${lb_code}" == "200" ]]; then
    check_ok "HTTPS ${KC_DOMAIN} /health/ready" "HTTP ${lb_code}"
else
    check_fail "HTTPS ${KC_DOMAIN} /health/ready" "HTTP ${lb_code} (erwartet: 200)"
fi

# HTTP→HTTPS Redirect
redirect_code="$(curl -sf --max-time "${HTTP_TIMEOUT}" \
    -o /dev/null -w '%{http_code}' \
    "http://${KC_DOMAIN}/health/ready" 2>/dev/null || echo "000")"

if [[ "${redirect_code}" == "301" ]]; then
    check_ok "HTTP→HTTPS Redirect" "HTTP ${redirect_code}"
else
    check_warn "HTTP→HTTPS Redirect" "HTTP ${redirect_code} (erwartet: 301)"
fi

# ==============================================================================
# 3. Cluster-Mitgliedschaft: beide Nodes müssen numberOfNodes=2 melden
# ==============================================================================

section "Cluster-Mitgliedschaft"

for node_ip in "${KC_NODE1_IP}" "${KC_NODE2_IP}"; do
    url="http://${node_ip}:${KC_MGMT_PORT}/health"
    label="Cluster-Nodes aus Sicht von ${node_ip}"

    response="$(curl -sf --max-time "${HTTP_TIMEOUT}" "${url}" 2>/dev/null || echo "")"

    if [[ -z "${response}" ]]; then
        check_fail "${label}" "Keine Antwort von ${url}"
        continue
    fi

    # Anzahl der Cluster-Nodes aus dem Health-Check-Response extrahieren.
    # Keycloak 26 liefert unter .checks[] einen Eintrag mit "cluster" im Namen
    # und darin .data.numberOfNodes (Integer).
    node_count=""
    cluster_status=""

    if command -v jq &>/dev/null; then
        # Suche nach dem Cluster-Health-Check-Eintrag (case-insensitive via ascii_downcase)
        cluster_status="$(printf '%s' "${response}" \
            | jq -r '.checks[]
                | select(.name | ascii_downcase | contains("cluster"))
                | .status' 2>/dev/null | head -1 || echo "")"
        node_count="$(printf '%s' "${response}" \
            | jq -r '.checks[]
                | select(.name | ascii_downcase | contains("cluster"))
                | .data.numberOfNodes // empty' 2>/dev/null | head -1 || echo "")"
    else
        # Fallback ohne jq: grep nach "numberOfNodes"
        node_count="$(printf '%s' "${response}" \
            | grep -oE '"numberOfNodes"\s*:\s*[0-9]+' \
            | grep -oE '[0-9]+$' || echo "")"
        cluster_status="$(printf '%s' "${response}" \
            | grep -oE '"status"\s*:\s*"[^"]*"' \
            | head -1 | grep -oE '"[^"]*"$' | tr -d '"' || echo "")"
    fi

    if [[ -z "${node_count}" ]]; then
        # numberOfNodes fehlt im Response → Keycloak läuft ggf. im Standalone-Modus
        # oder der Cluster-Check ist nicht aktiv. Status allein als Fallback.
        if [[ "${cluster_status}" == "UP" ]]; then
            check_warn "${label}" \
                "status=UP, numberOfNodes nicht im Response (Clustering aktiv?)"
        else
            check_fail "${label}" \
                "status=${cluster_status:-unbekannt}, numberOfNodes nicht ermittelbar"
        fi
    elif [[ "${node_count}" -eq 2 ]]; then
        check_ok "${label}" "${node_count}/2 Nodes im Cluster"
    elif [[ "${node_count}" -eq 1 ]]; then
        check_fail "${label}" \
            "${node_count}/2 Nodes im Cluster – Split-Brain oder zweite Node nicht verbunden"
    else
        check_warn "${label}" \
            "${node_count} Nodes im Cluster (erwartet: 2)"
    fi
done

# ==============================================================================
# 4. PostgreSQL via pg_isready
# ==============================================================================

section "PostgreSQL"

label="pg_isready ${DB_HOST}:5432 (${DB_NAME})"

if command -v pg_isready &>/dev/null; then
    pg_out="$(pg_isready \
        -h "${DB_HOST}" -p 5432 \
        -U "${DB_USER}" -d "${DB_NAME}" \
        --timeout "${HTTP_TIMEOUT}" 2>&1 || true)"

    if printf '%s' "${pg_out}" | grep -q "accepting connections"; then
        check_ok "${label}" "accepting connections"
    else
        check_fail "${label}" "${pg_out}"
    fi
else
    # Fallback: TCP-Porttest (kein Auth, kein DB-Name)
    if timeout "${HTTP_TIMEOUT}" bash -c \
        "echo > /dev/tcp/${DB_HOST}/5432" 2>/dev/null; then
        check_warn "${label}" \
            "TCP-Port erreichbar (pg_isready nicht installiert – kein Auth-Check)"
    else
        check_fail "${label}" "TCP-Port nicht erreichbar (pg_isready nicht installiert)"
    fi
fi

# ==============================================================================
# 5. TLS-Zertifikat: Handshake + Ablaufdatum via openssl s_client
#    (kein root nötig, funktioniert auch von extern)
# ==============================================================================

section "TLS-Zertifikat"

label_handshake="TLS-Handshake ${KC_DOMAIN}:443"
label_expiry="TLS-Ablaufdatum ${KC_DOMAIN}"

# Zertifikat vom Server abrufen und Ablaufdatum prüfen
cert_text="$(echo Q \
    | openssl s_client \
        -connect "${KC_DOMAIN}:443" \
        -servername "${KC_DOMAIN}" \
        -verify_return_error \
        2>/dev/null \
    | openssl x509 -noout -enddate -subject 2>/dev/null || echo "")"

if [[ -z "${cert_text}" ]]; then
    check_fail "${label_handshake}" "TLS-Verbindung fehlgeschlagen"
    check_fail "${label_expiry}" "Kein Zertifikat abrufbar"
else
    check_ok "${label_handshake}" "Verbindung und Zertifikatkette OK"

    expiry_str="$(printf '%s' "${cert_text}" \
        | grep 'notAfter=' | cut -d= -f2 || echo "")"

    if [[ -n "${expiry_str}" ]]; then
        expiry_epoch="$(date -d "${expiry_str}" '+%s' 2>/dev/null || echo "0")"
        now_epoch="$(date '+%s')"
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        if [[ "${days_left}" -lt 0 ]]; then
            check_fail "${label_expiry}" \
                "ABGELAUFEN seit ${days_left#-} Tagen!"
        elif [[ "${days_left}" -lt "${CERT_WARN_DAYS}" ]]; then
            check_warn "${label_expiry}" \
                "läuft in ${days_left} Tagen ab (< ${CERT_WARN_DAYS} Tage – Renewal prüfen!)"
        else
            check_ok "${label_expiry}" "gültig, läuft in ${days_left} Tagen ab"
        fi
    else
        check_warn "${label_expiry}" "Ablaufdatum konnte nicht geparst werden"
    fi
fi

# ==============================================================================
# Farbige Zusammenfassung
# ==============================================================================

total_checks=$(( $(printf '%b' "${check_log}" | grep -c '^') ))
ok_count=$(( total_checks - check_errors - check_warns ))

printf '\n%s%s Zusammenfassung %s%s\n' \
    "${C_BOLD}" "══════════════════════════════" \
    "══════════════════════════════" "${C_RESET}"

# Detail-Zeilen wiederholen (gruppiert nach Status)
if [[ "${check_errors}" -gt 0 ]]; then
    printf '\n  %sFehlgeschlagene Checks:%s\n' "${C_RED}${C_BOLD}" "${C_RESET}"
    while IFS=$'\t' read -r status lbl det; do
        [[ "${status}" == "FAIL" ]] || continue
        printf '    %s✗%s %s  %s%s%s\n' \
            "${C_RED}" "${C_RESET}" "${lbl}" "${C_DIM}" "${det}" "${C_RESET}"
    done < <(printf '%b' "${check_log}")
fi

if [[ "${check_warns}" -gt 0 ]]; then
    printf '\n  %sWarnungen:%s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}"
    while IFS=$'\t' read -r status lbl det; do
        [[ "${status}" == "WARN" ]] || continue
        printf '    %s!%s %s  %s%s%s\n' \
            "${C_YELLOW}" "${C_RESET}" "${lbl}" "${C_DIM}" "${det}" "${C_RESET}"
    done < <(printf '%b' "${check_log}")
fi

printf '\n  %s%-12s%s %s%d gesamt%s' \
    "${C_DIM}" "Checks:" "${C_RESET}" "${C_BOLD}" "${total_checks}" "${C_RESET}"
printf '  %s✓ %d OK%s' "${C_GREEN}" "${ok_count}" "${C_RESET}"
if [[ "${check_warns}" -gt 0 ]]; then
    printf '  %s! %d WARN%s' "${C_YELLOW}" "${check_warns}" "${C_RESET}"
fi
if [[ "${check_errors}" -gt 0 ]]; then
    printf '  %s✗ %d FAIL%s' "${C_RED}" "${check_errors}" "${C_RESET}"
fi
printf '\n'

printf '\n  %-14s ' "Endpunkte:"
printf '%shttps://%s%s\n' "${C_BOLD}" "${KC_DOMAIN}" "${C_RESET}"
printf '  %-14s %s\n' "" "kc01: ${KC_NODE1_IP}:${KC_HTTP_PORT}"
printf '  %-14s %s\n' "" "kc02: ${KC_NODE2_IP}:${KC_HTTP_PORT}"
printf '  %-14s %s:5432 / %s\n' "" "${DB_HOST}" "${DB_NAME}"

printf '\n'
if [[ "${check_errors}" -eq 0 ]]; then
    printf '%s%s ALLE %d CHECKS BESTANDEN ✓ %s%s\n' \
        "${C_GREEN}${C_BOLD}" \
        "══════════════════════" \
        "${total_checks}" \
        "══════════════════════" \
        "${C_RESET}"
    exit 0
else
    printf '%s%s %d VON %d CHECKS FEHLGESCHLAGEN ✗ %s%s\n' \
        "${C_RED}${C_BOLD}" \
        "═══════════════════" \
        "${check_errors}" \
        "${total_checks}" \
        "═══════════════════" \
        "${C_RESET}"
    exit 1
fi
