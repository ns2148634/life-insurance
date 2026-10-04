#!/usr/bin/env node
/**
 * 本機開發用靜態伺服器（零依賴，只用 Node 內建模組）
 *
 * 為什麼需要它？
 *   本站是純靜態網站，正式站在 GitHub Pages 的專案子路徑 /life-insurance/。
 *   Service Worker、manifest.json 這些 PWA 功能需要「http(s) 協定 + 正確路徑」才會正常，
 *   直接雙擊 .html（file://）會有一堆限制（SW 不能註冊、Origin: null、儲存空間異常）。
 *
 *   這支伺服器會把專案根目錄「同時」掛在
 *     http://localhost:5500/life-insurance/   ← 與正式站路徑完全一致
 *     http://localhost:5500/                  ← 方便快速開檔
 *   因此本機測到的行為與正式站一致。
 *
 * 用法：
 *   npm run dev                        # 預設 http://127.0.0.1:5500/life-insurance/
 *   node dev-server.js --port 8080     # 換埠（預設 5500，被佔用會自動往上找）
 *   node dev-server.js --host 0.0.0.0  # 讓同網段的手機／平板也能連
 *   node dev-server.js --help
 *
 * 注意：這支伺服器「只服務靜態檔案」，不會碰 Supabase；
 *       資料仍寫入 config.js 指向的正式專案（詳見 DEV.md）。
 */

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const ROOT = __dirname;                 // 專案根目錄（與 index.html 同一層）
const PREFIX = '/life-insurance';       // 正式站（GitHub Pages）的子路徑
const DEFAULT_PORT = 5500;
const MAX_PORT_TRIES = 10;

/* ------------------------------------------------------------------ *
 * 參數解析
 * ------------------------------------------------------------------ */
function readArg(name) {
  const i = process.argv.indexOf(name);
  if (i === -1) return null;
  const v = process.argv[i + 1];
  return v && !v.startsWith('--') ? v : '';
}

function printHelp() {
  console.log(`
本機開發伺服器（零依賴）

用法：
  node dev-server.js [選項]

選項：
  --port <n>     指定連接埠（預設 ${DEFAULT_PORT}，被佔用時自動往上找，最多試 ${MAX_PORT_TRIES} 次）
  --host <ip>    指定綁定位址（預設 127.0.0.1；要用手機測請用 0.0.0.0）
  --help         顯示這份說明

啟動後可開：
  http://localhost:<port>${PREFIX}/      ← 與正式站相同路徑（建議用這個）
  http://localhost:<port>/               ← 專案根目錄
`);
}

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  printHelp();
  process.exit(0);
}

const portArg = readArg('--port');
const hostArg = readArg('--host');

const startPort = portArg === null || portArg === '' ? DEFAULT_PORT : Number(portArg);
const host = hostArg ? hostArg : '127.0.0.1';

if (!Number.isInteger(startPort) || startPort <= 0 || startPort > 65535) {
  console.error(`[dev] --port 必須是 1~65535 的整數，收到：${portArg}`);
  process.exit(1);
}

/* ------------------------------------------------------------------ *
 * MIME
 * ------------------------------------------------------------------ */
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8',
  '.sql': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
};

// 開發時永遠不快取，才不會看到舊檔（Service Worker 在開發環境會自我卸載，見 sw.js）
const NO_CACHE = {
  'Cache-Control': 'no-store, no-cache, must-revalidate',
  'Pragma': 'no-cache',
  'Expires': '0',
};

/* ------------------------------------------------------------------ *
 * 路徑處理
 * ------------------------------------------------------------------ */

/**
 * 把請求網址轉成磁碟上的絕對路徑；回傳 null 代表請求不合法（要回 404）。
 */
function toFilePath(requestUrl) {
  let pathname = String(requestUrl).split('?')[0].split('#')[0];

  try {
    pathname = decodeURIComponent(pathname);
  } catch (e) {
    return null; // 壞掉的百分比編碼
  }

  if (!pathname.startsWith('/')) return null;

  // 把 /life-insurance 這層前綴對應回專案根目錄，其餘原樣
  if (pathname === PREFIX) pathname = '/';
  else if (pathname.startsWith(PREFIX + '/')) pathname = pathname.slice(PREFIX.length);

  // normalize 會收掉 . 與 ..；再擋一次殘留的 ..，避免路徑穿越
  const normalized = path.posix.normalize(pathname);
  if (normalized.includes('..')) return null;

  const filePath = path.join(ROOT, normalized);
  const insideRoot = filePath === ROOT || filePath.startsWith(ROOT + path.sep);
  return insideRoot ? filePath : null;
}

