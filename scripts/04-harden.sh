#!/usr/bin/env bash
# ==============================================================================
# 04-harden.sh – System-Hardening: UFW + SSH + Fail2ban + Unattended-Upgrades
#
# Ausführung: auf ALLEN VMs (db01, kc01, kc02, lb01)
# Voraussetzung: .env im Repo-Root muss befüllt sein (siehe .env.example)
#
# Verwendung:
#   sudo scripts/04-harden.sh <vm-typ>
#
# vm-typ (Pflichtparameter):
#   db        – Datenbankserver (db01): PostgreSQL-Port von KC-Nodes erlauben
#   keycloak  – Keycloak-Node (kc01/kc02): HTTP von lb01, JGroups zwischen Nodes
#   lb        – Load Balancer (lb01): HTTP+HTTPS von allen, Nginx-Fail2ban-Jails
#
# Was dieses Skript tut (alle Schritte idempotent):
#   1. Pakete installieren (ufw, fail2ban, unattended-upgrades)
#   2. UFW-Standardpolitik und rollenspezifische Regeln setzen
#   3. SSH-Hardening (Drop-in sshd_config.d, Port aus .env)
#   4. Fail2ban konfigurieren (SSH überall, Nginx-Jails auf lb)
#   5. Unattended-Upgrades konfigurieren (Security-Updates automatisch)
#   6. Services aktivieren / neu starten
#
# WARNUNG: Stelle sicher, dass SSH_PORT korrekt gesetzt ist und ein SSH-Schlüssel
#          hinterlegt ist, BEVOR PasswordAuthentication deaktiviert wird.
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
    printf '  db        – Datenbankserver (db01)\n'
    printf '  keycloak  – Keycloak-Node  (kc01 oder kc02)\n'
    printf '  lb        – Load Balancer  (lb01)\n'
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
# Voraussetzungen
# ==============================================================================

load_env
require_root

log_info "=== System-Hardening startet (Rolle: ${vm_role}) ==="

# ==============================================================================
# Schritt 1/6: Pakete installieren
# ==============================================================================

log_info "--- Schritt 1/6: Pakete installieren ---"

ensure_package ufw fail2ban unattended-upgrades apt-listchanges

# ==============================================================================
# Schritt 2/6: UFW-Regeln setzen (rollenbasiert)
# ==============================================================================

log_info "--- Schritt 2/6: UFW-Regeln konfigurieren (Rolle: ${vm_role}) ---"

# Standardpolitik: eingehend ablehnen, ausgehend erlauben.
# --force verhindert interaktive Rückfrage.
ufw --force default deny incoming
ufw --force default allow outgoing
log_info "UFW-Standardpolitik: deny incoming, allow outgoing"

# SSH auf allen VMs erlauben (Port aus .env).
# ufw allow ist idempotent – fügt dieselbe Regel nicht doppelt ein.
if [[ -n "${ADMIN_IPS:-}" ]]; then
    IFS=',' read -ra admin_ip_list <<< "${ADMIN_IPS}"
    for admin_ip in "${admin_ip_list[@]}"; do
        admin_ip="${admin_ip// /}"
        ufw allow from "${admin_ip}" to any port "${SSH_PORT}" proto tcp \
            comment "SSH Admin"
        log_info "SSH-Zugriff erlaubt von Admin-IP: ${admin_ip}:${SSH_PORT}"
    done
else
    ufw allow "${SSH_PORT}/tcp" comment "SSH"
    log_info "SSH-Zugriff erlaubt: Port ${SSH_PORT}/tcp (alle IPs)"
fi

