#!/usr/bin/env bash
# ==============================================================================
# 01-setup-db.sh – PostgreSQL 16 installieren und für Keycloak konfigurieren
#
# Ausführung: auf db01
# Voraussetzung: .env im Repo-Root muss befüllt sein (siehe .env.example)
#
# Was dieses Skript tut (alle Schritte idempotent):
#   1. PGDG-Repository und Signaturschlüssel einrichten
#   2. PostgreSQL 16 installieren
#   3. Service aktivieren und starten
#   4. listen_addresses auf DB_HOST setzen, bei Änderung neustarten
#   5. DB-User und Datenbank für Keycloak anlegen
#   6. pg_hba.conf aus Template deployen, bei Änderung reloaden
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/00-common.sh
source "${SCRIPT_DIR}/00-common.sh"

# ------------------------------------------------------------------------------
# Konstanten
# ------------------------------------------------------------------------------
readonly PG_VERSION=16
readonly PG_KEYRING="/usr/share/keyrings/postgresql-keyring.gpg"
readonly PG_SOURCES_LIST="/etc/apt/sources.list.d/pgdg.list"
readonly PG_SERVICE="postgresql@${PG_VERSION}-main"
readonly PG_HBA_CONF="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
readonly PG_HBA_TPL="${REPO_DIR}/configs/postgresql/pg_hba.conf.tpl"

# ==============================================================================
# Voraussetzungen
# ==============================================================================

load_env
require_root

log_info "=== PostgreSQL ${PG_VERSION} Setup startet ==="

# ==============================================================================
# Schritt 1/5: PGDG-Repository einrichten (idempotent)
# ==============================================================================

log_info "--- Schritt 1/5: PGDG-Repository prüfen ---"

ensure_package curl gnupg

needs_apt_update=0

if [[ ! -f "${PG_KEYRING}" ]]; then
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o "${PG_KEYRING}"
    log_info "PGDG-Signaturschlüssel installiert: ${PG_KEYRING}"
    needs_apt_update=1
else
    log_info "PGDG-Signaturschlüssel bereits vorhanden: ${PG_KEYRING}"
fi

if [[ ! -f "${PG_SOURCES_LIST}" ]]; then
    os_codename="$(lsb_release -cs)"
    printf 'deb [signed-by=%s] http://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' \
        "${PG_KEYRING}" "${os_codename}" > "${PG_SOURCES_LIST}"
    log_info "PGDG-Repository hinzugefügt: ${PG_SOURCES_LIST}"
    needs_apt_update=1
else
    log_info "PGDG-Repository bereits konfiguriert: ${PG_SOURCES_LIST}"
fi

if [[ "${needs_apt_update}" -eq 1 ]]; then
    log_info "apt-get update wird ausgeführt..."
    apt-get update -qq
fi

# ==============================================================================
# Schritt 2/5: PostgreSQL 16 installieren (idempotent via ensure_package)
# ==============================================================================

log_info "--- Schritt 2/5: PostgreSQL ${PG_VERSION} installieren ---"
ensure_package "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"

# ==============================================================================
# Schritt 3/5: Service aktivieren und starten (idempotent)
# ==============================================================================

log_info "--- Schritt 3/5: PostgreSQL-Service aktivieren ---"
ensure_service "${PG_SERVICE}"

# ==============================================================================
# Schritt 4/6: listen_addresses auf DB_HOST setzen (idempotent)
# ==============================================================================
# PostgreSQL lauscht standardmäßig nur auf 127.0.0.1. Damit Keycloak-Nodes
# von außen verbinden können, muss DB_HOST als zusätzliche Adresse eingetragen
# werden. ALTER SYSTEM schreibt in postgresql.auto.conf (Vorrang vor postgresql.conf).
# Änderung erfordert Restart (kein Reload).

log_info "--- Schritt 4/6: listen_addresses konfigurieren ---"

