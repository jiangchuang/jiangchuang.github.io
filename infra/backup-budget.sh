#!/bin/bash
# 备份 budget 账本（在设计上：运行在服务器本机，由 cron 每日触发）
#
# 为什么不先停服务：app.py 写 data.json 用的是 tmp + os.replace 原子替换，
# img/ 是一次性写入的随机文件名，任何时刻读到的都是完整文件。
# 所以这里不做 stop/start —— 加了反而制造停机窗口。
#
# 备份里包含 secret.txt（访问口令）。没有它，恢复后口令会重新生成，
# 浏览器里存的口令全部失效，家人会以为数据丢了。因此：
#   · 包权限固定 600
#   · 这个目录绝不能进公开仓、绝不能挂到网站目录下
#
# 用法：backup-budget.sh [--keep-days N] [--keep-files N] [--quiet]
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/budget}"
DEST="${DEST:-/var/backups/budget}"
KEEP_DAYS="${KEEP_DAYS:-14}"
KEEP_FILES="${KEEP_FILES:-40}"
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-days)  KEEP_DAYS="$2"; shift 2 ;;
    --keep-files) KEEP_FILES="$2"; shift 2 ;;
    --quiet)      QUIET=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

log() { [ "$QUIET" = 1 ] || echo "[$(date '+%F %T')] $*"; }
die() { echo "[$(date '+%F %T')] 失败: $*" >&2; exit 1; }

[ -f "$APP_DIR/data.json" ] || die "$APP_DIR/data.json 不存在，拒绝生成空备份"

mkdir -p "$DEST"
chmod 700 "$DEST"

TS="$(date '+%F_%H%M')"
OUT="$DEST/budget-$TS.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 先把要备份的东西收集到一个干净目录，避免直接 tar 时文件被并发改写 ----
cp -a "$APP_DIR/data.json" "$TMP/data.json"
# 注意：这里不能用 `[ -f x ] && cp` 的写法 —— 文件不存在时整句返回 1，
# 配合 set -e 会静默中断脚本（备份「看起来跑了」其实没跑完）。一律用 if。
if [ -f "$APP_DIR/secret.txt" ]; then cp -a "$APP_DIR/secret.txt" "$TMP/secret.txt"; fi
if [ -d "$APP_DIR/img" ]; then cp -a "$APP_DIR/img" "$TMP/img"; fi

# ---- 清单：证明「备份的是什么」。恢复后靠它比对 ----
ROWS="$(python3 - "$TMP/data.json" <<'PY'
import io, json, sys
try:
    d = json.load(io.open(sys.argv[1], encoding='utf-8'))
    rows = d.get('rows') or []
    todos = d.get('todos') or []
    print(f"{len(rows)}\t{len(todos)}\t{d.get('v','?')}\t{d.get('ts','?')}")
except Exception as e:
    print(f"ERR\t0\t-\t{type(e).__name__}")
PY
)"
ROWS_N="$(echo "$ROWS" | cut -f1)"
TODOS_N="$(echo "$ROWS" | cut -f2)"
VERSION="$(echo "$ROWS" | cut -f3)"
DATA_TS="$(echo "$ROWS" | cut -f4)"

{
  echo "generated_at=$(date '+%F %T %z')"
  echo "host=$(hostname)"
  echo "source=$APP_DIR"
  echo "data_rows=$ROWS_N"
  echo "data_todos=$TODOS_N"
  echo "data_version=$VERSION"
  echo "data_ts=$DATA_TS"
  echo "data_sha256=$(sha256sum "$TMP/data.json" | awk '{print $1}')"
  echo "files:"
  ( cd "$TMP" && find . -type f | sed 's|^\./|  |' | sort )
} > "$TMP/MANIFEST.txt"

# ---- 打包 ----
tar czf "$OUT" -C "$TMP" . || die "tar 失败"
chmod 600 "$OUT"
# 校验文件里的路径必须是「裸文件名」，这样在任何目录下 cd 进去都能 sha256sum -c
( cd "$DEST" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
chmod 600 "$OUT.sha256"

SIZE="$(du -h "$OUT" | awk '{print $1}')"
log "已备份 → $OUT ($SIZE, rows=$ROWS_N, todos=$TODOS_N, v=$VERSION)"

# ---- 自校验：立刻解一遍，防止「备份了个坏包」这种事一年后才发现 ----
tar tzf "$OUT" > /dev/null || die "刚生成的包打不开，这次备份不可信"
log "自校验通过（tar tzf 可读）"

# ---- 清理：按天数 + 按份数双阈值，避免一天跑很多次把磁盘塞满 ----
find "$DEST" -maxdepth 1 -name 'budget-*.tar.gz'     -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
find "$DEST" -maxdepth 1 -name 'budget-*.tar.gz.sha256' -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
ls -1t "$DEST"/budget-*.tar.gz 2>/dev/null | tail -n +$((KEEP_FILES + 1)) | while read -r f; do
  rm -f "$f" "$f.sha256"
done

log "保留 $(ls -1 "$DEST"/budget-*.tar.gz 2>/dev/null | wc -l) 份，占用 $(du -sh "$DEST" | awk '{print $1}')"
