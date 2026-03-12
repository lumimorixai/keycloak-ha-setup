#!/usr/bin/env bash
# ==============================================================================
# 02-setup-keycloak.sh – Adoptium JDK 21 + Keycloak HA installieren
#
# Ausführung: auf kc01 UND kc02 (je einzeln; kc01 zuerst wegen DB-Migration)
# Voraussetzung: .env im Repo-Root muss befüllt sein (siehe .env.example)
#
# Was dieses Skript tut (alle Schritte idempotent):
#   1. Adoptium-Repository einrichten und Temurin JDK 21 installieren
#   2. Keycloak-Tarball herunterladen und SHA512 verifizieren
#   3. Archiv entpacken, Symlink /opt/keycloak setzen
#   4. System-User 'keycloak' anlegen
#   5. keycloak.conf aus Template deployen
#   6. /etc/keycloak/env schreiben (JAVA_HOME, JAVA_OPTS_APPEND, Admin-Creds)
#   7. keycloak.service deployen, systemd daemon-reload bei Änderung
#   8. kc.sh build ausführen (nur wenn Config oder Version neu)
#   9. Service aktivieren und starten
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/00-common.sh
source "${SCRIPT_DIR}/00-common.sh"

# ------------------------------------------------------------------------------
# Statische Konstanten (kein .env erforderlich)
# ------------------------------------------------------------------------------
readonly KC_INSTALL_BASE="/opt"
readonly KC_SYMLINK="/opt/keycloak"
readonly KC_USER="keycloak"
readonly KC_GROUP="keycloak"
readonly KC_CONF_DIR="/etc/keycloak"
readonly KC_ENV_FILE="${KC_CONF_DIR}/env"
readonly KC_SERVICE_DST="/etc/systemd/system/keycloak.service"
readonly KC_SERVICE_SRC="${REPO_DIR}/configs/keycloak/keycloak.service"
readonly KC_CONF_TPL="${REPO_DIR}/configs/keycloak/keycloak.conf.tpl"
readonly ADOPTIUM_KEYRING="/usr/share/keyrings/adoptium-keyring.gpg"
readonly ADOPTIUM_SOURCES="/etc/apt/sources.list.d/adoptium.list"

# ==============================================================================
# Voraussetzungen
# ==============================================================================

load_env
require_root

# Abgeleitete Konstanten (benötigen KC_VERSION und JAVA_VERSION aus .env)
readonly KC_INSTALL_DIR="${KC_INSTALL_BASE}/keycloak-${KC_VERSION}"
readonly KC_TARBALL="/tmp/keycloak-${KC_VERSION}.tar.gz"
readonly KC_DOWNLOAD_URL="https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/keycloak-${KC_VERSION}.tar.gz"
readonly KC_CHECKSUM_URL="https://github.com/keycloak/keycloak/releases/download/${KC_VERSION}/keycloak-${KC_VERSION}.tar.gz.sha512"
readonly KC_CONF_DST="${KC_SYMLINK}/conf/keycloak.conf"
readonly KC_BUILD_HASH_FILE="${KC_SYMLINK}/conf/.build-hash"
readonly JAVA_PKG="temurin-${JAVA_VERSION}-jdk"

log_info "=== Keycloak ${KC_VERSION} Setup startet ==="

# ==============================================================================
# Schritt 1/9: Aktuelle Node-IP bestimmen
# ==============================================================================
# Wird für den JGroups TCP Bind-Address in /etc/keycloak/env benötigt.

log_info "--- Schritt 1/9: Node-IP bestimmen ---"

if ip -4 addr show | grep -qF "${KC_NODE1_IP}"; then
    KC_NODE_IP="${KC_NODE1_IP}"
    log_info "Node erkannt: kc01 (${KC_NODE_IP})"
elif ip -4 addr show | grep -qF "${KC_NODE2_IP}"; then
    KC_NODE_IP="${KC_NODE2_IP}"
    log_info "Node erkannt: kc02 (${KC_NODE_IP})"
else
    log_err "Keine der konfigurierten KC-Node-IPs gefunden auf dieser Maschine."
    log_err "  KC_NODE1_IP=${KC_NODE1_IP}"
    log_err "  KC_NODE2_IP=${KC_NODE2_IP}"
    log_err "Stelle sicher, dass das Skript auf kc01 oder kc02 ausgeführt wird."
    exit 1
fi
export KC_NODE_IP

