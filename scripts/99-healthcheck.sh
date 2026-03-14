#!/usr/bin/env bash
# ==============================================================================
# 99-healthcheck.sh – Validierung des Keycloak HA-Setups
#
# Ausführung: auf der jeweiligen VM mit Pflichtparameter für die VM-Rolle
#
# Verwendung:
#   scripts/99-healthcheck.sh <vm-typ>
#
# vm-typ:
#   lb        – Load Balancer (lb01): nginx, KC-Nodes, HTTPS End-to-End, TLS
#   keycloak  – Keycloak-Node (kc01/kc02): lokal, Peer, JGroups, DB-Verbindung
#   db        – Datenbankserver (db01): PostgreSQL, Verbindungen, jgroups_ping
#   mon       – Monitoring-VM (mon01): Prometheus, Grafana, Alertmanager, Exporter-Targets
#
# Exit-Code: 0 = alle Checks bestanden, 1 = mindestens ein FAIL
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/00-common.sh
source "${SCRIPT_DIR}/00-common.sh"

# ==============================================================================
# Pflichtparameter: VM-Typ
# ==============================================================================

usage() {
    printf 'Verwendung: %s <vm-typ>\n' "${0}"
    printf '  vm-typ: lb | keycloak | db | mon\n\n'
    printf '  lb        – Load Balancer (lb01)\n'
    printf '  keycloak  – Keycloak-Node (kc01 oder kc02)\n'
    printf '  db        – Datenbankserver (db01)\n'
    printf '  mon       – Monitoring-VM  (mon01)\n'
    exit 1
}

if [[ "${#}" -ne 1 ]]; then
    log_err "Genau ein Argument erwartet, ${#} übergeben."
    usage
fi

vm_role="${1}"

case "${vm_role}" in
    lb|keycloak|db|mon) ;;
    *)
        log_err "Ungültiger VM-Typ: '${vm_role}'. Erlaubt: lb, keycloak, db, mon"
        usage
        ;;
esac

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
check_total=0
# Jede Zeile: "STATUS\tLabel\tDetail"
check_log=''

readonly HTTP_TIMEOUT=10
readonly NC_TIMEOUT=5
readonly CERT_WARN_DAYS=30

# ==============================================================================
# Check-Funktionen
# ==============================================================================

