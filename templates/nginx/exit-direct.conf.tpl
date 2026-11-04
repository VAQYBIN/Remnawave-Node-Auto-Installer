# ─────────────────────────────────────────────────────────────
# nginx для роли exit-direct (выходная нода с прямыми подключениями)
#
# Сгенерировано setup_remnawave_node.sh из templates/nginx/exit-direct.conf.tpl.
# Ручные правки будут перезаписаны при следующем запуске скрипта
# (предыдущая версия сохраняется в /opt/nginx/backup-<дата>/).
#
# Блока stream нет: 443 слушает сам Xray и передаёт неавторизованные
# подключения на сайт-заглушку 127.0.0.1:{{SITE_LOCAL_PORT}}. Reality берёт
# этот сайт как target, поэтому у сайта обязательны TLS 1.3, X25519
# и HTTP/2.
# ─────────────────────────────────────────────────────────────

user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    server_tokens off;
    access_log off;

    # --- Сайт-заглушка: доступен только через Xray на 443 ---
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
