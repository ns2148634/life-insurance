# 一定要宸功專區 — 設定說明（goal-system.html）

「一定要宸功專區」分成四個分區（頁面上方可切換，預設顯示「個人專區」）：

| 分區 | 內容 | 資料來源 |
|------|------|----------|
| **個人專區** | 我的每月目標（輸入＋摘要）、每週行動計畫、我的實績（個人） | `goal_targets`、`agent_stats`（本人） |
| **通訊處專區** | 整個通訊處**總目標**、整個通訊處**合計實績**（只顯示合計，不列個人明細） | `get_unit_goal_totals()`、`get_unit_agent_stats_totals()` |
| **通訊處排行** | 各項實績指標的**前 10 名與數值**（可切換 10 個指標、可選月份） | `get_unit_agent_stats_ranking()` |
| **歷史資料** | 月／季／年回查：我的目標 vs 實績（含達成率）、通訊處合計、排行歷史（Top 10＋**我的名次**） | `goal_targets`、`agent_stats`、`get_unit_history()`、`get_unit_agent_stats_ranking_range()` |

### 個人專區

讓每位業務同仁設定**自己的每月目標**：

| 欄位 | 說明 |
|------|------|
| FYC 目標 | 首年度佣金目標（元） |
| 目標保費 | 當月預計收進的保費（元） |
| 目標件數 | 當月預計成交件數 |

系統再用「目標件數」自動換算**每週行動量**，比例沿用 `90day.html`：

- 接觸（拜訪） = 件數 × 5
- 面談（談 case） = 件數 × 3
- 約訪 = 件數 × 10

換算週數固定以 **每月 4 週**計，每週件數採**無條件進位**（例如 6 件／月 → 每週 2 件 → 每週接觸 10 人、面談 6 人、約訪 20 人）。

### 年度目標與 12 個月一覽

個人專區多了兩個面板（排在「一、我的每月目標」之後）：

| 面板 | 說明 |
|------|------|
| **二、我的年度目標** | 每年一筆的 FYC／保費／件數規劃（`public.goal_annual_targets`）。可按「平均帶入 12 個月」，把年度值平均寫進**尚未設定**的月份；已手動設定過的月份不會被覆蓋，餘數會分配到前幾個月，讓 12 個月加總盡量等於年度值 |
| **三、12 個月目標一覽** | 列出該年度 1～12 月的每月目標與「已設定／未設定」，下方合計並與年度目標比較差額 |

> 年度目標是**整年規劃**、每月目標是**執行值**，兩者不必相等；「12 個月目標一覽」下方會直接顯示差額，方便回頭補齊。
> 這兩個面板需要先執行 `supabase-schema-goal-annual.sql`（年度目標表）。該檔另含 `get_goal_board()`（舊團隊目標牆 RPC），目前前端已不再呼叫，保留給臨時查詢用。

### 通訊處專區

集結**全體同仁**，只顯示合計、不揭露任何個人明細：

- **整個通訊處總目標**：以 `get_unit_goal_totals()` 加總 FYC／保費／件數與已設定人數。
- **整個通訊處合計實績**：以 `get_unit_agent_stats_totals()` 加總全體同仁（保顧+ 同步）的記事筆數，並對照目標合計算達成率。

### 通訊處排行

以「保顧+」同步的實績，列出**全體同仁**在單一指標的前 10 名：

- 可切換月份，以及 10 個指標：本月總計、簽約、遞送建議書、約訪聯繫、新客戶、複訪、服務、理賠、增員、名下客戶。
- 名次、同仁姓名、數值與比例條；前三名以金／銀／銅標示。
- 只納入該指標 **> 0** 的同仁；同分依姓名排序（SQL 端 `row_number()` 固定結果）。
- `clients_count`（名下客戶）是該月同步的**客戶總數（現況值）**，不是本月新增。

> **隱私說明**：這是「不列個人明細」的**刻意例外**。排行需要顯示同仁姓名才能發揮激勵效果，
> 但函式只回傳名次、顯示名稱、該指標數值與同步時間，**不會輸出完整 email、客戶姓名或記事內容**。
> 若之後要改成遮罩姓名或只給管理員看，修改 `supabase-schema-unit-ranking.sql` 即可。

### 歷史資料

同一組「月／季／年」切換（月＝最近 12 個月、季＝最近 8 季、年＝最近 5 年），分成三個面板：