# ==============================================================================
# Schritt 2/9: Adoptium-Repository einrichten und Temurin JDK 21 installieren
# ==============================================================================

log_info "--- Schritt 2/9: Adoptium Temurin JDK ${JAVA_VERSION} installieren ---"

ensure_package curl gnupg

needs_apt_update=0

if [[ ! -f "${ADOPTIUM_KEYRING}" ]]; then
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor -o "${ADOPTIUM_KEYRING}"
    log_info "Adoptium-Signaturschlüssel installiert: ${ADOPTIUM_KEYRING}"
    needs_apt_update=1
else
    log_info "Adoptium-Signaturschlüssel bereits vorhanden: ${ADOPTIUM_KEYRING}"
fi

if [[ ! -f "${ADOPTIUM_SOURCES}" ]]; then
    os_codename="$(lsb_release -cs)"
    printf 'deb [arch=amd64 signed-by=%s] https://packages.adoptium.net/artifactory/deb %s main\n' \
        "${ADOPTIUM_KEYRING}" "${os_codename}" > "${ADOPTIUM_SOURCES}"
    log_info "Adoptium-Repository hinzugefügt: ${ADOPTIUM_SOURCES}"
    needs_apt_update=1
else
    log_info "Adoptium-Repository bereits konfiguriert: ${ADOPTIUM_SOURCES}"
fi

if [[ "${needs_apt_update}" -eq 1 ]]; then
    log_info "apt-get update wird ausgeführt..."
    apt-get update -qq
fi

ensure_package "${JAVA_PKG}"

# JAVA_HOME aus dem tatsächlich installierten Binärpfad ableiten
java_bin="$(readlink -f "$(command -v java)")"
JAVA_HOME_PATH="$(dirname "$(dirname "${java_bin}")")"
log_info "JAVA_HOME erkannt: ${JAVA_HOME_PATH}"

# ==============================================================================
# Schritt 3/9: Keycloak herunterladen und SHA512 verifizieren
# ==============================================================================

log_info "--- Schritt 3/9: Keycloak ${KC_VERSION} herunterladen ---"

if [[ -d "${KC_INSTALL_DIR}" ]]; then
    log_info "Keycloak ${KC_VERSION} bereits installiert: ${KC_INSTALL_DIR}"
else
    log_info "Lade Keycloak ${KC_VERSION} herunter: ${KC_DOWNLOAD_URL}"
    curl -fsSL --output "${KC_TARBALL}" "${KC_DOWNLOAD_URL}"

    log_info "Verifiziere SHA512-Checksumme..."
    expected_sha512="$(curl -fsSL "${KC_CHECKSUM_URL}" | awk '{print $1}')"
    actual_sha512="$(sha512sum "${KC_TARBALL}" | awk '{print $1}')"

    if [[ "${expected_sha512}" != "${actual_sha512}" ]]; then
        log_err "SHA512-Prüfsumme stimmt NICHT überein – Datei möglicherweise beschädigt oder manipuliert!"
        log_err "  Erwartet: ${expected_sha512}"
        log_err "  Ist:      ${actual_sha512}"
        rm -f "${KC_TARBALL}"
        exit 1
    fi
    log_info "SHA512-Checksumme verifiziert."

    tar -xzf "${KC_TARBALL}" -C "${KC_INSTALL_BASE}"
    rm -f "${KC_TARBALL}"
    log_info "Keycloak ${KC_VERSION} entpackt nach: ${KC_INSTALL_DIR}"
fi

# ==============================================================================
# Schritt 4/9: Symlink setzen
# ==============================================================================

log_info "--- Schritt 4/9: Symlink /opt/keycloak setzen ---"

current_target="$(readlink -f "${KC_SYMLINK}" 2>/dev/null || true)"
if [[ "${current_target}" == "${KC_INSTALL_DIR}" ]]; then
    log_info "Symlink bereits korrekt: ${KC_SYMLINK} → ${KC_INSTALL_DIR}"
else
    ln -sfn "${KC_INSTALL_DIR}" "${KC_SYMLINK}"
    log_info "Symlink gesetzt: ${KC_SYMLINK} → ${KC_INSTALL_DIR}"
fi

# ==============================================================================
# Schritt 5/9: System-User 'keycloak' anlegen (idempotent)
# ==============================================================================

log_info "--- Schritt 5/9: System-User '${KC_USER}' anlegen ---"

if id "${KC_USER}" &>/dev/null; then
    log_info "System-User bereits vorhanden: ${KC_USER}"