_record() {
    local status="$1" label="$2" detail="$3"
    check_log="${check_log}${status}\t${label}\t${detail}\n"
    check_total=$(( check_total + 1 ))
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
# Hilfsfunktionen
# ==============================================================================

# HTTP-Status-Code abrufen (kein -f: 4xx/5xx liefern trotzdem Code)
http_get_code() {
    curl -s --max-time "${HTTP_TIMEOUT}" \
        -o /dev/null -w '%{http_code}' "${1}" 2>/dev/null
}

# TCP-Port-Erreichbarkeit testen
tcp_check() {
    nc -z -w "${NC_TIMEOUT}" "${1}" "${2}" 2>/dev/null
}

# Keycloak-Cluster-Check-Status aus /health-Response extrahieren
kc_cluster_status() {
    local url="$1" response
    response="$(curl -s --max-time "${HTTP_TIMEOUT}" "${url}" 2>/dev/null || true)"
    if [[ -z "${response}" ]]; then
        echo "NO_RESPONSE"
        return
    fi
    if command -v jq &>/dev/null; then
        printf '%s' "${response}" \
            | jq -r '.checks[]
                | select(.name | ascii_downcase | contains("cluster"))
                | .status' 2>/dev/null \
            | head -1 || echo "UNKNOWN"
    else
        printf '%s' "${response}" \
            | grep -oE '"status"\s*:\s*"[^"]*"' \
            | head -1 | grep -oE '"[^"]*"$' | tr -d '"' || echo "UNKNOWN"
    fi
}

# ==============================================================================
# lb-Checks: nginx + KC-Nodes + HTTPS End-to-End + TLS
# ==============================================================================

checks_lb() {
    # --------------------------------------------------------------------------
    section "nginx"
    # --------------------------------------------------------------------------

    if systemctl is-active --quiet nginx 2>/dev/null; then
        check_ok "nginx service" "active"
    else
        check_fail "nginx service" "nicht aktiv – 'systemctl status nginx' prüfen"
    fi

    # --------------------------------------------------------------------------
    section "Keycloak-Nodes (direkt via Port ${KC_MGMT_PORT})"
    # --------------------------------------------------------------------------

    for node_ip in "${KC_NODE1_IP}" "${KC_NODE2_IP}"; do
        code="$(http_get_code "http://${node_ip}:${KC_MGMT_PORT}/health/ready")"
        label="Node ${node_ip}:${KC_MGMT_PORT} /health/ready"
        if [[ "${code}" == "200" ]]; then
            check_ok "${label}" "HTTP ${code}"
        else
            check_fail "${label}" "HTTP ${code:-000} (erwartet: 200)"
        fi
    done

    # --------------------------------------------------------------------------
    section "HTTPS End-to-End"
    # --------------------------------------------------------------------------

    code="$(http_get_code "https://${KC_DOMAIN}/realms/master")"
    if [[ "${code}" == "200" ]]; then
        check_ok "HTTPS ${KC_DOMAIN} /realms/master" "HTTP ${code}"
    else
        check_fail "HTTPS ${KC_DOMAIN} /realms/master" "HTTP ${code:-000} (erwartet: 200)"
    fi

    code="$(http_get_code "http://${KC_DOMAIN}/")"
    if [[ "${code}" == "301" ]]; then
        check_ok "HTTP→HTTPS Redirect" "HTTP ${code}"
    else
        check_warn "HTTP→HTTPS Redirect" "HTTP ${code:-000} (erwartet: 301)"
    fi

    # --------------------------------------------------------------------------
    section "TLS-Zertifikat"
    # --------------------------------------------------------------------------

    cert_text="$(echo Q \
        | openssl s_client \
            -connect "${KC_DOMAIN}:443" \
            -servername "${KC_DOMAIN}" \
            -verify_return_error \
            2>/dev/null \
        | openssl x509 -noout -enddate -subject 2>/dev/null || echo "")"

    if [[ -z "${cert_text}" ]]; then
        check_fail "TLS-Handshake ${KC_DOMAIN}:443" "Verbindung fehlgeschlagen"
        check_fail "TLS-Ablaufdatum ${KC_DOMAIN}" "Kein Zertifikat abrufbar"
    else
        check_ok "TLS-Handshake ${KC_DOMAIN}:443" "Verbindung und Zertifikatkette OK"

        expiry_str="$(printf '%s' "${cert_text}" | grep 'notAfter=' | cut -d= -f2 || echo "")"
        if [[ -n "${expiry_str}" ]]; then
            expiry_epoch="$(date -d "${expiry_str}" '+%s' 2>/dev/null || echo "0")"
            days_left=$(( (expiry_epoch - $(date '+%s')) / 86400 ))

            if [[ "${days_left}" -lt 0 ]]; then
                check_fail "TLS-Ablaufdatum ${KC_DOMAIN}" \
                    "ABGELAUFEN seit ${days_left#-} Tagen!"
            elif [[ "${days_left}" -lt "${CERT_WARN_DAYS}" ]]; then
                check_warn "TLS-Ablaufdatum ${KC_DOMAIN}" \
                    "läuft in ${days_left} Tagen ab (< ${CERT_WARN_DAYS} Tage – Renewal prüfen!)"
            else
                check_ok "TLS-Ablaufdatum ${KC_DOMAIN}" \
                    "gültig, läuft in ${days_left} Tagen ab"
            fi
        else
            check_warn "TLS-Ablaufdatum ${KC_DOMAIN}" "Ablaufdatum konnte nicht geparst werden"
        fi
    fi
}

# ==============================================================================
# keycloak-Checks: lokal + Peer + JGroups + DB
# ==============================================================================

checks_keycloak() {
    # --------------------------------------------------------------------------
    section "Lokaler Keycloak"
    # --------------------------------------------------------------------------

    code="$(http_get_code "http://localhost:${KC_MGMT_PORT}/health/ready")"
    if [[ "${code}" == "200" ]]; then
        check_ok "localhost:${KC_MGMT_PORT} /health/ready" "HTTP ${code}"
    else
        check_fail "localhost:${KC_MGMT_PORT} /health/ready" \
            "HTTP ${code:-000} (erwartet: 200)"
    fi

    cluster_status="$(kc_cluster_status "http://localhost:${KC_MGMT_PORT}/health")"
    case "${cluster_status}" in
        UP)          check_ok   "localhost Cluster-Check" "status=UP" ;;
        NO_RESPONSE) check_fail "localhost Cluster-Check" "Keine Antwort" ;;
        *)           check_fail "localhost Cluster-Check" "status=${cluster_status}" ;;
    esac

    # --------------------------------------------------------------------------
    # Peer-Node ermitteln: alle KC-Node-IPs außer der eigenen
    # --------------------------------------------------------------------------
    local_ip=""
    while IFS= read -r ip; do
        [[ -z "${ip}" ]] && continue
        if [[ "${ip}" == "${KC_NODE1_IP}" || "${ip}" == "${KC_NODE2_IP}" ]]; then
            local_ip="${ip}"
            break
        fi
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')

    peer_ips=()
    for node_ip in "${KC_NODE1_IP}" "${KC_NODE2_IP}"; do
        if [[ "${node_ip}" != "${local_ip}" ]]; then
            peer_ips+=("${node_ip}")
        fi
    done
    # Fallback falls lokale IP nicht erkannt: beide Nodes prüfen
    if [[ "${#peer_ips[@]}" -eq 0 ]]; then
        peer_ips=("${KC_NODE1_IP}" "${KC_NODE2_IP}")
    fi

    # --------------------------------------------------------------------------
    section "Peer-Node(s)"
    # --------------------------------------------------------------------------

    for peer_ip in "${peer_ips[@]}"; do
        code="$(http_get_code "http://${peer_ip}:${KC_MGMT_PORT}/health/ready")"
        label="Peer ${peer_ip}:${KC_MGMT_PORT} /health/ready"
        if [[ "${code}" == "200" ]]; then
            check_ok "${label}" "HTTP ${code}"
        else
            check_fail "${label}" "HTTP ${code:-000} (erwartet: 200)"
        fi

        label_jg="JGroups TCP ${peer_ip}:${KC_JGROUPS_PORT}"
        if tcp_check "${peer_ip}" "${KC_JGROUPS_PORT}"; then
            check_ok "${label_jg}" "Port erreichbar"
        else
            check_fail "${label_jg}" "Port nicht erreichbar – Cluster-Kommunikation unterbrochen"
        fi
    done

    # --------------------------------------------------------------------------
    section "Datenbankverbindung (${DB_HOST}:5432)"
    # --------------------------------------------------------------------------

    label_db="pg_isready ${DB_HOST}:5432 (${DB_NAME})"
    if command -v pg_isready &>/dev/null; then
        pg_out="$(pg_isready \
            -h "${DB_HOST}" -p 5432 \
            -U "${DB_USER}" -d "${DB_NAME}" \
            --timeout "${HTTP_TIMEOUT}" 2>&1 || true)"
        if printf '%s' "${pg_out}" | grep -q "accepting connections"; then
            check_ok "${label_db}" "accepting connections"
        else
            check_fail "${label_db}" "${pg_out}"
        fi
    elif tcp_check "${DB_HOST}" 5432; then
        check_warn "${label_db}" \
            "TCP Port erreichbar (pg_isready nicht installiert – kein Auth-Check)"
    else
        check_fail "${label_db}" "TCP Port nicht erreichbar"
    fi
}

