#!/usr/bin/env bash
# ==============================================================================
# 03-setup-nginx.sh – Nginx + Certbot installieren und für Keycloak konfigurieren
#
# Ausführung: auf lb01
# Voraussetzung: .env im Repo-Root muss befüllt sein (siehe .env.example)
#                DNS muss auf lb01 zeigen (Certbot-Voraussetzung)
#
# Was dieses Skript tut (alle Schritte idempotent):
#   1. Nginx und Certbot (certbot + python3-certbot-nginx) installieren
#   2. Certbot Webroot-Verzeichnis anlegen
#   3. Nginx vHost aus Template deployen, Syntax prüfen, Nginx neu laden
#   4. TLS-Zertifikat via Certbot beantragen (nur falls noch nicht vorhanden)
#   5. Automatische Zertifikat-Erneuerung via systemd-Timer prüfen/einrichten
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/00-common.sh
source "${SCRIPT_DIR}/00-common.sh"

# ------------------------------------------------------------------------------
# Konstanten
# ------------------------------------------------------------------------------
readonly NGINX_VHOST_TPL="${REPO_DIR}/configs/nginx/keycloak.conf.tpl"
# nginx.org-Paket nutzt conf.d/ (kein sites-available/sites-enabled wie beim Debian-Paket)
readonly NGINX_VHOST_DST="/etc/nginx/conf.d/keycloak.conf"
readonly NGINX_DEFAULT_CONF="/etc/nginx/conf.d/default.conf"
readonly CERTBOT_WEBROOT="/var/www/certbot"
readonly CERT_DIR="/etc/letsencrypt/live"
readonly NGINX_KEYRING="/usr/share/keyrings/nginx-keyring.gpg"
readonly NGINX_SOURCES="/etc/apt/sources.list.d/nginx.list"

# ==============================================================================
# Voraussetzungen
# ==============================================================================

load_env
require_root

log_info "=== Nginx + Certbot Setup startet ==="

# ==============================================================================
# Schritt 1/5: Nginx aus offiziellem nginx.org-Repo + Certbot installieren
# ==============================================================================
# Das Debian-Standard-Paket ist oft deutlich älter. Das offizielle Repo liefert
# aktuelle Stable-Releases mit allen Security-Fixes.

log_info "--- Schritt 1/5: Nginx (nginx.org) + Certbot installieren ---"

ensure_package curl gnupg

needs_apt_update=0

if [[ ! -f "${NGINX_KEYRING}" ]]; then
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o "${NGINX_KEYRING}"
    log_info "Nginx-Signaturschlüssel installiert: ${NGINX_KEYRING}"
    needs_apt_update=1
else
    log_info "Nginx-Signaturschlüssel bereits vorhanden: ${NGINX_KEYRING}"
fi

if [[ ! -f "${NGINX_SOURCES}" ]]; then
    os_codename="$(lsb_release -cs)"
    printf 'deb [signed-by=%s] https://nginx.org/packages/debian %s nginx\n' \
        "${NGINX_KEYRING}" "${os_codename}" > "${NGINX_SOURCES}"
    # Das offizielle Repo soll das Debian-Paket vorrangig bedienen
    printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 901\n' \
        > /etc/apt/preferences.d/99nginx
    log_info "Nginx-Repository (nginx.org) hinzugefügt: ${NGINX_SOURCES}"
    needs_apt_update=1
else
    log_info "Nginx-Repository bereits konfiguriert: ${NGINX_SOURCES}"
fi

if [[ "${needs_apt_update}" -eq 1 ]]; then
    apt-get update -qq
fi

ensure_package nginx certbot python3-certbot-nginx

# ==============================================================================
# Schritt 2/5: Certbot Webroot-Verzeichnis anlegen
# ==============================================================================

log_info "--- Schritt 2/5: Certbot Webroot-Verzeichnis anlegen ---"

if [[ ! -d "${CERTBOT_WEBROOT}" ]]; then
    mkdir -p "${CERTBOT_WEBROOT}"
    chown www-data:www-data "${CERTBOT_WEBROOT}"
    chmod 0755 "${CERTBOT_WEBROOT}"
    log_info "Certbot Webroot-Verzeichnis angelegt: ${CERTBOT_WEBROOT}"
else
    log_info "Certbot Webroot-Verzeichnis bereits vorhanden: ${CERTBOT_WEBROOT}"
fi

# ==============================================================================
# Schritt 3/5: Nginx vHost aus Template deployen
# ==============================================================================

log_info "--- Schritt 3/5: Nginx vHost deployen ---"

# Default-vHost entfernen (nginx.org-Paket legt default.conf in conf.d/ an)
if [[ -f "${NGINX_DEFAULT_CONF}" ]]; then
    rm -f "${NGINX_DEFAULT_CONF}"
    log_info "Default-vHost entfernt: ${NGINX_DEFAULT_CONF}"
else
    log_info "Default-vHost bereits entfernt."
fi

# Nur die tatsächlichen Shell-Variablen substituieren – nginx-Variablen wie
# $http_upgrade oder $connection_upgrade dürfen NICHT durch envsubst ersetzt werden.
readonly NGINX_ENVSUBST_VARS='${KC_DOMAIN} ${KC_NODE1_IP} ${KC_NODE2_IP} ${KC_HTTP_PORT} ${KC_MGMT_PORT}'

