#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""budget 前端交互测试（纯标准库 + 本机 Chrome 无头，兼容 Python 3.6）。

    python3 ui_test.py            # 默认端口 8098
    CHROME=/path/chrome python3 ui_test.py 8098

为什么要这么绕：本机的 Edge 无头起不来，而且 app.py 只服务 index.html 一个页面，
所以没法直接开一个 harness 页面去 iframe 里点。做法是——
  1. 把 app.py / index.html / data.sample.json 复制到临时目录（不碰仓库、不碰线上数据）
  2. 把测试脚本**内联进 index.html 的副本**，测试和被测算的是同一个文档
  3. 起临时实例 → Chrome `--dump-dom` 抓回结果块 → 解析 PASS/FAIL

⚠️ 只对临时实例跑，端口被占用会直接退出。
"""
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

BASE = os.path.dirname(os.path.abspath(__file__))
KEY = "uitestkey"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8098

CHROME_CANDIDATES = [
    os.environ.get("CHROME", ""),
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
]


def find_chrome():
    for p in CHROME_CANDIDATES:
        if p and os.path.exists(p):
            return p
    sys.exit("找不到 Chrome/Edge，用 CHROME=/path/to/chrome 指定")


TEST_JS = r"""
var log = [], done = false, fails = 0;
var _out = document.getElementById('uit-out');
if (!_out){ _out = document.createElement('div'); _out.id = 'uit-out'; document.body.appendChild(_out); }
function rec(s){ log.push(s); _out.textContent = log.join('\n'); }
function t(name, cond, extra){
  rec((cond ? 'PASS  ' : 'FAIL  ') + name + (extra ? '   [' + extra + ']' : ''));
  if (!cond) fails++;
}
function finish(msg){
  if (done) return; done = true;
  if (msg) rec('!! ' + msg);
  var el = document.createElement('div'); el.id = 'RESULT';
  el.textContent = '<<<RESULT>>>\n' + log.join('\n') + '\n<<<END>>>';
  document.body.appendChild(el);
}
window.addEventListener('error', function(e){ rec('JS ERROR: ' + e.message + ' @' + e.filename + ':' + e.lineno); });

function ids(){ return [].map.call(document.querySelectorAll('tbody tr[data-id]'), function(tr){ return tr.dataset.id; }); }
function subs(){
  return [].map.call(document.querySelectorAll('tbody tr[data-id]'), function(tr){
    return parseFloat(tr.querySelector('td.sub').textContent.replace(/[^\d.]/g, '')) || 0;
  });
}
function clickTh(k){
  var th = document.querySelector('thead th[data-k="' + k + '"]');
  th.dispatchEvent(new MouseEvent('click', {bubbles: true}));
}
function arrow(k){
  var th = document.querySelector('thead th[data-k="' + k + '"]');
  return th ? (th.dataset.arrow || '') : '(none)';
}
function asc(list){ for (var i = 1; i < list.length; i++){ if (list[i-1] > list[i]) return false; } return true; }
function desc(list){ for (var i = 1; i < list.length; i++){ if (list[i-1] < list[i]) return false; } return true; }

var tries = 0;
var timer = setInterval(function(){
  var rows = document.querySelectorAll('tbody tr[data-id]');
  if (rows.length < 2){
    if (++tries > 120){ clearInterval(timer); finish('TIMEOUT: 等不到表格数据 rows=' + rows.length); }
    return;
  }
  clearInterval(timer);
  try { run(); } catch(e){ finish('ERR ' + e.message + ' ' + (e.stack || '')); }
}, 100);

