#!/bin/bash
# 新机器一键重建（nginx + 目录 + 权限 + SELinux + 防火墙 + 日志上限）
#
# ⚠️ 状态说明：**本脚本没有在真实新机上跑过**（手边没有第二台机器）。
# 逻辑按 Rocky 8 写，装包/建目录/权限/配置渲染这几段是常规操作，但**首次使用请人工盯着输出**，
# 每一步都做了「先检测再执行」，重复跑是安全的。跑完必须执行 verify.sh。
#
# 用法（在目标机上以 root 跑，需要先把仓库弄到本机）：
#   SERVER_IP=1.2.3.4 ./rebuild-server.sh --ip 1.2.3.4
#   ./rebuild-server.sh --minimal     # 只落「最小 :80」，用于首次签发证书
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

MINIMAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ip) SERVER_IP="$2"; shift 2 ;;
    --minimal) MINIMAL=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
SERVER_IP="${SERVER_IP:-$(curl -s -m 8 https://api.ipify.org || echo '')}"

log() { echo "[$(date '+%F %T')] $*"; }
[ "$(id -u)" = 0 ] || { echo "要用 root 跑" >&2; exit 1; }

log "1/7 装包"
for p in nginx rsync tar cronie logrotate curl openssl; do
  rpm -q "$p" > /dev/null 2>&1 || dnf install -y "$p" > /dev/null
done
log "   完成"

log "2/7 建目录与权限"
install -d -m 755 "$WEBROOT"
install -d -m 755 "$ACME_WEBROOT/.well-known/acme-challenge"
install -d -m 700 "$CERT_DIR"
install -d -m 700 "$BACKUP_REMOTE"
install -d -m 755 "$(dirname "$APP_DIR")"
log "   完成"

log "3/7 SELinux（这里不处理，后面一定遇到 403 且找不到原因）"
if command -v getenforce > /dev/null 2>&1 && [ "$(getenforce)" != Disabled ]; then
  chcon -R -t httpd_sys_content_t "$WEBROOT" 2>/dev/null || true
  setsebool -P httpd_can_network_connect 1 2>/dev/null || true   # budget 反代要用
  log "   已设置 httpd_sys_content_t 与 httpd_can_network_connect"
else
  log "   SELinux 未启用，跳过"
fi

log "4/7 防火墙"
if command -v firewall-cmd > /dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http  > /dev/null
  firewall-cmd --permanent --add-service=https > /dev/null
  firewall-cmd --reload > /dev/null
  log "   已放行 80/443"
else
  log "   firewalld 未运行（云厂商安全组才是真正的门，那边要手工开）"
fi

log "5/7 日志上限（小磁盘机器的隐形杀手）"
mkdir -p /etc/systemd
if ! grep -q '^SystemMaxUse=' /etc/systemd/journald.conf 2>/dev/null; then
  printf 'SystemMaxUse=200M\n' >> /etc/systemd/journald.conf
  systemctl restart systemd-journald 2>/dev/null || true
fi
log "   journald 上限 200M"

log "6/7 渲染 vhost"
TPL="$HERE/nginx/blog.conf.tpl"
[ -f "$TPL" ] || { echo "找不到模板 $TPL" >&2; exit 1; }
OUT=/tmp/blog.conf.rendered
sed -e "s|\${DOMAIN}|$DOMAIN|g" -e "s|\${WWW}|$WWW|g" \
    -e "s|\${WEBROOT}|$WEBROOT|g" -e "s|\${ACME_WEBROOT}|$ACME_WEBROOT|g" \
    -e "s|\${CERT_DIR}|$CERT_DIR|g" -e "s|\${CERT_NAME}|$CERT_NAME|g" \
    -e "s|\${KEY_NAME}|$KEY_NAME|g" -e "s|\${SERVER_IP}|$SERVER_IP|g" \
    "$TPL" > "$OUT"

if [ "$MINIMAL" = 1 ]; then
  # 首次签发：只落最小 :80（除 challenge 外一律 404），避免「要证书才能 https、
  # 要 https 才能过 301 才能签发」的自锁
  sed -n '/MINIMAL 段/,/^# ============ 签完/p' "$OUT" | grep -E '^\s*(server|\s{4}|})' | sed 's/^# \{0,1\}//' > /tmp/minimal.conf || true
  cat > /etc/nginx/conf.d/blog.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/blog;
    location ^~ /.well-known/acme-challenge/ { root /var/www/blog; }
    location / { return 404; }
}
EOF
  log "   已落最小 :80（只用于签发证书）"
else
  if [ -f /etc/nginx/conf.d/blog.conf ]; then
    cp -a /etc/nginx/conf.d/blog.conf "/etc/nginx/conf.d/blog.conf.bak_$(date +%Y%m%d_%H%M%S)"
  fi
  install -m 644 "$OUT" /etc/nginx/conf.d/blog.conf
  log "   已落完整 vhost（旧配置已备份）"
fi

log "7/7 校验并启动"
nginx -t || { echo "nginx -t 没过，不要 restart" >&2; exit 1; }
systemctl enable --now nginx > /dev/null 2>&1 || true
systemctl reload nginx
log "完成。下一步：deploy-site.sh --to new，然后 cert-issue.sh --mode copy|issue，最后 verify.sh"
