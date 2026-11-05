# 宸功人士 — 設定說明（members.html）

「宸功人士」是團隊的組織圖與同仁的個人網頁，分成兩個分頁（頁面上方可切換，預設「組織圖」）。個人網頁（含「我的檔案」檢視模式）上方是一條職級色漸層裝飾帶，內容從它下面開始、不會被漸層蓋住：**左側是直式大照片，右側是姓名、職級、主管、夥伴、簡介與社群連結**；手機版改成照片置中在上、其餘資料往下堆疊。

| 分頁 | 內容 | 資料來源 |
|------|------|----------|
| **組織圖** | 傳統組織樹（`ul/li` 畫連線），**以最高職級 `AM`（處經理）為根節點**，依「所屬主管」往下分支；節點顏色代表職級（AM 藍、UM 紅、SAS 綠、AS 橘、AG 灰藍、未知金色）。點任何一個節點會開啟該同仁的**個人網頁**（職級、所屬主管、直屬夥伴、簡介、社群連結、年度心願時間軸）。有下屬的節點可 −／＋ 收合 | `get_member_directory()`、`get_member_wishes(uuid)` |
| **我的檔案** | 預設顯示**個人網頁檢視模式**（和你點別人看到的一樣；左側直式大照片、右側姓名／職級／主管／夥伴／簡介／社群連結，手機版上下排列），按右上「編輯我的檔案」才切到編輯模式：照片、姓名、簡介、IG／FB／LINE／LinkedIn、**職級**、**所屬主管**，以及**年度心願**（可切換年份，每月可寫多項）＋「我的時間軸」 | `member_profiles`、`profiles`、Storage `avatars`、`member_wishes`、`save_my_wishes()`、`get_member_wishes()` |

---

## 一、隱私設計（先看清楚再決定要不要開放）

1. **組織圖（同仁檔案）**：需要登入才能看。資料由 `security definer` 的 `get_member_directory()` 回傳，
   只包含「姓名、職級、主管姓名、照片路徑、簡介、社群連結」，
   **不會回傳 email 或 `is_admin`**。資料表 `member_profiles` 本身的 RLS 仍維持「只能讀自己那一列」。
2. **年度心願是全體可見（刻意設計）**：`member_wishes` 表的 RLS 只有「本人＋管理員」能讀寫；
   同仁要能看到彼此的時間軸，因此另提供 `security definer` 的 `get_member_wishes(uuid)`，
   只回「年／月／內容／排序／更新時間」，不含其他帳號資料，且必須登入才能呼叫。
   若只想讓本人看到，請照 `supabase-schema-member-wishes.sql` 檔尾的說明修改函式條件。
3. **照片是 public bucket**：`avatars` bucket 設為 public，拿到網址的人（含未登入）就能看圖；
   但只有本人能在自己的 `<uid>/` 資料夾寫入／覆蓋／刪除。
4. **職級與主管：本人可以自己改，最高職級除外**：除了 RLS，資料庫還有 trigger 檢查，
   一般同仁只能改「自己那一列」的 `rank_code` / `supervisor_id`，而且**不能把自己設成最高職級**
   （`member_ranks.sort_order` 最大的那一個，目前是 `AM` 處經理），避免組織圖長出多個根節點。

---

## 二、資料庫設定（只做一次）

> 專案沿用與影片研習／業務分享／宸功專區**同一個 Supabase 專案**：`dwesqvutdlvnmajxdcpn`

### 執行順序

1. `video-training/supabase-schema.sql`（若還沒跑過）
2. `supabase-schema-goals.sql`（提供 `goal_targets` 與 `private.set_updated_at()`）
3. `supabase-schema-agent-stats.sql`（個人實績；其他頁面會用到）
4. **`supabase-schema-members.sql`**（職級、成員資料、組織圖、頭像 bucket）
5. **`supabase-schema-member-wishes.sql`**（年度心願：`member_wishes` 與兩支 RPC）
6. `supabase-schema-goal-annual.sql`（年度目標；`goal-system.html` 會用到）