1. **我的歷史（目標 vs 保顧+ 實績）**
   - 行動量對照：約訪＝`first_visit`、接觸＝`new_client + follow_up`、面談＝`discuss_case`、成交＝`signed`；
     目標＝當期目標件數 ×10／×5／×3／×1，並顯示達成率（≥100% 金色、<100% 紅字）。
   - 目標與其他實績：FYC／保費／件數目標、實績總計、新客戶、複訪、服務、理賠、增員、名下客戶（期末）。
2. **通訊處統計歷史（合計）**：走 `get_unit_history()`，只回全體合計，不列個人明細。
3. **通訊處排行歷史**：走 `get_unit_agent_stats_ranking_range()`，可切換 10 個指標與期別；
   除了 Top 10，還會多回一列 `is_me`，因此**即使你的名次在前 10 名之外，也會在上方「我的名次」單獨顯示**。

> **客戶規劃歷程已獨立**：原本在歷史資料區的「客戶規劃歷程」已移到首頁的
> **「人生圖資料」**（`client-plans.html`），可依姓名／風險／保障項目／金額搜尋與期間篩選，
> 不再佔用宸功專區的版面。設定與驗證方式見 `client-plans.html` 頁首說明與 `DEV.md`。

> **季／年怎麼算**：目標與實績都是「期內月加總」；`clients_count`（名下客戶）是現況值，
> 取**期內最新月份**那一列，不是相加（表格下方也有註明）。
>
> **隱私**：個人歷史只讀自己的列（RLS）；通訊處只有合計；
> 排行沿用既有「刻意例外」，只輸出顯示名稱與數值，不含完整 email、客戶姓名或記事內容。

首頁（`index.html`）不再顯示「本月目標」摘要列；改為**每天第一次載入首頁時彈出「本月目標」**：
顯示自己的 FYC 目標與目標保費（目標件數 > 0 才顯示），當月未設定時顯示引導並可直接前往設定。
已看過記在 `localStorage` 的 `cg_goal_popup_<uid>_<YYYY-MM-DD>`（同一天重新整理不再彈、隔天再彈）；
要重新測試，請在 DevTools → Application → Local Storage 刪掉該 key 後重新整理即可。

---

## 一、資料庫設定（只做一次）

> 專案沿用與影片研習／業務分享**同一個 Supabase 專案**：`dwesqvutdlvnmajxdcpn`
> 前置條件：已執行過 `video-training/supabase-schema.sql`（提供 `public.profiles` 與 `private.is_admin()`）。

1. 開啟 Supabase 專案 → 左側 **SQL Editor**。
2. 貼上 `supabase-schema-goals.sql` 的**全部內容**，按 **Run**。
   - 腳本可重複執行（全部使用 `create ... if not exists` / `create or replace` / `drop policy if exists`）。
3. 看到 `Success. No rows returned` 即完成。

腳本會建立：

| 物件 | 用途 |
|------|------|
| `public.goal_targets` | 每月目標（一人一月一筆，`unique(user_id, period_month)`） |
| `public.goal_annual_targets` | 年度目標（一人一年一筆，`primary key (user_id, target_year)`；需執行 `supabase-schema-goal-annual.sql`） |
| `trg_goal_targets_updated` | 更新時自動寫 `updated_at` |
| RLS 政策 | 每人只能讀／寫自己的那一筆；管理員可讀全部 |
| `public.get_unit_goal_totals(date)` | 以 `security definer` 回傳**加總**（FYC／保費／件數／人數），供顯示「整個通訊處總目標」 |

> **通訊處專區的「合計實績」需要另外兩支 SQL**（依序執行）：
> `supabase-schema-agent-stats.sql`（建立 `public.agent_stats`）→ `supabase-schema-unit-stats.sql`
> （建立 `public.get_unit_agent_stats_totals(date)`，只回傳全體合計）。
> **「通訊處排行」再一支**：`supabase-schema-unit-ranking.sql`
> （建立 `public.get_unit_agent_stats_ranking(date, text, integer)`，回傳各指標前 10 名）。
> 詳細說明見 `AGENT-STATS-SETUP.md`。
>
> **「歷史資料」需要一支 SQL**（可與上面一起執行）：
> `supabase-schema-history.sql`（建立 `get_unit_history(date, date)` 期間合計與
> `get_unit_agent_stats_ranking_range(date, date, text, integer)` 期間排行＋`is_me`）。
> 只新增物件、可重複執行，結尾同樣會 `notify pgrst, 'reload schema'`。
>
> **「人生圖資料」（`client-plans.html`）另需一支**：
> `supabase-schema-insurance-plans.sql`（建立 `public.insurance_plans`，供
> `insurance-needs.html` 第 3 頁「儲存客戶資料」與人生圖資料搜尋使用）。

