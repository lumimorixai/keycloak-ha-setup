#!/usr/bin/env bash
# ==============================================================================
# 06-setup-mon-vm.sh – Prometheus + Grafana + Alertmanager auf Monitoring-VM
#
# Ausführung: auf mon01 (oder auf lb01 im DEV-Setup)
# Voraussetzung: .env im Repo-Root muss befüllt sein (siehe .env.example)
#
# Was dieses Skript tut (alle Schritte idempotent):
#   1. node_exporter installieren (Debian-Paket, Self-Monitoring)
#   2. Prometheus installieren (Debian-Paket)
#   3. Alertmanager installieren (Debian-Paket)
#   4. Blackbox-Exporter installieren (TLS-Probe)
#   5. Grafana installieren (offizielles grafana.com-Repo)
#   6. prometheus.yml aus Template deployen
#   7. alertmanager.yml aus Template deployen
#   8. Blackbox-Exporter Config deployen
#   9. Alert-Rules deployen (statische Datei)
#  10. Grafana Datasource auto-provisioning
#  11. Grafana Dashboard-Provisioning konfigurieren
#  12. Dashboards deployen (Community-Download + Custom)
#  13. Services aktivieren und starten
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/00-common.sh
source "${SCRIPT_DIR}/00-common.sh"

# ==============================================================================
# Konstanten
# ==============================================================================

readonly PROM_CONF="/etc/prometheus/prometheus.yml"
readonly PROM_CONF_TPL="${REPO_DIR}/configs/monitoring/prometheus.yml.tpl"
readonly ALERT_RULES_SRC="${REPO_DIR}/configs/monitoring/alert-rules.yml"
readonly ALERT_RULES_DST="/etc/prometheus/alert-rules.yml"
readonly AM_CONF="/etc/prometheus/alertmanager.yml"
readonly AM_CONF_TPL="${REPO_DIR}/configs/monitoring/alertmanager.yml.tpl"
readonly GRAFANA_DS_SRC="${REPO_DIR}/configs/monitoring/grafana-datasource.yml"
readonly GRAFANA_DS_DST="/etc/grafana/provisioning/datasources/prometheus.yml"
readonly GRAFANA_KEYRING="/usr/share/keyrings/grafana-keyring.gpg"
readonly GRAFANA_SOURCES="/etc/apt/sources.list.d/grafana.list"
readonly GRAFANA_DASH_PROV_SRC="${REPO_DIR}/configs/monitoring/grafana-dashboards.yml"
readonly GRAFANA_DASH_PROV_DST="/etc/grafana/provisioning/dashboards/default.yml"
readonly GRAFANA_DASH_DIR="/var/lib/grafana/dashboards"
readonly CUSTOM_DASH_SRC="${REPO_DIR}/configs/monitoring/dashboards"

# Community-Dashboard-IDs (grafana.com)
readonly -a COMMUNITY_DASHBOARDS=(
    "1860:node-exporter-full"
    "9628:postgresql"
    "12708:nginx"
)

# envsubst-Variablen für prometheus.yml (nur .env-Variablen ersetzen)
readonly BLACKBOX_CONF_SRC="${REPO_DIR}/configs/monitoring/blackbox.yml"
readonly BLACKBOX_CONF_DST="/etc/prometheus/blackbox.yml"

readonly PROM_ENVSUBST_VARS='${KC_DOMAIN} ${KC_NODE1_IP} ${KC_NODE2_IP} ${KC_MGMT_PORT} ${DB_HOST} ${LB_HOST} ${PROM_BLACKBOX_ADMIN_TARGET}'
# envsubst-Variablen für alertmanager.yml
readonly AM_ENVSUBST_VARS='${ACME_EMAIL}'

# ==============================================================================
# Hilfsfunktionen
# ==============================================================================

# Community-Dashboard von grafana.com herunterladen und Datasource normalisieren
download_community_dashboard() {
    local dashboard_id="${1}"
    local target_file="${2}"
    local api_url="https://grafana.com/api/dashboards/${dashboard_id}/revisions/latest/download"

    if [[ -f "${target_file}" ]]; then
        log_info "Community-Dashboard bereits vorhanden: ${target_file}"
        return 0
    fi

    log_info "Community-Dashboard herunterladen: ID ${dashboard_id} → ${target_file}"
    local tmp_file
    tmp_file="$(mktemp)"

    if ! curl -fsSL "${api_url}" -o "${tmp_file}"; then
        log_warn "Download fehlgeschlagen: Dashboard ID ${dashboard_id} – übersprungen"
        rm -f "${tmp_file}"
        return 0
    fi

    # id auf null setzen, Datasource auf unsere Prometheus-UID normalisieren
    if command -v jq &>/dev/null; then
        jq '.id = null' "${tmp_file}" > "${target_file}"
        rm -f "${tmp_file}"
    else
        mv "${tmp_file}" "${target_file}"
    fi

    chown grafana:grafana "${target_file}"
    chmod 0640 "${target_file}"
    log_info "Community-Dashboard deployed: ${target_file}"
}