每一步都在 Supabase → SQL Editor 貼上**整份 `.sql` 檔**（不是這份 `.md`）按 **Run**，
看到 `Success. No rows returned` 即可。三支腳本都可重複執行
（`create ... if not exists` / `create or replace` / `drop policy if exists`）。

### `supabase-schema-members.sql` 會建立

| 物件 | 用途 |
|------|------|
| `public.member_ranks` | 職級對照（由低到高）：`AG` 專員、`AS` 業務主任、`SAS` 業務襄理、`UM` 區經理、`AM` 處經理。`sort_order` 最大者＝最高職級（目前 `AM`），組織圖以它為根節點。舊版代碼會自動遷移（`REP → AG`、`CM → AM`） |
| `public.member_profiles` | 每人一列（1:1 對 `auth.users`）：職級、主管、照片路徑、簡介、社群連結 |
| `trg_auth_user_create_member` | 新帳號自動建立 `member_profiles`（預設 `AG`、無主管） |
| `trg_member_profiles_no_cycle` | 組織圖防迴圈（往上追最多 32 層） |
| `trg_member_profiles_protect` | 本人可改自己的職級／主管，但**最高職級只有管理員能設定**；不能改 `user_id`（service_role 與 SQL Editor 不受限） |
| `public.get_member_directory()` | 組織圖的唯讀來源（只回顯示欄位） |
| Storage bucket `avatars` | 頭像（public 讀取、本人可寫、單檔 2MB、JPEG／PNG／WebP） |

腳本結尾會把既有 `profiles` 回填成 `member_profiles`，所以**不用手動一筆一筆新增**。

### `supabase-schema-member-wishes.sql` 會建立

| 物件 | 用途 |
|------|------|
| `public.member_wishes` | 年度心願：`user_id + wish_year + wish_month + content + sort_order`；一年一月可有多列（上限 10 項／月、單項 200 字） |
| `public.save_my_wishes(p_year integer, p_items jsonb)` | 一次覆寫自己某一年度的心願（先檢查 → 刪除該年度 → 重新寫入，單一交易） |
| `public.get_member_wishes(p_user uuid)` | 讀某位同仁的心願時間軸（`security definer`，只回顯示欄位） |

`p_items` 範例：`[{"month":3,"content":"通過考核"},{"month":3,"content":"簽下第一件"}]`。

### `supabase-schema-goal-annual.sql` 會建立

| 物件 | 用途 |
|------|------|
| `public.goal_annual_targets` | 每人每年的年度目標（`primary key (user_id, target_year)`） |
| `public.get_goal_board(date)` | 原本的團隊目標牆 RPC；`members.html` 改版後**不再呼叫**（函式保留，舊連結與其他用途仍可手動使用） |

### 如果 Storage bucket 沒自動建立

腳本對 bucket 的建立有做例外處理；若你的專案權限不允許，請手動建立：

1. Supabase → **Storage** → **New bucket**
2. Name：`avatars`，勾選 **Public bucket**
3. 檔案大小上限：`2 MB`；允許的 MIME：`image/jpeg`、`image/png`、`image/webp`
4. 再重跑一次 `supabase-schema-members.sql`（會補上 `storage.objects` 的 policy）

---

## 三、前端使用（不需要改任何金鑰）

- 頁面：`members.html`（組織圖／我的檔案）
- 入口：`index.html` → 「目標管理」分類的「宸功人士」卡片；登入後的快捷列也有連結
- 職級與主管（兩種方式都可以）：
  - **本人自己改**：`members.html` →「我的檔案」→ 右上「編輯我的檔案」→ 選「職級」「所屬主管」→ 儲存。
    職級選單只能選到 `UM`，`AM` 會標示「（需管理員設定）」並反灰；所屬主管選單**不會列出自己與自己的下屬**。
  - **管理員代改**：`accounts.html`（限管理員）→ 表格的「職級」「所屬主管」下拉選單，可設任何人（含 `AM`）。
  - **一定要有一位 `AM` 處經理且「所屬主管＝未設定」**，組織圖才有根節點
  - 建議由上往下設定：先設 `AM` → 再設 `UM` 的主管＝`AM` → 再往下（`SAS` → `AS` → `AG`）
  - 改完回 `members.html` 重新整理，即可看到新的分支與顏色
