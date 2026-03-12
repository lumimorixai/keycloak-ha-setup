# ==============================================================================
# Nginx vHost für Keycloak HA
# Template: configs/nginx/keycloak.conf.tpl
# Deployment via deploy_config() in 03-setup-nginx.sh (envsubst)
#
# Platzhalter (aus .env):
#   ${KC_DOMAIN}    – Öffentlicher FQDN (z.B. auth.example.com)
#   ${KC_NODE1_IP}  – Interne IP von kc01
#   ${KC_NODE2_IP}  – Interne IP von kc02
#   ${KC_HTTP_PORT} – Keycloak HTTP-Port (Standard: 8080)
# ==============================================================================

# WebSocket-Upgrade-Mapping: leitet Upgrade-Requests korrekt weiter und
# erhält gleichzeitig HTTP/1.1-Keepalive für normale Requests.
# Ohne diesen map-Block werden WebSocket-Verbindungen der Admin-Console
# abgebrochen, weil Connection "" den Upgrade-Header unterdrückt.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}

upstream keycloak_backend {
    # ip_hash garantiert Session-Stickiness pro Client-IP.
    # Upgrade-Pfad: sticky cookie (nginx-module-ndk + lua) – später möglich.
    ip_hash;

    server ${KC_NODE1_IP}:${KC_HTTP_PORT} max_fails=3 fail_timeout=30s;
    server ${KC_NODE2_IP}:${KC_HTTP_PORT} max_fails=3 fail_timeout=30s;

    keepalive 32;
}

# HTTP → HTTPS Redirect (plus ACME Challenge Passthrough für Certbot)
server {
    listen 80;
    listen [::]:80;
    server_name ${KC_DOMAIN};

    # Certbot ACME Challenge (Let's Encrypt Webroot)
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files $uri =404;
    }

    # Alles andere → HTTPS umleiten
    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS vHost
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${KC_DOMAIN};

    # TLS-Zertifikate (von Certbot angelegt)
    ssl_certificate     /etc/letsencrypt/live/${KC_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${KC_DOMAIN}/privkey.pem;

    # Empfohlene TLS-Parameter (Mozilla Intermediate Kompatibilität)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    # HSTS (6 Monate; erst nach vollständigem Test auf produktion aktivieren)
    add_header Strict-Transport-Security "max-age=15768000" always;

    # Proxy-Buffer: Keycloak-Token können sehr groß werden (viele Realm-Rollen).
    # Ohne diese Einstellung → 502-Fehler bei großen Token-Responses.
    proxy_buffer_size          128k;
    proxy_buffers              4 256k;
    proxy_busy_buffers_size    256k;

    # Timeouts (Keycloak benötigt ggf. längere Auth-Flows)
    proxy_connect_timeout  10s;
    proxy_send_timeout     60s;
    # 3600s: WebSocket-Verbindungen der Admin-Console sind lange idle.
    # Bei 60s würde Nginx idle WS-Verbindungen trennen → UI-Fehler.
    proxy_read_timeout    3600s;

    location / {
        proxy_pass http://keycloak_backend;

        # X-Forwarded-* Header für Keycloak proxy-headers=xforwarded
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port  $server_port;

        # HTTP/1.1 + WebSocket-Support (via map-Block oben):
        #   - Upgrade-Request  → Connection: upgrade  (WS-Handshake)
        #   - normaler Request → Connection: ""        (Keepalive)
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