# ==============================================================================
# Voraussetzungen
# ==============================================================================

load_env
require_root

log_info "=== Monitoring-Stack Setup startet ==="

# ==============================================================================
# Schritt 1/13: node_exporter auf mon01 selbst installieren
# ==============================================================================
# prometheus.yml.tpl hat localhost:9100 als Target – node_exporter muss lokal laufen.

log_info "--- Schritt 1/13: node_exporter installieren ---"

ensure_package prometheus-node-exporter
ensure_service prometheus-node-exporter

# ==============================================================================
# Schritt 2/13: Prometheus installieren
# ==============================================================================

log_info "--- Schritt 2/13: Prometheus installieren ---"

ensure_package prometheus

# ==============================================================================
# Schritt 3/13: Alertmanager installieren
# ==============================================================================

log_info "--- Schritt 3/13: Alertmanager installieren ---"

ensure_package prometheus-alertmanager

# ==============================================================================
# Schritt 4/13: Blackbox-Exporter installieren (TLS-Probe)
# ==============================================================================

log_info "--- Schritt 4/13: Blackbox-Exporter installieren ---"

ensure_package prometheus-blackbox-exporter

# ==============================================================================
# Schritt 5/13: Grafana installieren (offizielles Repo)
# ==============================================================================

log_info "--- Schritt 5/13: Grafana installieren ---"

ensure_package curl gnupg apt-transport-https jq

needs_apt_update=0

if [[ ! -f "${GRAFANA_KEYRING}" ]]; then
    curl -fsSL https://apt.grafana.com/gpg.key \
        | gpg --dearmor -o "${GRAFANA_KEYRING}"
    log_info "Grafana-Signaturschlüssel installiert: ${GRAFANA_KEYRING}"
    needs_apt_update=1
else
    log_info "Grafana-Signaturschlüssel bereits vorhanden: ${GRAFANA_KEYRING}"
fi

if [[ ! -f "${GRAFANA_SOURCES}" ]]; then
    printf 'deb [signed-by=%s] https://apt.grafana.com stable main\n' \
        "${GRAFANA_KEYRING}" > "${GRAFANA_SOURCES}"
    log_info "Grafana-Repository hinzugefügt: ${GRAFANA_SOURCES}"
    needs_apt_update=1
else
    log_info "Grafana-Repository bereits konfiguriert: ${GRAFANA_SOURCES}"
fi

if [[ "${needs_apt_update}" -eq 1 ]]; then
    log_info "apt-get update wird ausgeführt..."
    apt-get update -qq
fi

ensure_package grafana

# ==============================================================================
# Schritt 6/13: prometheus.yml aus Template deployen
# ==============================================================================

log_info "--- Schritt 6/13: prometheus.yml deployen ---"

# Blackbox-Target fuer die Admin-Domain nur setzen wenn KC_ADMIN_DOMAIN befuellt
# ist – sonst landet "https://" als Target in der Config und TLSProbeFailure
# feuert dauerhaft. Einrueckung passend zur YAML-Liste im Template.
if [[ -n "${KC_ADMIN_DOMAIN:-}" ]]; then
    PROM_BLACKBOX_ADMIN_TARGET="          - https://${KC_ADMIN_DOMAIN}"
    log_info "Blackbox-Probe fuer Admin-Domain aktiv: https://${KC_ADMIN_DOMAIN}"
else
    PROM_BLACKBOX_ADMIN_TARGET="          # keine Admin-Domain konfiguriert (KC_ADMIN_DOMAIN leer)"
fi
export PROM_BLACKBOX_ADMIN_TARGET

prom_changed=0
if [[ ! -f "${PROM_CONF}" ]] \
    || ! diff -q \
        <(envsubst "${PROM_ENVSUBST_VARS}" < "${PROM_CONF_TPL}") \
        "${PROM_CONF}" &>/dev/null; then
    prom_changed=1
fi

deploy_config "${PROM_CONF_TPL}" "${PROM_CONF}" "prometheus:prometheus" "0640" "${PROM_ENVSUBST_VARS}"

# ==============================================================================
# Schritt 7/13: alertmanager.yml aus Template deployen
# ==============================================================================

log_info "--- Schritt 7/13: alertmanager.yml deployen ---"

am_changed=0
if [[ ! -f "${AM_CONF}" ]] \
    || ! diff -q \
        <(envsubst "${AM_ENVSUBST_VARS}" < "${AM_CONF_TPL}") \
        "${AM_CONF}" &>/dev/null; then
    am_changed=1
fi

