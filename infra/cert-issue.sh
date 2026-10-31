#!/bin/bash
# 证书三件事：检查续期链路、拷贝到新机、或重新签发。
#
# 先说结论：**迁移窗口内优先拷证书，不要重签。**
# 现有证书有效到 2027-01-28、续期排在 2026-12-29；只要迁移发生在这之前，
# scp 过去就能用，零签发风险（重签会消耗 Let's Encrypt 的速率限制）。
#
# 用法：
#   cert-issue.sh --mode check      # 看现在到底有没有人管续期（最常跑这个）
#   cert-issue.sh --mode copy       # 从旧机拷证书 + acme.sh 到新机（在新机上跑）
#   cert-issue.sh --mode issue      # 重新签发（要求 DNS 已指向本机）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "必须指定 --mode check|copy|issue" >&2; exit 2; }

log() { echo "[$(date '+%F %T')] $*"; }

case "$MODE" in

check)
  log "=== 证书文件 ==="
  for f in "$CERT_DIR/$CERT_NAME" "$CERT_DIR/$KEY_NAME"; do
    if [ -f "$f" ]; then
      printf "  ✓ %s\n" "$f"
    else
      printf "  ✗ %s 不存在\n" "$f"
    fi
  done

  log "=== 实际到期时间（以文件为准，不信印象）==="
  openssl x509 -in "$CERT_DIR/$CERT_NAME" -noout -subject -dates 2>/dev/null || true

  log "=== 续期配置（新机拷过来后，这里最容易对着旧路径空跑）==="
  CONF="$(ls -1 "$ACME_HOME/${DOMAIN}"*/"${DOMAIN}".conf 2>/dev/null | head -1)"
  if [ -n "$CONF" ]; then
    grep -E 'Le_Webroot|Le_NextRenewTime|Le_ReloadCmd' "$CONF" || true
  else
    log "  ✗ 找不到 $ACME_HOME/${DOMAIN}*/${DOMAIN}.conf —— acme.sh 没接管，续期不会发生"
  fi

  log "=== 定时任务 ==="
  crontab -l 2>/dev/null | grep -i acme || log "  ✗ crontab 里没有 acme 条目"
  systemctl list-timers --all 2>/dev/null | grep -i acme || true

  log "=== 服务端实际给出去的证书 ==="
  echo | openssl s_client -servername "$WWW" -connect "$WWW:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null || log "  ✗ 连不上，或 443 没起来"
  ;;

copy)
  [ -n "${OLD_SERVER:-}" ] || { echo "先设 OLD_SERVER=root@旧IP 再跑（别写死在脚本里）" >&2; exit 2; }
  log "从 $OLD_SERVER 拷证书到本机"
  mkdir -p "$CERT_DIR" "$ACME_HOME"
  chmod 700 "$CERT_DIR" "$ACME_HOME"
  scp -q "$OLD_SERVER:$CERT_DIR/$CERT_NAME" "$OLD_SERVER:$CERT_DIR/$KEY_NAME" "$CERT_DIR/"
  chmod 600 "$CERT_DIR/$KEY_NAME"
  scp -q -r "$OLD_SERVER:$ACME_HOME/." "$ACME_HOME/"
  log "改续期配置里的 webroot（路径不一致会导致续期静默失败）"
  for c in "$ACME_HOME"/*/"${DOMAIN}".conf; do
    [ -f "$c" ] || continue
    sed -i "s|^Le_Webroot=.*|Le_Webroot='$ACME_WEBROOT'|" "$c"
    grep -E 'Le_Webroot|Le_NextRenewTime' "$c" || true
  done
  log "重挂 install-cert（reloadcmd 存在续期配置里，换机后必须重挂一次）"
  "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$CERT_DIR/$KEY_NAME" \
    --fullchain-file "$CERT_DIR/$CERT_NAME" \
    --reloadcmd "nginx -s reload" || log "  install-cert 失败，手动看上面的报错"
  log "完成。接着跑：$0 --mode check"
  ;;

issue)
  # 签发前先自查三件事，省得浪费 LE 的速率限制
  ip_here="$(curl -s -m 8 https://api.ipify.org || echo '')"
  ip_dns="$(getent hosts "$WWW" | awk '{print $1}' | head -1)"
  log "本机出口 IP：${ip_here:-读不到}｜$WWW 解析到：${ip_dns:-读不到}"
  [ "$ip_here" = "$ip_dns" ] || log "  ✗ 两者不一致：DNS 还没指向本机。此时签发必然失败，还会消耗速率限制"
  [ "$ip_here" = "$ip_dns" ] || { echo "确认 DNS 已生效再重跑"; exit 1; }

  log "用 webroot 模式签发（不要用 standalone：那要停 nginx，站点会裸奔）"
  "$ACME_HOME/acme.sh" --issue -d "$DOMAIN" -d "$WWW" -w "$ACME_WEBROOT" --keylength ec-256
  "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$CERT_DIR/$KEY_NAME" \
    --fullchain-file "$CERT_DIR/$CERT_NAME" \
    --reloadcmd "nginx -s reload"
  log "完成。接着跑：$0 --mode check"
  ;;

*)
  echo "未知模式: $MODE" >&2; exit 2 ;;
esac
