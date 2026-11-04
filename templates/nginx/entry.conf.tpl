# ─────────────────────────────────────────────────────────────
# nginx для роли entry (входная нода)
#
# Сгенерировано setup_remnawave_node.sh из templates/nginx/entry.conf.tpl.
# Ручные правки будут перезаписаны при следующем запуске скрипта
# (предыдущая версия сохраняется в /opt/nginx/backup-<дата>/).
#
# 443/tcp принимает nginx (stream) и, не терминируя TLS, разводит
# подключения по SNI:
#   {{NODE_DOMAIN}}  → Xray (Reality) на 127.0.0.1:{{XRAY_LOCAL_PORT}}
#   всё остальное    → сайт-заглушка на 127.0.0.1:{{SITE_LOCAL_PORT}}
# Reality берёт этот же сайт как target, поэтому у сайта обязательны
# TLS 1.3, X25519 и HTTP/2.
# ─────────────────────────────────────────────────────────────

user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
}

# --- L4: разводим 443 по SNI, TLS не терминируем ---
stream {
    map $ssl_preread_server_name $backend {
        {{NODE_DOMAIN}}  xray;
        default          site;
    }

    upstream xray { server 127.0.0.1:{{XRAY_LOCAL_PORT}}; }
    upstream site { server 127.0.0.1:{{SITE_LOCAL_PORT}}; }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $backend;
        proxy_connect_timeout 5s;
        proxy_timeout 600s;
        # proxy_protocol НЕ включаем: в Xray нет acceptProxyProtocol, xver = 0
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    server_tokens off;
    access_log off;

    # --- Сайт-заглушка: доступен только через stream на 443 ---
    server {
        listen 127.0.0.1:{{SITE_LOCAL_PORT}} ssl default_server;
        http2 on;
        server_name {{NODE_DOMAIN}};

        ssl_certificate     /etc/nginx/ssl/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/privkey.key;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ecdh_curve X25519:prime256v1:secp384r1;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;

        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }
    }

    # --- 80/tcp: только редирект на HTTPS ---
    server {
        listen 80 default_server;
        server_name _;
        return 301 https://{{NODE_DOMAIN}}$request_uri;
    }
}