# ==============================================================================
# db-Checks: PostgreSQL Service + Konfiguration + Verbindungen + jgroups_ping
# ==============================================================================

checks_db() {
    # --------------------------------------------------------------------------
    section "PostgreSQL Service"
    # --------------------------------------------------------------------------

    pg_active_svc=""
    for svc in postgresql postgresql-16 "postgresql@16-main"; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            pg_active_svc="${svc}"
            break
        fi
    done

    if [[ -n "${pg_active_svc}" ]]; then
        check_ok "PostgreSQL service" "active (${pg_active_svc})"
    else
        check_fail "PostgreSQL service" "kein aktiver postgresql*-Service gefunden"
    fi

    label_pg="pg_isready lokal (${DB_NAME})"
    if command -v pg_isready &>/dev/null; then
        pg_out="$(pg_isready \
            -h localhost -p 5432 \
            -U "${DB_USER}" -d "${DB_NAME}" \
            --timeout "${HTTP_TIMEOUT}" 2>&1 || true)"
        if printf '%s' "${pg_out}" | grep -q "accepting connections"; then
            check_ok "${label_pg}" "accepting connections"
        else
            check_fail "${label_pg}" "${pg_out}"
        fi
    elif tcp_check "localhost" 5432; then
        check_warn "${label_pg}" "TCP Port erreichbar (pg_isready nicht installiert)"
    else
        check_fail "${label_pg}" "TCP Port nicht erreichbar"
    fi

    # Für detaillierte psql-Abfragen wird passwordless sudo zu postgres benötigt
    if ! sudo -n -u postgres true 2>/dev/null; then
        check_warn "PostgreSQL-Detailabfragen" \
            "Übersprungen – passwordless sudo zu postgres nicht verfügbar"
        return
    fi

    # --------------------------------------------------------------------------
    section "PostgreSQL Konfiguration"
    # --------------------------------------------------------------------------

    listen_addr="$(sudo -u postgres psql -Atc \
        "SELECT setting FROM pg_settings WHERE name = 'listen_addresses'" \
        2>/dev/null || echo "")"

    if [[ -n "${listen_addr}" ]]; then
        if printf '%s' "${listen_addr}" | grep -qF "${DB_HOST}"; then
            check_ok "listen_addresses" "${listen_addr}"
        else
            check_warn "listen_addresses" \
                "${listen_addr} – enthält ${DB_HOST} nicht (KC-Nodes können nicht verbinden)"
        fi
    else
        check_warn "listen_addresses" "Konnte nicht abgefragt werden"
    fi

    # --------------------------------------------------------------------------
    section "Aktive Verbindungen von KC-Nodes"
    # --------------------------------------------------------------------------

    for kc_ip in "${KC_NODE1_IP}" "${KC_NODE2_IP}"; do
        conn_count="$(sudo -u postgres psql -Atc \
            "SELECT COUNT(*) FROM pg_stat_activity
             WHERE datname = '${DB_NAME}' AND client_addr = '${kc_ip}'" \
            2>/dev/null || echo "")"
        label_conn="Verbindungen von ${kc_ip}"
        if [[ -z "${conn_count}" ]]; then
            check_warn "${label_conn}" "Konnte nicht abgefragt werden"
        elif [[ "${conn_count}" -gt 0 ]]; then
            check_ok "${label_conn}" "${conn_count} aktive Verbindung(en)"
        else
            check_warn "${label_conn}" \
                "0 Verbindungen – Keycloak auf ${kc_ip} gestartet?"
        fi
    done

    # --------------------------------------------------------------------------
    section "Cluster-Mitgliedschaft (jgroups_ping)"
    # --------------------------------------------------------------------------

    # jgroups_ping: Tabellenname in KC 26 (mit Unterstrich, nicht JGROUPSPING)
    node_rows="$(sudo -u postgres psql -Atd "${DB_NAME}" -c \
        "SELECT name || ' (' || ip || ')' ||
                CASE WHEN coord THEN ' [coordinator]' ELSE '' END
         FROM jgroups_ping
         ORDER BY coord DESC, name" \
        2>/dev/null || echo "")"

    node_count=0
    if [[ -n "${node_rows}" ]]; then
        node_count="$(printf '%s\n' "${node_rows}" | grep -c '.' || true)"
    fi

    if [[ "${node_count}" -eq 2 ]]; then
        check_ok "jgroups_ping" "${node_count}/2 Nodes registriert"
        while IFS= read -r row; do
            [[ -n "${row}" ]] && check_ok "  └─ ${row}" ""
        done <<< "${node_rows}"
    elif [[ "${node_count}" -eq 1 ]]; then
        check_warn "jgroups_ping" \
            "1/2 Nodes registriert – zweite Node noch nicht verbunden"
        while IFS= read -r row; do
            [[ -n "${row}" ]] && check_warn "  └─ ${row}" ""
        done <<< "${node_rows}"
    else
        check_fail "jgroups_ping" \
            "${node_count} Einträge – Clustering nicht aktiv oder Nodes nicht gestartet"
    fi
}

