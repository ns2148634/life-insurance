# 本機開發與測試（DEV）

本站是**純靜態網站**（沒有建置流程、沒有後端伺服器），網頁內容就是瀏覽器直接載入的檔案。
「好像無法本機測試」通常是因為**直接雙擊 `.html`（`file://`）**或**路徑與正式站不同**，而不是程式壞了。

> 正式站路徑：`https://<你的帳號>.github.io/life-insurance/`
> 本機路徑：`http://localhost:5500/life-insurance/`（由 `dev-server.js` 模擬，路徑完全一致）

---

## 一、快速開始

```powershell
cd c:\life-insurance
npm run dev
```

終端機會印出：

```
  建議開啟：http://localhost:5500/life-insurance/
```

打開這個網址即可。**不需要 `npm install`**：`dev-server.js` 只用 Node 內建模組
（本機 Node v24 已足夠，Node 18 以上皆可）。

### 常用選項

| 需求 | 指令 |
| --- | --- |
| 換連接埠（預設 5500，被佔用會自動 +1） | `npm run dev -- --port 8080` |
| 讓同網段的手機／平板也能連 | `npm run dev -- --host 0.0.0.0` |
| 看說明 | `npm run dev -- --help` |

手機測試：手機與電腦連同一個 Wi-Fi → 開終端機印出的 `http://192.168.x.x:5500/life-insurance/`。
（非 localhost 時 Service Worker 不會註冊，屬正常現象。）

---

## 二、為什麼不能直接雙擊 HTML？

| 直接開檔（`file://`）的問題 | 影響 |
| --- | --- |
| Service Worker 無法註冊 | 離線快取、加入主畫面（PWA）測不到 |
| 網址是 `file:///C:/...`，不是 `/life-insurance/` | 絕對路徑、`manifest.json` 的 `scope` 對不上 |
| 請求的 `Origin: null`、儲存空間被視為不透明來源 | 登入狀態（session）可能存不住、Supabase 請求可能被擋 |
| 瀏覽器對 `file://` 的安全性限制 | 行為與正式站不一致，測了也不準 |

所以：**一律用 `npm run dev` 開 `http://localhost:5500/life-insurance/`**。

---

## 三、⚠️ 本機測試會寫入「正式」Supabase

`config.js`、`video-training/config.js`、`sharing/config.js` 都指向**正式** Supabase 專案
（`dwesqvutdlvnmajxdcpn`），也就是說：

- 本機登入用的就是同仁的正式帳號。
- 在本機新增／修改的資料（姓名、觀看進度、分享連結）會**直接寫進正式資料庫**。

建議：
1. 用你自己的帳號測試，不要亂改別人的資料。
2. 測「新增分享」這類會留下資料的功能，測完自己刪掉。
3. 需要完全隔離的環境時，見第七節（需先安裝 Docker）。

---

## 四、各頁面在本機的預期行為

| 頁面 | 本機可測 | 說明 |
| --- | --- | --- |
| `index.html` | ✅ | 上方登入區塊需連得到 Supabase；其餘為靜態目錄 |
| `insurance-needs.html` 等試算工具 | ✅ | 純前端計算，離線也能用（`html2pdf` 已放在 `libs/`） |
| `90day.html`（90 天手冊） | ✅ | 雲端用 Firebase RTDB；**連不到時會自動退回「僅本機儲存」**，狀態列顯示「⚠️ 雲端同步失敗，僅本機儲存」，不影響本機測試 |
| `accounts.html` | ✅ | 需管理員帳號登入，且該帳號 `profiles.is_admin = true` |
| `video-training/*` | ✅ | 需登入；影片為 YouTube 內嵌，需網路 |
| `sharing/*` | ✅ | 需登入 |

---

## 五、看不到最新修改？清掉 Service Worker 快取

`sw.js` 已改成「**偵測到 localhost 就自動卸載、完全不快取**」，正常情況不會再發生。
若你之前曾在**同一個網址**測過舊版，仍可能殘留：

1. DevTools（F12）→ **Application** → **Service Workers** → 對 `sw.js` 按 **Unregister**。
2. **Application** → **Storage** → **Clear site data**。
3. `Ctrl + Shift + R` 強制重新整理。

