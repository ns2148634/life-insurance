/*!
 * assets/client-theme.js — 客戶端「顧問模式」主題切換
 * ---------------------------------------------------------------------------
 * 用法：只放進客戶會看的頁面，且要在 <head> 最先載入：
 *
 *   <html lang="zh-TW" data-cg-theme="light">
 *   ...
 *   <script src="./assets/client-theme.js"></script>
 *
 * 行為：
 *   1. 預設淺色（html 已先標 data-cg-theme="light"，沒有 JS 也不會閃黑）。
 *   2. 若使用者上次切換成深色，會在第一次繪製前把屬性改成 dark。
 *   3. 自動更新 <meta name="theme-color">，並在頁首加入 44px 的切換鈕。
 *   4. 不使用任何函式庫，也不碰登入 / Supabase。
 */
(function () {
  'use strict';

  var KEY = 'cg-client-theme';
  var PAPER = '#f7f4ea';
  var DARK = '#0d1a26';
  var root = document.documentElement;

  function read() {
    try {
      return localStorage.getItem(KEY);
    } catch (e) {
      return null;
    }
  }

  function save(theme) {
    try {
      localStorage.setItem(KEY, theme);
    } catch (e) {
      /* 無痕模式：只切換本次瀏覽，不影響功能 */
    }
  }

  function preferred() {
    return read() === 'dark' ? 'dark' : 'light';
  }

  function metaEl() {
    return document.querySelector('meta[name="theme-color"]');
  }

  function paintMeta(theme) {
    var meta = metaEl();
    if (!meta) return;
    meta.setAttribute('content', theme === 'light' ? PAPER : DARK);
  }

  function apply(theme, persist) {
    root.setAttribute('data-cg-theme', theme);
    paintMeta(theme);
    if (persist) save(theme);
    syncButton(theme);
    try {
      document.dispatchEvent(new CustomEvent('cg:themechange', { detail: { theme: theme } }));
    } catch (e) { /* 舊瀏覽器忽略 */ }
  }

  /* ---------- 第一次繪製前先套用偏好 ---------- */
  paintMeta(preferred());
  if (preferred() === 'dark') root.setAttribute('data-cg-theme', 'dark');
  else root.setAttribute('data-cg-theme', 'light');

  /* ---------- 切換鈕 ---------- */
  var button = null;
  var topbar = null;
  var botnav = null;
  var compact = window.matchMedia ? window.matchMedia('(max-width: 900px)') : null;

  function targetHost() {
    if (compact && compact.matches && botnav) return botnav;
    return topbar;
  }

  function placeButton() {
    if (!button) return;
    var host = targetHost();
    if (host && button.parentNode !== host) host.appendChild(button);
  }

  function syncButton(theme) {
    if (!button) return;
    var toDark = theme === 'light';
    button.setAttribute('aria-label', toDark ? '切換為深色模式' : '切換為淺色模式');
    button.setAttribute('title', toDark ? '切換為深色模式' : '切換為淺色模式');
    button.setAttribute('aria-pressed', toDark ? 'false' : 'true');
    button.innerHTML =
      '<span class="cg-theme-toggle__icon" aria-hidden="true">' +
      (toDark ? '☾' : '☀') +
      '</span><span class="cg-theme-toggle__text">' +
      (toDark ? '深色' : '淺色') +
      '</span>';
  }

  function mountButton() {
    if (button) return;
    topbar = document.getElementById('topbar') || document.querySelector('.topbar');
    botnav = document.getElementById('botnav');
    if (!topbar) return;

    if (botnav) {
      document.body.classList.add('cg-has-botnav');
    }

    button = document.createElement('button');
    button.type = 'button';
    button.className = 'cg-theme-toggle';
    button.addEventListener('click', function () {
      apply(root.getAttribute('data-cg-theme') === 'light' ? 'dark' : 'light', true);
    });

    placeButton();
    syncButton(root.getAttribute('data-cg-theme') || preferred());

    if (compact) {
      if (compact.addEventListener) compact.addEventListener('change', placeButton);
      else if (compact.addListener) compact.addListener(placeButton);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mountButton, { once: true });
  } else {
    mountButton();
  }

  /* 供其他頁面／除錯使用 */
  window.CGTheme = {
    get: function () { return root.getAttribute('data-cg-theme') || 'light'; },
    set: function (theme) { apply(theme === 'dark' ? 'dark' : 'light', true); },
    reset: function () { apply('light', true); }
  };
})();
