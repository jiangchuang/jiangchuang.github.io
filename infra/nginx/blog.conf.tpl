# 站点 vhost 模板 —— 由 rebuild-server.sh 用 env.sh 的变量渲染后落到
# /etc/nginx/conf.d/blog.conf。不要直接改服务器上那份，改这里再重新渲染。
#
# 两个顺序坑（都是真踩过的）：
#   1. 301 必须写在 location / 里，不能写在 server 级。
#      server 级的 return 会在 location 匹配之前执行，ACME 的 challenge 请求
#      会被 301 走，证书签发/续期直接失败。
#   2. 首次签发时还没有证书，但 80 已经在 301 到 https —— 自锁。
#      新机先只落「最小 :80 server」（见下方 MINIMAL 段），签完再换完整版。

# ============ MINIMAL 段：新机首次签发证书时只用这一段 ============
# server {
#     listen 80 default_server;
#     server_name _;
#     root ${ACME_WEBROOT};
#     location ^~ /.well-known/acme-challenge/ { root ${ACME_WEBROOT}; }
#     location / { return 404; }
# }
# ============ 签完删掉上面那段，启用下面 ============

server {
    listen 443 ssl http2;
    server_name ${WWW} ${DOMAIN};
    root ${WEBROOT};
    index index.html;

    ssl_certificate     ${CERT_DIR}/${CERT_NAME};
    ssl_certificate_key ${CERT_DIR}/${KEY_NAME};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # 静态站不需要任何动态能力：禁掉 .md/.txt 直读（STYLE.md、README.md 不进公网视野）
    location ~* \.(md|markdown)$ { return 404; }
    location ~ /\.(?!well-known) { return 404; }

    # 有状态应用（budget）挂在这个前缀下；它有自己的 vhost 片段
    include /etc/nginx/snippets/budget.conf;

    location / {
        try_files $uri $uri/ =404;
    }
}

# 80 端口：只放行 ACME，其余全量 301（IP 访问也跳到域名，保持单一入口）
server {
    listen 80 default_server;
    server_name ${WWW} ${DOMAIN} ${SERVER_IP} _;
    root ${WEBROOT};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
    }

    location / {
        return 301 https://${WWW}$request_uri;
    }
}
