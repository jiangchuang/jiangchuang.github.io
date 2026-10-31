#!/bin/bash
# 唯一事实源：域名、路径、端口、保留份数都写在这里。
# 别的脚本只 `source env.sh`，不许自己硬编码 IP 和路径 ——
# 换机器的时候，只需要改这一个文件。

# ---- 域名与证书 ----
DOMAIN="jiangchuang.top"
WWW="www.${DOMAIN}"
APP_HOST=""                          # 预留：budget 子域（迁移时再启用，现在用 /budget/ 路径）
CERT_DIR="/etc/nginx/ssl"
CERT_NAME="${DOMAIN}.cer"            # 与 acme.sh --install-cert 的落点保持一致
KEY_NAME="${DOMAIN}.key"
ACME_HOME="/root/.acme.sh"
ACME_WEBROOT="/var/www/blog"         # webroot 模式：challenge 文件写在站点根下

# ---- 服务器 ----
# 公开仓里不留真实地址：这里只是占位，真实值写在同目录 env.local（已 gitignore）。
SERVER="root@CHANGE-ME.invalid"      # 占位，被 env.local 覆盖
SERVER_NEW=""                        # 迁移时填新机 IP，其余脚本用 --to new 切换
WEBROOT="/var/www/blog"
APP_DIR="/opt/budget"
APP_PORT="8082"

# ---- 备案（页面页脚要显示）----
ICP="渝ICP备2026027352号-1"

# ---- 备份 ----
BACKUP_REMOTE="/var/backups/budget"
BACKUP_LOCAL="I:/backups/budget"
BACKUP_KEEP_DAYS=14                  # 服务器上保留天数
BACKUP_KEEP_FILES=40                 # 服务器上最多几份（防一天跑多次）
PULL_KEEP_DAYS=30                    # 本机异地副本保留天数

# ---- 发布 ----
# 只发这些路径。用白名单而不是黑名单：新加一个目录时，宁可忘记发布，
# 也不要把 infra/（含 IP、SSH 用法）或 projects/ 推上公网。
DEPLOY_PATHS="index.html about.html search.html assets posts interactive"
MAX_FILE_MB=10                       # 单文件超过它就不许发布（改走对象存储/CDN）

# ---- 本机私有值（不进公开仓）----
# 这个仓是公开的，服务器地址这类东西不能写进被跟踪的文件。
# 真值放 env.local，那一行在 .gitignore 里；没有 env.local 时用上面的占位，
# 脚本会因为连不上 CHANGE-ME.invalid 立刻报错，而不是悄悄用错地址。
_ENV_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.local"
if [ -f "$_ENV_LOCAL" ]; then
  # shellcheck disable=SC1090
  . "$_ENV_LOCAL"
fi
