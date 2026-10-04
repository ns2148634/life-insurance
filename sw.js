const CACHE = 'guardian-v8';
const BASE = '/life-insurance/';
const ASSETS = [
  BASE,
  BASE + 'config.js',
  BASE + 'accounts.html',
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
      return caches.match(e.request).then(function(cached){
        return cached || caches.match(BASE);
      });
    })
  );
});
