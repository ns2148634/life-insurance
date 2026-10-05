/*!
 * auth-guard.js — 全站登入守衛（宸功保險）
 * ---------------------------------------------------------------------------
 * 用法：在「需要登入才能看」的頁面 <head> 內加一行
 *
 *   <script src="./auth-guard.js"></script>
 *
 * 子目錄頁面可自行指定路徑（預設會找同層的 config.js / login.html）：
 *
 *   <script src="../auth-guard.js" data-config="../config.js" data-login="../login.html"></script>
 *
 * 行為：
 *   1. 一載入就先隱藏 <body>，避免未登入者看到內容閃一下（防閃現）。
 *   2. 動態載入 Supabase SDK 與 config.js（不阻塞頁面既有程式）。
 *   3. 檢查登入 session：
 *        有登入  → 顯示頁面，並把 sb / session / user 掛到 window.authGuard
 *        沒登入  → location.replace(login.html?next=<原本要去的頁面>)
 *   4. 連不到 Supabase（離線／CDN 被擋）→ 一樣導向登入頁並帶 error=1，
 *      避免「載入失敗就放行」變成繞過守衛的後門。
 *
 * 頁面若需要同一個 Supabase client，請等這裡準備好再用：
 *
 *   const { sb, session, user } = await window.authGuard.ready;
 *
 * ⚠️ 本站是純靜態網站（GitHub Pages），這支守衛只是「前端擋人」，
 *    有決心的人仍可停用 JS 或直接看原始碼。真正的資料保護是 Supabase 的 RLS。
 *    詳見 DEV.md。
 */
(function () {
  "use strict";

  /* ---------- 0. 找出自己（script）的位置，推導 config / login 路徑 ---------- */
  var me = document.currentScript;
  if (!me) {
    // 少數瀏覽器／動態插入時抓不到 currentScript，改為往回找自己
    var all = document.getElementsByTagName("script");
    for (var i = all.length - 1; i >= 0; i--) {
      if (/auth-guard\.js/.test(all[i].getAttribute("src") || "")) { me = all[i]; break; }
    }
  }

  var myUrl;
  try {
    myUrl = new URL((me && me.getAttribute("src")) || "./auth-guard.js", location.href);
  } catch (e) {
    myUrl = new URL("./auth-guard.js", location.href);
  }

  function absolute(path) {
    try { return new URL(path, location.href).href; } catch (e) { return path; }
  }

  var attr = (me && me.dataset) || {};
  var CONFIG_URL = attr.config ? absolute(attr.config) : new URL("config.js", myUrl).href;
  var LOGIN_URL = attr.login ? absolute(attr.login) : new URL("login.html", myUrl).href;
  var CDN_URL = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2";

  /* ---------- 1. 先擋住畫面，避免內容閃現 ---------- */
  var root = document.documentElement;
  root.setAttribute("data-auth-guard", "pending");

  var style = document.createElement("style");
  style.textContent =
    'html[data-auth-guard="pending"]{background:#0d1a26;}' +
    'html[data-auth-guard="pending"] body{visibility:hidden !important;}';
  (document.head || root).appendChild(style);

  function reveal() {
    root.removeAttribute("data-auth-guard");
  }

  /* ---------- 2. 小工具 ---------- */
  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = src;
      s.async = false;
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error("載入失敗：" + src)); };
      (document.head || root).appendChild(s);
    });
  }

  function nextValue() {
    return encodeURIComponent(location.pathname + location.search + location.hash);
  }

  function toLogin(suffix) {
    location.replace(LOGIN_URL + "?next=" + nextValue() + (suffix || ""));
  }

  /* ---------- 3. 對外接口（頁面用 await window.authGuard.ready 取得 sb） ---------- */
  window.authGuard = {
    ready: null,
    sb: null,
    session: null,
    user: null,
    loginUrl: LOGIN_URL
  };

  /* ---------- 4. 主要流程 ---------- */
  var ready = (async function () {
    if (!window.supabase) {
      await loadScript(CDN_URL);
    }
    if (typeof SUPABASE_URL === "undefined" || typeof SUPABASE_ANON_KEY === "undefined") {
      await loadScript(CONFIG_URL);
    }

    var sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    var res = await sb.auth.getSession();
    var session = (res && res.data) ? res.data.session : null;

    if (!session) return { sb: sb, session: null, user: null };

    window.authGuard.sb = sb;
    window.authGuard.session = session;
    window.authGuard.user = session.user;

    reveal();
    return { sb: sb, session: session, user: session.user };
  })();

  window.authGuard.ready = ready;

  ready.then(function (g) {
    // 有登入 → 已經在 ready 內 reveal()，這裡不用再做
    if (!g || !g.session) toLogin("");
  }).catch(function (err) {
    // 載入 SDK / config 失敗（離線或被擋）→ 不放行，導向登入頁並帶錯誤旗標
    console.error("[auth-guard] " + (err && err.message ? err.message : err));
    toLogin("&error=1");
  });
})();