function sendText(res, status, text) {
  res.writeHead(status, Object.assign({
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': Buffer.byteLength(text),
  }, NO_CACHE));
  res.end(text);
}

function send404(res, requestUrl) {
  const addr = server && server.address();
  const port = addr ? addr.port : startPort;
  sendText(res, 404,
    '404 Not Found\n\n' +
    '找不到這個檔案：' + requestUrl + '\n\n' +
    '提示：本機請開 http://localhost:' + port + PREFIX + '/\n');
}

function sendFile(req, res, filePath, stat) {
  const ext = path.extname(filePath).toLowerCase();
  res.writeHead(200, Object.assign({
    'Content-Type': MIME[ext] || 'application/octet-stream',
    'Content-Length': stat.size,
    'Last-Modified': stat.mtime.toUTCString(),
  }, NO_CACHE));

  if (req.method === 'HEAD') { res.end(); return; }

  const stream = fs.createReadStream(filePath);
  stream.on('error', (err) => {
    console.error('[dev] 讀檔失敗:', err.message);
    res.destroy();
  });
  stream.pipe(res);
}

/* ------------------------------------------------------------------ *
 * 請求處理
 * ------------------------------------------------------------------ */
function handler(req, res) {
  const startedAt = Date.now();
  const requestUrl = req.url || '/';

  res.on('finish', () => {
    console.log('[dev] ' + req.method + ' ' + requestUrl + ' → ' + res.statusCode +
      ' (' + (Date.now() - startedAt) + 'ms)');
  });

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    sendText(res, 405, 'Method Not Allowed');
    return;
  }

  const filePath = toFilePath(requestUrl);
  if (!filePath) { send404(res, requestUrl); return; }

  fs.stat(filePath, (err, stat) => {
    if (!err && stat.isFile()) {
      sendFile(req, res, filePath, stat);
      return;
    }

    // 目錄（含網址結尾是 / 的情況）→ 找 index.html
    const indexPath = path.join(filePath, 'index.html');
    fs.stat(indexPath, (err2, stat2) => {
      if (!err2 && stat2.isFile()) {
        sendFile(req, res, indexPath, stat2);
        return;
      }

      // config.local.js 是可選的本機覆蓋設定（見 DEV.md）：
      // 不存在時回一份空 JS，避免 Console 一直出現 404 噪音。
      if (path.basename(filePath) === 'config.local.js') {
        const stub = '// config.local.js（本機選用，目前不存在 → 空檔案）\n';
        res.writeHead(200, Object.assign({
          'Content-Type': MIME['.js'],
          'Content-Length': Buffer.byteLength(stub),
        }, NO_CACHE));
        res.end(stub);
        return;
      }

      send404(res, requestUrl);
    });
  });
}

/* ------------------------------------------------------------------ *
 * 啟動
 * ------------------------------------------------------------------ */
let server = null;

function localAddresses() {
  const out = [];
  const ifaces = os.networkInterfaces();
  Object.keys(ifaces).forEach((name) => {
    (ifaces[name] || []).forEach((info) => {
      if (info.family === 'IPv4' && !info.internal) out.push(info.address);
    });
  });
  return out;
}

function listen(port, triesLeft) {
  server = http.createServer(handler);

  server.on('error', (err) => {
    if (err.code === 'EADDRINUSE' && triesLeft > 0) {
      console.warn('[dev] 連接埠 ' + port + ' 已被佔用，改用 ' + (port + 1) + '…');
      listen(port + 1, triesLeft - 1);
      return;
    }
    console.error('[dev] 啟動失敗:', err.message);
    process.exit(1);
  });

  server.listen(port, host, () => {
    const openHost = (host === '0.0.0.0' || host === '::') ? 'localhost' : host;

    console.log('');
    console.log('  宸功保險工具總覽 — 本機開發伺服器');
    console.log('  根目錄：' + ROOT);
    console.log('');
    console.log('  建議開啟：http://' + openHost + ':' + port + PREFIX + '/');
    console.log('  也可開啟：http://' + openHost + ':' + port + '/');

    if (host === '0.0.0.0' || host === '::') {
      localAddresses().forEach((ip) => {
        console.log('  同網段裝置：http://' + ip + ':' + port + PREFIX + '/');
      });
    }

    console.log('');
    console.log('  按 Ctrl+C 結束');
    console.log('');
  });
}

function shutdown() {
  console.log('\n[dev] 正在關閉…');
  if (!server) process.exit(0);
  server.close(() => process.exit(0));
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

listen(startPort, MAX_PORT_TRIES);

