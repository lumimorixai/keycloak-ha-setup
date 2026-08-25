# ==============================================================================
# keycloak.conf – Keycloak Server-Konfiguration (Template)
#
# Deployed via 02-setup-keycloak.sh → /opt/keycloak/conf/keycloak.conf
# Nach jeder Änderung MUSS kc.sh build ausgeführt werden (geschieht im Skript).
#
# Variablen (aus .env):
#   DB_HOST, DB_NAME, DB_USER, DB_PASSWORD
#   KC_HTTP_PORT, KC_DOMAIN, KC_JGROUPS_PORT
# ==============================================================================

# --- Datenbank ----------------------------------------------------------------
# Keycloak baut die JDBC-URL aus Host + Datenbankname zusammen.
db=postgres
db-url-host=${DB_HOST}
db-url-database=${DB_NAME}
db-username=${DB_USER}
db-password=${DB_PASSWORD}
db-pool-initial-size=5
db-pool-min-size=5
db-pool-max-size=20

# --- HTTP (TLS wird am Nginx-Reverse-Proxy terminiert) -----------------------
# Keycloak hört nur auf HTTP; HTTPS endet am lb01-Nginx.
http-enabled=true
http-port=${KC_HTTP_PORT}

# --- Hostname / Reverse Proxy ------------------------------------------------
# Vollständige URL nötig (KC 24+), damit generierte Redirect-URIs https:// nutzen.
# proxy-headers=xforwarded: KC vertraut X-Forwarded-Proto/Host vom Nginx.
hostname=https://${KC_DOMAIN}
hostname-strict=true
proxy-headers=xforwarded

# --- Clustering (JDBC_PING2 für Node-Discovery via PostgreSQL) ---------------
# JDBC_PING2 nutzt die PostgreSQL-DB NUR für Node-Discovery.
# Der eigentliche Cluster-Datentransfer läuft über JGroups TCP (Port ${KC_JGROUPS_PORT}).
# Der JGroups TCP Bind-Address wird per -Djgroups.bind.address in JAVA_OPTS_APPEND gesetzt
# (in /etc/keycloak/env, geschrieben von 02-setup-keycloak.sh).
cache=ispn
cache-stack=jdbc-ping

# --- Health & Metrics --------------------------------------------------------
# Seit Keycloak 25+ laufen Health/Metrics auf einem separaten Management-Port
# (Standard: 9000), NICHT auf dem HTTP-Port (8080).
# /health/ready erreichbar unter http://<node>:${KC_MGMT_PORT}/health/ready
health-enabled=true
metrics-enabled=true
http-management-port=${KC_MGMT_PORT}

# --- User-Event-Metriken -----------------------------------------------------
# metrics-enabled allein liefert NUR JVM-, HTTP- und Datasource-Metriken.
# Login-, Logout- und Registrierungs-Events erscheinen erst mit der folgenden
# Option – als eine einzige Metrik:
#   keycloak_user_events_total{realm="...", event="login", error="", client_id="...", idp="..."}
# Die alten Namen keycloak_successful_login / keycloak_failed_login_attempts
# stammen aus der Wildfly-Extension keycloak-metrics-spi und existieren in der
# Quarkus-Distribution NICHT.
event-metrics-user-enabled=true
event-metrics-user-tags=realm,clientId,idp

# --- Logging -----------------------------------------------------------------
# Auf stdout (journald übernimmt via systemd): kein separates Logfile nötig.
log=console
log-level=INFO
