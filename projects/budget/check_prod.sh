#!/bin/bash
# 装修预算 · 线上只读验收（不改任何数据，可随时对 /opt/budget 跑）
#   用法: bash check_prod.sh <口令> [站点前缀]
#   例:   bash check_prod.sh TxO2yl_SQ6Q1 http://47.117.13.158/budget
set -u

KEY="${1:?用法: bash check_prod.sh <口令> [站点前缀]}"
BASE="${2:-http://47.117.13.158/budget}"
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); printf '  [PASS] %s %s\n' "$1" "${2:-}"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s %s\n' "$1" "${2:-}"; }

code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }
hdr()  { curl -s -D - -o /dev/null -m 10 "$@" | tr -d '\r'; }

echo "== 1. 首页与协商缓存 =="
H=$(hdr "$BASE/")
ET=$(printf '%s' "$H" | awk 'tolower($1)=="etag:"{print $2}')
[ "$(printf '%s' "$H" | head -1 | grep -c ' 200 ')" = "1" ] && ok "首页 200" || bad "首页 200"
[ -n "$ET" ] && ok "首页带 ETag" "$ET" || bad "首页带 ETag"
[ "$(code -H "If-None-Match: $ET" "$BASE/")" = "304" ] && ok "首页命中 304" || bad "首页命中 304"
printf '%s' "$H" | grep -qi 'x-content-type-options: nosniff' && ok "nosniff" || bad "nosniff"
printf '%s' "$H" | grep -qi 'content-security-policy:' && ok "CSP" || bad "CSP"
printf '%s' "$H" | grep -qi 'referrer-policy: no-referrer' && ok "Referrer-Policy" || bad "Referrer-Policy"
printf '%s' "$H" | grep -qi 'cache-control: no-cache' && ok "Cache-Control=no-cache" || bad "Cache-Control=no-cache"

echo "== 2. gzip（<55KB 压到约 1/4）=="
RAW=$(curl -s -o /dev/null -m 10 -w '%{size_download}' "$BASE/")
GZ=$(curl -s -o /dev/null -m 10 -H 'Accept-Encoding: gzip' -w '%{size_download}' "$BASE/")
CE=$(hdr -H 'Accept-Encoding: gzip' "$BASE/" | grep -i '^content-encoding:' || true)
if [ -n "$CE" ] && [ "$GZ" -lt "$RAW" ]; then
  ok "gzip 生效" "${RAW}B -> ${GZ}B"
else
  bad "gzip 未生效" "raw=${RAW}B gz=${GZ}B ${CE:-无 Content-Encoding（nginx 片段没更新？）}"
fi

echo "== 3. API 鉴权与数据 =="
[ "$(code "$BASE/api/data")" = "401" ] && ok "无口令 401" || bad "无口令 401"
AH=$(hdr -H "X-Auth: $KEY" "$BASE/api/data")
AET=$(printf '%s' "$AH" | awk 'tolower($1)=="etag:"{print $2}')
printf '%s' "$AH" | head -1 | grep -q ' 200 ' && ok "带口令 200" || bad "带口令 200"
[ -n "$AET" ] && ok "数据带 ETag" "$AET" || bad "数据带 ETag"
[ "$(code -H "X-Auth: $KEY" -H "If-None-Match: $AET" "$BASE/api/data")" = "304" ] \
  && ok "轮询命中 304（不再传全量）" || bad "轮询命中 304"

BODY=$(curl -s -m 10 -H "X-Auth: $KEY" "$BASE/api/data")
V=$(printf '%s' "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("v","?"))' 2>/dev/null)
NR=$(printf '%s' "$BODY" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("rows",[])))' 2>/dev/null)
SUM=$(printf '%s' "$BODY" | python3 -c '
import json,sys
d=json.load(sys.stdin)
t=sum((float(r.get("qty") or 0))*(float(r.get("price") or 0))+(float(r.get("extra") or 0)) for r in d.get("rows",[]))
print(round(t,2))' 2>/dev/null)
echo "     v=$V rows=${NR:-?} 明细合计=¥${SUM:-?}"

echo "== 4. 上传与爬虫 =="
[ "$(code -X POST -H "Content-Type: image/jpeg" --data-binary 'x' "$BASE/api/upload")" = "401" ] \
  && ok "上传无口令 401" || bad "上传无口令 401"
FAKE='<html><script>alert(1)</script></html>'
[ "$(code -X POST -H "X-Auth: $KEY" -H 'Content-Type: image/jpeg' --data-binary "$FAKE" "$BASE/api/upload")" = "400" ] \
  && ok "HTML 冒充图片被拒 400" || bad "HTML 冒充图片被拒 400"
ROB=$(curl -s -m 10 "$BASE/robots.txt")
printf '%s' "$ROB" | grep -q 'Disallow: /' && ok "robots.txt 禁爬" || bad "robots.txt 禁爬"
printf '%s' "$H" | grep -qi 'server: nginx' && echo "     注意：Server 头仍暴露 nginx 版本（server_tokens 需在 server 级改）"

echo ""
echo "结果：$PASS 通过 / $FAIL 失败"
echo "⚠️ 本次未写入任何数据（只有 1 次故意的 400 上传）。"
[ "$FAIL" -eq 0 ] || exit 1