# Rollenspezifische Regeln
case "${vm_role}" in
    db)
        log_info "UFW: Regeln für db (PostgreSQL)"
        for kc_ip in "${KC_NODE1_IP}" "${KC_NODE2_IP}"; do
            ufw allow from "${kc_ip}" to any port 5432 proto tcp \
                comment "PostgreSQL von ${kc_ip}"
            log_info "PostgreSQL-Zugriff erlaubt von: ${kc_ip}:5432"
        done
        ;;

    keycloak)
        log_info "UFW: Regeln für keycloak"
        # HTTP vom Load Balancer
        ufw allow from "${LB_HOST}" to any port "${KC_HTTP_PORT}" proto tcp \
            comment "Keycloak HTTP von lb01"
        log_info "Keycloak HTTP-Zugriff erlaubt von lb01 (${LB_HOST}:${KC_HTTP_PORT})"

        # JGroups TCP zwischen kc01 und kc02 (bidirektional).
        # Beide IPs bekommen die Regel – kein separates Skript pro Node nötig.
        for peer_ip in "${KC_NODE1_IP}" "${KC_NODE2_IP}"; do
            ufw allow from "${peer_ip}" to any port "${KC_JGROUPS_PORT}" proto tcp \
                comment "JGroups TCP von ${peer_ip}"
            log_info "JGroups TCP-Zugriff erlaubt von: ${peer_ip}:${KC_JGROUPS_PORT}"
        done
        ;;

    lb)
        log_info "UFW: Regeln für lb (Load Balancer)"
        ufw allow 80/tcp  comment "HTTP (ACME Challenge)"
        ufw allow 443/tcp comment "HTTPS"
        log_info "HTTP Port 80 und HTTPS Port 443 erlaubt (alle IPs)"
        ;;
esac

# UFW aktivieren bzw. Regeln neu laden
if ufw status | grep -q "Status: active"; then
    ufw reload
    log_info "UFW-Regeln neu geladen."
else
    ufw --force enable
    log_info "UFW aktiviert."
fi

# ==============================================================================
# Schritt 3/6: SSH-Hardening
# ==============================================================================

log_info "--- Schritt 3/6: SSH-Hardening ---"

# Drop-in-Datei unter sshd_config.d/ (ab OpenSSH 8.2 / Debian 10+).
# Überschreibt Werte aus /etc/ssh/sshd_config ohne diese zu modifizieren.
readonly SSHD_HARDENING_CONF="/etc/ssh/sshd_config.d/99-keycloak-hardening.conf"

tmp_sshd="$(mktemp)"
cat > "${tmp_sshd}" <<EOF
# Keycloak HA Hardening – generiert von 04-harden.sh
# Nicht manuell bearbeiten; erneutes Ausführen des Skripts aktualisiert diese Datei.

# SSH-Port (aus .env: SSH_PORT)
Port ${SSH_PORT}

# Nur Public-Key-Auth (Passwort-Auth und Challenge-Response deaktiviert)
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes

# Root-Login und leere Passwörter verbieten
PermitRootLogin no
PermitEmptyPasswords no

# Inaktive Sessions nach 5 Minuten trennen (2 * 150s)
ClientAliveInterval 150
ClientAliveCountMax 2

# Login-Timeout und Auth-Versuche begrenzen (Ergänzung zu Fail2ban)
LoginGraceTime 30
MaxAuthTries 4

# X11-Forwarding deaktivieren (nicht benötigt auf Server-VMs)
X11Forwarding no
EOF

sshd_changed=0
if [[ -f "${SSHD_HARDENING_CONF}" ]] \
    && diff -q "${tmp_sshd}" "${SSHD_HARDENING_CONF}" &>/dev/null; then
    log_info "SSH-Hardening-Konfiguration bereits aktuell: ${SSHD_HARDENING_CONF}"
    rm -f "${tmp_sshd}"
else
    if [[ -f "${SSHD_HARDENING_CONF}" ]]; then
        backup_file "${SSHD_HARDENING_CONF}"
    fi
    mv "${tmp_sshd}" "${SSHD_HARDENING_CONF}"
    chmod 0600 "${SSHD_HARDENING_CONF}"
    chown root:root "${SSHD_HARDENING_CONF}"
    log_info "SSH-Hardening-Konfiguration geschrieben: ${SSHD_HARDENING_CONF}"
    sshd_changed=1
fi

# Konfiguration validieren, bevor wir reloaden (verhindert Aussperren)
if ! sshd -t; then
    log_err "SSH-Konfiguration ungültig! Änderung wird rückgängig gemacht."
    rm -f "${SSHD_HARDENING_CONF}"
    exit 1
