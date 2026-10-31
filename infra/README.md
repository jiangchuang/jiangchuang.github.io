# infra · 换机器工具箱

这里的脚本**不随站点发布**（`deploy-site.sh` 用白名单，只发页面和资源）。
原因是它们包含服务器 IP、备份策略、SSH 用法——这些不该出现在公网可读的目录里。

## 三条最常用的命令

```bash
./infra/deploy-site.sh              # 演练：只统计要传什么，不动服务器
./infra/deploy-site.sh --apply      # 真发（旧版自动留成 /var/www/blog.old-<时间>）
./infra/verify.sh                   # 全面体检：站点 + 应用 + 证书 + 备份 + 磁盘
python infra/check-site.py          # 内容一致性：目录/索引/脱敏/备案号
```

## 文件清单

| 文件 | 干什么 | 状态 |
|---|---|---|
| `env.sh` | **唯一事实源**：域名、路径、端口、保留份数。换机只改这一个文件 | 正常 |
| `deploy-site.sh` | 本机 → 服务器发布（tar 流 + 目录交换，替代 rsync） | 正常 |
| `backup-budget.sh` | 服务器端打包账本（data.json + secret.txt + img），带 sha256 与行数清单 | 已实跑 |
| `backup-pull.sh` | 把备份拉到本机 `I:/backups/budget`（异地副本） | 已实跑 |
| `restore-budget.sh` | 从备份恢复；默认 `--dry-run` 只演练 | 已实跑（含 --apply） |
| `verify.sh` | 一次跑完全部验收 | 已实跑 |
| `check-site.py` | 站点一致性自检，0 错误才算过 | 已实跑 |
| `cert-issue.sh` | `--mode check/copy/issue` 证书三件事 | `check` 已实跑 |
| `nginx/blog.conf.tpl` | vhost 模板（301 下沉到 location，含 ACME 前置） | 与现网一致 |
| `rebuild-server.sh` | 新机一键重建 | ⚠️ **未在真实新机跑过**，首次使用请人工盯输出 |
| `tools/build-tools-release.sh` | 交叉编译三个平台 + 打包 + 生成 CHECKSUMS | 已实跑 |
| `MIGRATION.md` | 换机 8 步清单（顺序即正确性） | — |

## 几条设计上的「为什么」

- **不用 rsync**：这台 Windows 的 Git Bash 只带 scp。tar 流同样只传差异，还不受 Windows 权限位干扰。
- **目录交换而不是逐文件删除**：本地删掉一篇文章，线上要跟着消失。手工删是最容易忘的一步。
- **发布用白名单不用黑名单**：新加一个目录时宁可忘记发布，也不要把 `infra/` 推上公网。
- **备份要含 `secret.txt`**：否则恢复后口令重新生成，家人以为数据丢了。代价是备份包含凭据 → 包权限 600、永不进公开仓。
- **不做 `stop` 再备份**：`app.py` 用 `tmp + os.replace` 原子写，随时读都是完整文件。加 stop/start 反而制造停机窗口。
