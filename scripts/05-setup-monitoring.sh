#!/usr/bin/env bash
# ==============================================================================
# 05-setup-monitoring.sh – Monitoring-Exporter auf Ziel-VMs installieren
#
# Ausführung: auf db01, kc01/kc02, lb01
# Voraussetzung: .env im Repo-Root muss befüllt sein (siehe .env.example)
#
# Verwendung:
#   sudo scripts/05-setup-monitoring.sh <vm-typ>
#
# vm-typ (Pflichtparameter):
#   db        – node_exporter + postgres_exporter
#   keycloak  – node_exporter (KC-Metriken sind built-in auf Port 9000)
#   lb        – node_exporter + nginx-prometheus-exporter
#
# Was dieses Skript tut (alle Schritte idempotent):
#   1. node_exporter installieren (Debian-Paket, alle Rollen)
#   2. Rollenspezifische Exporter installieren:
#      - db:  postgres_exporter (GitHub-Release)
#      - lb:  nginx-prometheus-exporter (GitHub-Release)
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
    printf '  vm-typ: db | keycloak | lb\n'
    printf '\n'
    printf '  db        – node_exporter + postgres_exporter\n'
    printf '  keycloak  – node_exporter (KC-Metriken built-in)\n'
    printf '  lb        – node_exporter + nginx-prometheus-exporter\n'
    exit 1
}

if [[ "${#}" -ne 1 ]]; then
    log_err "Genau ein Argument erwartet, ${#} übergeben."
    usage
fi

vm_role="${1}"

case "${vm_role}" in
    db|keycloak|lb) ;;
    *)
        log_err "Ungültiger VM-Typ: '${vm_role}'. Erlaubt: db, keycloak, lb"
        usage
        ;;
esac

# ==============================================================================
# Konstanten
# ==============================================================================

readonly PG_EXPORTER_VERSION="0.16.0"
readonly PG_EXPORTER_URL="https://github.com/prometheus-community/postgres_exporter/releases/download/v${PG_EXPORTER_VERSION}/postgres_exporter-${PG_EXPORTER_VERSION}.linux-amd64.tar.gz"
readonly PG_EXPORTER_BIN="/usr/local/bin/postgres_exporter"
readonly PG_EXPORTER_ENV="/etc/default/postgres_exporter"
readonly PG_EXPORTER_USER="postgres_exporter"

readonly FAIL2BAN_METRICS_SRC="${REPO_DIR}/configs/monitoring/fail2ban-metrics.sh"
readonly FAIL2BAN_METRICS_DST="/usr/local/bin/fail2ban-metrics.sh"
readonly FAIL2BAN_CRON="/etc/cron.d/fail2ban-metrics"

readonly KC_CLUSTER_METRICS_SRC="${REPO_DIR}/configs/monitoring/keycloak-cluster-metrics.sh"
readonly KC_CLUSTER_METRICS_DST="/usr/local/bin/keycloak-cluster-metrics.sh"
readonly KC_CLUSTER_CRON="/etc/cron.d/keycloak-cluster-metrics"

readonly NGINX_EXPORTER_VERSION="1.4.0"
readonly NGINX_EXPORTER_URL="https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/v${NGINX_EXPORTER_VERSION}/nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_linux_amd64.tar.gz"
readonly NGINX_EXPORTER_BIN="/usr/local/bin/nginx-prometheus-exporter"

# ==============================================================================
# Voraussetzungen
# ==============================================================================

load_env
require_root

log_info "=== Monitoring-Exporter Setup startet (Rolle: ${vm_role}) ==="

# ==============================================================================
# Schritt 1: node_exporter (alle Rollen)
# ==============================================================================

log_info "--- Schritt 1: node_exporter installieren ---"

ensure_package prometheus-node-exporter
ensure_service prometheus-node-exporter

# ==============================================================================
# Schritt 2: Fail2ban-Textfile-Collector (alle Rollen)
# ==============================================================================
# Schreibt aktuell gebannte IPs als Prometheus-Gauge in eine .prom-Datei,
# die vom node_exporter Textfile-Collector gelesen wird.

log_info "--- Schritt 2: Fail2ban-Metrics Textfile-Collector ---"

