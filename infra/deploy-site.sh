#!/bin/bash
# 一条命令发布静态站：本机 → 服务器
#
# 为什么用 tar 流 + 目录交换，而不是 rsync：
#   1. 这台 Windows 的 Git Bash 只带 scp，没有 rsync（装 cygwin 才能有，不值得）；
#   2. tar 流同样只传差异（gzip 压缩后比裸 rsync 还省），而且不受 Windows 路径/权限干扰；
#   3. 用「解到新目录再整体换过去」代替逐文件删除 —— 本地删了哪个文件，
#      线上就跟着消失，不会留下一堆孤儿页（手动删是最容易忘的一步）。
#
# 用法：
#   deploy-site.sh              # 演练：只统计要传什么、多大，不动服务器
#   deploy-site.sh --apply      # 真发（会保留上一版为 /var/www/blog.old-<时间>）
#   deploy-site.sh --to new     # 发到 env.sh 里的 SERVER_NEW（迁移演练用）
#   deploy-site.sh --apply --allow-large   # 放行 >10MB 的单文件
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/env.sh"

APPLY=0
TARGET="$SERVER"
ALLOW_LARGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --to) [ "$2" = new ] && { [ -n "$SERVER_NEW" ] || { echo "env.sh 里 SERVER_NEW 还是空的" >&2; exit 2; }; TARGET="$SERVER_NEW"; } || TARGET="$2"; shift 2 ;;
    --allow-large) ALLOW_LARGE=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[$(date '+%H:%M:%S')] 失败: $*" >&2; exit 1; }

cd "$ROOT"

# ---- 1. 体积守卫：先看有没有该外置的大文件 ----
BIG="$(find $DEPLOY_PATHS -type f -size +${MAX_FILE_MB}M 2>/dev/null | sort)"
if [ -n "$BIG" ]; then
  echo "以下文件超过 ${MAX_FILE_MB}MB："
  echo "$BIG" | while read -r f; do printf "  %6s  %s\n" "$(du -h "$f" | awk '{print $1}')" "$f"; done
  if [ "$ALLOW_LARGE" = 0 ]; then
    die "先确认这些文件该不该进仓库（视频建议走对象存储/CDN）；确认要发就加 --allow-large"
  fi
  log "已用 --allow-large 放行"
fi

# ---- 2. 打包 ----
# 注意：这里必须用 POSIX 路径做临时文件。Git Bash 的 mktemp 会返回
# C:\Users\...\Temp/tmp.xxx 这种混合路径，传给它自带的 tar 会直接失败。
# 而且**不要**把 tar 的 stderr 丢进 /dev/null —— 那样失败会伪装成「什么都没发生」。
TARBALL="/tmp/deploy-$$.tar.gz"
ls -d $DEPLOY_PATHS > /dev/null 2>&1 || die "DEPLOY_PATHS 里有路径不存在，检查 env.sh"
tar czf "$TARBALL" --exclude='.DS_Store' --exclude='*.bak*' $DEPLOY_PATHS \
  || die "打包失败（上面是 tar 的原始报错）"
SIZE="$(du -h "$TARBALL" | awk '{print $1}')"
# 只数文件，不数目录条目 —— tar 的列表里目录也占一行，拿它跟 find 的文件数比必然不符
NFILE="$(tar tzf "$TARBALL" | grep -v '/$' | wc -l | tr -d ' ')"
HTM="$(tar tzf "$TARBALL" | grep -c '\.html$' || true)"
log "待发布：$NFILE 个文件（页面 $HTM 个），压缩后 $SIZE"

# ---- 3. 台账里的绝对引用检查（可移植性地基）----
ABS="$(grep -rl "45\.117\.\|47\.117\.13\.158\|https://www\.${DOMAIN}/" $DEPLOY_PATHS --include='*.html' --include='*.css' --include='*.json' 2>/dev/null | grep -v 'dm-tools' || true)"
if [ -n "$ABS" ]; then
  echo "注意：以下文件含绝对域名/IP（换域名或上 CDN 时要改）："
  echo "$ABS" | sed 's/^/  /'
fi

if [ "$APPLY" = 0 ]; then
  log "演练结束，服务器未动。要真发：deploy-site.sh --apply"
  exit 0
fi

# ---- 4. 上传并原子换目录 ----
STAMP="$(date '+%Y%m%d_%H%M%S')"
# 先清空暂存目录：上一次中途失败可能留下半套文件，混进这次发布就是「线上有旧文件」的经典来源
log "清理 $WEBROOT.new（上一次失败可能留下残留）"
ssh "$TARGET" "rm -rf $WEBROOT.new && mkdir -p $WEBROOT.new"
cat "$TARBALL" | ssh "$TARGET" "tar xzf - -C $WEBROOT.new" || die "解包失败，$WEBROOT 未受影响"

log "校验解包结果"
REMOTE_N="$(ssh "$TARGET" "find $WEBROOT.new -type f | wc -l" | tr -d ' ')"
if [ "$REMOTE_N" != "$NFILE" ]; then
  die "远端文件数($REMOTE_N) ≠ 本地($NFILE)，中止，线上未动"
fi
log "  文件数一致（$REMOTE_N）"

log "换目录（旧版留作 $WEBROOT.old-$STAMP）"
ssh "$TARGET" "set -e
  chown -R root:nginx $WEBROOT.new 2>/dev/null || chown -R root:root $WEBROOT.new
  find $WEBROOT.new -type d -exec chmod 755 {} \;
  find $WEBROOT.new -type f -exec chmod 644 {} \;
  # Rocky/CentOS 上最常见的「配置没错但 403」就是 SELinux 上下文不对
  command -v chcon >/dev/null && chcon -R -t httpd_sys_content_t $WEBROOT.new 2>/dev/null || true
  [ -d $WEBROOT ] && mv $WEBROOT $WEBROOT.old-$STAMP || true
  mv $WEBROOT.new $WEBROOT
  ls -d $WEBROOT.old-* 2>/dev/null | sort | head -n -2 | xargs -r rm -rf
" || die "换目录失败，检查 $WEBROOT.old-$STAMP 与 $WEBROOT.new"

# ---- 5. 抽样验收（不是 echo done）----
log "验收"
FAIL=0
for u in "/" "/about.html" "/posts/dmsqlq-log-parse.html" "/interactive/dmsqlq-log-parse.html" "/assets/search.json"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $WWW" "https://$WWW$u" || echo 000)"
  printf "  %-42s %s\n" "$u" "$code"
  [ "$code" = 200 ] || FAIL=1
done
# 视频必须支持 Range，否则拖动进度条会从头开始
code="$(curl -s -o /dev/null -w '%{http_code}' -r 0-1023 -H "Host: $WWW" "https://$WWW/interactive/dm-backup-recover.mp4" || echo 000)"
printf "  %-42s %s（应为 206）\n" "mp4 Range 请求" "$code"
[ "$code" = 206 ] || FAIL=1

[ "$FAIL" = 0 ] && log "发布完成，全部验收通过" || log "发布完成，但有验收项未通过（看上面）"
