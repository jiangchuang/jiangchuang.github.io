# 装修预算 · 协同账本

给家里装修记账用的双人协作小应用：两个人（手机或电脑）打开同一个链接，各自改格子，停止输入约 1 秒自动保存，**按行合并、不会互相覆盖**。

- **前端** `index.html` —— 单文件，内联 CSS/JS，零外部依赖（不引 CDN、不引图表库），断网也能打开看
- **后端** `app.py` —— Python 3.6+ 标准库，零第三方包（线上机是 Rocky 8 自带 Python 3.6.8）
- **数据** `data.json` —— 单个 JSON + 版本号乐观锁；图片单独落盘到 `img/`

## 放在这里的原因

本站（博客）跑在 `47.117.13.158:80`；应用跑在同一台机器的 `127.0.0.1:8082`，由 nginx 反代到 `/budget/`。源码放博客仓的 `projects/` 下，跨机取用和迭代都方便。

```
浏览器 ──> nginx(:80) ──/budget/──> 127.0.0.1:8082 (python3 app.py)
                                        └── data.json   唯一数据源
                                        └── img/        待办配图
```

## 功能

| 模块 | 说明 |
|---|---|
| 明细表 | 13 列（分类/项目/数量/单位/单价/附加费/品牌/规格/供应商/进度/备注/小计/操作），点格即改，`Esc` 撤销本格 |
| 汇总 | 明细合计、不可预见费（费率可改，默认 5%）、预算总额，实时联动 |
| 预算占比 | 手写 SVG 环形图。悬停扇区/图例 → 其他段变淡、中心显示该分类占比与金额、**表格对应行同步高亮**；点击 → 按分类筛选，再点取消 |
| 进度分布 | 按金额的 100% 堆叠横条；只有一类时自动收起并给提示 |
| 近期待办 | 可手动添加，日期默认本周六，2 天内标橙、过期标红；可附一张参考图（点缩略图全屏看）；完成后划线沉底 |
| 排序 | 点表头：升序 → 降序 → 回到原始顺序。手机端表头是隐藏的，改用工具条上的「排序」下拉。**排序只改视图**，保存与 CSV 导出仍按原始顺序。正在格子里打字时顺序会冻住（否则改单价、行在手底下跳走），离开格子约 0.2 秒后自动摆回排序该有的位置 |
| 其他 | 分类/进度筛选、全文搜索（打开页面光标就在搜索框；之后按 `/` 或 `Ctrl+K` 随时回去，`Esc` 清空）、复制行、删除行（`Ctrl+Z` 撤销）、导出 CSV、打印 |

搜索/筛选生效时，表格底部会写「筛选 N / 共 M 项」，避免合计看着像少了东西。别人改了行，8 秒轮询同步过来时那几行会闪一下淡橙色（2.4 秒）——否则你根本不知道表格哪儿变了。

## 数据模型

`data.json` 顶层：

| 字段 | 含义 |
|---|---|
| `v` | 版本号，每次成功写入 +1，用于乐观锁 |
| `ts` / `who` | 最后保存时间 / 保存人（浏览器本地记的名字） |
| `rate` | 不可预见费费率（百分数，如 `5`） |
| `title` | 页面标题 |
| `rows[]` | 明细行，字段见下 |
| `todos[]` | 待办，`{id, text, due, img, by, done}` |

`rows[]` 单行字段：`id, cat, name, qty, unit, price, extra, brand, spec, sup, prog, note`。
其中 `qty / price / extra` 是数值，其余是字符串；后端按白名单过滤，未知字段丢弃。

## 接口

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| GET | `/` | 否 | 前端单页。带 `ETag`，`If-None-Match` 命中回 `304`（刷新不再重下 58KB） |
| GET | `/api/data` | 口令 | 读全量数据。带 `ETag`，未变更回 `304`（8 秒轮询靠这个省流量） |
| PUT | `/api/data` | 口令 | 写数据。`200` 成功（回 `v` 与**新 ETag**）、`400` 参数非法、`409` 版本冲突（返回 `data` 供前端行级合并） |
| POST | `/api/upload` | 口令 | 上传配图（二进制），返回 `{url:"img/xxxx.jpg"}`；按**文件头**校验真实类型 |
| GET | `/img/<name>` | 否 | 读配图，文件名 18 位随机 hex，`max-age=604800, immutable` |
| GET | `/api/health` | 否 | 健康检查 |
| GET | `/robots.txt` | 否 | `Disallow: /`（另加 `<meta name="robots" content="noindex">` 双保险） |

口令取 `secret.txt` 首行；文件不存在则首次启动自动生成。请求头 `X-Auth: <口令>`，也接受 `?k=<口令>`（仅首次点链接用，前端随即存进 localStorage，之后所有请求——含上传——都只走 `X-Auth` 头）。

> 上传曾经把口令拼在 URL 上（`api/upload?k=...`），会原样落进 nginx access log。现在统一走 `X-Auth`，并且 nginx 片段对 `/budget/` 直接 `access_log off`。

## 响应头

后端对**所有**响应统一附加（见 `Handler.SEC_HEADERS`）：