- 年度心願：`members.html` → 「我的檔案」→「編輯我的檔案」→「二、年度心願」
  - `‹` `›` 切換年份；每月可寫多項（＋新增一項／✕刪除），按「儲存這一年」一次寫入
  - 每月最多 10 項、單項 200 字；空白列不會儲存
  - 儲存是「整年覆寫」：先刪掉自己該年度的舊資料，再依畫面順序重新寫入（單一交易）
- 年度目標與 12 個月一覽：`goal-system.html` → 個人專區 → 「二、我的年度目標」「三、12 個月目標一覽」

### 第一次建置的建議流程

1. 執行三支 SQL（順序見上：members → member-wishes → goal-annual）。
   若之前已跑過舊版，`supabase-schema-members.sql` 會自動把 `REP` 改名為 `AG`、`CM` 改名為 `AM`（成員的職級一起搬過去），可安全重複執行。
2. 開 `accounts.html`，把一位同仁設為 `AM` 且「所屬主管＝未設定」；再依序往下設定其他人的主管
   （或請同仁自己在「我的檔案 → 編輯」選職級與主管）。
3. 開 `members.html` →「組織圖」確認層級與顏色正確（每個人都掛在對的人底下）。
4. 開 `members.html` →「我的檔案」→ 按「編輯我的檔案」→ 上傳照片、填簡介與社群連結、確認職級與主管。
5. 同一頁往下寫「年度心願」（可切年份、每月多項）→ 按「儲存這一年」→ 儲存後回到檢視模式，「我的時間軸」應出現內容。
6. 點組織圖上的自己（金色外框）→ 個人網頁應顯示同樣的時間軸，並有「編輯我的檔案」按鈕。
7. （選用）開 `goal-system.html` → 填年度目標 → 按「平均帶入 12 個月」（只補空白月份）。

---

## 四、驗證清單（建議照順序做）

1. **組織圖**：重新整理後最上方是 `AM`（金色外框標示「你」如果那是你）；下屬依「所屬主管」分層、節點顏色＝職級；沒有主管的人暫列在 `AM` 下一層，上方會提示人數。
2. **沒有 AM 時**：最上方會出現虛擬節點「請設定 AM」，並提示請管理員設定 `AM`。
3. **點人看檔案**：點任一節點 → 個人網頁顯示職級、所屬主管（可再點進去看）、直屬夥伴、簡介、社群連結與「年度心願時間軸」；版面是「左側直式大照片＋右側資料」（手機版照片置中在上、資料往下堆疊），上方漸層只是裝飾帶、不會蓋到照片與姓名；按 Esc 或點背景可關閉。
4. **我的檔案**：
   - 預設是檢視模式（個人網頁），按右上「編輯我的檔案」才會出現表單；「取消」可放棄修改。
   - 改姓名 → 儲存 → 組織圖與檔案立即更新（`profiles.full_name` 是共用欄位），並自動回到檢視模式。
   - 上傳照片 → 組織圖節點出現大頭照；重新整理後仍在（網址帶 `?v=<時間>` 破快取）。
   - 改職級／所屬主管 → 儲存 → 組織圖的分支與顏色跟著變。
     `AM` 選項只有管理員能選；所屬主管選單不會出現自己或自己的下屬。
5. **年度心願**：
   - 在 3 月按兩次「＋新增一項」→ 出現兩個輸入框；填內容 →「儲存這一年」→ 狀態顯示「已儲存 2 項」。
   - 「我的時間軸」出現「今年 年」與「3 月」，並依輸入順序列出兩項。
   - 切到別的年份 → 12 個月份都是空的；切回來 → 內容還在。
   - 把其中一項清空後儲存 → 該項消失（空白不儲存）。
   - 用另一位同仁帳號登入 → 點你的節點，能看到你的時間軸（刻意公開）。
