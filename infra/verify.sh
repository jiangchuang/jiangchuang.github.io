#!/bin/bash
# 一次跑完全部验收。换机器之后、改完配置之后、心里没底的任何时候都跑它。
# 只读，不会改任何东西，随便跑。
#
# 用法：verify.sh [--to new]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

TARGET_HOST="$WWW"
if [ "${1:-}" = "--to" ] && [ -n "${2:-}" ]; then
  TARGET_HOST="$2"
fi

PASS=0; FAIL=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; PASS=$((PASS+1)); }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; FAIL=$((FAIL+1)); }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }
sect() { printf "\n\033[1m%s\033[0m\n" "$*"; }

code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null || echo 000; }

sect "一、静态站（HTTPS 直连）"
for u in / /about.html /search.html /posts/ /interactive/ /assets/search.json \
         /posts/dmsqlq-log-parse.html /interactive/dmsqlq-log-parse.html; do
  c="$(code "https://$TARGET_HOST$u")"
  [ "$c" = 200 ] && ok "$u → 200" || bad "$u → $c"
done

sect "二、强制跳转与证书"
c="$(code "http://$TARGET_HOST/")"
[ "$c" = 301 ] && ok "http → 301" || bad "http → $c（应该是 301）"
loc="$(curl -s -o /dev/null -m 10 -w '%{redirect_url}' "http://$TARGET_HOST/" 2>/dev/null)"
case "$loc" in https://*) ok "跳转到 $loc" ;; *) bad "跳转目标异常：$loc" ;; esac

if command -v openssl > /dev/null 2>&1; then
  end="$(echo | openssl s_client -servername "$TARGET_HOST" -connect "$TARGET_HOST:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [ -n "$end" ]; then
    left=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if [ "$left" -gt 20 ]; then ok "证书还有 $left 天（$end）"
    elif [ "$left" -gt 0 ]; then warn "证书只剩 $left 天，续期可能没跑起来"
    else bad "证书已过期或读不到（$end）"; fi
  else bad "读不到证书到期时间"; fi
fi

sect "三、有状态应用（budget 账本）"
c="$(code "https://$TARGET_HOST/budget/")"
[ "$c" = 200 ] && ok "/budget/ → 200" || bad "/budget/ → $c"
c="$(code "https://$TARGET_HOST/budget/api/health")"
[ "$c" = 200 ] && ok "/budget/api/health → 200" || warn "/budget/api/health → $c（后端可能没起）"

if [ -z "${SKIP_SSH:-}" ]; then
  state="$(ssh -o ConnectTimeout=8 "$SERVER" "systemctl is-active budget.service" 2>/dev/null | tail -1)"
  [ "$state" = active ] && ok "budget.service = active" || bad "budget.service = ${state:-读不到}"

  sect "四、备份与续期任务（服务器侧）"
  n="$(ssh -o ConnectTimeout=8 "$SERVER" "ls -1 $BACKUP_REMOTE/budget-*.tar.gz 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')"
  [ "${n:-0}" -gt 0 ] && ok "服务器上有 $n 份账本备份" || bad "服务器上没有备份，先跑 backup-budget.sh"

  newest="$(ssh -o ConnectTimeout=8 "$SERVER" "ls -1t $BACKUP_REMOTE/budget-*.tar.gz 2>/dev/null | head -1" 2>/dev/null)"
  if [ -n "$newest" ]; then
    age_h=$(( ( $(date +%s) - $(ssh -o ConnectTimeout=8 "$SERVER" "stat -c %Y '$newest'" 2>/dev/null | tr -d ' ') ) / 3600 ))
    [ "$age_h" -lt 48 ] && ok "最新备份距今 ${age_h}h" || bad "最新备份距今 ${age_h}h，定时任务可能没跑"
    ssh -o ConnectTimeout=8 "$SERVER" "cd $(dirname "$newest") && sha256sum -c \$(basename $newest).sha256" >/dev/null 2>&1 \
      && ok "最新备份 sha256 校验通过" || bad "最新备份校验失败（包可能坏了）"
  fi

  ssh -o ConnectTimeout=8 "$SERVER" "crontab -l 2>/dev/null | grep -q backup-budget.sh" 2>/dev/null \
    && ok "备份定时任务存在" || bad "没有备份定时任务"
  ssh -o ConnectTimeout=8 "$SERVER" "crontab -l 2>/dev/null | grep -q acme.sh" 2>/dev/null \
    && ok "证书续期任务存在" || bad "没有 acme 续期任务，证书会静默过期"

  d="$(ssh -o ConnectTimeout=8 "$SERVER" "df -h / | tail -1 | awk '{print \$5}'" 2>/dev/null | tr -d ' %')"
  [ "${d:-0}" -lt 80 ] && ok "根分区使用 ${d}%" || warn "根分区使用 ${d}%，该清了（先看 journalctl --disk-usage）"
fi

sect "五、本机异地备份副本"
nl="$(ls -1 "$BACKUP_LOCAL"/budget-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
[ "${nl:-0}" -gt 0 ] && ok "本机有 ${nl} 份异地副本" || bad "本机没有副本 —— 服务器盘一坏就全没了"

printf "\n\033[1m结果：%d 项通过，%d 项失败\033[0m\n" "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