function run(){
  var orig = ids();
  rec('rows=' + orig.length + '  origOrder=' + orig.join(','));
  rec('subs(orig)=' + subs().join(','));

  // 1-3 表头三态
  clickTh('sub');
  t('表头点一下 → 小计升序', asc(subs()), subs().join(','));
  t('升序箭头 ▲', arrow('sub') === '▲', arrow('sub'));
  clickTh('sub');
  t('再点 → 降序', desc(subs()), subs().join(','));
  t('降序箭头 ▼', arrow('sub') === '▼', arrow('sub'));
  clickTh('sub');
  t('第三下 → 回到原始顺序', ids().join(',') === orig.join(','), ids().join(','));
  t('原始顺序无箭头', arrow('sub') === '', '[' + arrow('sub') + ']');

  // 4 排序只改视图
  var foot = document.getElementById('footSum').textContent;
  clickTh('sub');
  t('排序不影响合计金额', document.getElementById('footSum').textContent === foot, document.getElementById('footSum').textContent);
  clickTh('sub'); clickTh('sub');
  t('取消排序后回到原序（state.rows 没被污染）', ids().join(',') === orig.join(','));

  // 5 手机下拉
  var sel = document.getElementById('fSort');
  sel.value = 'price:-1';
  sel.dispatchEvent(new Event('change', {bubbles: true}));
  var prices = [].map.call(document.querySelectorAll('tbody tr[data-id]'), function(tr){
    return parseFloat(tr.querySelector('[data-f="price"]').value.replace(/,/g, '')) || 0;
  });
  t('下拉「单价 从高到低」生效', desc(prices), prices.join(','));
  t('表头箭头跟着下拉走', arrow('price') === '▼', arrow('price'));
  sel.value = '';
  sel.dispatchEvent(new Event('change', {bubbles: true}));
  t('下拉清空 → 恢复原序', ids().join(',') === orig.join(','));

  // 6 搜索 + 底部口径
  var q = document.getElementById('q');
  var name = document.querySelector('tbody tr[data-id] [data-f="name"]').value;
  q.value = name.slice(0, 2) || 'x';
  q.dispatchEvent(new Event('input', {bubbles: true}));
  var n = document.querySelectorAll('tbody tr[data-id]').length;
  var label = document.getElementById('footLabel').textContent;
  t('搜索后行数变少', n < orig.length, n + '/' + orig.length);
  t('底部写「筛选 N / 共 M 项」', /筛选\s*\d+\s*\/\s*共\s*\d+\s*项/.test(label), label);
  t('合计仍是全量', document.getElementById('footSum').textContent === foot, document.getElementById('footSum').textContent);

  // 7 Esc 清空
  q.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));
  t('Esc 清空搜索', q.value === '' && document.querySelectorAll('tbody tr[data-id]').length === orig.length);
  t('清空后底部回到「合计（N 项）」', /^合计/.test(document.getElementById('footLabel').textContent), document.getElementById('footLabel').textContent);

  // 8 / 快捷键
  q.blur();
  document.dispatchEvent(new KeyboardEvent('keydown', {key: '/', bubbles: true}));
  t('按 / 聚焦搜索框', document.activeElement === q, document.activeElement && (document.activeElement.id || document.activeElement.tagName));

  // 9 打字期间不重排
  clickTh('sub');
  var first = ids()[0];
  var tr0 = document.querySelector('tbody tr[data-id="' + first + '"]');
  var priceEl = tr0.querySelector('[data-f="price"]');
  priceEl.focus();
  priceEl.value = '9999999';
  priceEl.dispatchEvent(new Event('input', {bubbles: true}));
  tr0.querySelector('[data-f="cat"]').dispatchEvent(new Event('change', {bubbles: true}));  // 改分类会整体重绘
  var after = ids();
  t('打字期间重绘不把行挪走', after[0] === first, 'first=' + after[0] + ' 期望=' + first);
  t('重绘后光标还在原格子里', document.activeElement && document.activeElement.dataset && document.activeElement.dataset.f === 'price',
    document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.f : String(document.activeElement && document.activeElement.tagName));

  // 10 失焦后归位（focusout 后 180ms 重绘）
  document.activeElement.blur();
  setTimeout(tail, 600);
}

function tail(){
  t('失焦后箭头仍是 ▲', arrow('sub') === '▲', arrow('sub'));
  t('失焦后自动按小计升序归位', asc(subs()), subs().join(','));
  t('页面只有 1 个 thead', document.querySelectorAll('thead').length === 1, document.querySelectorAll('thead').length);
  finish('DONE fails=' + fails);
}
"""


def build_instance(tmp):
    for f in ("app.py", "index.html", "data.sample.json"):
        shutil.copy(os.path.join(BASE, f), os.path.join(tmp, f))
    shutil.copy(os.path.join(BASE, "data.sample.json"), os.path.join(tmp, "data.json"))
    io.open(os.path.join(tmp, "secret.txt"), "w", encoding="utf-8").write(KEY + "\n")
    html = io.open(os.path.join(tmp, "index.html"), encoding="utf-8").read()
    if "</body>" not in html:
        sys.exit("index.html 里找不到 </body>，无法注入测试脚本")
    html = html.replace("</body>", "<script>\n" + TEST_JS + "\n</script>\n</body>")
    io.open(os.path.join(tmp, "index.html"), "w", encoding="utf-8").write(html)


def wait_port(port, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        try:
            urllib.request.urlopen("http://127.0.0.1:%d/api/health" % port, timeout=1).read()
            return True
        except Exception:
            time.sleep(0.2)
    return False


def main():
    chrome = find_chrome()
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", PORT))
    except OSError:
        sys.exit("端口 %d 已被占用，换个端口再跑" % PORT)
    finally:
        s.close()

    tmp = tempfile.mkdtemp(prefix="budget-ui-")
    proc = None
    try:
        build_instance(tmp)
        proc = subprocess.Popen([sys.executable, "app.py", str(PORT)], cwd=tmp,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if not wait_port(PORT):
            sys.exit("临时实例没起来：\n" + (proc.stdout.read() or b"").decode("utf-8", "replace"))

        profile = os.path.join(tmp, "_profile")
        out = subprocess.check_output([
            chrome, "--headless=new", "--disable-gpu", "--no-sandbox", "--no-proxy-server",
            "--no-first-run", "--hide-scrollbars", "--window-size=1400,1000",
            "--user-data-dir=" + profile, "--virtual-time-budget=20000", "--dump-dom",
            "http://127.0.0.1:%d/?k=%s" % (PORT, KEY),
        ], stderr=subprocess.DEVNULL)
        dom = out.decode("utf-8", "replace")
        m = re.search(r'<div id="RESULT">(.*?)</div>', dom, re.S)
        if not m:
            body = re.search(r'<div id="uit-out">(.*?)</div>', dom, re.S)
            sys.exit("拿不到结果块。页面内日志：\n" + (body.group(1) if body else "(空)"))
        text = m.group(1).replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
        print(text)
        npass = text.count("PASS  ")
        nfail = text.count("FAIL  ")
        print("\n结果：%d 通过 / %d 失败" % (npass, nfail))
        return 0 if nfail == 0 else 1
    finally:
        if proc:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
