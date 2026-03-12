# ==============================================================================
# pg_hba.conf – PostgreSQL Client-Authentifizierung
# Template: envsubst ersetzt Platzhalter beim Deployment via 01-setup-db.sh
#
# Variablen (aus .env):
#   DB_NAME      – Keycloak-Datenbankname (z.B. keycloak)
#   DB_USER      – Keycloak-DB-User (z.B. keycloak)
#   KC_NODE1_IP  – Interne IP von kc01
#   KC_NODE2_IP  – Interne IP von kc02
# ==============================================================================

# TYPE  DATABASE        USER            ADDRESS                 METHOD

# --- Lokale Administration (postgres-Systemuser via Unix-Socket) --------
# Peer-Auth: Betriebssystem-Username muss mit DB-Username übereinstimmen.
local   all             postgres                                peer
local   all             all                                     reject

# --- Keycloak-Nodes: Zugriff von kc01 und kc02 --------------------------
# scram-sha-256 ist sicherer als md5 und von PostgreSQL 14+ standardmäßig
# unterstützt. Passwort wird über KC_NODE*_IP/32 auf einzelne IPs begrenzt.
host    ${DB_NAME}      ${DB_USER}      ${KC_NODE1_IP}/32       scram-sha-256
host    ${DB_NAME}      ${DB_USER}      ${KC_NODE2_IP}/32       scram-sha-256

# --- Lokaler IPv4/IPv6-Zugriff (Wartung, Monitoring, Healthchecks) ------
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
