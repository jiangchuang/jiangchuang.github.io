#!/usr/bin/env python3
# 把工作区里的两篇 DTS 长文（自带独立样式的单页 HTML）转成站点文章。
#
# 为什么要有这个脚本：源稿是「一份 HTML 自带 CSS」的形态，方便单独分享；
# 站点这边有 nav / 主题变量 / 页脚备案号 / 目录索引。手工粘一次能成，
# 但改稿要再粘一次，第二次一定漏东西（我漏过页脚）。所以做成幂等的转换。
#
# 用法：python infra/import-dts-posts.py            # 只转换，不动索引
#      源目录默认取环境变量 DTS_SRC，没有就用下面的 DEFAULT_SRC
import io
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SRC = r'C:\Users\JC\WorkBuddy\2026-10-22-10-33-19'
SRC = os.environ.get('DTS_SRC', DEFAULT_SRC)

IMG_DIR = os.path.join(ROOT, 'assets', 'dts')

# 源稿里的私有变量 → 站点主题变量（不映射的话行内 style 会静默失效）
VARMAP = {
    '--ink': '--text',
    '--sub': '--text-3',
    '--blue': '--accent',
    '--blue-soft': '--accent-soft',
    '--soft': '--bg-2',
    '--warn-soft': '--bg-2',
    '--ok-soft': '--bg-2',
}

POSTS = [
    {
        'src': 'DTS博客-01-命令行定时迁移.html',
        'out': 'posts/dm-dts-once-sync.html',
        'title': '没有图形界面的服务器，怎么把达梦的数据搬过去？',
        'h1': '没有图形界面的服务器，<br>怎么把达梦的数据搬过去？',
        'date': '2026-11-04',
        'cat': '迁移同步',
        'desc': ('服务器没装图形界面、隔着 VPN 迁库又慢，怎么办：在 Windows 上把达梦 DTS 任务配好，'
                 '复制它生成的 XML，传到服务器用命令行跑一次。含 8 步动图、4 条踩坑（进度无百分比、'
                 '退出码不可信、重跑会重复写入、OOM 后假死）与实跑输出。'),
        'links': {'DTS博客-02-代理模式.html': 'dm-dts-agent-mode.html'},
    },
    {
        'src': 'DTS博客-02-代理模式.html',
        'out': 'posts/dm-dts-agent-mode.html',
        'title': '界面照旧点点点，数据不绕 VPN：达梦 DTS 代理模式',
        'h1': '界面照旧点点点，数据不绕 VPN：<br>达梦 DTS 代理模式',
        'date': '2026-11-04',
        'cat': '迁移同步',
        'desc': ('服务器没有图形界面、或者不想让数据绕 VPN？在服务器起一个 DTS 代理，Windows 界面只当遥控器，'
                 '数据全程在服务器内网流动。含端口怎么挑、防火墙怎么放行、代理节点在哪，'
                 '以及与「命令行跑 XML」的优劣势对照与选型判据。'),
        'links': {'DTS博客-01-命令行定时迁移.html': 'dm-dts-once-sync.html'},
    },
]