# ==============================================================================
# mon-Checks: Prometheus + Grafana + Alertmanager + Exporter-Targets
# ==============================================================================

checks_mon() {
    # --------------------------------------------------------------------------
    section "Monitoring-Services"
    # --------------------------------------------------------------------------

    for svc in prometheus grafana-server prometheus-alertmanager; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            check_ok "${svc} service" "active"
        else
            check_fail "${svc} service" "nicht aktiv – 'systemctl status ${svc}' prüfen"
        fi
    done

    # --------------------------------------------------------------------------
    section "Prometheus API"
    # --------------------------------------------------------------------------

    code="$(http_get_code "http://localhost:9090/-/ready")"
    if [[ "${code}" == "200" ]]; then
        check_ok "Prometheus :9090 /-/ready" "HTTP ${code}"
    else
        check_fail "Prometheus :9090 /-/ready" "HTTP ${code:-000} (erwartet: 200)"
    fi

    # --------------------------------------------------------------------------
    section "Grafana API"
    # --------------------------------------------------------------------------

    code="$(http_get_code "http://localhost:3000/api/health")"
    if [[ "${code}" == "200" ]]; then
        check_ok "Grafana :3000 /api/health" "HTTP ${code}"
    else
        check_fail "Grafana :3000 /api/health" "HTTP ${code:-000} (erwartet: 200)"
    fi

    # --------------------------------------------------------------------------
    section "Alertmanager API"
    # --------------------------------------------------------------------------

    code="$(http_get_code "http://localhost:9093/-/ready")"
    if [[ "${code}" == "200" ]]; then
        check_ok "Alertmanager :9093 /-/ready" "HTTP ${code}"
    else
        check_fail "Alertmanager :9093 /-/ready" "HTTP ${code:-000} (erwartet: 200)"
    fi

    # --------------------------------------------------------------------------
    section "Prometheus Scrape-Targets"
    # --------------------------------------------------------------------------

    if command -v curl &>/dev/null; then
        targets_json="$(curl -s --max-time "${HTTP_TIMEOUT}" \
            'http://localhost:9090/api/v1/targets' 2>/dev/null || echo "")"
        if [[ -n "${targets_json}" ]] && command -v jq &>/dev/null; then
            total_targets="$(printf '%s' "${targets_json}" \
                | jq -r '.data.activeTargets | length' 2>/dev/null || echo "0")"
            up_targets="$(printf '%s' "${targets_json}" \
                | jq -r '[.data.activeTargets[] | select(.health == "up")] | length' \
                2>/dev/null || echo "0")"
            down_targets=$(( total_targets - up_targets ))

            if [[ "${down_targets}" -eq 0 ]] && [[ "${total_targets}" -gt 0 ]]; then
                check_ok "Scrape-Targets" "${up_targets}/${total_targets} UP"
            elif [[ "${total_targets}" -eq 0 ]]; then
                check_warn "Scrape-Targets" "Keine Targets konfiguriert"
            else
                check_fail "Scrape-Targets" "${down_targets}/${total_targets} DOWN"
                # Einzelne DOWN-Targets auflisten
                printf '%s' "${targets_json}" \
                    | jq -r '.data.activeTargets[]
                        | select(.health != "up")
                        | "\(.scrapePool) → \(.labels.instance)"' \
                    2>/dev/null \
                    | while IFS= read -r tgt; do
                        check_fail "  └─ ${tgt}" "DOWN"
                    done
            fi
        else
            check_warn "Scrape-Targets" "jq nicht installiert – Detail-Check übersprungen"
        fi
    fi

    # --------------------------------------------------------------------------
    section "Alert-Rules"
    # --------------------------------------------------------------------------

    rules_json="$(curl -s --max-time "${HTTP_TIMEOUT}" \
        'http://localhost:9090/api/v1/rules' 2>/dev/null || echo "")"
    if [[ -n "${rules_json}" ]] && command -v jq &>/dev/null; then
        rule_count="$(printf '%s' "${rules_json}" \
            | jq -r '[.data.groups[].rules[]] | length' 2>/dev/null || echo "0")"
        firing_count="$(printf '%s' "${rules_json}" \
            | jq -r '[.data.groups[].rules[] | select(.state == "firing")] | length' \
            2>/dev/null || echo "0")"

        if [[ "${rule_count}" -eq 0 ]]; then
            check_warn "Alert-Rules" "Keine Rules geladen"
        elif [[ "${firing_count}" -gt 0 ]]; then
            check_warn "Alert-Rules" "${rule_count} Rules geladen, ${firing_count} firing"
        else
            check_ok "Alert-Rules" "${rule_count} Rules geladen, keine firing"
        fi
    fi
}

