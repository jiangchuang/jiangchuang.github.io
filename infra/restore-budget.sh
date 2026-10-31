#!/bin/bash
# 从备份包恢复 budget 账本（默认只演练，不落盘）
#
# 两种用法：
#   restore-budget.sh --from <包> --dry-run     只在临时目录解包比对，线上一个字节不动
#   restore-budget.sh --from <包> --apply       真恢复（会 stop 服务、留快照、start、自测）
#
# 设计要点：
#   1. 先校 sha256，再解包 —— 坏包不往下走
#   2. 用 MANIFEST 里的行数与实际解出来的 data.json 对比 —— 这是唯一能证明「真的恢复了」的指标
#   3. apply 前把现有 /opt/budget 整个目录快照成 .pre-restore-<时间>，恢复错了能一步退回
#   4. 恢复后跑 projects/budget/smoke_test.py（若存在），不靠「我觉得应该没问题」
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/budget}"
FROM=""
MODE=dry

# 只有操作默认目录时才接管 systemd。指向别处（演练副本）时纯文件操作，
# 这样可以在 /tmp 的副本上把 --apply 全流程真跑一遍，完全不碰线上服务。
SVC=""
[ "$APP_DIR" = "/opt/budget" ] && SVC=budget.service

while [ $# -gt 0 ]; do
  case "$1" in
    --from)  FROM="$2"; shift 2 ;;
    --dry-run) MODE=dry; shift ;;
    --apply)   MODE=apply; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "[$(date '+%F %T')] 失败: $*" >&2; exit 1; }

[ -n "$FROM" ] || die "必须指定 --from <备份包>"
[ -f "$FROM" ] || die "备份包不存在: $FROM"

# ---- 1. 校验 ----
if [ -f "$FROM.sha256" ]; then
  ( cd "$(dirname "$FROM")" && sha256sum -c "$(basename "$FROM").sha256" ) || die "sha256 不匹配，包已损坏"
  log "sha256 校验通过"
else
  log "注意：没有 .sha256 校验文件，跳过完整性校验（老包可能没生成）"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar xzf "$FROM" -C "$TMP" || die "解包失败"
[ -f "$TMP/data.json" ] || die "包里没有 data.json"

# ---- 2. 比对 ----
MANIFEST_ROWS="$(grep -E '^data_rows=' "$TMP/MANIFEST.txt" 2>/dev/null | cut -d= -f2 || echo '?')"
ACTUAL="$(python3 - "$TMP/data.json" <<'PY'
import io, json, sys
d = json.load(io.open(sys.argv[1], encoding='utf-8'))
print(f"{len(d.get('rows') or [])}\t{len(d.get('todos') or [])}\t{d.get('v','?')}")
PY
)"
ACT_ROWS="$(echo "$ACTUAL" | cut -f1)"
ACT_TODOS="$(echo "$ACTUAL" | cut -f2)"
ACT_VER="$(echo "$ACTUAL" | cut -f3)"

log "包内数据：rows=$ACT_ROWS todos=$ACT_TODOS v=$ACT_VER｜清单记录：rows=$MANIFEST_ROWS"
[ "$MANIFEST_ROWS" = "$ACT_ROWS" ] || die "行数对不上（清单 $MANIFEST_ROWS ≠ 实际 $ACT_ROWS），这个包不可信"

IMG_N=$(find "$TMP/img" -type f 2>/dev/null | wc -l | tr -d ' ')
log "包内图片 $IMG_N 张，secret.txt $([ -f "$TMP/secret.txt" ] && echo 有 || echo 无)"

if [ "$MODE" = dry ]; then
  log "演练结束：包可解、数据可读、行数与清单一致。线上未做任何改动。"
  exit 0
fi

# ---- 3. 真恢复 ----
[ -f "$APP_DIR/data.json" ] || die "$APP_DIR 看起来不像 budget 目录，拒绝恢复"
STAMP="$(date '+%Y%m%d_%H%M%S')"
SNAP="$(dirname "$APP_DIR")/$(basename "$APP_DIR").pre-restore-$STAMP"

svc() { [ -n "$SVC" ] || return 0; systemctl "$1" "$SVC"; }

log "停服务${SVC:+（$SVC）}"
svc stop || true

log "快照现有数据 → $SNAP"
cp -a "$APP_DIR" "$SNAP" || { svc start; die "快照失败，已重启服务"; }

log "落盘"
install -o root -g root -m 600 "$TMP/data.json" "$APP_DIR/data.json"
if [ -f "$TMP/secret.txt" ]; then
  install -o root -g root -m 600 "$TMP/secret.txt" "$APP_DIR/secret.txt"
fi
if [ -d "$TMP/img" ]; then
  mkdir -p "$APP_DIR/img"
  cp -a "$TMP/img/." "$APP_DIR/img/"
fi

log "启服务${SVC:+（$SVC）}"
svc start
if [ -n "$SVC" ]; then
  sleep 1
  systemctl is-active --quiet "$SVC" || { log "服务没起来，回滚"; rm -rf "$APP_DIR"; mv "$SNAP" "$APP_DIR"; svc start; die "已回滚到恢复前状态"; }
fi

# ---- 4. 自测 ----
if [ -f "$APP_DIR/smoke_test.py" ]; then
  log "跑 smoke_test.py"
  ( cd "$APP_DIR" && python3 smoke_test.py ) || log "smoke_test 有失败项，请人工看上面输出"
fi

AFTER="$(python3 - "$APP_DIR/data.json" <<'PY'
import io, json, sys
d = json.load(io.open(sys.argv[1], encoding='utf-8'))
print(len(d.get('rows') or []))
PY
)"
log "恢复完成：线上 rows=$AFTER（期望 $ACT_ROWS）"
[ "$AFTER" = "$ACT_ROWS" ] || die "恢复后行数不一致，快照保留在 $SNAP"
log "快照保留在 $SNAP（确认无误后可删）"