else
    useradd \
        --system \
        --no-create-home \
        --home-dir "${KC_SYMLINK}" \
        --shell /sbin/nologin \
        --comment "Keycloak Service User" \
        "${KC_USER}"
    log_info "System-User angelegt: ${KC_USER}"
fi

# Verzeichnisse einrichten und Eigentumsrechte setzen
mkdir -p "${KC_SYMLINK}/data"
# chown nur auf die Install-Verzeichnisse, nicht global rekursiv bei jedem Lauf.
# Beim Erst-Install: komplettes Verzeichnis; danach nur data/ (Laufzeit-Schreibzugriff).
if [[ "$(stat -c '%U' "${KC_INSTALL_DIR}")" != "${KC_USER}" ]]; then
    log_info "Eigentumsrechte werden gesetzt (Erstinstallation): ${KC_INSTALL_DIR}"
    chown -R "${KC_USER}:${KC_GROUP}" "${KC_INSTALL_DIR}"
fi
chown "${KC_USER}:${KC_GROUP}" "${KC_SYMLINK}/data"

mkdir -p "${KC_CONF_DIR}"
chown root:root "${KC_CONF_DIR}"
chmod 0755 "${KC_CONF_DIR}"

# ==============================================================================
# Schritt 6/9: keycloak.conf aus Template deployen
# ==============================================================================

log_info "--- Schritt 6/9: keycloak.conf deployen ---"

# Vorab prüfen ob Inhalt sich ändern würde (für gezielten Build-Trigger)
kc_conf_changed=0
if [[ ! -f "${KC_CONF_DST}" ]] \
    || ! diff -q \
        <(envsubst < "${KC_CONF_TPL}") \
        "${KC_CONF_DST}" &>/dev/null; then
    kc_conf_changed=1
fi

deploy_config "${KC_CONF_TPL}" "${KC_CONF_DST}" "${KC_USER}:${KC_GROUP}" "0640"

# ==============================================================================
# Schritt 7/9: /etc/keycloak/env schreiben (JAVA_HOME, JVM-Opts, Admin-Creds)
# ==============================================================================

log_info "--- Schritt 7/9: EnvironmentFile /etc/keycloak/env schreiben ---"

# Hinweis: KEYCLOAK_ADMIN* wird von Keycloak NUR beim ersten Start ausgewertet,
# solange noch kein Admin in der Datenbank existiert. Danach werden die Variablen
# ignoriert – es ist sicher, sie dauerhaft in der Datei zu belassen.
tmp_env="$(mktemp)"
cat > "${tmp_env}" <<EOF
# Keycloak Runtime-Umgebung
# Generiert von 02-setup-keycloak.sh – Nicht manuell bearbeiten.
# Erneutes Ausführen des Setup-Skripts aktualisiert diese Datei.

# Temurin JDK (von kc.sh für den Java-Aufruf genutzt)
JAVA_HOME=${JAVA_HOME_PATH}

# JVM-Heap-Einstellungen + JGroups TCP Bind-Address für JDBC_PING2-Clustering.
# -Djgroups.bind.address muss die IP dieser Node (${KC_NODE_IP}) sein.
JAVA_OPTS_APPEND=${JAVA_OPTS} -Djgroups.bind.address=${KC_NODE_IP} -Djgroups.bind.port=${KC_JGROUPS_PORT}

# Initialer Admin-User (NUR beim allerersten Start ohne Admin in der DB wirksam).
KEYCLOAK_ADMIN=${KC_ADMIN_USER}
KEYCLOAK_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}
EOF

kc_env_changed=0
if [[ -f "${KC_ENV_FILE}" ]] && diff -q "${tmp_env}" "${KC_ENV_FILE}" &>/dev/null; then
    log_info "EnvironmentFile bereits aktuell: ${KC_ENV_FILE}"
    rm -f "${tmp_env}"
else
    if [[ -f "${KC_ENV_FILE}" ]]; then
        backup_file "${KC_ENV_FILE}"
    fi
    mv "${tmp_env}" "${KC_ENV_FILE}"
    chown "${KC_USER}:${KC_GROUP}" "${KC_ENV_FILE}"
    chmod 0600 "${KC_ENV_FILE}"
    log_info "EnvironmentFile geschrieben: ${KC_ENV_FILE}"
    kc_env_changed=1
fi

