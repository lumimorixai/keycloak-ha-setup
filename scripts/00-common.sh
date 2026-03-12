#!/usr/bin/env bash
# ==============================================================================
# 00-common.sh – Shared Helper-Funktionen für alle Setup-Skripte
#
# Verwendung: source "$(dirname "$0")/00-common.sh"
#
# Bereitgestellte Funktionen:
#   load_env        – .env laden, Pflichtfelder prüfen
#   require_root    – Root/sudo prüfen
#   ensure_package  – apt install idempotent
#   deploy_config   – Template → Ziel via envsubst, Backup anlegen
#   ensure_service  – systemctl enable+start idempotent
#   backup_file     – Timestamped Backup anlegen
#   log_info        – [INFO] Logging auf stdout
#   log_warn        – [WARN] Logging auf stderr
#   log_err         – [ERR]  Logging auf stderr
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log_info() {
    printf '[INFO] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_warn() {
    printf '[WARN] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

log_err() {
    printf '[ERR]  %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# ------------------------------------------------------------------------------
# load_env – Lädt .env aus dem Repo-Root (ein Verzeichnis über scripts/)
#
# Sucht .env relativ zum Skript-Verzeichnis: ../  (Repo-Root)
# Pflichtfelder werden geprüft; fehlt eines, bricht das Skript ab.
#
# Verwendung: load_env
# ------------------------------------------------------------------------------
load_env() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    local env_file="${script_dir}/../.env"

    if [[ ! -f "${env_file}" ]]; then
        log_err ".env nicht gefunden: ${env_file}"
        log_err "Kopiere .env.example nach .env und befülle alle Pflichtfelder."
        exit 1
    fi

    # set -a exportiert alle Variablen automatisch, damit envsubst (Kindprozess
    # in deploy_config) die Werte sehen kann. set +a stellt den Zustand danach zurück.
    set -a
    # shellcheck source=/dev/null
    source "${env_file}"
    set +a
    log_info ".env geladen aus: ${env_file}"

    # Pflichtfelder prüfen
    local required_vars=(
        KC_DOMAIN
        ACME_EMAIL
        DB_HOST
        KC_NODE1_IP
        KC_NODE2_IP
        LB_HOST
        DB_NAME
        DB_USER
        DB_PASSWORD
        KC_VERSION
        KC_ADMIN_USER
        KC_ADMIN_PASSWORD
        KC_HTTP_PORT
        KC_JGROUPS_PORT
        JAVA_VERSION
        JAVA_OPTS
        SSH_PORT
    )

    local missing=0
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_err "Pflichtfeld nicht gesetzt oder leer: ${var}"
            missing=1
        fi
    done

    if [[ "${missing}" -eq 1 ]]; then
        log_err "Bitte alle Pflichtfelder in .env befüllen."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# require_root – Prüft, ob das Skript als root ausgeführt wird
#
# Verwendung: require_root
# ------------------------------------------------------------------------------
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "Dieses Skript muss als root ausgeführt werden (sudo ${0})."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# ensure_package – Installiert ein Paket nur wenn noch nicht vorhanden
#
# Verwendung: ensure_package <paketname> [<paketname> ...]
# ------------------------------------------------------------------------------
ensure_package() {
    local packages=("$@")
    local to_install=()

    for pkg in "${packages[@]}"; do
        if dpkg -s "${pkg}" &>/dev/null; then
            log_info "Paket bereits installiert: ${pkg}"
        else
            log_info "Paket wird installiert: ${pkg}"
            to_install+=("${pkg}")
        fi
    done

    if [[ "${#to_install[@]}" -gt 0 ]]; then
        apt-get install -y "${to_install[@]}"
    fi
}

# ------------------------------------------------------------------------------
# backup_file – Erstellt ein Backup einer Datei mit Timestamp
#
# Verwendung: backup_file <pfad>
# Gibt den Backup-Pfad auf stdout aus.
# ------------------------------------------------------------------------------
backup_file() {
    local target="${1}"

    if [[ ! -f "${target}" ]]; then
        log_warn "backup_file: Datei existiert nicht, kein Backup nötig: ${target}"
        return 0
    fi

    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    local backup_path="${target}.bak.${timestamp}"

    cp -p "${target}" "${backup_path}"
    log_info "Backup erstellt: ${backup_path}"
    printf '%s\n' "${backup_path}"
}

# ------------------------------------------------------------------------------
# deploy_config – Deployed ein Template via envsubst ans Ziel
#
# Liest das Template, ersetzt ${VARIABLE}-Platzhalter mit den aktuellen
# Umgebungsvariablen, und schreibt das Ergebnis ans Ziel.
# Falls die Zieldatei bereits existiert und identisch ist, wird nichts getan.
# Falls die Zieldatei existiert und abweicht, wird zuerst ein Backup erstellt.
#
# Verwendung: deploy_config <template> <ziel> [<owner:group>] [<mode>]
#   template  – Pfad zur .tpl-Datei
#   ziel      – Ziel-Pfad der fertigen Config
#   owner     – optional: chown owner:group (z.B. "keycloak:keycloak")
#   mode      – optional: chmod (z.B. "0640")
# ------------------------------------------------------------------------------
deploy_config() {
    local template="${1}"
    local target="${2}"
    local owner="${3:-}"
    local mode="${4:-}"

    if [[ ! -f "${template}" ]]; then
        log_err "deploy_config: Template nicht gefunden: ${template}"
        exit 1
    fi

    # Envsubst auf Template anwenden → temporäre Datei
    local tmp_file
    tmp_file="$(mktemp)"
    envsubst < "${template}" > "${tmp_file}"

    # Zieldatei existiert und ist identisch → nichts tun
    if [[ -f "${target}" ]] && diff -q "${tmp_file}" "${target}" &>/dev/null; then
        log_info "Config bereits aktuell, kein Deployment nötig: ${target}"
        rm -f "${tmp_file}"
        return 0
    fi

    # Backup anlegen falls Ziel existiert
    if [[ -f "${target}" ]]; then
        backup_file "${target}"
    fi

    # Zielverzeichnis ggf. anlegen
    local target_dir
    target_dir="$(dirname "${target}")"
    if [[ ! -d "${target_dir}" ]]; then
        mkdir -p "${target_dir}"
        log_info "Verzeichnis erstellt: ${target_dir}"
    fi

    # Config deployen
    mv "${tmp_file}" "${target}"
    log_info "Config deployed: ${template} → ${target}"

    # Berechtigungen setzen
    if [[ -n "${owner}" ]]; then
        chown "${owner}" "${target}"
        log_info "Owner gesetzt: ${owner} für ${target}"
    fi
    if [[ -n "${mode}" ]]; then
        chmod "${mode}" "${target}"
        log_info "Modus gesetzt: ${mode} für ${target}"
    fi
}

# ------------------------------------------------------------------------------
# ensure_service – Aktiviert und startet einen systemd-Service idempotent
#
# Führt `systemctl enable` und `systemctl start` nur aus, wenn der Service
# nicht bereits enabled/active ist.
#
# Verwendung: ensure_service <service-name>
# ------------------------------------------------------------------------------
ensure_service() {
    local service="${1}"

    # Enable (idempotent: systemctl enable ist selbst idempotent, aber wir loggen)
    if systemctl is-enabled --quiet "${service}" 2>/dev/null; then
        log_info "Service bereits enabled: ${service}"
    else
        systemctl enable "${service}"
        log_info "Service enabled: ${service}"
    fi

    # Start
    if systemctl is-active --quiet "${service}" 2>/dev/null; then
        log_info "Service bereits aktiv: ${service}"
    else
        systemctl start "${service}"
        log_info "Service gestartet: ${service}"
    fi
}

# ------------------------------------------------------------------------------
# Hinweis für direkte Ausführung
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_err "00-common.sh ist eine Bibliothek und wird nicht direkt ausgeführt."
    log_err "Verwende: source \"\$(dirname \"\$0\")/00-common.sh\""
    exit 1
fi