| 头 | 值 | 为什么 |
|---|---|---|
| `X-Content-Type-Options` | `nosniff` | 不让浏览器猜类型（配合上传校验） |
| `Referrer-Policy` | `no-referrer` | 链接里带 `?k=`，外跳时别把口令带给别人 |
| `X-Frame-Options` | `SAMEORIGIN` | 防点击劫持 |
| `Content-Security-Policy` | `default-src 'self'; img-src 'self' data: blob:; …` | 只允许同源，挡掉外部脚本注入 |
| `Cache-Control` | 首页/数据 `no-cache`（必须回源校验）、API 写操作 `no-store` | 配合 ETag 做协商缓存 |

## 本地跑起来

```bash
cd projects/budget
cp data.sample.json data.json       # 示例数据，3 行 + 1 条待办
python3 app.py 8099
# 浏览器打开 http://127.0.0.1:8099/ ，口令见本地生成的 secret.txt
```

Windows 上 `python app.py 8099` 同理。Python 3.6 即可，无需建虚拟环境。

## 部署（线上机 `47.117.13.158`）

```bash
scp app.py index.html root@47.117.13.158:/opt/budget/
ssh root@47.117.13.158 'systemctl restart budget'      # unit 里已 Restart=always
```

首次部署（或改了 unit/nginx 片段）跑一遍幂等脚本：

```bash
scp budget.service budget.nginx deploy.sh root@47.117.13.158:/opt/budget/
ssh root@47.117.13.158 'bash /opt/budget/deploy.sh'
```

`deploy.sh` 会：装 systemd unit → 装 nginx 片段 → 往 `nginx.conf`（IP 直连）与 `conf.d/blog.conf`（域名）各插一行 `include`（**改前备份 `*.bak_budget_*`**）→ `nginx -t` → reload → 本机自测。

> ⚠️ 这台机器上还跑着达梦 `dmserver(5666)` 与 `dmap(4236)`，**只碰 `/opt/budget`、`budget.service` 和 nginx 片段，别动它们**。

切换/回滚数据：

```bash
ssh root@47.117.13.158 'cp /opt/budget/data.json /opt/budget/data.$(date +%F).json'   # 备份快照
ssh root@47.117.13.158 'journalctl -u budget -n 50 --no-pager'                       # 看日志
```

## 已知限制（也是可以下手优化的地方）

1. **待办是整体合并**，不是逐条合并。两人同时改待办时，后保存的会覆盖前者（明细行是逐行合并的，不受影响）。要改成逐条合并得动协议（每行加 `updTs` 或删除墓碑），没实测过的并发场景不敢上。
2. ~~轮询 8 秒全量拉取~~ → **已改**：加 `ETag` + `If-None-Match`，对方没改动时后端只回 304（约 300 字节），不再每次传 7KB 全量。
3. **单口令，无用户体系**。已缓解（上传改走 `X-Auth`、nginx 对 `/budget/` 关访问日志、加 `no-referrer`），但地址栏首次仍会出现 `?k=`。彻底解决要登录态 Cookie。
4. **只有 `.bak`，无历史版本**。想回溯只能靠外部快照。
5. **CSV 导出在前端拼字符串**，几千行以上会卡。
6. **打印样式没做 A4 分页控制**，长表会断在奇怪的位置。
7. 表格不支持列宽拖拽、列排序。
8. 无 PWA，手机上不能离线打开。
9. **HTTPS 还没上**。站点走 80 明文，`?k=` 在此环境下可被中间人看到。要上得先有证书（IP 签不了 DV，得用域名 + 备案，而 `jiangchuang.top` 现在被备案阻断）。

改代码时注意：**线上是 Python 3.6.8**，别用 3.7+ 语法（`:=`、`dataclasses`、`from __future__ import annotations` 那套）。前端为了能单文件离线用，**不引入任何外部库**。

## 验证

```bash
# 1) 本地起一个测试实例（会写数据，别指线上目录）
cp data.sample.json data.json && python3 app.py 8099
python3 smoke_test.py http://127.0.0.1:8099 "$(cat secret.txt)"      # 16 项全链路

# 2) 线上只读验收（不改数据，可随时跑）
bash check_prod.sh <口令> http://47.117.13.158/budget
```

`smoke_test.py` 覆盖：鉴权、304 协商、乐观锁（正确/过期/非法 `base_v`）、上传类型校验、`robots.txt`、重复 id 去重。
`check_prod.sh` 覆盖：首页与数据的 304、五项安全头、gzip 压缩比、401/400 分支、账目条数与合计（只读，最后打印 `v`/rows/合计供人工比对）。

## 文件

| 文件 | 说明 |
|---|---|
| `app.py` | 后端（静态页 + API + 图片上传） |
| `index.html` | 前端单页（内联 CSS/JS） |
| `budget.service` | systemd unit（`127.0.0.1:8082`，开机自启） |
| `budget.nginx` | nginx 片段（`/budget/` 反代 + gzip + 关访问日志） |
| `deploy.sh` | 幂等部署脚本 |
| `smoke_test.py` | 接口冒烟测试（**会写数据**，只对测试实例跑） |
| `check_prod.sh` | 线上只读验收（不改数据） |
| `data.sample.json` | 示例数据（**真实账目不入库**） |
| `secret.txt` `data.json` `img/` | 运行时生成，已在 `.gitignore` 中排除 |