fi
log_info "SSH-Konfiguration validiert (sshd -t OK)."

if [[ "${sshd_changed}" -eq 1 ]]; then
    # Debian 13+: ssh.service; ältere: sshd.service
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    log_info "SSH-Daemon neu geladen."
    log_warn "WICHTIG: SSH-Port ist jetzt ${SSH_PORT}, PasswordAuthentication deaktiviert."
    log_warn "         Stelle sicher, dass ein SSH-Key hinterlegt ist!"
fi

# ==============================================================================
# Schritt 4/6: Fail2ban konfigurieren
# ==============================================================================

log_info "--- Schritt 4/6: Fail2ban konfigurieren ---"

readonly F2B_JAIL_LOCAL="/etc/fail2ban/jail.local"

tmp_f2b="$(mktemp)"
cat > "${tmp_f2b}" <<EOF
# Fail2ban – generiert von 04-harden.sh
# Nicht manuell bearbeiten; erneutes Ausführen des Skripts aktualisiert diese Datei.

[DEFAULT]
bantime   = 3600
findtime  = 600
maxretry  = 5
# UFW als Backend für sauberere Integration
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 4
bantime  = 7200
EOF

# Nginx-Jails nur auf dem Load Balancer
if [[ "${vm_role}" == "lb" ]]; then
    cat >> "${tmp_f2b}" <<EOF

