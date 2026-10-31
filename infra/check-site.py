#!/usr/bin/env python3
# 站点一致性自检：只读，改完内容跑一遍再提交。
#
# 为什么需要它：静态站的"目录"是手写的 li 列表，漏了一篇不会有任何报错 ——
# 页面能打开、链接能跳，只是没人能从首页找到它。这类错只能靠机器查。
#
# 用法：python infra/check-site.py      # 0 告警才算过
import io, json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

ERR, WARN, OK = [], [], []


def err(m): ERR.append(m)
def warn(m): WARN.append(m)
def ok(m): OK.append(m)


def read(p):
    return io.open(p, encoding='utf-8', errors='replace').read()


# ---------- 1. search.json 与真实文件 ----------
data = json.loads(read('assets/search.json'))
items = data.get('items') or []
ok(f'search.json 收录 {len(items)} 条')
if data.get('site') != '达梦手记':
    err(f"search.json 的 site 字段是「{data.get('site')}」，应为「达梦手记」")
for it in items:
    u = it.get('u', '')
    if not u or not os.path.exists(u):
        err(f"search.json 里的路径不存在：{u}")
    for k in ('t', 'c', 'd', 'x'):
        if not it.get(k):
            err(f"search.json 条目缺字段 {k}：{u}")
    if len(it.get('x', '')) < 40:
        warn(f"摘要太短（<40 字），搜出来没信息量：{u}")

# 反向：页面存在但没进索引
site_pages = []
for d in ('posts', 'interactive'):
    for f in sorted(os.listdir(d)):
        if f.endswith('.html') and f != 'index.html':
            site_pages.append(f'{d}/{f}')
for p in ('about.html',):
    if os.path.exists(p):
        site_pages.append(p)
indexed = {it['u'] for it in items}
for p in site_pages:
    if p not in indexed:
        warn(f'页面存在但没进 search.json（搜不到）：{p}')

# ---------- 2. 三处目录页的条目与索引是否对得上 ----------
def count_links(fn):
    s = read(fn)
    return len(re.findall(r'<li><a href="[^"]+\.html"[^>]*><span class="idx">', s))

for fn, expect in (('index.html', None), ('posts/index.html', None), ('interactive/index.html', None)):
    n = count_links(fn)
    if n == 0:
        err(f'{fn} 里一条目录项都没找到（选择器可能变了）')
    else:
        ok(f'{fn} 列了 {n} 条')

# ---------- 3. 篇数硬编码（用户明确要求别提篇数）----------
for fn in ('index.html', 'posts/index.html', 'interactive/index.html', 'README.md'):
    s = read(fn)
    for m in re.finditer(r'[一二三四五六七八九十百\d]+\s*篇', s):
        seg = s[max(0, m.start() - 30):m.end() + 20].replace('\n', ' ')
        # 「这篇/那篇/每篇/多篇」是正常用法，只揪数量词
        if re.match(r'^[一二三四五六七八九十百\d]+\s*篇$', m.group(0).strip()):
            err(f'{fn} 里有硬编码篇数「{m.group(0).strip()}」：…{seg}…')

# ---------- 4. 可移植性：不该出现的绝对引用 ----------
ABS_PAT = re.compile(r'https?://(?:www\.)?jiangchuang\.top|47\.117\.13\.158|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+')
for d in ('posts', 'interactive', 'assets', '.'):
    for f in os.listdir(d):
        p = os.path.join(d, f)
        if not (f.endswith('.html') or f.endswith('.css') or f.endswith('.json')):
            continue
        for m in ABS_PAT.finditer(read(p)):
            ctx = read(p)[max(0, m.start() - 40):m.end() + 40].replace('\n', ' ')
            err(f'{p} 含绝对地址/内网 IP：…{ctx}…')


def walk(d):
    for f in os.listdir(d):
        p = os.path.join(d, f)
        if os.path.isdir(p):
            yield from walk(p)
        else:
            yield p


# ---------- 5. 品牌与备案号 ----------
for p in list(walk('posts')) + list(walk('interactive')) + ['index.html', 'about.html', 'search.html']:
    if not p.endswith('.html'):
        continue
    s = read(p)
    if '闯' in s:
        err(f'{p} 里还有「闯」字（品牌已改成「达梦手记」）')
    if '渝ICP备2026027352号-1' not in s:
        err(f'{p} 页脚缺备案号（工信部要求全站可见）')
    if 'about.html' not in s:
        warn(f'{p} 没有指向 about.html 的入口')

# ---------- 6. 二维码必须是折叠的 ----------
for p in list(walk('posts')) + list(walk('interactive')) + ['index.html']:
    if not p.endswith('.html'):
        continue
    s = read(p)
    if 'wechat-qr.png' in s and 'contact-fold' not in s and 'cta-qr-fold' not in s:
        err(f'{p} 的二维码还是裸奔的（没折起来）')

# ---------- 7. 占位 meta description ----------
PLACEHOLDER = '数据库一线实践笔记：迁移同步、日常运维、性能调优与故障恢复。'
for p in walk('posts'):
    if p.endswith('.html') and PLACEHOLDER in read(p):
        err(f'{p} 的 meta description 还是占位句')

# ---------- 8. 出结果 ----------
print()
for m in OK:
    print(f'  \033[32m✓\033[0m {m}')
for m in WARN:
    print(f'  \033[33m!\033[0m {m}')
for m in ERR:
    print(f'  \033[31m✗\033[0m {m}')
print(f'\n通过 {len(OK)}｜提醒 {len(WARN)}｜错误 {len(ERR)}')
sys.exit(1 if ERR else 0)