6. **跨帳號**：用另一位同仁登入，「我的檔案」只會是自己的資料；組織圖全體可見。
7. **防護**：
   - 一般同仁在 Console 直接 `update member_profiles set rank_code='AM' where user_id = auth.uid()` → 應被 trigger 拒絕（42501）。改 `UM` 以下則允許。
   - 把 A 設為 B 的主管、再想把 B 設為 A 的主管 → 應被拒絕（組織圖迴圈）。
   - 用別人的 uid 上傳頭像 → Storage policy 應拒絕。
   - 直接 `insert into member_wishes` 別人的 `user_id` → RLS 應拒絕（`save_my_wishes` 只寫自己）。
8. **離線（PWA）**：`members.html` 已加入 `sw.js` 快取清單（`guardian-v31`）；
   連線過一次後斷網重開，至少能載入頁面骨架（資料仍需網路）。

---

## 五、常見問題

**Q1. 畫面顯示「找不到函式 get_member_directory / get_member_wishes / save_my_wishes」**
→ SQL 還沒執行，或 PostgREST 的 schema 快取還沒更新。請先確認三支 SQL 都跑過
（`supabase-schema-members.sql` → `supabase-schema-member-wishes.sql` → `supabase-schema-goal-annual.sql`），
再在 SQL Editor 執行：

```sql
notify pgrst, 'reload schema';
```

**Q2. 組織圖少了一個人**
→ 該帳號沒有 `member_profiles` 列。重跑 `supabase-schema-members.sql` 會自動回填；
或檢查 `profiles` 是否有對應的 `auth.users`。
（若只是「掛錯位置」，請看 Q4。）

**Q3. 名字顯示「未具名同仁」**
→ `profiles.full_name` 是空的。請到「我的檔案」或「帳號管理」補姓名（不會用 email 代替）。

**Q4. 組織圖的人全部擠在 AM 下面**
→ 這些人的 `supervisor_id` 還沒設定（或設到不在名單中的人）。請管理員到 `accounts.html`，
或由同仁自己在「我的檔案 → 編輯」選「所屬主管」，由 `AM` 開始**往下**設定；設定後重新整理 `members.html`。

**Q5. 出現「組織圖不可形成迴圈」**
→ 你正把某人的下屬設成他的主管。請先解除原本的主管關係，再設定新的。

**Q6. 出現「職級只能由管理員調整」**
→ 代表你想設定的職級是最高職級（目前 `AM`），這是刻意的保護：`AM` 會成為組織圖的根節點，
必須由管理員在 `accounts.html` 設定（或在 SQL Editor 直接更新，不受 trigger 限制）。
`UM` 以下的職級，本人可在「我的檔案 → 編輯」自行調整。

**Q7. 為什麼最上面是「請設定 AM」？**
→ 名單裡沒有任何 `rank_code = 'AM'` 的成員。請管理員到 `accounts.html` 把一位同仁的職級設為
「處經理」，並把他的「所屬主管」設成未設定，組織圖就會以他為根節點。

**Q8. 為什麼別人的時間軸是空的？**
→ 對方還沒在「我的檔案」→「年度心願」寫入內容（或只寫了空白列）。寫入並按「儲存這一年」後，
其他同仁點他的節點就看得到。

**Q9. 按「儲存這一年」後，時間軸沒更新？**
→ 先看狀態列是否顯示「已儲存 N 項」。若顯示錯誤，最常見是函式還沒建立（Q1）；
若顯示 0 項，代表畫面上沒有非空白的內容（空白不會儲存）。
另外提醒：儲存是**整年覆寫**，若把某一項清空後再儲存，該項會被刪除。

**Q10. 年度目標和 12 個月加總不一致，是壞掉了嗎？**
→ 不是。年度目標是整年規劃，每月目標是執行值，本來就可能不同；
「12 個月目標一覽」下方會顯示差額，方便你回頭調整。

**Q11. 換照片沒生效**
→ 圖片網址會帶 `?v=<avatar_updated_at>` 破快取；若仍是舊圖，請確認上傳成功訊息與
Storage → `avatars` → `<你的 uid>/avatar.jpg` 是否存在。

**Q12. 可以分「通訊處」嗎？**
→ 目前沒有單位欄位，組織圖與時間軸都是**全體同仁**。若未來要分單位，
建議在 `member_profiles` 增加 `unit_code`，再於 RPC 加過濾條件。