# ==============================================================================
# Header
# ==============================================================================

printf '\n%s%s Keycloak HA Healthcheck (%s) %s\n' \
    "${C_BOLD}" "═══════════════════" "${vm_role}" "═══════════════════${C_RESET}"
printf '  %s%-16s%s %s\n' "${C_DIM}" "Zeitpunkt:" "${C_RESET}" "$(date '+%Y-%m-%d %H:%M:%S')"
printf '  %s%-16s%s %s\n' "${C_DIM}" "Domain:" "${C_RESET}" "${KC_DOMAIN}"
printf '  %s%-16s%s %s / %s\n\n' "${C_DIM}" "KC-Nodes:" "${C_RESET}" \
    "${KC_NODE1_IP}:${KC_HTTP_PORT}" "${KC_NODE2_IP}:${KC_HTTP_PORT}"

# ==============================================================================
# Checks ausführen
# ==============================================================================

case "${vm_role}" in
    lb)       checks_lb ;;
    keycloak) checks_keycloak ;;
    db)       checks_db ;;
    mon)      checks_mon ;;
esac

# ==============================================================================
# Zusammenfassung
# ==============================================================================

ok_count=$(( check_total - check_errors - check_warns ))

printf '\n%s%s Zusammenfassung %s%s\n' \
    "${C_BOLD}" "══════════════════════════════" \
    "══════════════════════════════" "${C_RESET}"

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
    "${C_DIM}" "Checks:" "${C_RESET}" "${C_BOLD}" "${check_total}" "${C_RESET}"
printf '  %s✓ %d OK%s' "${C_GREEN}" "${ok_count}" "${C_RESET}"
[[ "${check_warns}"  -gt 0 ]] && printf '  %s! %d WARN%s' "${C_YELLOW}" "${check_warns}"  "${C_RESET}"
[[ "${check_errors}" -gt 0 ]] && printf '  %s✗ %d FAIL%s' "${C_RED}"    "${check_errors}" "${C_RESET}"
printf '\n\n'

if [[ "${check_errors}" -eq 0 ]]; then
    printf '%s%s ALLE %d CHECKS BESTANDEN ✓ %s%s\n\n' \
        "${C_GREEN}${C_BOLD}" \
        "══════════════════════" \
        "${check_total}" \
        "══════════════════════" \
        "${C_RESET}"
    exit 0
else
    printf '%s%s %d VON %d CHECKS FEHLGESCHLAGEN ✗ %s%s\n\n' \
        "${C_RED}${C_BOLD}" \
        "═══════════════════" \
        "${check_errors}" \
        "${check_total}" \
        "═══════════════════" \
        "${C_RESET}"
    exit 1
fi