deploy_config "${AM_CONF_TPL}" "${AM_CONF}" "prometheus:prometheus" "0640" "${AM_ENVSUBST_VARS}"

# ==============================================================================
# Schritt 8/13: Blackbox-Exporter Config deployen
# ==============================================================================

log_info "--- Schritt 8/13: Blackbox-Exporter Config deployen ---"

blackbox_changed=0
if [[ ! -f "${BLACKBOX_CONF_DST}" ]] \
    || ! diff -q "${BLACKBOX_CONF_SRC}" "${BLACKBOX_CONF_DST}" &>/dev/null; then
    if [[ -f "${BLACKBOX_CONF_DST}" ]]; then
        backup_file "${BLACKBOX_CONF_DST}"
    fi
    cp "${BLACKBOX_CONF_SRC}" "${BLACKBOX_CONF_DST}"
    chmod 0644 "${BLACKBOX_CONF_DST}"
    log_info "Blackbox-Config deployed: ${BLACKBOX_CONF_DST}"
    blackbox_changed=1
else
    log_info "Blackbox-Config bereits aktuell: ${BLACKBOX_CONF_DST}"
fi

# ==============================================================================
# Schritt 9/13: Alert-Rules deployen (statische Datei, kein envsubst)
# ==============================================================================

log_info "--- Schritt 9/13: Alert-Rules deployen ---"

rules_changed=0
if [[ ! -f "${ALERT_RULES_DST}" ]] \
    || ! diff -q "${ALERT_RULES_SRC}" "${ALERT_RULES_DST}" &>/dev/null; then
    if [[ -f "${ALERT_RULES_DST}" ]]; then
        backup_file "${ALERT_RULES_DST}"
    fi
    cp "${ALERT_RULES_SRC}" "${ALERT_RULES_DST}"
    chown prometheus:prometheus "${ALERT_RULES_DST}"
    chmod 0640 "${ALERT_RULES_DST}"
    log_info "Alert-Rules deployed: ${ALERT_RULES_DST}"
    rules_changed=1
else
    log_info "Alert-Rules bereits aktuell: ${ALERT_RULES_DST}"
fi

# Prometheus-Config-Syntax prüfen (inkl. Alert-Rules)
if command -v promtool &>/dev/null; then
    log_info "Prometheus-Konfiguration wird geprüft (promtool)..."
    promtool check config "${PROM_CONF}"
    log_info "Prometheus-Konfiguration OK."
fi

# ==============================================================================
# Schritt 10/13: Grafana Datasource auto-provisioning
# ==============================================================================

log_info "--- Schritt 10/13: Grafana Datasource konfigurieren ---"

# Provisioning-Verzeichnis sicherstellen
if [[ ! -d "$(dirname "${GRAFANA_DS_DST}")" ]]; then
    mkdir -p "$(dirname "${GRAFANA_DS_DST}")"
    log_info "Grafana Provisioning-Verzeichnis angelegt."
fi

if [[ -f "${GRAFANA_DS_DST}" ]] \
    && diff -q "${GRAFANA_DS_SRC}" "${GRAFANA_DS_DST}" &>/dev/null; then
    log_info "Grafana Datasource bereits aktuell: ${GRAFANA_DS_DST}"
else
    if [[ -f "${GRAFANA_DS_DST}" ]]; then
        backup_file "${GRAFANA_DS_DST}"
    fi
    cp "${GRAFANA_DS_SRC}" "${GRAFANA_DS_DST}"
    chown grafana:grafana "${GRAFANA_DS_DST}"
    chmod 0640 "${GRAFANA_DS_DST}"
    log_info "Grafana Datasource deployed: ${GRAFANA_DS_DST}"
fi

# ==============================================================================
# Schritt 11/13: Grafana Dashboard-Provisioning konfigurieren
# ==============================================================================

log_info "--- Schritt 11/13: Grafana Dashboard-Provisioning ---"

grafana_changed=0

# Provisioning-Verzeichnis sicherstellen
if [[ ! -d "$(dirname "${GRAFANA_DASH_PROV_DST}")" ]]; then
    mkdir -p "$(dirname "${GRAFANA_DASH_PROV_DST}")"
fi

if [[ -f "${GRAFANA_DASH_PROV_DST}" ]] \
    && diff -q "${GRAFANA_DASH_PROV_SRC}" "${GRAFANA_DASH_PROV_DST}" &>/dev/null; then
    log_info "Dashboard-Provisioning bereits aktuell: ${GRAFANA_DASH_PROV_DST}"
else
    if [[ -f "${GRAFANA_DASH_PROV_DST}" ]]; then
        backup_file "${GRAFANA_DASH_PROV_DST}"
    fi
    cp "${GRAFANA_DASH_PROV_SRC}" "${GRAFANA_DASH_PROV_DST}"
    chown grafana:grafana "${GRAFANA_DASH_PROV_DST}"
    chmod 0640 "${GRAFANA_DASH_PROV_DST}"
    log_info "Dashboard-Provisioning deployed: ${GRAFANA_DASH_PROV_DST}"
    grafana_changed=1
