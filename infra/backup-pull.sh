#!/bin/bash
# 把服务器上的 budget 备份拉到本机（异地副本）
#
# 为什么要异地：服务器上 /var/backups/budget 和 /opt/budget 在同一块盘。
# 盘坏了、机器退了、误删了 —— 那份备份跟原数据一起没。同机同盘 = 没有备份。
#
# 本机没有 rsync（Git Bash 只带 scp），所以这里用「远端列清单 + 逐个 scp 缺失文件」，
# 零外部依赖。备份包很小（几十 KB 级），全量比对也不心疼。
#
# 用法：
#   backup-pull.sh              拉取缺的文件并清理过期
#   backup-pull.sh --verify     额外做一次恢复演练（解包到临时目录比对行数，不动线上）
#   backup-pull.sh --list       只列两端差异
set -euo pipefail

# 这个仓是公开的，真实服务器地址放在 env.local（已 gitignore），不写在这里。
_BACKUP_PULL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_BACKUP_PULL_DIR/env.local" ]; then
  # shellcheck disable=SC1090
  . "$_BACKUP_PULL_DIR/env.local"
fi

SERVER="${SERVER:-root@CHANGE-ME.invalid}"
REMOTE_DIR="${REMOTE_DIR:-/var/backups/budget}"
LOCAL_DIR="${LOCAL_DIR:-I:/backups/budget}"
KEEP_DAYS="${KEEP_DAYS:-30}"

MODE=pull
case "${1:-}" in
  --verify) MODE=verify ;;
  --list)   MODE=list ;;
  "")       ;;
  *) echo "未知参数: $1" >&2; exit 2 ;;
esac

log() { echo "[$(date '+%F %T')] $*"; }
die() { echo "[$(date '+%F %T')] 失败: $*" >&2; exit 1; }

mkdir -p "$LOCAL_DIR"

# ---- 远端清单（只要包名，不要路径）----
REMOTE_LIST="$(ssh -o ConnectTimeout=10 "$SERVER" "ls -1 $REMOTE_DIR/budget-*.tar.gz 2>/dev/null || true" | xargs -r -n1 basename)"
[ -n "$REMOTE_LIST" ] || die "远端 $REMOTE_DIR 里没有备份包（先跑一次 backup-budget.sh）"

TOTAL=$(echo "$REMOTE_LIST" | wc -l | tr -d ' ')
NEW=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [ ! -f "$LOCAL_DIR/$f" ]; then
    if [ "$MODE" = list ]; then
      echo "  缺 $f"
    else
      scp -q "$SERVER:$REMOTE_DIR/$f" "$LOCAL_DIR/" || { echo "  拉取失败 $f" >&2; continue; }
      scp -q "$SERVER:$REMOTE_DIR/$f.sha256" "$LOCAL_DIR/" 2>/dev/null || true
      NEW=$((NEW + 1))
    fi
  fi
done <<< "$REMOTE_LIST"

if [ "$MODE" = list ]; then
  log "远端 $TOTAL 份，本地 $(ls -1 "$LOCAL_DIR"/budget-*.tar.gz 2>/dev/null | wc -l | tr -d ' ') 份"
  exit 0
fi

[ "$NEW" -gt 0 ] && log "本次新拉取 $NEW 份" || log "本地已是最新，无需拉取"

# ---- 清理本地过期（按天数）----
find "$LOCAL_DIR" -maxdepth 1 -name 'budget-*.tar.gz' -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
find "$LOCAL_DIR" -maxdepth 1 -name 'budget-*.tar.gz.sha256' -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true

LOCAL_N=$(ls -1 "$LOCAL_DIR"/budget-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
log "本地共 $LOCAL_N 份，占用 $(du -sh "$LOCAL_DIR" 2>/dev/null | awk '{print $1}')"

# ---- 恢复演练：证明「这个包真的能恢复」，而不只是「文件存在」----
if [ "$MODE" = verify ]; then
  NEWEST=$(ls -1t "$LOCAL_DIR"/budget-*.tar.gz | head -1)
  log "演练包：$(basename "$NEWEST")"
  bash "$(dirname "$0")/restore-budget.sh" --from "$NEWEST" --dry-run
fi