# 站点没有的提示块/流程图/播放器样式，补在这里；全部用主题变量，两套配色都成立
EXTRA_CSS = '''
/* ---- 本文补充组件（用站点主题变量，ink / dark 两套配色都成立）---- */
.content .lead{background:var(--accent-soft);border-left:3px solid var(--accent);padding:15px 19px;
  border-radius:0 var(--radius-lg) var(--radius-lg) 0;margin:24px 0;font-size:15.5px}
.content .lead p{margin:8px 0 0}
.content .warn,.content .ok{border-left:3px solid var(--line-2);background:var(--bg-2);
  padding:13px 17px;border-radius:0 var(--radius-lg) var(--radius-lg) 0;margin:20px 0;font-size:15px}
.content .warn{border-left-color:#c9881e}
.content .ok{border-left-color:var(--accent)}
.content .warn p:first-child,.content .ok p:first-child{margin-top:0}
.content .warn p:last-child,.content .ok p:last-child{margin-bottom:0}
.content .cap{font-size:13px;color:var(--text-3);text-align:center;margin:4px 0 26px;line-height:1.7}
.content img{margin-left:auto;margin-right:auto}
.content pre{background:var(--code-bg);color:var(--code-fg);padding:18px 20px;
  border-radius:var(--radius-lg);overflow-x:auto;margin:20px 0;border-left:3px solid var(--accent);line-height:1.7}
.content pre code{background:none;color:inherit;padding:0;font-size:13.5px;white-space:pre}
.content .flow{display:flex;align-items:center;justify-content:center;gap:8px;flex-wrap:wrap;
  background:var(--bg-2);border:1px solid var(--line);border-radius:var(--radius-lg);padding:18px 12px;margin:22px 0}
.content .flow .box{background:var(--bg);border:1.5px solid var(--accent);color:var(--accent);
  border-radius:var(--radius);padding:8px 13px;font-size:14px;font-weight:600;white-space:nowrap}
.content .flow .box.bad{border-color:var(--line-2);color:var(--text-3)}
.content .flow .arw{color:var(--text-3);font-size:18px}
.content .steps{counter-reset:s}
.content .step{position:relative;padding-left:44px;margin:26px 0}
.content .step::before{counter-increment:s;content:counter(s);position:absolute;left:0;top:3px;
  width:28px;height:28px;border-radius:50%;background:var(--accent);color:var(--bg);
  font-size:14px;font-weight:700;display:flex;align-items:center;justify-content:center}
.content .demo{margin:18px 0 8px;padding:14px;background:var(--bg-2);border:1px solid var(--line);
  border-radius:var(--radius-lg)}
.content .demo .gif{width:100%;margin:0}
.content .demo .cap{margin:10px 0 0}
.content details{margin:16px 0 26px;border:1px solid var(--line);border-radius:var(--radius-lg);
  padding:10px 14px;background:var(--bg-2)}
.content summary{cursor:pointer;color:var(--accent);font-size:14.5px;font-weight:600}
.content .stepper{margin-top:14px}
.content .stepper img{width:100%;margin:0;background:var(--bg)}
.content .stepper .tt{font-weight:700;margin:10px 0 2px;color:var(--text)}
.content .stepper .ss{color:var(--text-3);font-size:14px;margin:0}
.content .bar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:10px 0 0}
.content .bar button{border:1px solid var(--accent);background:var(--bg);color:var(--accent);
  border-radius:var(--radius);padding:5px 12px;font-size:13.5px;cursor:pointer;font-family:inherit}
.content .bar button:hover{background:var(--accent-soft)}
.content .bar .idx{color:var(--text-3);font-size:13.5px;margin-left:auto}
.content .dots{display:flex;gap:5px;margin-top:9px}
.content .dots span{height:5px;flex:1;background:var(--line-2);border-radius:3px;cursor:pointer}
.content .dots span.on{background:var(--accent)}
.content .goto{font-size:14px;color:var(--text-3);margin:10px 0 0}
.content .pc{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin:20px 0}
.content .pc>div{border:1px solid var(--line);border-radius:var(--radius-lg);padding:13px 16px;background:var(--bg-2)}
.content .pc>div.good{border-top:3px solid var(--accent)}
.content .pc>div.bad{border-top:3px solid #c9881e}
.content .pc h3{margin:0 0 8px;font-size:16.5px;padding-left:0}
.content .pc h3::before{display:none}
.content .pc ul{margin:0;padding-left:20px}
.content .pc li{font-size:14.5px;line-height:1.7;margin:5px 0}
.content .decide{margin:16px 0}
.content .decide .q{display:flex;justify-content:space-between;align-items:center;gap:12px;
  flex-wrap:wrap;border:1px solid var(--line);border-left:3px solid var(--accent);
  border-radius:0 var(--radius) var(--radius) 0;padding:9px 14px;margin:8px 0;
  background:var(--bg-2);font-size:15px}
.content .decide .q b{color:var(--accent);white-space:nowrap}
@media(max-width:640px){.content .pc{grid-template-columns:1fr}}
'''

HEAD_TPL = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{title} · 达梦手记</title>
<meta name="description" content="{desc}">
<link rel="stylesheet" href="../assets/site.css">
<style>{extra}</style>
<script>
(function(){{
  var THEMES = ['ink', 'dark'];
  var NAMES = {{ ink: '水墨', dark: '墨夜' }};
  // 早期版本把深色主题的内部代号写成 'sar'，这里映射一次，
  // 免得老访客 localStorage 里存着 'sar' 时主题失效。
  var ALIAS = {{ sar: 'dark' }};
  var KEY = 'jc-notes-theme';
  var cur = 'ink';
  function norm(v){{ return ALIAS[v] || v; }}
  try {{
    var s = norm(localStorage.getItem(KEY));
    if (s && THEMES.indexOf(s) >= 0) {{ cur = s; }}
  }} catch (e) {{}}
  // 支持 ?theme=dark 直接指定配色（便于分享某个配色 / 截图预览）
  try {{
    var m = location.search.match(/[?&]theme=([\\w-]+)/);
    var t = m ? norm(m[1]) : null;
    if (t && THEMES.indexOf(t) >= 0) {{ cur = t; }}
  }} catch (e) {{}}
  document.documentElement.setAttribute('data-theme', cur);

  window.__applyTheme = function(t){{
    cur = norm(t);
    if (THEMES.indexOf(cur) < 0) {{ cur = 'ink'; }}
    document.documentElement.setAttribute('data-theme', cur);
    var el = document.querySelector('.theme-name');
    if (el) {{ el.textContent = NAMES[cur] || cur; }}
    try {{ localStorage.setItem(KEY, cur); }} catch (e) {{}}
  }};
  window.__cycleTheme = function(){{
    var cur = document.documentElement.getAttribute('data-theme');
    var i = THEMES.indexOf(cur);
    window.__applyTheme(THEMES[(i + 1) % THEMES.length]);
  }};
  document.addEventListener('DOMContentLoaded', function(){{
    window.__applyTheme(cur);
  }});
}})();
</script>
</head>
<body>
<nav class="nav">
  <div class="nav-in">
    <a class="brand" href="../index.html">
      <span class="brand-mark">&gt;_</span>
      <span class="brand-txt">达梦手记</span>
    </a>
    <ul class="nav-links">
      <li><a href="../index.html">目录</a></li>
      <li><a href="./">图文版</a></li>
    </ul>
    <a class="nav-search" href="../search.html" title="搜索笔记">
      <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M16.5 16.5 21 21"/></svg>
      <span>搜索</span>
    </a>
    <button class="theme-btn" type="button" onclick="__cycleTheme()" title="切换配色风格">
      <span class="theme-dot"></span><span class="theme-name">水墨</span>
    </button>
  </div>