`dev-server.js` 對所有檔案都送 `Cache-Control: no-store`，所以不會有一般 HTTP 快取的問題。

---

## 六、常見問題

| 症狀 | 原因 / 處理 |
| --- | --- |
| 打開 `http://localhost:5500/` 出現 404 | 路徑不對。請用 `http://localhost:5500/life-insurance/`（本機的 `/` 也可以，但兩者路徑不同） |
| 畫面顯示「無法載入登入元件，請確認網路連線後重新整理」 | 連不到 jsdelivr CDN（`@supabase/supabase-js`）或 Supabase；請檢查網路／Proxy／防火牆 |
| 登入一直失敗 | 帳密錯誤、該帳號未在 Supabase 勾選 Auto Confirm User，或帳號已被停用 |
| Console 出現 `SW registration failed` | 本機已不會註冊 SW；若仍出現請依第五節清掉舊 SW |
| 改了 HTML／CSS／JS 沒生效 | 依第五節清 Service Worker，再 `Ctrl + Shift + R` |
| 連接埠被佔用 | `dev-server.js` 會自動改用 5501、5502…；或 `npm run dev -- --port 8090` |
| Console 出現 `config.local.js 404` | 本機伺服器已針對此檔回傳空 JS 避免 404；這個檔是**選用的本機覆蓋設定**，目前沒有任何頁面載入它（見第七節） |

---

## 七、（選用）之後想完全隔離後端

本機目前**沒有安裝 Docker**，所以「本機 Supabase」還不能跑。若日後要做：

1. 安裝 Docker Desktop（Windows）。
2. `npx supabase init`
3. 把現有 SQL 搬成 migrations（內容可直接複製）：
   - `video-training/supabase-schema.sql` → `supabase/migrations/<timestamp>_video_training.sql`
   - `video-training/supabase-watch-progress-fix.sql` → `supabase/migrations/<timestamp>_watch_progress_fix.sql`
   - `sharing/supabase-schema-links.sql` → `supabase/migrations/<timestamp>_sharing_links.sql`
4. `npx supabase start` → 本機 API 會是 `http://127.0.0.1:54321`。
5. 讓頁面指向本機 Supabase：建立 `config.local.js`（放在網站根目錄，正式站不要 commit），
   在各頁 `config.js` **之前**載入，並讓 `config.js` 優先採用它，例如：

   ```js
   // config.local.js（本機專用；正式站請勿提交）
   window.__SB_LOCAL__ = {
     url: "http://127.0.0.1:54321",
     anonKey: "<supabase status 顯示的 anon key>"
   };
   ```

   ```js
   // config.js（改成優先讀本機覆蓋）
   const SUPABASE_URL = (window.__SB_LOCAL__ && window.__SB_LOCAL__.url) || "https://dwesqvutdlvnmajxdcpn.supabase.co";
   const SUPABASE_ANON_KEY = (window.__SB_LOCAL__ && window.__SB_LOCAL__.anonKey) || "eyJhbGciOi...";
   ```

   `dev-server.js` 已經對 `config.local.js` 做了處理（不存在時回傳空 JS），
   所以要加上那一行 `<script src="config.local.js"></script>` 時不會有 404 噪音。

---

## 八、這次為了「可本機測試」改了什麼

| 檔案 | 變更 |
| --- | --- |
| `dev-server.js`（新增） | 零依賴靜態伺服器：專案同時掛在 `/` 與 `/life-insurance/`，預設埠 5500，全站 `no-store` |
| `package.json` | 新增 `scripts.dev`（`node dev-server.js`）、`name`、`private`；未新增任何依賴 |
| `sw.js` | `BASE` 改由 `self.location` 推導（不再寫死 `/life-insurance/`）；localhost 自動卸載不快取；離線 fallback 不再回傳 `undefined`；cache 版號 `v8 → v9` |
| `index.html`、`insurance-needs.html` | 本機（localhost／127.0.0.1）不註冊 Service Worker |
| `README.md`、`DEV.md` | 補上本機測試說明 |

> 以上皆未改動任何 Supabase 邏輯、SQL 或既有頁面行為，正式站功能不受影響。