current_listen="$(sudo -u postgres psql -Atc \
    "SELECT setting FROM pg_settings WHERE name = 'listen_addresses'" 2>/dev/null || true)"
desired_listen="${DB_HOST},127.0.0.1"

if [[ "${current_listen}" == "${desired_listen}" ]]; then
    log_info "listen_addresses bereits korrekt: ${current_listen}"
else
    sudo -u postgres psql -c \
        "ALTER SYSTEM SET listen_addresses TO '${desired_listen}';"
    log_info "listen_addresses gesetzt: ${desired_listen} – PostgreSQL wird neugestartet."
    systemctl restart "${PG_SERVICE}"
    log_info "PostgreSQL neugestartet."
fi

# ==============================================================================
# Schritt 5/6: Keycloak DB-User und Datenbank anlegen (idempotent)
# ==============================================================================

log_info "--- Schritt 5/6: DB-User '${DB_USER}' und Datenbank '${DB_NAME}' anlegen ---"

# DB-User anlegen: prüfen ob rolname bereits existiert
user_exists="$(sudo -u postgres psql -Atc \
    "SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}'" 2>/dev/null || true)"

if [[ "${user_exists}" == "1" ]]; then
    log_info "DB-User bereits vorhanden: ${DB_USER}"
else
    # Passwort über stdin übergeben, um es nicht in der Prozessliste zu exponieren
    sudo -u postgres psql -c \
        "CREATE ROLE \"${DB_USER}\" WITH LOGIN PASSWORD '${DB_PASSWORD}';"
    log_info "DB-User angelegt: ${DB_USER}"
fi

# Datenbank anlegen: prüfen ob datname bereits existiert
db_exists="$(sudo -u postgres psql -Atc \
    "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'" 2>/dev/null || true)"

if [[ "${db_exists}" == "1" ]]; then
    log_info "Datenbank bereits vorhanden: ${DB_NAME}"
else
    sudo -u postgres psql -c \
        "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\" ENCODING 'UTF8' TEMPLATE template0;"
    log_info "Datenbank angelegt: ${DB_NAME}"
fi

# ==============================================================================
# Schritt 6/6: pg_hba.conf deployen (idempotent, Reload nur bei Änderung)
# ==============================================================================

log_info "--- Schritt 6/6: pg_hba.conf aus Template deployen ---"

if [[ ! -f "${PG_HBA_TPL}" ]]; then
    log_err "Template nicht gefunden: ${PG_HBA_TPL}"
    exit 1
fi

# Vorab prüfen ob sich der Zielinhalt ändern würde (für gezielten Reload)
hba_changed=0
if [[ ! -f "${PG_HBA_CONF}" ]] \
    || ! diff -q \
        <(envsubst < "${PG_HBA_TPL}") \
        "${PG_HBA_CONF}" &>/dev/null; then
    hba_changed=1
fi

deploy_config "${PG_HBA_TPL}" "${PG_HBA_CONF}" "postgres:postgres" "0640"

if [[ "${hba_changed}" -eq 1 ]]; then
    log_info "pg_hba.conf geändert – PostgreSQL wird neu geladen (reload, keine Verbindungsunterbrechung)."
    systemctl reload "${PG_SERVICE}"
    log_info "PostgreSQL erfolgreich neu geladen."
else
    log_info "pg_hba.conf unverändert – kein Reload notwendig."
fi

# ==============================================================================
# Abschluss
# ==============================================================================

log_info "=== PostgreSQL ${PG_VERSION} Setup abgeschlossen ==="
log_info "listen_addresses: ${desired_listen}"
log_info "DB-Host:     ${DB_HOST}:5432"
log_info "Datenbank:   ${DB_NAME}"
log_info "DB-User:     ${DB_USER}"
log_info "Service:     ${PG_SERVICE} ($(systemctl is-active "${PG_SERVICE}" 2>/dev/null || echo 'unbekannt'))"
