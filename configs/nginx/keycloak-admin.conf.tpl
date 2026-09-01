# ==============================================================================
# Nginx vHost für die Keycloak Admin-Console (separate Domain)
# Template: configs/nginx/keycloak-admin.conf.tpl
# Deployment via deploy_config() in 03-setup-nginx.sh (envsubst)
#
# Wird NUR deployed wenn KC_ADMIN_DOMAIN in .env gesetzt ist. Ist die Variable
# leer, entfernt 03-setup-nginx.sh eine eventuell vorhandene Datei wieder.
#
# Platzhalter (aus .env):
#   KC_ADMIN_DOMAIN   – FQDN der Admin-Console (z.B. kc-admin-dev.example.de)
#   NGINX_ADMIN_ALLOW – von 03-setup-nginx.sh erzeugte allow/deny-Zeilen aus
#                       KC_ADMIN_ALLOW_IPS (leer = Kommentarzeile)
#
# Die Namen stehen hier bewusst ohne Dollar-Klammern: envsubst ersetzt sie sonst
# auch im Kommentar, und der mehrzeilige allow/deny-Block bricht daraus aus.
#
# ABHÄNGIGKEIT: Dieser vHost nutzt den upstream "keycloak_backend" und die
# Variable $connection_upgrade aus keycloak.conf. Beide sind dort global
# definiert und dürfen hier NICHT wiederholt werden – nginx -t bricht sonst
# mit "duplicate upstream" bzw. "duplicate map" ab.
# ==============================================================================

# HTTP → HTTPS Redirect (plus ACME Challenge Passthrough für Certbot)
server {
    listen 80;
    listen [::]:80;
    server_name ${KC_ADMIN_DOMAIN};

    # Certbot ACME Challenge – bewusst OHNE IP-Beschränkung, die Anfrage kommt
    # von den Let's-Encrypt-Servern, nicht von den Admin-IPs.
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files $uri =404;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS vHost – Admin-Console
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${KC_ADMIN_DOMAIN};

    # TLS-Zertifikate (eigenes Zertifikat, unabhängig von der Login-Domain)
    ssl_certificate     /etc/letsencrypt/live/${KC_ADMIN_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${KC_ADMIN_DOMAIN}/privkey.pem;

    # Empfohlene TLS-Parameter (Mozilla Intermediate Kompatibilität)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSLAdmin:10m;
    ssl_session_tickets off;

    # HSTS (6 Monate)
    add_header Strict-Transport-Security "max-age=15768000" always;

    # Die Admin-Console gehört nicht in Suchmaschinen-Indizes.
    add_header X-Robots-Tag "noindex, nofollow" always;

    # Proxy-Buffer: Admin-Token enthalten viele Rollen und werden groß.
    # Ohne diese Einstellung → 502-Fehler bei großen Token-Responses.
    proxy_buffer_size          128k;
    proxy_buffers              4 256k;
    proxy_busy_buffers_size    256k;

    # Timeouts (3600s: idle WebSocket-Verbindungen der Admin-Console)
    proxy_connect_timeout  10s;
    proxy_send_timeout     60s;
    proxy_read_timeout    3600s;

    location / {
        # Zugriffsbeschränkung aus KC_ADMIN_ALLOW_IPS (leer = offen für alle)
        ${NGINX_ADMIN_ALLOW}

        # Kompletter Pfadraum, nicht nur /admin/: die Console braucht
        # /realms/... für den Auth-Flow und /resources/... für Assets.
        proxy_pass http://keycloak_backend;

        # X-Forwarded-* Header für Keycloak proxy-headers=xforwarded
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port  $server_port;

        # HTTP/1.1 + WebSocket-Support (map-Block aus keycloak.conf)
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