</nav>
<main class="wrap article">
  <div class="art-head">
    <div class="meta">{date} &nbsp;·&nbsp; {cat}</div>
    <h1>{h1}</h1>
    <span class="cat">{cat}</span>
  </div>
  <div class="content">
{body}
</div>
  <section class="contact" hidden>
    <div class="contact-body">
      <h3>卡在某一步了？</h3>
      <p>把这三样发我：<b>卡在第几步</b>、报错原文、<code>DM</code> 与 DTS 的版本号。不用发库里的数据，也不用发口令。</p>
      <details class="contact-fold">
        <summary>要我微信？点开看二维码（不点也行）</summary>
        <div class="contact-qr">
          <img src="../assets/wechat-qr.png" alt="微信二维码" width="120" height="120" loading="lazy">
          <span>扫了备注「达梦」<br>不备注我也加</span>
        </div>
        <p class="contact-mail">邮件：<a href="mailto:jiang-chuang@qq.com">jiang-chuang@qq.com</a></p>
      </details>
    </div>
  </section>
  <div class="art-foot">
    <a href="./">← 返回图文版目录</a>
  </div>
</main>
<footer>
  <div class="wrap foot">
    <p class="quote">纸上得来终觉浅，绝知此事要躬行。</p>
    <p>达梦手记</p>
    <p>联系：<a href="mailto:jiang-chuang@qq.com">jiang-chuang@qq.com</a></p>
    <p><a href="../about.html">本站说明</a> · <a href="https://beian.miit.gov.cn/" target="_blank" rel="noopener">渝ICP备2026027352号-1</a></p>
  </div>
</footer>
<script src="../assets/site.js" defer></script>
</body>
</html>
'''


def read(p):
    return io.open(p, encoding='utf-8').read()


def write(p, s):
    io.open(p, 'w', encoding='utf-8', newline='\n').write(s)


def body_of(html):
    m = re.search(r'<body[^>]*>(.*)</body>', html, re.S)
    if not m:
        sys.exit('找不到 <body>')
    return m.group(1).strip()


def convert(post):
    src = os.path.join(SRC, post['src'])
    if not os.path.exists(src):
        sys.exit('源文件不存在：' + src)
    b = body_of(read(src))

    # 去掉源稿自己的页面外壳与页脚。
    # 不能用 "</div>\s*$" 这类末尾锚点：一篇的播放器 <script> 排在 </div> 之后，
    # 锚点就永远匹配不上，foot 会留在正文里、标签多一层（这个坑是 HTMLParser 数出来的）。
    b = re.sub(r'\s*<div class="foot">.*?</div>', '', b, count=1, flags=re.S)
    b = re.sub(r'^\s*<div class="wrap">\s*', '', b)
    i = b.rfind('</div>')
    if i != -1:
        b = b[:i] + b[i + len('</div>'):]

    # 取出 h1 / meta（站点有 art-head，正文里不再留）
    parts = post['h1']
    b = re.sub(r'<h1[^>]*>.*?</h1>\s*', '', b, count=1, flags=re.S)
    b = re.sub(r'<div class="meta">.*?</div>\s*', '', b, count=1, flags=re.S)

    # 路径与变量的改写
    b = b.replace('dts-img/', '../assets/dts/')
    for k, v in post['links'].items():
        b = b.replace(k, v)
    for k, v in VARMAP.items():
        b = b.replace('var(%s)' % k, 'var(%s)' % v)

    # 本地预览版没有的标题层级修正：源稿用了 h2 作章节，站点同样处理，无需改
    out = HEAD_TPL.format(title=post['title'], desc=post['desc'], extra=EXTRA_CSS,
                          date=post['date'], cat=post['cat'], h1=parts,
                          body=b.strip() + '\n')
    write(os.path.join(ROOT, post['out']), out)
    return post['out']


def copy_images():
    os.makedirs(IMG_DIR, exist_ok=True)
    n = 0
    srcdir = os.path.join(SRC, 'dts-img')
    for f in sorted(os.listdir(srcdir)):
        if f.startswith('_') or not f.lower().endswith(('.png', '.gif', '.jpg')):
            continue
        shutil.copy2(os.path.join(srcdir, f), os.path.join(IMG_DIR, f))
        n += 1
    return n


if __name__ == '__main__':
    n = copy_images()
    print('图片复制 %d 个 → assets/dts/' % n)
    for p in POSTS:
        print('生成', convert(p))