if dpkg -s fail2ban &>/dev/null; then
    # Textfile-Collector-Verzeichnis sicherstellen
    mkdir -p /var/lib/prometheus/node-exporter

    # Skript installieren
    if [[ -f "${FAIL2BAN_METRICS_DST}" ]] \
        && diff -q "${FAIL2BAN_METRICS_SRC}" "${FAIL2BAN_METRICS_DST}" &>/dev/null; then
        log_info "fail2ban-metrics.sh bereits aktuell."
    else
        install -m 0755 "${FAIL2BAN_METRICS_SRC}" "${FAIL2BAN_METRICS_DST}"
        log_info "fail2ban-metrics.sh installiert: ${FAIL2BAN_METRICS_DST}"
    fi

    # Cronjob anlegen (alle 2 Minuten)
    cron_content="# Fail2ban metrics for Prometheus textfile collector
*/2 * * * * root ${FAIL2BAN_METRICS_DST}
"
    if [[ -f "${FAIL2BAN_CRON}" ]] \
        && printf '%s' "${cron_content}" | diff -q - "${FAIL2BAN_CRON}" &>/dev/null; then
        log_info "Fail2ban-Cronjob bereits aktuell."
    else
        printf '%s' "${cron_content}" > "${FAIL2BAN_CRON}"
        chmod 0644 "${FAIL2BAN_CRON}"
        log_info "Fail2ban-Cronjob installiert: ${FAIL2BAN_CRON}"
    fi

    # Einmal sofort ausführen
    "${FAIL2BAN_METRICS_DST}" || true
    log_info "Fail2ban-Metrics initial geschrieben."
else
    log_info "Fail2ban nicht installiert – Textfile-Collector übersprungen."
fi

# ==============================================================================
# Schritt 3: Rollenspezifische Exporter
# ==============================================================================

case "${vm_role}" in
    # ==========================================================================
    # db: postgres_exporter
    # ==========================================================================
    db)
        log_info "--- Schritt 3: postgres_exporter ${PG_EXPORTER_VERSION} installieren ---"

        ensure_package curl

        # System-User anlegen (idempotent)
        if id "${PG_EXPORTER_USER}" &>/dev/null; then
            log_info "System-User bereits vorhanden: ${PG_EXPORTER_USER}"
        else
            useradd --system --no-create-home --shell /sbin/nologin \
                --comment "Postgres Exporter" "${PG_EXPORTER_USER}"
            log_info "System-User angelegt: ${PG_EXPORTER_USER}"
        fi

        # Binary herunterladen und installieren
        if [[ -f "${PG_EXPORTER_BIN}" ]]; then
            installed_version="$("${PG_EXPORTER_BIN}" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")"
            if [[ "${installed_version}" == "${PG_EXPORTER_VERSION}" ]]; then
                log_info "postgres_exporter ${PG_EXPORTER_VERSION} bereits installiert."
            else
                log_info "postgres_exporter Version ${installed_version:-unbekannt} → ${PG_EXPORTER_VERSION} Upgrade."
            fi
        fi

        if [[ ! -f "${PG_EXPORTER_BIN}" ]] \
            || ! "${PG_EXPORTER_BIN}" --version 2>&1 | grep -qF "${PG_EXPORTER_VERSION}"; then
            tmp_dir="$(mktemp -d)"
            log_info "Lade postgres_exporter ${PG_EXPORTER_VERSION} herunter..."
            curl -fsSL --output "${tmp_dir}/pg_exporter.tar.gz" "${PG_EXPORTER_URL}"
            tar -xzf "${tmp_dir}/pg_exporter.tar.gz" -C "${tmp_dir}" --strip-components=1
            install -m 0755 "${tmp_dir}/postgres_exporter" "${PG_EXPORTER_BIN}"
            rm -rf "${tmp_dir}"
            log_info "postgres_exporter installiert: ${PG_EXPORTER_BIN}"
        fi

        # Environment-File mit DATA_SOURCE_NAME (enthält DB-Passwort)
        # Passwort URL-encoden: Sonderzeichen wie / @ : etc. brechen die URI-Syntax
        db_password_encoded="$(printf '%s' "${DB_PASSWORD}" | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')"

        tmp_env="$(mktemp)"
        cat > "${tmp_env}" <<EOF
