#!/bin/bash
# 装修预算应用 · 47 服务器部署脚本（幂等）
set -euo pipefail

APP_DIR=/opt/budget
SNIP=/etc/nginx/snippets/budget.conf
STAMP=$(date +%Y%m%d_%H%M%S)

echo "== 1. 目录与权限 =="
mkdir -p "$APP_DIR" /etc/nginx/snippets
chmod 700 "$APP_DIR"
chmod 600 "$APP_DIR/secret.txt" || true

echo "== 2. systemd 服务 =="
install -m 644 "$APP_DIR/budget.service" /etc/systemd/system/budget.service
systemctl daemon-reload
systemctl enable budget.service >/dev/null 2>&1 || true
systemctl restart budget.service
sleep 1.5
systemctl is-active budget.service

echo "== 3. nginx 反代片段 =="
install -m 644 "$APP_DIR/budget.nginx" "$SNIP"

python3 - "$SNIP" <<'PY'
import sys
snip = "/etc/nginx/snippets/budget.conf"
inc = "include " + snip + ";"

# 1) nginx.conf 的 default_server（IP 直接访问走这里）
p = "/etc/nginx/nginx.conf"
s = open(p, encoding="utf-8").read()
if inc not in s:
    import shutil, time
    shutil.copy2(p, p + ".bak_budget_" + time.strftime("%Y%m%d_%H%M%S"))
    old = "root         /var/www/blog;"
    if old in s:
        s = s.replace(old, old + "\n        " + inc, 1)
        open(p, "w", encoding="utf-8").write(s)
        print("nginx.conf: 已插入 include")
    else:
        print("nginx.conf: 未找到锚点，跳过")
else:
    print("nginx.conf: 已存在 include，跳过")

# 2) blog.conf 的域名 server（jiangchuang.top 也能访问 /budget/）
p2 = "/etc/nginx/conf.d/blog.conf"
if not __import__("os").path.exists(p2):
    print("blog.conf: 不存在，跳过")
else:
    s2 = open(p2, encoding="utf-8").read()
    if inc not in s2:
        import shutil, time
        shutil.copy2(p2, p2 + ".bak_budget_" + time.strftime("%Y%m%d_%H%M%S"))
        anchor = "index index.html;"
        if anchor in s2:
            s2 = s2.replace(anchor, anchor + "\n    " + inc, 1)
            open(p2, "w", encoding="utf-8").write(s2)
            print("blog.conf: 已插入 include")
    else:
        print("blog.conf: 已存在 include，跳过")
PY

echo "== 4. 校验并平滑重载 nginx =="
cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.reload_bak_$STAMP"
nginx -t
systemctl reload nginx

echo "== 5. 本机自测 =="
# reload 是异步的，老 worker 可能还在接新连接，等一拍再测
sleep 2
echo -n "  直连后端 health: "; curl -s http://127.0.0.1:8082/api/health; echo
echo -n "  经 nginx /budget/ 首页: "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/budget/
echo -n "  经 nginx /budget/api/health: "; curl -s http://127.0.0.1/budget/api/health; echo

RAW=$(curl -s -o /dev/null -w '%{size_download}' http://127.0.0.1/budget/)
GZ=$(curl -s -o /dev/null -H 'Accept-Encoding: gzip' -w '%{size_download}' http://127.0.0.1/budget/)
if [ "$GZ" -lt "$RAW" ]; then
  echo "  首页 gzip: 生效 ${RAW}B -> ${GZ}B"
else
  echo "  首页 gzip: 未生效（${RAW}B -> ${GZ}B）—— 检查 budget.nginx 是否已安装"
fi

HH=$(curl -s -D - -o /dev/null http://127.0.0.1/budget/ | tr -d '\r')
echo -n "  安全头: nosniff="; printf '%s' "$HH" | grep -qi 'x-content-type-options: nosniff' && echo -n "yes" || echo -n "no"
echo -n " csp=";        printf '%s' "$HH" | grep -qi 'content-security-policy:' && echo -n "yes" || echo -n "no"
echo -n " referrer=";   printf '%s' "$HH" | grep -qi 'referrer-policy:' && echo "yes" || echo "no"
ET=$(printf '%s' "$HH" | awk 'tolower($1)=="etag:"{print $2}')
if [ -n "$ET" ]; then
  echo "  首页 ETag: $ET -> 复请求 $(curl -s -o /dev/null -w '%{http_code}' -H "If-None-Match: $ET" http://127.0.0.1/budget/)"
else
  echo "  首页 ETag: 缺失（app.py 没更新？）"
fi
echo "== 完成 =="
