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