# ==============================================================================
# Schritt 8/9: keycloak.service deployen
# ==============================================================================

log_info "--- Schritt 8/9: keycloak.service deployen ---"

kc_service_changed=0
if [[ ! -f "${KC_SERVICE_DST}" ]] \
    || ! diff -q "${KC_SERVICE_SRC}" "${KC_SERVICE_DST}" &>/dev/null; then
    if [[ -f "${KC_SERVICE_DST}" ]]; then
        backup_file "${KC_SERVICE_DST}"
    fi
    cp "${KC_SERVICE_SRC}" "${KC_SERVICE_DST}"
    chown root:root "${KC_SERVICE_DST}"
    chmod 0644 "${KC_SERVICE_DST}"
    systemctl daemon-reload
    log_info "keycloak.service deployed und daemon-reload ausgeführt."
    kc_service_changed=1
else
    log_info "keycloak.service bereits aktuell: ${KC_SERVICE_DST}"
fi

# ==============================================================================
# Schritt 9/9: kc.sh build ausführen (nur wenn nötig), dann Service starten
# ==============================================================================

log_info "--- Schritt 9/9: Keycloak Build und Service ---"

# Build ist nötig wenn:
#   a) keycloak.conf wurde geändert oder erstmals deployed
#   b) kein Build-Hash existiert (Erstinstallation oder manuell entfernt)
#   c) gespeicherter Hash weicht von aktuellem Config-Hash ab (Versions-Upgrade)
current_conf_hash="$(sha256sum "${KC_CONF_DST}" | awk '{print $1}')"
stored_hash=""
if [[ -f "${KC_BUILD_HASH_FILE}" ]]; then
    stored_hash="$(cat "${KC_BUILD_HASH_FILE}")"
fi

build_needed=0
if [[ "${kc_conf_changed}" -eq 1 ]] \
    || [[ ! -f "${KC_BUILD_HASH_FILE}" ]] \
    || [[ "${stored_hash}" != "${current_conf_hash}" ]]; then
    build_needed=1
fi

if [[ "${build_needed}" -eq 1 ]]; then
    log_info "Build wird ausgeführt (Config geändert oder Erstinstallation)."

    # Service stoppen falls aktiv (Build darf nicht während des Betriebs laufen)
    if systemctl is-active --quiet keycloak 2>/dev/null; then
        systemctl stop keycloak
        log_info "Keycloak gestoppt für Build."
    fi

    # Build als keycloak-User ausführen (der Install-Dir gehört ihm)
    sudo -u "${KC_USER}" \
        env "JAVA_HOME=${JAVA_HOME_PATH}" \
        "${KC_SYMLINK}/bin/kc.sh" build
    log_info "kc.sh build abgeschlossen."

    # Hash nach erfolgreichem Build speichern
    echo "${current_conf_hash}" > "${KC_BUILD_HASH_FILE}"
    chown "${KC_USER}:${KC_GROUP}" "${KC_BUILD_HASH_FILE}"
    log_info "Build-Hash gespeichert: ${KC_BUILD_HASH_FILE}"
else
    log_info "Build nicht nötig – Config unverändert (Hash: ${current_conf_hash:0:12}...)."
fi

# Neustart bestimmen: nötig wenn Service-Unit, Env-Datei oder Build geändert
kc_restart_needed=$(( build_needed + kc_service_changed + kc_env_changed ))

if systemctl is-active --quiet keycloak 2>/dev/null; then
    if [[ "${kc_restart_needed}" -gt 0 ]]; then
        systemctl restart keycloak
        log_info "Keycloak neugestartet (Konfiguration geändert)."
    else
        log_info "Keycloak bereits aktiv, kein Neustart notwendig."
    fi
else
    ensure_service keycloak
fi

# ==============================================================================
# Abschluss
# ==============================================================================

log_info "=== Keycloak ${KC_VERSION} Setup abgeschlossen ==="
log_info "Node:        ${KC_NODE_IP}"
log_info "Version:     ${KC_VERSION}"
log_info "Install-Dir: ${KC_INSTALL_DIR}"
log_info "Config:      ${KC_CONF_DST}"
log_info "Service:     keycloak ($(systemctl is-active keycloak 2>/dev/null || echo 'unbekannt'))"
log_info ""
log_info "HINWEIS: kc01 zuerst starten und auf /health/ready warten, dann kc02 starten."
log_info "         Reihenfolge verhindert Race-Condition bei der Keycloak-DB-Migration."
