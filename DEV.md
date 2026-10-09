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

> **全站都需登入**：所有頁面的 `<head>` 都載入了 `auth-guard.js`，
> 未登入會自動導向根目錄的 `login.html`（機制見「四之一」）。

| 頁面 | 本機可測 | 說明 |
| --- | --- | --- |
| `login.html`（根目錄） | ✅ | 全站共用登入頁；本身不需登入即可開 |
| `index.html` | ✅ | 工具總覽；需登入。登入區塊仍需連得到 Supabase |
| `insurance-needs.html` 等試算工具 | ✅ | 需登入；計算本身是純前端（`html2pdf` 已放在 `libs/`） |
| `90day.html`（90 天手冊） | ✅ | 需登入；進度**跟著登入帳號**存（Firebase RTDB `cg90/users/<uid>` + 本機 mirror），連不到雲端時會自動退回「僅本機儲存」，狀態列顯示「⚠️ 雲端同步失敗，僅本機儲存」（見「四之二」） |
| `goal-system.html`（一定要宸功專區） | ✅ | 需登入；每月目標存在 Supabase `public.goal_targets`（一人一月一筆）。**第一次使用前需先在 SQL Editor 執行 `supabase-schema-goals.sql`**，否則讀寫會失敗（見 `goal-system-SETUP.md`） |
| `accounts.html` | ✅ | 需管理員帳號登入，且該帳號 `profiles.is_admin = true` |
| `video-training/*` | ✅ | 需登入；影片為 YouTube 內嵌，需網路 |
| `sharing/*` | ✅ | 需登入 |

---

## 四之一、全站登入守衛（`auth-guard.js` + `login.html`）

本站是**純靜態網站、沒有後端**，所以「要登入才能用」是由前端守衛達成：

| 檔案 | 角色 |
| --- | --- |
| `auth-guard.js` | **守衛**。放在需要登入的頁面 `<head>`：先隱藏 `<body>`（避免內容閃現）→ 動態載入 Supabase SDK 與 `config.js` → 檢查 session → 未登入就 `location.replace('login.html?next=<原本要去的頁面>')` |
| `login.html`（根目錄） | **全站共用登入頁**。登入成功後用 `next` 導回原本要去的頁面（只接受站內相對路徑，避免被拿來做開放轉址） |

要讓**新頁面**也需要登入，只要在 `<head>` 內加一行：

```html
<script src="./auth-guard.js"></script>
```

子目錄頁面可自行指定路徑（預設找同層的 `config.js` / `login.html`）：

```html
<script src="../auth-guard.js" data-config="../config.js" data-login="../login.html"></script>
```

頁面若需要同一個 Supabase client，等守衛準備好再拿（`index.html` 就是這樣寫的）：

```js
const { sb, session, user } = await window.authGuard.ready;
```

### 注意事項（務必理解）

- **這只是前端擋人，不是真正的安全機制。** 靜態網站的 HTML 本來就是公開的，
  有決心的人停用 JS 或直接看原始碼，仍看得到頁面內容。
  **真正保護資料的是 Supabase 的 RLS**——影片、分享連結、帳號資料都存在 Supabase，
  未登入者拿不到。
- 因此守衛採「**無法驗證就不放行**」：離線或 CDN 被擋載入失敗時，
  會帶 `error=1` 導向登入頁，不會出現「載入失敗就放行」的後門。
- 副作用：**離線時可能無法使用**（原本試算工具可離線用）。
  若瀏覽器已快取 `supabase-js` 且 session 仍未過期，離線還是進得來；否則會停在登入頁。
- `config.js` 已改成「已宣告就略過」的寫法（`typeof` 判斷 + `var`），
  所以守衛與頁面各自載入時，不會發生 `const` 重複宣告的 `SyntaxError`。

---

## 四之二、`90day.html` 的進度存在哪（跟著登入帳號）

**2026-10 修訂**：移除「🔑 主管解鎖」密碼、移除「切換查看學員」下拉，並一併移除主管管理面板
（新增學員／刪除／點卡片切換）。90 天的進度**直接綁定登入帳號**，不必再選「這是哪一位學員的」。

| 位置 | 內容 |
| --- | --- |
| 雲端 Firebase RTDB `cg90/users/<登入者 uid>` | `{ uid, name, email, updatedAt, progress }`；`name` 取自 `profiles.full_name`，沒填就退成 email |
| 本機 `localStorage` `cg90_progress_<uid>` | 同一份進度的 mirror；雲端連不上時仍會保存（狀態列顯示「☁️ 未連線雲端，僅本機儲存」） |
| 舊版資料 `cg90/students/<隨機 id>` | **保留不動**。只有在「這個帳號完全沒有紀錄」且姓名相同時，才會自動沿用一次，避免舊進度消失 |

- 同步判定：比 `progress.savedAt`，**雲端較新就覆蓋畫面**（在別台裝置更新過也會帶入）。
- 反過來，本機比雲端新（或雲端還沒有資料）時，第一次連線會把本機推上去。
- 沒有取得登入者時（守衛正在導向 `login.html`）**完全不寫入**任何資料。
- 頁面只讀寫「自己那一份」，但 ⚠️ **Firebase Realtime Database 的讀寫權限以 Firebase 規則為準**
  （與 Supabase 的 RLS 無關）。要真的保護資料，請到 Firebase Console → Realtime Database → Rules
  限制成「只有登入者能存取自己的節點」；前端守衛本身沒有任何祕密可言。
- 目前全站只有這一頁用 Firebase，其餘（影片研習、業務分享）都走 Supabase。
  若日後想統一，把這頁改成 Supabase 資料表（`auth.uid()` + RLS）會更一致，
  但需要在 SQL Editor 執行一次新增資料表的 SQL。

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

