# 一定要宸功專區 — 設定說明（goal-system.html）

「一定要宸功專區」分成兩個分區（頁面上方可切換，預設顯示「個人專區」）：

| 分區 | 內容 | 資料來源 |
|------|------|----------|
| **個人專區** | 我的每月目標（輸入＋摘要）、每週行動計畫、我的實績（個人） | `goal_targets`、`agent_stats`（本人） |
| **通訊處專區** | 整個通訊處**總目標**、整個通訊處**合計實績**（只顯示合計，不列個人明細） | `get_unit_goal_totals()`、`get_unit_agent_stats_totals()` |

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

### 通訊處專區

集結**全體同仁**，只顯示合計、不揭露任何個人明細：

- **整個通訊處總目標**：以 `get_unit_goal_totals()` 加總 FYC／保費／件數與已設定人數。
- **整個通訊處合計實績**：以 `get_unit_agent_stats_totals()` 加總全體同仁（保顧+ 同步）的記事筆數，並對照目標合計算達成率。

首頁（`index.html`）會多一列「本月目標 Monthly Targets」，同時顯示**我的目標**與**整個通訊處的加總**。

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
| `trg_goal_targets_updated` | 更新時自動寫 `updated_at` |
| RLS 政策 | 每人只能讀／寫自己的那一筆；管理員可讀全部 |
| `public.get_unit_goal_totals(date)` | 以 `security definer` 回傳**加總**（FYC／保費／件數／人數），供顯示「整個通訊處總目標」 |

> **通訊處專區的「合計實績」需要另外兩支 SQL**（依序執行）：
> `supabase-schema-agent-stats.sql`（建立 `public.agent_stats`）→ `supabase-schema-unit-stats.sql`
> （建立 `public.get_unit_agent_stats_totals(date)`，只回傳全體合計）。詳細說明見 `AGENT-STATS-SETUP.md`。

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

---

## 二、前端設定（無需修改程式）

`goal-system.html` 與 `index.html` 都會自動沿用 `auth-guard.js` 載入的 Supabase client 與 `config.js`，
**不需要再填任何金鑰**。只要 SQL 執行完成，重新整理頁面即可使用。

- 新頁面：`goal-system.html`
- 首頁入口：`index.html` → 最上方「目標管理」分類的 ★ 卡片，以及頁首的「本月目標」摘要列。

---

## 三、驗證（建議照順序做）

1. 登入後開啟 `goal-system.html`。
2. 選擇月份 → 填入 FYC／保費／件數 → 按「儲存本月目標」，看到綠色「已儲存 ✓」。
3. 下方「每週行動計畫」數字應隨件數即時變動（例如件數 4 → 每週成交 1、接觸 5、面談 3、約訪 10）。
4. 回到 `index.html`，「本月目標」摘要列應顯示你的數字；「整個通訊處」為全體同仁加總。
5. 切到「通訊處專區」：應顯示「一、整個通訊處總目標」與「二、整個通訊處合計實績」；
   後者需要另外兩支 SQL（`supabase-schema-agent-stats.sql` → `supabase-schema-unit-stats.sql`）已執行。
6. 在 SQL Editor 交叉檢查：
   ```sql
   select * from public.goal_targets order by period_month desc, updated_at desc;
   select * from public.get_unit_goal_totals(date_trunc('month', now())::date);
   select * from public.get_unit_agent_stats_totals(date_trunc('month', now())::date);
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