### 資料表結構

```
public.goal_targets
  id              uuid  pk        default gen_random_uuid()
  user_id         uuid  not null  → auth.users(id) on delete cascade
  period_month    date  not null  一律為該月 1 號（check 限制）
  fyc_target      numeric(12,0)   >= 0
  premium_target  numeric(12,0)   >= 0
  case_target     integer         >= 0
  created_at      timestamptz     default now()
  updated_at      timestamptz     default now()
  unique (user_id, period_month)
```

> ⚠️ 前端一律用 `period_month = 'YYYY-MM-01'` 讀寫，資料庫也有 `check` 擋掉非 1 號的日期，避免同一個月出現兩筆。

```
public.insurance_plans          -- 人生圖資料（client-plans.html 讀取；每次儲存新增一筆）
  id              uuid  pk        default gen_random_uuid()
  user_id         uuid  not null  → auth.users(id) on delete cascade（RLS 比對 auth.uid()）
  client_name     text  not null  1–40 字（不含其他個資）
  monthly_income  numeric(12,0)   >= 0
  risk_order      jsonb  not null 四項風險 id 陣列（長度必須為 4）
  coverage        jsonb  not null 保障內容顯示快照（保留「20-40」等原文）
  created_at      timestamptz     default now()
  updated_at      timestamptz     default now()
```

> `coverage` 範例：
> `[{"cat":"death","title":"活的太短","priority":1,"items":[{"key":"death-0","name":"一般身故","value":"450","unit":"萬元"}]}]`
> —— 前端只負責顯示，不再重算，因此人生圖資料頁看到的數字與當時儲存的一致。

---

## 二、前端設定（無需修改程式）

`goal-system.html`、`client-plans.html` 與 `index.html` 都會自動沿用 `auth-guard.js` 載入的 Supabase client 與 `config.js`，
**不需要再填任何金鑰**。只要 SQL 執行完成，重新整理頁面即可使用。

- 頁面：`goal-system.html`（目標與歷史）、`client-plans.html`（人生圖資料）
- 首頁入口：`index.html` → 最上方「目標管理」分類的 ★ 卡片，以及頁首的「本月目標」摘要列；
  客戶規劃搜尋則在「客戶顧問」分類的「人生圖資料」卡片（頁首登入區塊也有快捷連結）。

---

## 三、驗證（建議照順序做）

1. 登入後開啟 `goal-system.html`。
2. 選擇月份 → 填入 FYC／保費／件數 → 按「儲存本月目標」，看到綠色「已儲存 ✓」。
3. 下方「每週行動計畫」數字應隨件數即時變動（例如件數 4 → 每週成交 1、接觸 5、面談 3、約訪 10）。
   接著在「二、我的年度目標」填年度 FYC／保費／件數 → 按「儲存年度目標」→ 按「平均帶入 12 個月」，
   「三、12 個月目標一覽」應補滿 12 個月（既有月份不被覆蓋），表格下方會顯示合計與年度目標的差額。
4. 回到 `index.html`，「本月目標」摘要列應顯示你的數字；「整個通訊處」為全體同仁加總。
5. 切到「通訊處專區」：應顯示「一、整個通訊處總目標」與「二、整個通訊處合計實績」；
   後者需要另外兩支 SQL（`supabase-schema-agent-stats.sql` → `supabase-schema-unit-stats.sql`）已執行。
6. 切到「通訊處排行」：選月份與指標，應顯示前 10 名與數值；
   需先執行 `supabase-schema-unit-ranking.sql`。沒有資料時應顯示「尚無大於 0 的資料」。
7. 切到「歷史資料」：
   - 切「月／季／年」，三張表應跟著換算；季／年的數字＝期內月加總。
   - 「名下客戶（期末）」旁會標示取用的月份（期內最新月份）。
   - 排行歷史選「季／年」後，Top 10 與「我的名次」應一起更新；若你排在前 10 名外，
     上方會出現「你的名次：第 N 名」與「前 10 名之外」的說明。
8. 開 `insurance-needs.html` 走到第 3 頁，填姓名與月收入 →「儲存客戶資料」→ 看到綠色成功訊息；
   按 **F5 重新整理後再存一次**，開 `client-plans.html`（人生圖資料）應看到 **2 筆**（每次新增、不覆蓋），
   在搜尋框輸入客戶姓名或「醫療」等關鍵字，應只剩符合的規劃並自動展開。