# postgres_exporter – generiert von 05-setup-monitoring.sh
DATA_SOURCE_NAME=postgresql://${DB_USER}:${db_password_encoded}@127.0.0.1:5432/${DB_NAME}?sslmode=disable
EOF

        pg_env_changed=0
        if [[ -f "${PG_EXPORTER_ENV}" ]] \
            && diff -q "${tmp_env}" "${PG_EXPORTER_ENV}" &>/dev/null; then
            log_info "postgres_exporter Env-Datei bereits aktuell."
            rm -f "${tmp_env}"
        else
            pg_env_changed=1
            if [[ -f "${PG_EXPORTER_ENV}" ]]; then
                backup_file "${PG_EXPORTER_ENV}"
            fi
            mv "${tmp_env}" "${PG_EXPORTER_ENV}"
            chown root:"${PG_EXPORTER_USER}" "${PG_EXPORTER_ENV}"
            chmod 0640 "${PG_EXPORTER_ENV}"
            log_info "postgres_exporter Env-Datei geschrieben: ${PG_EXPORTER_ENV}"
        fi

        # systemd Unit
        readonly PG_EXPORTER_SERVICE="/etc/systemd/system/postgres-exporter.service"
        tmp_unit="$(mktemp)"
        cat > "${tmp_unit}" <<EOF
[Unit]
Description=Prometheus PostgreSQL Exporter
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=exec
User=${PG_EXPORTER_USER}
Group=${PG_EXPORTER_USER}
EnvironmentFile=${PG_EXPORTER_ENV}
ExecStart=${PG_EXPORTER_BIN}
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

        pg_svc_changed=0
        if [[ -f "${PG_EXPORTER_SERVICE}" ]] \
            && diff -q "${tmp_unit}" "${PG_EXPORTER_SERVICE}" &>/dev/null; then
            log_info "postgres-exporter.service bereits aktuell."
            rm -f "${tmp_unit}"
        else
            if [[ -f "${PG_EXPORTER_SERVICE}" ]]; then
                backup_file "${PG_EXPORTER_SERVICE}"
            fi
            mv "${tmp_unit}" "${PG_EXPORTER_SERVICE}"
            chmod 0644 "${PG_EXPORTER_SERVICE}"
            systemctl daemon-reload
            log_info "postgres-exporter.service deployed."
            pg_svc_changed=1
        fi

        ensure_service postgres-exporter

        if [[ $(( pg_svc_changed + pg_env_changed )) -gt 0 ]] \
            && systemctl is-active --quiet postgres-exporter 2>/dev/null; then
            systemctl restart postgres-exporter
            log_info "postgres-exporter neugestartet (Konfiguration geändert)."
        fi
        ;;

    # ==========================================================================
    # lb: nginx-prometheus-exporter
    # ==========================================================================
    lb)
        log_info "--- Schritt 3: nginx-prometheus-exporter ${NGINX_EXPORTER_VERSION} installieren ---"

        ensure_package curl

        # Binary herunterladen und installieren
        if [[ -f "${NGINX_EXPORTER_BIN}" ]]; then
            installed_version="$("${NGINX_EXPORTER_BIN}" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")"
            if [[ "${installed_version}" == "${NGINX_EXPORTER_VERSION}" ]]; then
                log_info "nginx-prometheus-exporter ${NGINX_EXPORTER_VERSION} bereits installiert."
            fi
        fi

        if [[ ! -f "${NGINX_EXPORTER_BIN}" ]] \
            || ! "${NGINX_EXPORTER_BIN}" --version 2>&1 | grep -qF "${NGINX_EXPORTER_VERSION}"; then
            tmp_dir="$(mktemp -d)"
            log_info "Lade nginx-prometheus-exporter ${NGINX_EXPORTER_VERSION} herunter..."
            curl -fsSL --output "${tmp_dir}/nginx_exporter.tar.gz" "${NGINX_EXPORTER_URL}"
            tar -xzf "${tmp_dir}/nginx_exporter.tar.gz" -C "${tmp_dir}"
            install -m 0755 "${tmp_dir}/nginx-prometheus-exporter" "${NGINX_EXPORTER_BIN}"
            rm -rf "${tmp_dir}"
            log_info "nginx-prometheus-exporter installiert: ${NGINX_EXPORTER_BIN}"
        fi

        # systemd Unit
        readonly NGINX_EXPORTER_SERVICE="/etc/systemd/system/nginx-exporter.service"
        tmp_unit="$(mktemp)"
        cat > "${tmp_unit}" <<'EOF'
