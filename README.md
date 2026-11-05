# 达梦手记

达梦现场那些"搜不到、或者搜到了也不敢信"的问题，写成照着做就能做对的东西。

**正式站：<https://www.jiangchuang.top/>**（渝ICP备2026027352号-1）

**镜像：<https://jiangchuang.github.io>**

---

## 关于

我在达梦数据库（DM8）一线交付与运维中整理下来的实践记录。内容准则见 [`STYLE.md`](STYLE.md)（唯一事实源）。

大部分选题有两个版本，按你的习惯挑：

- **交互版**（`interactive/`）：分步卡片 + 命令一键复制 + 实测输出，现场照着敲最顺手
- **长文版**（`posts/`）：命令与输出逐条对应，可被搜索引擎收录、可被引用

选题尽量做到 **具体报错原文 + 具体版本 + 具体场景**，方便遇到同样问题的人按关键词搜到。

## 内容

| 交互版 | 长文版 | 分类 |
|---|---|---|
| 主备集群：重启与主备切换 | [达梦主备集群：重启与切换的完整操作](posts/dm-reboot-switchover.html) | 高可用与集群 |
| 在线更换授权文件 dm.key（不停机） | [达梦数据库在线更换授权文件（不停机版）](posts/dm-license-update.html) | 日常运维 |
| 利用备份恢复误删表（dmrman 时间点恢复） | [达梦利用备份恢复误删表（时间点恢复）](posts/dm-backup-recover.html) | 故障恢复 |
| 数据文件 .DBF 误删后的恢复（句柄法） | [数据文件误删后的恢复方案](posts/recover-deleted-dbf.html) | 日常运维 |
| 命令行交付实操：登录、表空间、授权与建表 | — | 交付 |
| SQL 日志怎么读：把 `?` 还原成真实参数（dmsqlq） | [同题长文](posts/dmsqlq-log-parse.html) | 工具 |
| — | [Python 连接达梦：三条通道怎么选](posts/python-dm-connection-channels.html) | 应用开发 |
| — | [Flink CDC 接达梦：卡住你的不是连接器，是日志里的 ID](posts/dm-cdc-logmnr-id.html) | 日常运维 |
| — | [把「难」拆开：四种难，四种解法](posts/how-to-decompose-hard-problems.html) | 工作方法 |

完整清单以 [`assets/search.json`](assets/search.json) 为准（站内搜索也读这个文件）。

## 自研工具

现场反复要敲的东西，能脚本化的做成了单文件程序，安装包放在独立的发布仓：

**<https://gitee.com/jiangchuang/dm-tools>**（只放编译好的包，不放源码）

| 工具 | 干什么 |
|---|---|
| `dmsqlq` | 把 `dmsql_*.log` 里带 `?` 的 SQL 按 `PARAMS` 行还原成真实参数，导出可执行 SQL，按累计耗时排优化优先级 |
| `dmkit` | 运维诊断工具箱：P0 巡检、ASH 体检、锁阻塞树、执行计划、故障取证包 |

## 站点结构

```
index.html            首页
search.html           站内搜索页
about.html            本站说明（为什么有这个地方）
STYLE.md              内容准则（唯一事实源）
interactive/*.html    交互版
posts/*.html          长文版
assets/site.css       全站样式（两套主题的变量都在这一个文件里）
assets/search.json    搜索索引
assets/video/         长文版内嵌的录屏
.nojekyll             关闭 Jekyll，纯静态直出
infra/                换机器/备份/发布用的脚本（不随站点发布）
projects/*/           站外小项目源码（不随站点发布，各自有 README）
```

纯静态站点：**无后端、无构建步骤**，克隆下来直接打开 `index.html` 就能看。

`infra/` 和 `projects/` 不会被部署到线上——前者是运维脚本，后者是独立项目（目前有 `projects/budget/`：家庭装修预算协同账本）。

## 主题

内置两套配色，导航栏右上角按钮切换，选择记在浏览器本地：

| 主题 | 风格 |
|---|---|
| `ink`（默认） | 水墨 —— 宣纸底 + 朱砂 + 衬线标题 |
| `dark` | 墨夜 —— 深色底 + 青色 + 无衬线 |

想加第三套：复制 `assets/site.css` 里 `html[data-theme="dark"]{ ... }` 那一块，
改个名字和颜色值即可 —— 组件样式全部走 CSS 变量，不用碰。

## 说明

- 文章原稿（Markdown）另存于本地，本仓库只存渲染后的静态页。
- 页面里的录屏是正文的一部分，体积较大，浏览时注意流量。
- 联系邮箱：jiang-chuang@qq.com