9. 在 SQL Editor 交叉檢查：
   ```sql
   select * from public.goal_targets order by period_month desc, updated_at desc;
   select * from public.get_unit_goal_totals(date_trunc('month', now())::date);
   select * from public.get_unit_agent_stats_totals(date_trunc('month', now())::date);
   select * from public.get_unit_agent_stats_ranking(date_trunc('month', now())::date, 'signed', 10);
   select * from public.get_unit_history(
     (date_trunc('month', now()) - interval '11 months')::date,
     date_trunc('month', now())::date);
   select * from public.get_unit_agent_stats_ranking_range(
     date_trunc('quarter', now())::date, date_trunc('month', now())::date, 'signed', 10);
   select client_name, monthly_income, risk_order, created_at
     from public.insurance_plans order by created_at desc;
   ```

---

## 四、常見問題

**Q1. 畫面顯示「找不到資料表 goal_targets」或「讀取通訊處加總失敗」**
→ `supabase-schema-goals.sql` 還沒執行，或 PostgREST 的 schema 快取還沒更新。
請執行下列其中一項後重新整理：

```sql
notify pgrst, 'reload schema';
```

（Supabase 專案 → Settings → API → 也有「Reload schema cache」按鈕，效果相同。）

**Q2. 儲存失敗，訊息含 `row-level security`**
→ `user_id` 必須等於自己的 `auth.uid()`。本頁一律以登入者身分寫入，若自行用 SQL 塞資料請以**該同仁的 uid** 為 `user_id`。

**Q3. 「整個通訊處」的數字是什麼範圍？**
→ 目前 `profiles` 沒有「單位／通訊處」欄位，因此 `get_unit_goal_totals()`（目標）與
`get_unit_agent_stats_totals()`（合計實績）都是**全體同仁加總**。
若未來要分通訊處，需先在 `profiles` 增加 `unit` 欄位，再於兩支函式加入 `where p.unit = <我的 unit>` 的過濾。

**Q4. 每月要重新設定嗎？**
→ 不用「重新設定」，但**每個月是一筆獨立資料**；換到新月份時表單會是空的，填一次即可。舊月份資料會保留，可切換月份回查。

**Q5. 為什麼每月算 4 週？**
→ 為了讓每週目標是乾淨的整數、方便排行程（沿用 90 天手冊的簡化方式）。若想改成以實際週數計算，調整 `goal-system.html` 最上方的 `WEEK_PER_MONTH` 即可。

**Q6. 「通訊處專區」的實績為什麼看不到個人名字？**
→ 這是刻意的隱私界線。一般同仁只能讀 `agent_stats` 自己那一列（RLS），
所以通訊處專區改走 `security definer` 的 `get_unit_agent_stats_totals()`，只回傳**合計**與同步時間，
不會揭露任何個人明細；「已設定人數」也只看得到總數。

**Q7. 那「通訊處排行」為什麼看得到名字？**
→ 排行是上述隱私界線的**刻意例外**（依團隊需求開放）。它走另一支 `security definer` 函式
`get_unit_agent_stats_ranking()`，只回傳「名次、顯示名稱、該指標數值、同步時間」，
不包含完整 email、客戶姓名或記事內容。若不想開放，可在函式內遮罩名稱，或把執行權限收回給管理員。

**Q8. 「歷史資料」顯示「讀取通訊處歷史失敗／讀取排行歷史失敗」**
→ 還沒執行 `supabase-schema-history.sql`，或 PostgREST 的 schema 快取還沒更新。
先在 SQL Editor 執行該檔（結尾會 `notify pgrst, 'reload schema'`），再重新整理。
若只是「我的歷史」失敗，通常是 `goal_targets`／`agent_stats` 尚未建立。

**Q9. 「儲存客戶資料」失敗，或人生圖資料顯示讀取失敗**
→ 先執行 `supabase-schema-insurance-plans.sql`。若訊息含 `row-level security`，
代表寫入的 `user_id` 不是自己的 `auth.uid()`（本頁一律用登入者身分寫入）。
人生圖資料（`client-plans.html`）一般同仁只會看到**自己**儲存的資料，換帳號看不到別人的；
管理員（`profiles.is_admin = true`）可看到全部，這是刻意的。

**Q10. 為什麼「人生圖資料」每次儲存都變成一筆，不會覆蓋？**
→ 這是需求：保留每次諮詢當下的保障內容快照（含「20-40」這種區間原文），
方便在 `client-plans.html` 用姓名或保障項目搜尋、回看客戶規劃的變化。
若要刪除，可在 SQL Editor 以本人身分刪除該列
（RLS 允許本人 delete），或日後再加「刪除」按鈕。
