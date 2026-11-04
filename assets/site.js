/* 文章底部「一键反馈」。
 *
 * 为什么是按钮而不是表单/邮件：那两种都要读者腾出手打字，实际使用率接近零。
 * 这里只记两个信号：有人跑通了、有人卡住了。点完即走，不跳转、不弹窗、不留身份。
 * 服务端只是 nginx 的一个 204 + 独立日志，没有数据库、没有接口。
 */
(function () {
  var btns = document.querySelectorAll('[data-sig]');
  if (!btns.length) return;

  var note = document.getElementById('sigNote');
  var help = document.getElementById('sigHelp');
  var KEY = 'sig:';

  function mark(slug, text) {
    btns.forEach(function (b) {
      b.disabled = true;
      if (b.getAttribute('data-sig') === slug) b.classList.add('sig-on');
    });
    if (note && text) { note.hidden = false; note.textContent = text; }
  }

  btns.forEach(function (btn) {
    var slug = btn.getAttribute('data-sig');
    if (!slug) return;

    // 点过的就别重复计数，也别让人以为没生效
    try { if (localStorage.getItem(KEY + slug)) mark(slug, '已记下过，谢谢。'); } catch (e) {}

    btn.addEventListener('click', function () {
      try {
        fetch('/sig/' + slug, {mode: 'no-cors', cache: 'no-store', keepalive: true});
      } catch (e) { /* 信号发不出去也不能影响阅读 */ }
      try { localStorage.setItem(KEY + slug, '1'); } catch (e) {}

      if (slug.indexOf('stuck') > -1) {
        mark(slug, '收到。');
        if (help) help.open = true;
      } else {
        mark(slug, '记下了，谢谢。');
      }
    });
  });
})();

/* 2026-11-04｜所有文章页统一一行「已解决 / 未解决」。
 * 只在 posts/ 与 interactive/ 注入；首页、关于页不注入（保留纯文字联系入口）。
 * 复用同一个 nginx /sig/ 204 信号与 localStorage 去重，不新增后端、不记身份。
 * 二维码由 site.css 全站收起；这里把原来的大段联系区块 hidden，
 * 默认只露两个按钮，点「未解决」才展开联系方式。
 */
(function () {
  /* 全站二维码收起：直接压到行内样式，首页 / 关于页也一起（它们不注入反馈条）。
     site.css 里的同名规则是静态兜底，这里保证未加载 site.css 的页面也生效。 */
  Array.prototype.forEach.call(
    document.querySelectorAll('.contact-fold,.cta-qr-fold,.contact-qr,.cta-qr,img[src*="wechat-qr.png"]'),
    function (el) { el.style.display = 'none'; }
  );

  if (!/\/posts\/|\/interactive\//.test(location.pathname)) return;
  if (/\/(index\.html)?$/.test(location.pathname)) return;   /* 目录页不是文章 */
  var anchor = document.querySelector('section.contact, section.card.cta');
  if (!anchor) return;

  /* 反馈条样式自带，不依赖页面有没有加载 site.css */
  var sty = document.createElement('style');
  sty.textContent =
    '.fb-bar{margin:40px 0 0;padding:18px 22px;border:1px solid rgba(128,128,128,.28);border-radius:12px}' +
    '.fb-q{margin:0 0 12px;font-size:14px}' +
    '.fb-bar .sig-row{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin:0}' +
    '.fb-bar .sig-btn{font:inherit;font-size:13px;padding:7px 15px;background:transparent;color:inherit;border:1px solid rgba(128,128,128,.45);border-radius:8px;cursor:pointer}' +
    '.fb-bar .sig-btn:hover{border-color:currentColor}' +
    '.fb-bar .sig-btn:disabled{cursor:default;opacity:.5}' +
    '.fb-bar .sig-note{font-size:12.5px;opacity:.65}' +
    '.fb-bar .sig-help{margin:14px 0 0;font-size:13px;line-height:1.75}' +
    '.fb-bar .sig-help summary{cursor:pointer;list-style:none}' +
    '.fb-bar .sig-help p{margin:8px 0 0}' +
    '@media print{.fb-bar{display:none}}';
  document.head.appendChild(sty);

  anchor.hidden = true;
  anchor.style.display = 'none';
  var bar = document.createElement('section');
  bar.className = 'fb-bar';
  bar.innerHTML =
    '<p class="fb-q">这篇解决了你的问题吗？</p>' +
    '<div class="sig-row">' +
      '<button class="sig-btn" type="button" data-fb="ok">已解决</button>' +
      '<button class="sig-btn" type="button" data-fb="stuck">未解决</button>' +
      '<span class="sig-note" id="fbNote" hidden></span>' +
    '</div>' +
    '<details class="sig-help" id="fbHelp">' +
      '<summary>没解决？联系方式在这</summary>' +
      '<p>说清三件事就够判断：<b>卡在第几步</b>、<b>报错原文（带错误码）</b>、<b>版本号</b>。不用发配置文件和日志原文；口令整个别贴，IP、主机名、库名、真实表名先自行脱敏。</p>' +
      '<p>邮件：<a href="mailto:jiang-chuang@qq.com">jiang-chuang@qq.com</a>　·　共性问题会补成新的指南，想让后来人搜到、也看得见补没补，就在 <a href="https://gitee.com/jiangchuang/blog/issues" target="_blank" rel="noopener">Gitee 仓库</a> 提 issue，回复公开可查。</p>' +
    '</details>';
  anchor.parentNode.insertBefore(bar, anchor);

  var btns = bar.querySelectorAll('[data-fb]');
  var note = bar.querySelector('#fbNote');
  var help = bar.querySelector('#fbHelp');
  var slug = (location.pathname.split('/').pop() || 'post').replace(/\.html.*$/, '');
  var KEY = 'fb:' + slug + ':';

  function mark(kind, text) {
    Array.prototype.forEach.call(btns, function (b) {
      b.disabled = true;
      if (b.getAttribute('data-fb') === kind) b.classList.add('sig-on');
    });
    if (note) { note.hidden = false; note.textContent = text; }
  }

  Array.prototype.forEach.call(btns, function (btn) {
    var kind = btn.getAttribute('data-fb');
    try { if (localStorage.getItem(KEY + kind)) mark(kind, '已记下过，谢谢。'); } catch (e) {}
    btn.addEventListener('click', function () {
      try { fetch('/sig/' + slug + '-' + kind, {mode: 'no-cors', cache: 'no-store', keepalive: true}); } catch (e) {}
      try { localStorage.setItem(KEY + kind, '1'); } catch (e) {}
      if (kind === 'stuck') { mark(kind, '收到。'); if (help) help.open = true; }
      else { mark(kind, '记下了，谢谢。'); }
    });
  });
})();