[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
maxretry = 5

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 2
EOF
    log_info "Fail2ban: Nginx-Jails werden konfiguriert (Rolle: lb)."
fi

f2b_changed=0
if [[ -f "${F2B_JAIL_LOCAL}" ]] \
    && diff -q "${tmp_f2b}" "${F2B_JAIL_LOCAL}" &>/dev/null; then
    log_info "Fail2ban-Konfiguration bereits aktuell: ${F2B_JAIL_LOCAL}"
    rm -f "${tmp_f2b}"
else
    if [[ -f "${F2B_JAIL_LOCAL}" ]]; then
        backup_file "${F2B_JAIL_LOCAL}"
    fi
    mv "${tmp_f2b}" "${F2B_JAIL_LOCAL}"
    chmod 0644 "${F2B_JAIL_LOCAL}"
    chown root:root "${F2B_JAIL_LOCAL}"
    log_info "Fail2ban-Konfiguration geschrieben: ${F2B_JAIL_LOCAL}"
    f2b_changed=1
fi

# ==============================================================================
# Schritt 5/6: Unattended-Upgrades konfigurieren
# ==============================================================================

log_info "--- Schritt 5/6: Unattended-Upgrades konfigurieren ---"

# 20auto-upgrades: Steuert welche apt-Hooks automatisch laufen.
# APT::Periodic::Update-Package-Lists "1"  → apt-get update täglich
# APT::Periodic::Unattended-Upgrade   "1"  → Security-Updates täglich
# APT::Periodic::AutocleanInterval    "7"  → Paketcache wöchentlich bereinigen

readonly AUTO_UPGRADES_CONF="/etc/apt/apt.conf.d/20auto-upgrades"

tmp_auto="$(mktemp)"
cat > "${tmp_auto}" <<'EOF'
// Keycloak HA – generiert von 04-harden.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

if [[ -f "${AUTO_UPGRADES_CONF}" ]] \
    && diff -q "${tmp_auto}" "${AUTO_UPGRADES_CONF}" &>/dev/null; then
    log_info "auto-upgrades-Konfiguration bereits aktuell: ${AUTO_UPGRADES_CONF}"
    rm -f "${tmp_auto}"
else
    if [[ -f "${AUTO_UPGRADES_CONF}" ]]; then
        backup_file "${AUTO_UPGRADES_CONF}"
    fi
    mv "${tmp_auto}" "${AUTO_UPGRADES_CONF}"
    chmod 0644 "${AUTO_UPGRADES_CONF}"
    log_info "auto-upgrades-Konfiguration geschrieben: ${AUTO_UPGRADES_CONF}"
fi

# 50unattended-upgrades: Legt fest, welche Origins eingespielt werden.
# Nur Security-Updates – keine normalen Debian-Updates (zu riskant ohne Test).
# Reboot wird NICHT automatisch durchgeführt (Server-Koordination nötig).

readonly UNATTENDED_UPGRADES_CONF="/etc/apt/apt.conf.d/50unattended-upgrades"

tmp_uu="$(mktemp)"
cat > "${tmp_uu}" <<'EOF'
// Keycloak HA – generiert von 04-harden.sh
// Nur Security-Updates automatisch einspielen.
Unattended-Upgrade::Allowed-Origins {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

// Pakete, die NIEMALS automatisch aktualisiert werden (manueller Test erforderlich)
Unattended-Upgrade::Package-Blacklist {
    "keycloak";
    "postgresql*";
    "nginx";
    "temurin*";
};

// Kein automatischer Reboot – Neustarts müssen koordiniert erfolgen
Unattended-Upgrade::Automatic-Reboot "false";

// E-Mail-Benachrichtigung bei Fehlern (leer = deaktiviert)
Unattended-Upgrade::Mail "";

// Alte Kernel-Pakete nach Upgrade entfernen
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Nicht mehr benötigte Abhängigkeiten entfernen
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

if [[ -f "${UNATTENDED_UPGRADES_CONF}" ]] \
    && diff -q "${tmp_uu}" "${UNATTENDED_UPGRADES_CONF}" &>/dev/null; then
    log_info "unattended-upgrades-Konfiguration bereits aktuell: ${UNATTENDED_UPGRADES_CONF}"
    rm -f "${tmp_uu}"
else
    if [[ -f "${UNATTENDED_UPGRADES_CONF}" ]]; then
        backup_file "${UNATTENDED_UPGRADES_CONF}"
    fi
    mv "${tmp_uu}" "${UNATTENDED_UPGRADES_CONF}"
    chmod 0644 "${UNATTENDED_UPGRADES_CONF}"
    log_info "unattended-upgrades-Konfiguration geschrieben: ${UNATTENDED_UPGRADES_CONF}"
fi

# Dry-Run zur Konfigurationsprüfung (keine echten Upgrades)
log_info "Unattended-Upgrades Konfiguration wird geprüft (dry-run)..."
unattended-upgrade --dry-run 2>&1 | while IFS= read -r line; do
    log_info "  unattended-upgrade: ${line}"
done
log_info "Unattended-Upgrades Dry-Run OK."

# ==============================================================================
# Schritt 6/6: Services aktivieren / neu starten
# ==============================================================================

log_info "--- Schritt 6/6: Services aktivieren ---"

ensure_service fail2ban

if [[ "${f2b_changed}" -eq 1 ]]; then
    systemctl restart fail2ban
    log_info "Fail2ban neugestartet (Konfiguration geändert)."
fi

# unattended-upgrades läuft als systemd-Timer (apt-daily.timer / apt-daily-upgrade.timer)
for timer in apt-daily.timer apt-daily-upgrade.timer; do
    if systemctl list-unit-files "${timer}" &>/dev/null; then
        if systemctl is-enabled --quiet "${timer}" 2>/dev/null; then
            log_info "Timer bereits aktiv: ${timer}"
        else
            systemctl enable --now "${timer}"
            log_info "Timer aktiviert: ${timer}"
        fi
    fi
done

# ==============================================================================
# Abschluss
# ==============================================================================

log_info "=== System-Hardening abgeschlossen ==="
log_info "VM-Rolle:            ${vm_role}"
log_info "SSH-Port:            ${SSH_PORT}"
log_info "UFW:                 $(ufw status | head -1)"
log_info "Fail2ban:            $(systemctl is-active fail2ban 2>/dev/null || echo 'unbekannt')"
log_info "Unattended-Upgrades: aktiviert (nur Security-Updates, kein Auto-Reboot)"
log_info ""
log_info "Aktive UFW-Regeln:"
ufw status numbered 2>/dev/null | while IFS= read -r line; do
    log_info "  ${line}"
done