nginx_changed=0
if [[ ! -f "${NGINX_VHOST_DST}" ]] \
    || ! diff -q \
        <(envsubst "${NGINX_ENVSUBST_VARS}" < "${NGINX_VHOST_TPL}") \
        "${NGINX_VHOST_DST}" &>/dev/null; then
    nginx_changed=1
fi

deploy_config "${NGINX_VHOST_TPL}" "${NGINX_VHOST_DST}" "root:root" "0644" "${NGINX_ENVSUBST_VARS}"

# Nginx-Syntax prüfen
log_info "Nginx-Konfiguration wird geprüft..."
nginx -t
log_info "Nginx-Syntax OK."

# Nginx neu laden (nur bei Änderungen oder falls nicht aktiv)
if systemctl is-active --quiet nginx; then
    if [[ "${nginx_changed}" -eq 1 ]]; then
        systemctl reload nginx
        log_info "Nginx neu geladen (Konfiguration geändert)."
    else
        log_info "Nginx läuft, keine Änderungen – kein Reload nötig."
    fi
else
    ensure_service nginx
fi

# ==============================================================================
# Schritt 4/5: TLS-Zertifikat via Certbot beantragen
# ==============================================================================

log_info "--- Schritt 4/5: TLS-Zertifikat beantragen ---"

cert_path="${CERT_DIR}/${KC_DOMAIN}/fullchain.pem"

if [[ -f "${cert_path}" ]]; then
    log_info "TLS-Zertifikat bereits vorhanden: ${cert_path}"
else
    log_info "Beantrage Let's Encrypt Zertifikat für: ${KC_DOMAIN}"
    log_info "HINWEIS: Stelle sicher, dass DNS für ${KC_DOMAIN} auf diese IP zeigt."
    log_info "         Rate-Limit: max 5 Produktiv-Zertifikate pro Domain pro Woche."
    log_info "         Für Tests: --staging Flag verwenden."

    # Prüfen ob --staging-Flag via Umgebungsvariable gesetzt
    certbot_staging_flag=""
    if [[ "${CERTBOT_STAGING:-0}" == "1" ]]; then
        certbot_staging_flag="--staging"
        log_warn "Staging-Modus aktiv (CERTBOT_STAGING=1) – Zertifikat nicht für Produktion geeignet."
    fi

    certbot certonly \
        --webroot \
        --webroot-path "${CERTBOT_WEBROOT}" \
        --non-interactive \
        --agree-tos \
        --email "${ACME_EMAIL}" \
        --domain "${KC_DOMAIN}" \
        ${certbot_staging_flag:+"${certbot_staging_flag}"}

    log_info "TLS-Zertifikat erfolgreich beantragt: ${cert_path}"

    # Nginx mit vollem TLS-Config neu laden
    nginx -t
    systemctl reload nginx
    log_info "Nginx mit TLS-Konfiguration neu geladen."
fi

# ==============================================================================
# Schritt 5/5: Automatische Zertifikat-Erneuerung prüfen
# ==============================================================================

log_info "--- Schritt 5/5: Certbot Auto-Renewal prüfen ---"

# Certbot richtet via apt automatisch einen systemd-Timer ein.
# Wir prüfen nur ob er aktiv ist und loggen den Status.
if systemctl is-active --quiet certbot.timer 2>/dev/null; then
    log_info "Certbot systemd-Timer aktiv (automatische Erneuerung gewährleistet)."
elif systemctl list-unit-files certbot.timer &>/dev/null; then
    systemctl enable --now certbot.timer
    log_info "Certbot systemd-Timer aktiviert."
else
    # Fallback: Cron-Job prüfen (ältere certbot-Versionen nutzen Cron)
    if [[ -f /etc/cron.d/certbot ]]; then
        log_info "Certbot Cron-Job vorhanden: /etc/cron.d/certbot"
    else
        log_warn "Kein Certbot-Timer und kein Cron-Job gefunden!"
        log_warn "Bitte manuell einen Renewal-Mechanismus einrichten:"
        log_warn "  certbot renew --dry-run  (zum Testen)"
    fi
fi

# Dry-Run des Renewals testen (prüft Konfiguration ohne Zertifikat-Anfrage)
log_info "Certbot Renewal-Konfiguration wird geprüft (dry-run)..."
certbot renew --dry-run --quiet 2>&1 | while IFS= read -r line; do
    log_info "  certbot: ${line}"
done
log_info "Certbot Renewal-Dry-Run erfolgreich."

# ==============================================================================
# Abschluss
# ==============================================================================

log_info "=== Nginx + Certbot Setup abgeschlossen ==="
log_info "Domain:      https://${KC_DOMAIN}"
log_info "Zertifikat:  ${cert_path}"
log_info "Nginx:       $(systemctl is-active nginx 2>/dev/null || echo 'unbekannt')"
log_info "Backend:     ${KC_NODE1_IP}:${KC_HTTP_PORT}, ${KC_NODE2_IP}:${KC_HTTP_PORT}"
