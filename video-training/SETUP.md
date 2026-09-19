# 影片研習系統 — 設定與維運說明

Supabase 專案：`dwesqvutdlvnmajxdcpn`

## 一、頁面與功能

| 檔案 | 用途 |
| --- | --- |
| `login.html` | 業務員登入（帳號由主管配發） |
| `videos.html` | 影片清單 + 觀看進度 |
| `watch.html` | 觀看影片並記錄進度 |
| `profile.html` | **我的帳號**：填寫/修改姓名、自行更改密碼 |
| `admin.html` | 主管後台：團隊完成度、**代為重設業務員密碼** |
| `config.js` | Supabase URL / anon key |
| `supabase-schema.sql` | 資料表、RLS、函式、觸發器（可重複執行） |

## 二、第一次使用（或每次修改 SQL 後）必做

1. 打開 Supabase Dashboard → **SQL Editor** → **New query**
2. 把 `supabase-schema.sql` **整份內容貼上** → Run
   - 這份 SQL 是**可重複執行**的（`if not exists` / `drop policy if exists` / `create or replace`），
     之後每次改動都能直接整份重跑，不會報錯。
3. 設定自己的管理員權限（只需做一次）：
   ```sql
   update public.profiles set is_admin = true where id = '<你的 user id>';
   ```
   （user id 可在 Authentication → Users 頁面點進帳號後複製）
4. 新增業務員帳號：Authentication → **Users → Add user**
   - 填 Email + 密碼，勾選 **Auto Confirm User**（否則無法登入）
   - 可在 **User Metadata** 先填 `{"full_name":"王小明"}`，業務員之後也能自己登入到「我的帳號」改寫
5. 新增影片：
   ```sql
   insert into public.videos (title, youtube_id, duration_sec, sort_order)
   values ('第一課：保單健檢基礎', 'XXXXXXXXXXX', 600, 1);
   ```
   YouTube 影片請用「不公開 Unlisted」，不要用「私人」。

## 三、業務員怎麼自己改資料 / 密碼

1. 登入後在影片清單右上角點 **我的帳號**
2. **個人資料**：Email 唯讀（登入帳號），可填寫／修改 **姓名** → 按「儲存」
   - 姓名會顯示在影片清單與主管的完成度報表
3. **更改密碼**：輸入目前密碼 + 新密碼（至少 8 字元）+ 再次確認 → 按「變更密碼」
   - 程式會先用目前密碼登入驗證身分，再更新密碼
   - 可勾選「同時登出其他裝置的登入狀態」
4. 忘記密碼沒有自助流程（本專案未設定寄信 SMTP），請洽主管重設。

## 四、主管如何代為重設業務員密碼

1. 以管理員帳號登入 → `admin.html`
2. 在該業務員那一列按 **重設密碼**
3. 按 **產生隨機密碼**（或自行輸入，至少 8 字元）→ **確認重設**
4. 畫面會出現臨時密碼（可點選複製），請提供給該業務員
   - 重設同時會**撤銷該業務員所有登入狀態**，他必須用臨時密碼重新登入
   - 請提醒他登入後到「我的帳號」改成自己的密碼

> 實作方式：前端呼叫 `sb.rpc('admin_reset_user_password', { p_user_id, p_new_password })`，
> 由資料庫端的 `security definer` 函式檢查 `private.is_admin()` 後更新 `auth.users.encrypted_password`
> 並刪除 `auth.sessions`。未登入者或非管理員呼叫會直接被拒絕（42501）。

## 五、安全性設計（本次修訂）

- **修掉 policy 無限遞迴**：舊版 `profiles` 的 admin policy 直接 `select profiles`，
  造成 `profiles` / `watch_progress` 所有查詢回 `500 infinite recursion detected`。
  現在改用 `private.is_admin()`（security definer）只查一次。
- `profiles` 開放「自己新增／修改自己那一列」，`using` 與 `with check` 都限制 `auth.uid() = id`
  （避免有人把自己的列改成別人或改掉 id）。
- 用 trigger `trg_protect_is_admin` 擋住**自行把 `is_admin` 改成 true**（RLS 無法限制單一欄位）。
- `anon` 角色已撤銷 `profiles` / `videos` / `watch_progress` 的所有權限。
- policy 皆使用官方建議寫法：`to authenticated` + `(select auth.uid())`。
- `admin_reset_user_password` 只 `grant execute` 給 `authenticated`，且函式內再檢查管理員身分。

## 六、疑難排解

| 症狀 | 原因 / 處理 |
| --- | --- |
| 網頁 Console 出現 `500 infinite recursion detected in policy for relation "profiles"` | `supabase-schema.sql` 還沒執行（或執行失敗）。整份重跑一次即可。 |
| 影片清單右上角一直顯示 email、改了姓名沒生效 | 同上，RLS 尚未修好；請先執行 SQL。 |
| 儲存姓名出現 `permission denied` / `new row violates row-level security` | SQL 沒跑完（缺少 `update own profile` / `insert own profile` policy）。 |
| 重設密碼出現 `function extensions.crypt(text, text) does not exist` | pgcrypto 不在 `extensions` schema。執行：`create extension if not exists pgcrypto with schema extensions;`，若已安裝在別處請改該函式內的 schema 前綴。 |
| 重設密碼出現 `permission denied for function admin_reset_user_password` | 呼叫者不是管理員（`profiles.is_admin = false`），或該函式的 grant 未生效。 |
| 重設密碼後無法用新密碼登入 | 代表直接寫 `auth.users.encrypted_password` 在此專案不相容。請改用 Dashboard → Authentication → Users → 該使用者 → Reset password 重設，並回報以便改走 Admin API（Edge Function）。 |
| 業務員登入後被導回登入頁 | Session 遺失（例如瀏覽器隱私模式、或 `config.js` 的 URL / anon key 有誤）。 |