fi

# ==============================================================================
# Schritt 12/13: Dashboards deployen (Community-Download + Custom)
# ==============================================================================

log_info "--- Schritt 12/13: Dashboards deployen ---"

# Dashboard-Verzeichnis anlegen
if [[ ! -d "${GRAFANA_DASH_DIR}" ]]; then
    mkdir -p "${GRAFANA_DASH_DIR}"
    chown grafana:grafana "${GRAFANA_DASH_DIR}"
    log_info "Dashboard-Verzeichnis angelegt: ${GRAFANA_DASH_DIR}"
fi

# Community-Dashboards von grafana.com herunterladen
for entry in "${COMMUNITY_DASHBOARDS[@]}"; do
    dash_id="${entry%%:*}"
    dash_name="${entry#*:}"
    download_community_dashboard "${dash_id}" "${GRAFANA_DASH_DIR}/${dash_name}.json"
done

# Custom-Dashboards aus dem Repo kopieren
if [[ -d "${CUSTOM_DASH_SRC}" ]]; then
    for src_file in "${CUSTOM_DASH_SRC}"/*.json; do
        [[ -f "${src_file}" ]] || continue
        dst_file="${GRAFANA_DASH_DIR}/$(basename "${src_file}")"
        if [[ -f "${dst_file}" ]] \
            && diff -q "${src_file}" "${dst_file}" &>/dev/null; then
            log_info "Custom-Dashboard bereits aktuell: ${dst_file}"
        else
            cp "${src_file}" "${dst_file}"
            chown grafana:grafana "${dst_file}"
            chmod 0640 "${dst_file}"
            log_info "Custom-Dashboard deployed: ${dst_file}"
            grafana_changed=1
        fi
    done
fi

# ==============================================================================
# Schritt 13/13: Services aktivieren und starten
# ==============================================================================

log_info "--- Schritt 13/13: Services aktivieren ---"

ensure_service prometheus
ensure_service prometheus-alertmanager
ensure_service prometheus-blackbox-exporter
ensure_service grafana-server

# Prometheus bei Config-Änderung neu laden (SIGHUP = config reload ohne Restart)
if [[ $(( prom_changed + rules_changed )) -gt 0 ]] \
    && systemctl is-active --quiet prometheus 2>/dev/null; then
    systemctl reload prometheus 2>/dev/null \
        || systemctl restart prometheus
    log_info "Prometheus neu geladen (Konfiguration geändert)."
fi

# Blackbox-Exporter bei Config-Änderung neu starten
if [[ "${blackbox_changed}" -eq 1 ]] \
    && systemctl is-active --quiet prometheus-blackbox-exporter 2>/dev/null; then
    systemctl restart prometheus-blackbox-exporter
    log_info "Blackbox-Exporter neu gestartet (Konfiguration geändert)."
fi

# Alertmanager bei Config-Änderung neu laden
if [[ "${am_changed}" -eq 1 ]] \
    && systemctl is-active --quiet prometheus-alertmanager 2>/dev/null; then
    systemctl reload prometheus-alertmanager 2>/dev/null \
        || systemctl restart prometheus-alertmanager
    log_info "Alertmanager neu geladen (Konfiguration geändert)."
fi

# Grafana bei Dashboard/Datasource-Änderung neu starten
if [[ "${grafana_changed}" -eq 1 ]] \
    && systemctl is-active --quiet grafana-server 2>/dev/null; then
    systemctl restart grafana-server
    log_info "Grafana neu gestartet (Dashboard-Konfiguration geändert)."
fi

# ==============================================================================
# Abschluss
# ==============================================================================

log_info "=== Monitoring-Stack Setup abgeschlossen ==="
log_info "Prometheus:   $(systemctl is-active prometheus 2>/dev/null || echo 'unbekannt') (:9090)"
log_info "Alertmanager: $(systemctl is-active prometheus-alertmanager 2>/dev/null || echo 'unbekannt') (:9093)"
log_info "Grafana:      $(systemctl is-active grafana-server 2>/dev/null || echo 'unbekannt') (:3000)"
log_info ""
log_info "Grafana Login: http://<IP>:3000 (Standard: admin/admin)"
log_info "Prometheus UI: http://<IP>:9090"
log_info ""
log_info "Nächste Schritte:"
log_info "  1. Exporter auf Ziel-VMs installieren: sudo scripts/05-setup-monitoring.sh <rolle>"
log_info "  2. Firewall-Regeln setzen: sudo scripts/04-harden.sh mon"
log_info "  3. Scrape-Targets prüfen: http://<IP>:9090/targets"
