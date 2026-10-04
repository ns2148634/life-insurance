# 業務分享專區 — 設定與維運說明

Supabase 專案：`dwesqvutdlvnmajxdcpn`（與 `video-training` 共用同一組帳號）

## 一、頁面與功能

| 檔案 | 用途 |
| --- | --- |
| `login.html` | 登入（沿用影片研習的帳號；已登入自動導向 `share.html`） |
| `share.html` | **主頁**：一進站先看到**分享清單**（標題／來源／標籤）與搜尋 / 分類篩選 / 排序；要分享時按「**＋ 我要分享**」才展開分享表單 |
| `config.js` | Supabase URL / anon key（與 video-training 相同） |
| `style.css` | 樣式（色票對齊首頁 `index.html` 的 token） |
| `supabase-schema-links.sql` | 資料表、索引、trigger、RLS（可重複執行） |

## 二、MVP 功能範圍

- 登入的同仁**新增分享**：清單上方按「＋ 我要分享」展開表單，填網址、標題、分享理由、分類、（可選）標籤；送出後表單自動收合，訊息顯示在清單上方
- **瀏覽**所有人的分享（卡片式），可「開啟原文」與「複製連結」
- 只有**分享者本人**能編輯 / 刪除自己的分享
- 搜尋（標題 / 理由 / 標籤 / 來源 / 分享者）、**分類篩選**、排序（最新 / 最舊 / 只看我的）
- 分享人姓名以**即時查詢**顯示：同仁在「我的帳號」改名後，**舊分享也會跟著顯示新名**
- 網址僅允許 `http` / `https`（前端驗證 + 資料庫 check 約束雙重把關）

> Phase 2（尚未實作，schema 已預留 `is_hidden` 欄位）：管理員下架、我的最愛、重複連結提醒、自動抓取標題。

## 三、第一次使用（或每次修改 SQL 後）必做

1. 先確認已執行過 `video-training/supabase-schema.sql`（本模組會沿用其中的
   `public.profiles` 與 `private.is_admin()`）。
2. 打開 Supabase Dashboard → **SQL Editor** → **New query**。
3. 把 `sharing/supabase-schema-links.sql` **整份內容貼上** → Run。
   - 這份 SQL 是**可重複執行**的，之後改動都能直接整份重跑。
   - 從 2026-10 版起，本檔額外包含 `public.get_user_display_names()` 函式
     （分享人姓名的即時查詢），**沒重跑的話舊分享改名後仍會顯示舊名**。
4. 若分享清單出現「找不到資料表 shared_links」，在 SQL Editor 執行：
   ```sql
   notify pgrst, 'reload schema';
   ```
   再重新整理頁面。
5. **不需要**新增帳號，也不需要改 `manifest.json`；同仁用影片研習的帳號即可登入。

## 四、分類

固定 6 類（前端下拉與資料庫 check 約束一致）：

`醫療健康` / `退休理財` / `稅務法令` / `時事趨勢` / `業務心法` / `其他`

> 若要新增分類，需同時修改兩處：`sharing/supabase-schema-links.sql`
> 的 `shared_links_category_chk` 約束，以及 `share.html` 的 `CATEGORIES` 陣列。

## 五、安全性設計

- **登入才能使用**：`anon` 角色已撤銷 `shared_links` 所有權限；前端未登入會被導回 `login.html`。
- **只能以自己的身分分享**：insert policy `with check (auth.uid() = shared_by)`。
- **只能改 / 刪自己的**：update / delete policy 限制 `auth.uid() = shared_by`，
  且 update 的 `with check` 再擋掉改 `shared_by` 與自行設定 `is_hidden`。
- **管理員**（`profiles.is_admin = true`）可讀、改、刪任何一列（供 Phase 2 下架使用），
  透過 `private.is_admin()`（security definer）判斷，避免 RLS 遞迴。
- **防 XSS**：所有輸出文字經 `escapeHtml`；網址經 `safeUrl()` 只允許 `http`/`https`，
  外連一律 `target="_blank" rel="noopener noreferrer"`。
- 分享人姓名顯示為**即時查詢**：`shared_by_name`（分享當下寫入）僅作為**後備快照**，
  前端另呼叫 `public.get_user_display_names(p_ids)`（security definer）取得最新姓名，
  因此同仁在「我的帳號」改名後，**舊分享也會跟著顯示新名**。
  該函式只回傳呼叫者指定的 id、且需登入、單次上限 500 筆，不會外洩全體同仁名單；
  若函式尚未建立（未重跑 SQL）或呼叫失敗，會自動退回快照，不影響瀏覽。

## 六、疑難排解

| 症狀 | 原因 / 處理 |
| --- | --- |
| 分享清單顯示「讀取分享清單失敗：… does not exist」 | `supabase-schema-links.sql` 還沒執行，或 PostgREST schema 快取未更新 → 執行 `notify pgrst, 'reload schema';` |
| 分享送出後出現 `new row violates row-level security policy` | insert policy 未生效，或未登入。整份重跑 SQL 後重新登入再試。 |
| 分享後看不到自己的資料 | 讀取 policy 未生效，或 `is_hidden` 被設為 `true`（MVP 不會）。整份重跑 SQL。 |
| 列表顯示 email 而非姓名 | 該同仁尚未在「我的帳號」填寫姓名（沿用影片研習的 `profiles.full_name`）。 |
| 同仁改名後，舊分享仍顯示舊名 | 尚未重跑 `sharing/supabase-schema-links.sql`（缺少 `get_user_display_names` 函式），或該筆的 `shared_by` 為 null（原作者帳號已刪除，只能顯示快照）。 |
| 送出時顯示「網址格式不正確」 | 需填完整網址且以 `http://` 或 `https://` 開頭（例如少了 `https://` 會擋下）。 |
| 點了卡片上的編輯 / 刪除沒反應 | 該筆不是你的分享；只有分享者本人（或管理員）能看到這兩個按鈕。 |
| 網址要換成新分類卻被擋 | 新分類需同步更新資料庫的 check 約束與前端 `CATEGORIES`（見第四節）。 |
