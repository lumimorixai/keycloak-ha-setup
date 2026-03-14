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
#   4. Grafana installieren (offizielles grafana.com-Repo)
#   5. prometheus.yml aus Template deployen
#   6. alertmanager.yml aus Template deployen
#   7. Alert-Rules deployen (statische Datei)
#   8. Grafana Datasource auto-provisioning
#   9. Services aktivieren und starten
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

# envsubst-Variablen für prometheus.yml (nur .env-Variablen ersetzen)
readonly PROM_ENVSUBST_VARS='${KC_NODE1_IP} ${KC_NODE2_IP} ${KC_MGMT_PORT} ${DB_HOST} ${LB_HOST}'
# envsubst-Variablen für alertmanager.yml
readonly AM_ENVSUBST_VARS='${ACME_EMAIL}'

# ==============================================================================
# Voraussetzungen
# ==============================================================================

load_env
require_root

log_info "=== Monitoring-Stack Setup startet ==="

# ==============================================================================
# Schritt 1/9: node_exporter auf mon01 selbst installieren
# ==============================================================================
# prometheus.yml.tpl hat localhost:9100 als Target – node_exporter muss lokal laufen.

log_info "--- Schritt 1/9: node_exporter installieren ---"

ensure_package prometheus-node-exporter
ensure_service prometheus-node-exporter

# ==============================================================================
# Schritt 2/9: Prometheus installieren
# ==============================================================================

log_info "--- Schritt 2/9: Prometheus installieren ---"

ensure_package prometheus

# ==============================================================================
# Schritt 3/9: Alertmanager installieren
# ==============================================================================

log_info "--- Schritt 3/9: Alertmanager installieren ---"

ensure_package prometheus-alertmanager

# ==============================================================================
# Schritt 4/9: Grafana installieren (offizielles Repo)
# ==============================================================================

log_info "--- Schritt 4/9: Grafana installieren ---"

ensure_package curl gnupg apt-transport-https

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
# Schritt 5/9: prometheus.yml aus Template deployen
# ==============================================================================

log_info "--- Schritt 5/9: prometheus.yml deployen ---"

prom_changed=0
if [[ ! -f "${PROM_CONF}" ]] \
    || ! diff -q \
        <(envsubst "${PROM_ENVSUBST_VARS}" < "${PROM_CONF_TPL}") \
        "${PROM_CONF}" &>/dev/null; then
    prom_changed=1
fi

deploy_config "${PROM_CONF_TPL}" "${PROM_CONF}" "prometheus:prometheus" "0640" "${PROM_ENVSUBST_VARS}"

# ==============================================================================
# Schritt 6/9: alertmanager.yml aus Template deployen
# ==============================================================================

log_info "--- Schritt 6/9: alertmanager.yml deployen ---"

am_changed=0
if [[ ! -f "${AM_CONF}" ]] \
    || ! diff -q \
        <(envsubst "${AM_ENVSUBST_VARS}" < "${AM_CONF_TPL}") \
        "${AM_CONF}" &>/dev/null; then
    am_changed=1
fi

deploy_config "${AM_CONF_TPL}" "${AM_CONF}" "prometheus:prometheus" "0640" "${AM_ENVSUBST_VARS}"

# ==============================================================================
# Schritt 7/9: Alert-Rules deployen (statische Datei, kein envsubst)
# ==============================================================================

log_info "--- Schritt 7/9: Alert-Rules deployen ---"

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
# Schritt 8/9: Grafana Datasource auto-provisioning
# ==============================================================================

log_info "--- Schritt 8/9: Grafana Datasource konfigurieren ---"

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
# Schritt 9/9: Services aktivieren und starten
# ==============================================================================

log_info "--- Schritt 9/9: Services aktivieren ---"

ensure_service prometheus
ensure_service prometheus-alertmanager
ensure_service grafana-server

# Prometheus bei Config-Änderung neu laden (SIGHUP = config reload ohne Restart)
if [[ $(( prom_changed + rules_changed )) -gt 0 ]] \
    && systemctl is-active --quiet prometheus 2>/dev/null; then
    systemctl reload prometheus 2>/dev/null \
        || systemctl restart prometheus
    log_info "Prometheus neu geladen (Konfiguration geändert)."
fi

# Alertmanager bei Config-Änderung neu laden
if [[ "${am_changed}" -eq 1 ]] \
    && systemctl is-active --quiet prometheus-alertmanager 2>/dev/null; then
    systemctl reload prometheus-alertmanager 2>/dev/null \
        || systemctl restart prometheus-alertmanager
    log_info "Alertmanager neu geladen (Konfiguration geändert)."
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