[Unit]
Description=Prometheus Nginx Exporter
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/nginx-prometheus-exporter \
    -nginx.scrape-uri=http://127.0.0.1/nginx_status
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
DynamicUser=true

[Install]
WantedBy=multi-user.target
EOF

        nginx_svc_changed=0
        if [[ -f "${NGINX_EXPORTER_SERVICE}" ]] \
            && diff -q "${tmp_unit}" "${NGINX_EXPORTER_SERVICE}" &>/dev/null; then
            log_info "nginx-exporter.service bereits aktuell."
            rm -f "${tmp_unit}"
        else
            if [[ -f "${NGINX_EXPORTER_SERVICE}" ]]; then
                backup_file "${NGINX_EXPORTER_SERVICE}"
            fi
            mv "${tmp_unit}" "${NGINX_EXPORTER_SERVICE}"
            chmod 0644 "${NGINX_EXPORTER_SERVICE}"
            systemctl daemon-reload
            log_info "nginx-exporter.service deployed."
            nginx_svc_changed=1
        fi

        ensure_service nginx-exporter

        if [[ "${nginx_svc_changed}" -eq 1 ]] \
            && systemctl is-active --quiet nginx-exporter 2>/dev/null; then
            systemctl restart nginx-exporter
            log_info "nginx-exporter neugestartet (Konfiguration geändert)."
        fi
        ;;

    # ==========================================================================
    # keycloak: nur node_exporter (bereits in Schritt 1 installiert)
    # ==========================================================================
    keycloak)
        log_info "--- Schritt 3: Keycloak Cluster-Metrics Textfile-Collector ---"
        log_info "KC-Metriken sind built-in auf Port ${KC_MGMT_PORT} (/metrics)."

        # Cluster-Membership als Textfile-Metrik exportieren
        ensure_package curl jq

        # Textfile-Collector-Verzeichnis sicherstellen
        mkdir -p /var/lib/prometheus/node-exporter

        # Skript installieren
        if [[ -f "${KC_CLUSTER_METRICS_DST}" ]] \
            && diff -q "${KC_CLUSTER_METRICS_SRC}" "${KC_CLUSTER_METRICS_DST}" &>/dev/null; then
            log_info "keycloak-cluster-metrics.sh bereits aktuell."
        else
            install -m 0755 "${KC_CLUSTER_METRICS_SRC}" "${KC_CLUSTER_METRICS_DST}"
            log_info "keycloak-cluster-metrics.sh installiert: ${KC_CLUSTER_METRICS_DST}"
        fi

        # Cronjob anlegen (jede Minute)
        kc_cron_content="# Keycloak cluster membership metrics for Prometheus textfile collector
* * * * * root ${KC_CLUSTER_METRICS_DST}
"
        if [[ -f "${KC_CLUSTER_CRON}" ]] \
            && printf '%s' "${kc_cron_content}" | diff -q - "${KC_CLUSTER_CRON}" &>/dev/null; then
            log_info "Keycloak-Cluster-Cronjob bereits aktuell."
        else
            printf '%s' "${kc_cron_content}" > "${KC_CLUSTER_CRON}"
            chmod 0644 "${KC_CLUSTER_CRON}"
            log_info "Keycloak-Cluster-Cronjob installiert: ${KC_CLUSTER_CRON}"
        fi

        # Einmal sofort ausführen
        "${KC_CLUSTER_METRICS_DST}" || true
        log_info "Keycloak-Cluster-Metrics initial geschrieben."
        ;;
esac

# ==============================================================================
# Abschluss
# ==============================================================================

log_info "=== Monitoring-Exporter Setup abgeschlossen ==="
log_info "Rolle:          ${vm_role}"
log_info "node_exporter:  $(systemctl is-active prometheus-node-exporter 2>/dev/null || echo 'unbekannt') (:9100)"

case "${vm_role}" in
    db)
        log_info "pg_exporter:    $(systemctl is-active postgres-exporter 2>/dev/null || echo 'unbekannt') (:9187)"
        ;;
    lb)
        log_info "nginx_exporter: $(systemctl is-active nginx-exporter 2>/dev/null || echo 'unbekannt') (:9113)"
        ;;
esac
