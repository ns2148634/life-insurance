// 宸功保險工具總覽 — Service Worker
//
// 路徑策略：BASE 由「瀏覽器當下的位置」推導，不再寫死路徑。
//   正式站 https://<user>.github.io/life-insurance/  → BASE = '/life-insurance/'
//   本機   http://localhost:5500/life-insurance/     → BASE = '/life-insurance/'
//   本機   http://localhost:5500/                    → BASE = '/'
// 這樣用 `npm run dev` 本機測試時，路徑行為才會跟正式站一致（詳見 DEV.md）。
const BASE = new URL('./', self.location.href).pathname;

// 本機開發（localhost / 127.0.0.1 / ::1）不啟用快取：
// 直接把自己卸載，避免「改了檔案重新整理卻還是舊版」的鬼打牆。
const IS_LOCAL_DEV = /^(localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0)$/.test(self.location.hostname);

const CACHE = 'guardian-v13';
const ASSETS = [
  BASE,
  BASE + 'config.js',
  BASE + 'auth-guard.js',
  BASE + 'login.html',
  BASE + 'accounts.html',
  BASE + 'goal-system.html',
  BASE + 'insurance-needs.html',
  BASE + '90day.html',
  BASE + 'manager-income.html',
  BASE + 'career-system.html',
  BASE + 'libs/html2pdf.bundle.min.js',
  BASE + 'video-training/login.html',
  BASE + 'video-training/videos.html',
  BASE + 'video-training/watch.html',
  BASE + 'video-training/profile.html',
  BASE + 'video-training/admin.html',
  BASE + 'video-training/style.css',
  BASE + 'video-training/config.js',
  BASE + 'sharing/login.html',
  BASE + 'sharing/share.html',
  BASE + 'sharing/style.css',
  BASE + 'sharing/config.js',
];

if (IS_LOCAL_DEV) {
  // ---- 本機開發：不安裝快取，卸載自己後所有請求直接走網路 ----
  self.addEventListener('install', function() {
    self.skipWaiting();
  });

  self.addEventListener('activate', function(e) {
    e.waitUntil(
      self.registration.unregister().then(function() {
        console.log('[SW] 本機開發環境：已停用 Service Worker（不快取、不攔截請求）');
        return self.clients.claim();
      })
    );
  });

  // 刻意不註冊 fetch 監聽 → 瀏覽器直接向 dev-server.js 取最新檔案
} else {
  self.addEventListener('install', function(e) {
    e.waitUntil(
      caches.open(CACHE).then(function(cache) {
        return cache.addAll(ASSETS);
      }).catch(function(err) {
        console.log('Cache install error (ok in dev):', err);
      })
    );
    self.skipWaiting();
  });

  self.addEventListener('activate', function(e) {
    e.waitUntil(
      caches.keys().then(function(keys) {
        return Promise.all(
          keys.filter(function(k){ return k !== CACHE; })
              .map(function(k){ return caches.delete(k); })
        );
      }).then(function(){
        return self.clients.claim();
      })
    );
  });

  // 改為「網路優先」：每次都先嘗試抓最新版本，
  // 只有在離線時才使用快取，確保更新後立即生效。
  self.addEventListener('fetch', function(e) {
    if (!e.request.url.startsWith(self.location.origin)) return;
    if (e.request.method !== 'GET') return;

    e.respondWith(
      fetch(e.request).then(function(res) {
        if (res && res.status === 200 && res.type !== 'opaque') {
          var clone = res.clone();
          caches.open(CACHE).then(function(cache){
            cache.put(e.request, clone);
          });
        }
        return res;
      }).catch(function() {
        // 離線時退回快取；連 BASE 都沒有（例如第一次就離線）也要給出合法回應，
        // 不能回 undefined，否則會變成 "Failed to convert value to 'Response'"。
        return caches.match(e.request).then(function(cached) {
          if (cached) return cached;
          return caches.match(BASE).then(function(root) {
            return root || caches.match(BASE + 'index.html');
          });
        }).then(function(res) {
          return res || new Response('離線中，且本頁尚未被快取。', {
            status: 503,
            headers: { 'Content-Type': 'text/plain; charset=utf-8' }
          });
        });
      })
    );
  });
}
