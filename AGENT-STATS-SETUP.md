# 我的實績（agent_stats）— 設定說明

`goal-system.html` 的「三、我的實績」會顯示你在**「ShowAll 保顧+」**的行程實績
（新客戶／約訪聯繫／複訪／遞送建議書／簽約的**筆數**），並與本站設定的「每月目標」對照達成率。

資料流（單向、由保顧+ 推過來）：

```
保顧+ (Next.js + Supabase uditztyjqbpzxzgquiym)
  ①  GitHub Actions 排程呼叫 /api/cron/sync-agent-stats（每天 3 次、帶 x-cron-secret）
  ②  export_agent_stats(p_from, p_to)         ← 只吐「筆數」，不含記事內容／客戶姓名
  ③  以 service role 寫入本站的 ingest_agent_stats(p_rows)
本站 (純靜態 GitHub Pages + Supabase dwesqvutdlvnmajxdcpn)
  ④  public.agent_stats（每人每月一列）→ goal-system.html 只讀自己那一列（RLS）
```

> ⚠️ **隱私界線**：全程只傳「筆數」與 email／顯示名稱。
> 客戶姓名、記事內容、聯絡方式等一律不出保顧+。
> 本站前端沒有任何寫入權限（`agent_stats` 只有 `select` 政策，沒有 insert／update／delete）。

### 誰會被同步（匯出範圍）

保顧+ 會匯出**兩類**人，**只要其中一類成立就會被同步**（2026-10-10 起「個人付費者」也納入）：

**① 團隊成員**（條件與 `/stats/team` 的成員排行完全相同）

| 條件 | 說明 |
|------|------|
| `team_members.status = 'active'` | 仍在團隊中（已離開／移除者不匯出） |
| 團隊 `teams.stats_status = 'active'` | 團隊統計已解鎖（比照 `/stats/team` 的付費／解鎖界線） |
| `auth.users.banned_until is null` | 帳號未被停權 |

> **不要求成員自己有 Pro 訂閱**：團隊方案（0053 後）只有 Owner 付費、成員免費，
> 所以「成員都是有效 Pro」不再是正確條件。

**② 個人付費者**（沒有團隊、或所屬團隊還沒解鎖，只要自己付費就涵蓋）

| 條件 | 說明 |
|------|------|
| `subscriptions.plan in ('pro', 'team')` | 自己那一列是專業會員或團隊方案 |
| `subscriptions.status = 'active'` | 訂閱有效——**不看到期日**，與 app 端 `getMembership`／0053 `my_team_access()` 同一條判準（到期與否由管理員的「調整到期日／取消」決定） |
| `auth.users.banned_until is null` | 帳號未被停權 |

**不會被同步的人**：沒團隊又沒付費（免費帳號）、團隊未解鎖且自己沒付費、已停權帳號。
同步之後才退訂／到期未續者，**已同步的舊月份仍留在本站**，只是往後不再被更新
（要清掉請管理員自行刪除該列）。

> **對應鍵是「登入 email」**：保顧+ 用 `auth.users.email` 匯出，本站再用它對應
> `agent_stats.user_id`。若同仁在團隊資料裡登記的是 A、但登入用的是 B，會以 B 為準。

---

## 一、本站要做的事（只做一次）

1. 開啟 **本站**的 Supabase 專案 **`dwesqvutdlvnmajxdcpn`** → **SQL Editor**。
   ⚠️ **不要**貼到「ShowAll 保顧+」的專案 `uditztyjqbpzxzgquiym`——兩個專案在 Dashboard 裡
   看起來幾乎一樣，這是實際發生過的失誤；貼錯會炸 `42P01 relation "public.profiles" does not exist`（見 Q8）。
2. 貼上 `supabase-schema-agent-stats.sql` 的**全部內容**，按 **Run**（應顯示 `Success. No rows returned`）。
   - 可重複執行（`create ... if not exists` / `create or replace` / `drop policy if exists`）。
   - 檔頭有 fail-fast 守衛：貼錯專案會直接顯示「貼錯專案：找不到 public.profiles」。
   - 前置條件：已執行過 `video-training/supabase-schema.sql`（提供 `public.profiles`、`private.is_admin()`）。
3. 到 **Settings → API** 抄下 **Project URL** 與 **service_role key**，交給保顧+ 設定環境變數（見下節）。

腳本會建立：

| 物件 | 用途 |
|------|------|
| `public.agent_stats` | 每人每月一筆實績計數（`unique(email, stat_month)`，重跑同步不會重複累加） |
| RLS 政策 | 本人只能讀自己的列；管理員（`private.is_admin()`）可讀全部；**沒有任何寫入政策** |
| `public.ingest_agent_stats(jsonb)` | **只給 service_role** 的寫入函式（upsert，並由 email 解析 `user_id`） |

### 資料表結構

```
public.agent_stats
  id            uuid  pk        default gen_random_uuid()
  stat_month    date  not null  該月 1 號（check 限制）
  user_id       uuid            → auth.users(id)，由 email 對應；對不到為 null
  email         text  not null  跨系統對應鍵（一律存小寫）
  display_name  text
  new_client / first_visit / follow_up / claim / service / discuss_case / signed / recruit
                integer not null default 0    ← 保顧+ 記事八分類的「筆數」
  total         integer not null default 0    ← 該月記事總筆數
  clients_count integer not null default 0    ← 名下客戶總數（不分月份的現況值）
  source        text  not null default 'baogu'
  synced_at     timestamptz not null default now()
  unique (email, stat_month)
```

> 本站畫面只取其中五項：新客戶、約訪聯繫（`first_visit`）、複訪、遞送建議書（`discuss_case`）、簽約。
> 「接觸」＝ 新客戶 ＋ 複訪（對應 `goal-system.html` 每週行動計畫的「接觸 ×5」）。

---

## 二、保顧+ 要做的事（只做一次）

### 1. 執行 migration

在保顧+ 的 Supabase 專案（**`uditztyjqbpzxzgquiym`**，⚠️ 不是本站的 `dwesqvutdlvnmajxdcpn`）
→ SQL Editor，貼上 `supabase/migrations/0057_agent_stats_export.sql` 執行。

> 這支函式**只授權給 `service_role`**（`revoke ... from public, anon, authenticated`），
> 一般會員或前端即使知道函式名稱也呼叫不到（403）。

### 2. 設定環境變數（Vercel → Project → Settings → Environment Variables）

| 變數 | 來源 | 說明 |
|------|------|------|
| `CRON_SECRET` | 自己產生一組隨機字串 | 若已為 `team-maintenance` 設過，沿用同一組即可 |
| `SUPABASE_SERVICE_ROLE_KEY` | 保顧+ 自己的 service_role key | **這次新增**（保顧+ 原本沒用到 service role，只有 anon key） |
| `AGENT_STATS_SUPABASE_URL` | 本站 Supabase 的 Project URL | `https://dwesqvutdlvnmajxdcpn.supabase.co` |
| `AGENT_STATS_SUPABASE_SERVICE_ROLE_KEY` | 本站 Supabase 的 **service_role** key | 只存在伺服端，**絕不可**出現在任何前端檔案（不要加 `NEXT_PUBLIC_` 前綴） |

> 本機要測 cron 時，把這四行寫進保顧+ 的 `.env.local` 即可（該檔已在 `.gitignore`）。

> ⚠️ 四把都要放在**伺服端環境變數**（Vercel → Settings → Environment Variables，或本機 `.env.local`）。
> 未設定時，API 會回 `503 sync not configured`／`503 cron not configured`，**不影響保顧+ 其他功能**。

> ⚠️ **改完環境變數一定要按 Redeploy**（Vercel → Deployments → 最新一筆 → ⋯ → Redeploy）。
> 環境變數只對「之後」的部署生效，漏了這步線上仍會回 `503 sync not configured`。

> `CRON_SECRET` 若先前已為 `/api/cron/team-maintenance` 設過就沿用（兩支 cron 共用同一把）。
> 2026-10-10 線上實測 `https://tool.showall.tw/api/cron/sync-agent-stats` 已回
> `401 {"ok":false,"error":"unauthorized"}`，代表該把已設定、且線上部署已含這支 route
> （route 的順序是：secret 為空 → `503`；標頭不符 → `401`）。

設好四把之後，可以先這樣自我診斷（帶對 secret 打一次）：

```powershell
# 200 {"ok":true,...} → 四把都好了，剩下只差排程
# 503 sync not configured → 另外三把沒設好，或設了但沒 Redeploy
# 500 ... Could not find the function ... → 四把都好了，但對應那支 SQL 還沒跑
curl.exe -i -H "x-cron-secret: <你的 CRON_SECRET>" "https://tool.showall.tw/api/cron/sync-agent-stats?months=2"
```

### 3. 設定排程（每天 3 次：台北 07:30／12:30／17:30）

保顧+ 沒有 `vercel.json`，cron 一律靠**外部觸發**帶標頭打
`https://tool.showall.tw/api/cron/sync-agent-stats?months=6`（本專案現行做法＝**不必改程式**）。
下面兩個免費做法**擇一即可**；端點是冪等 upsert，兩個都開也只是多打幾次，不會重複計算。

| | 做法 A：GitHub Actions（**預設**） | 做法 B：cron-job.org |
|---|---|---|
| 第三方服務 | **不需要** | 要帳號 ＋ API key |
| 準點 | GitHub 官方說明：尖峰（整點前後）可能延遲數分鐘 | 準點到分 |
| 失敗怎麼知道 | 自己看 Actions 頁，或開 GitHub 的失敗通知 | 可開 email 失敗通知 |
| 設定放哪 | 私有 repo `insurance-tools` 的 workflow（進版控、可 review） | cron-job.org Console |

#### 做法 A：GitHub Actions（不用第三方，預設）

- 檔案在**保顧+ 的 repo** `insurance-tools`：`.github/workflows/sync-agent-stats.yml`。
  repo 是私有的，所以 workflow 設定與執行紀錄都不公開。
- 執行紀錄（頁面右上角有 **Next run**，每個 run 的 **Summary** 有該次網址／HTTP 碼／回應 JSON）：
  <https://github.com/ns2148634/insurance-tools/actions/workflows/sync-agent-stats.yml>
- **為什麼放私有 repo**：公開 repo 的排程 workflow **閒置 60 天會被 GitHub 自動停用**
  （官方原文：In a public repository, scheduled workflows are automatically disabled when no repository
  activity has occurred in 60 days），私有 repo 不受此限。代價是私有 repo 的 Actions 會計分鐘數：
  一天 3 次 × 30 天＝90 次、每次不滿 1 分鐘以 1 分鐘計 ≈ **90 分鐘／月**，免費方案 2,000 分鐘／月很夠。
- **cron 一律 UTC**（GitHub 規定），要自己換算；且刻意排在 `:30`——整點是 GitHub 排程最壅塞的時段（官方建議避開）：

  | 台北 | UTC | 寫法 |
  |---|---|---|
  | 07:30 | 前一天 23:30 | `30 23 * * *` |
  | 12:30 | 04:30 | `30 4 * * *` |
  | 17:30 | 09:30 | `30 9 * * *` |

- 排程只會被**預設分支（`main`）**上的版本觸發：改時間＝改那三行 cron 再 push。
- 一次性設定（需先 `gh auth login`）：

  ```powershell
  # 1) 把 CRON_SECRET 放進 repo secret（值＝上一節那把；不會進指令歷史）
  $s = Read-Host '貼上 CRON_SECRET（不會顯示）' -AsSecureString
  [System.Net.NetworkCredential]::new('', $s).Password |
    gh secret set CRON_SECRET --repo ns2148634/insurance-tools
  gh secret list --repo ns2148634/insurance-tools      # 應看到 CRON_SECRET

  # 2) 手動測一次（months=2 只回溯兩個月，快又輕）
  gh workflow run sync-agent-stats.yml --repo ns2148634/insurance-tools -f months=2
  gh run watch --repo ns2148634/insurance-tools        # 綠勾＝成功
  ```

  或走網頁：repo → **Actions** → 左側「實績同步」→ **Run workflow**（可填 `months`）。
- 平時：`gh run list --repo ns2148634/insurance-tools` 看歷史；
  `gh workflow disable|enable sync-agent-stats.yml --repo ns2148634/insurance-tools` 臨時停／開。
- 每次執行的網址、HTTP 碼與回應 JSON 都會寫進該 run 的 **Summary**；
  失敗訊息會直接說明是哪一種（401 secret 不符／503 環境變數未生效／500 SQL 未執行）。
- **失敗通知要自己開**：GitHub → Settings → Notifications → Actions → 只通知失敗的 workflow；
  沒開就只能自己來看 Actions 頁。

#### 做法 B：cron-job.org（要準點到分再用）

以免費的 [cron-job.org](https://cron-job.org) 為例，**一個 job 就能設多個時間**，所以一天 3 次只要一筆 job：

| 欄位 | 填值 |
|------|------|
| Title | `保顧+ 實績同步` |
| URL | `https://tool.showall.tw/api/cron/sync-agent-stats?months=6` |
| Schedule | Every day → 加入 **3 個時間**：`07:30`、`12:30`、`17:30` |
| Timezone | `Asia/Taipei` ← 一定要手動改，預設是 UTC（忘了改，你設的 07:30 會變成台北 15:30） |
| Advanced → Headers | `x-cron-secret: <你的 CRON_SECRET>`（**只放 Header，不要放進 URL query**，URL 會被各層 log 記下來） |

1. 登入 cron-job.org → **Create cronjob** → 照上表填（時間欄可按 **＋** 逐個加入 07:30 / 12:30 / 17:30）→ 儲存。
2. 存檔後按 **TEST RUN**：回應應為 `{"ok":true,"months":6,"rows":N,"syncedAt":"…"}`。
3. 之後在該 job 的 **History** 可看每次執行的 HTTP 狀態；建議開啟 email 失敗通知（排程掛掉才不會無聲無息）。

**不想點 UI？用 API 一次建好**（cron-job.org → Settings → **API key**；官方文件 <https://docs.cron-job.org/rest-api.html>）：

```powershell
$key    = '<cron-job.org API key>'      # 等同帳密，建議加 IP 限制、用完撤銷
$secret = '<你的 CRON_SECRET>'

$body = @{
  job = @{
    title         = '保顧+ 實績同步'
    url           = 'https://tool.showall.tw/api/cron/sync-agent-stats?months=6'
    enabled       = $true
    saveResponses = $true
    requestMethod = 0                        # 0 = GET
    schedule      = @{
      timezone  = 'Asia/Taipei'
      expiresAt = 0                          # 0 = 永不過期
      hours     = @(7, 12, 17)               # ← 一天三次
      minutes   = @(30)                      # 搭配上面 = 07:30 / 12:30 / 17:30
      mdays     = @(-1)                      # -1 = 每天
      months    = @(-1)                      # -1 = 每月
      wdays     = @(-1)                      # -1 = 每週每一天
    }
    extendedData  = @{ headers = @{ 'x-cron-secret' = $secret } }
  }
} | ConvertTo-Json -Depth 6

# 建立：注意是 PUT /jobs（不是 POST），成功回 {"jobId":12345}
Invoke-RestMethod -Method Put -Uri 'https://api.cron-job.org/jobs' `
  -Headers @{ Authorization = "Bearer $key" } -ContentType 'application/json' -Body $body

# 驗證建出來的內容（schedule.hours 應為 [7,12,17]）
Invoke-RestMethod -Uri 'https://api.cron-job.org/jobs' -Headers @{ Authorization = "Bearer $key" } |
  Select-Object -ExpandProperty jobs |
  Select-Object jobId, title, enabled, @{ n = 'schedule'; e = { $_.schedule | ConvertTo-Json -Compress } }
```

> ⚠️ cron-job.org 的 API 預設每天 100 次請求配額（本用途一天 0~3 次，遠低於上限）；建立 job 的端點速率限制為 1 次/秒、5 次/分。
>
> 若手邊有 `C:\insurance-tools` 專案，也可直接跑 `scripts\setup-cronjob.ps1`：`-DryRun` 先預覽 payload（secret 會遮蔽），
> 不加 `-DryRun` 即建立並回讀驗證（API key 與 `CRON_SECRET` 用隱藏輸入詢問，不會進指令歷史）。
> 預設就是每天 3 次 07:30／12:30／17:30；改時間用 `-Hours 8,13,18 -Minutes 0`、改回溯月數用 `-Months 12`、更新既有 job 用 `-JobId <id>`。

#### 兩個做法共同的注意事項

- **為什麼一天 3 次？**「我的實績」是月度統計：早班、午休、收班各同步一次，白天記的行程最慢約 4~5 小時
  就會出現在本站（每天只跑 07:30 的話最壞要等近 24 小時）。
- `months` 預設 6、上限 24（回溯補齊歷史月份；每次都是 upsert，**重跑安全**，跑幾次都不會重複計算）。
- `rows` 是**所有月份加總的寫入列數**；`0` 代表那些月份沒有可匯出的記事（正常）。
- 想更即時（例如每小時）：做法 A 多加幾行 cron、做法 B 改排程即可，成本都極低。

> **為什麼不用 Vercel 內建的 Vercel Cron？**
> 1. **免費的 Hobby 方案「一天只能執行一次」**——排程寫成一天多次（如 `30 7,12,17 * * *`）**會在部署時就失敗**
>    （官方限制：Hobby＝Once per day；Pro 才支援 Once per minute）。要一天 3 次就得升級 Pro。
> 2. 就算升級，Vercel Cron 的請求只帶 `Authorization: Bearer $CRON_SECRET`、**不會**帶 `x-cron-secret`，
>    還得改 `app/api/cron/sync-agent-stats/route.ts` 並新增 `vercel.json`。
> 所以維持**外部觸發**（做法 A／B 都是打同一支端點）：**不必改程式、不必付費、時間要調隨時可調**。

---

## 三、驗證（建議照順序做）

1. **cron 未帶／帶錯 secret** → 應回 `401 unauthorized`：
   ```powershell
   curl.exe -i "https://tool.showall.tw/api/cron/sync-agent-stats"
   ```
2. **帶正確 secret** → 回 `{"ok":true,"months":6,"rows":N,...}`。若回 `503`＝環境變數沒設好或**沒 Redeploy**；
   若回 `500 ... Could not find the function ...`＝四把都好了，但對應那支 SQL（`export_agent_stats` 在保顧+、
   `ingest_agent_stats` 在本站）還沒執行。
   - **排程本身有沒有在跑**：`gh run list --repo ns2148634/insurance-tools --limit 5`（或 repo → Actions →
     「實績同步」）；每個 run 的 **Summary** 有該次網址、HTTP 碼與回應 JSON，失敗訊息會直接指出是哪一種（401／503／500）。
3. **同步範圍對不對**（保顧+ 的 Supabase SQL Editor）：跑一次匯出函式看名單——
   ```sql
   select * from public.export_agent_stats(
     date_trunc('month', now()) - interval '1 month',
     date_trunc('month', now())
   );
   ```
   - 應該看到**所有「團隊統計已解鎖」的團隊成員**，**加上所有個人付費者**（即使他沒團隊）。
   - 想確認個人付費者一個都沒漏，用 `0057_agent_stats_export.sql` 檔尾那段 `except` 查詢比對（應為 0 列）。
4. **本站資料表**（Supabase SQL Editor）：
   ```sql
   select stat_month, email, user_id, total, signed, synced_at
   from public.agent_stats order by stat_month desc, email;
   ```
   - `user_id` 應有你自己的帳號；若為 `null` 就是 email 對不上（見 Q2）。
5. **前端**：登入後開 `goal-system.html` → 選本月 → 「三、我的實績」應顯示數字與「資料更新：…」。
   切到沒有資料的月份應顯示「本月尚無保顧+ 實績資料」，而不是錯誤訊息。
6. **與保顧+ 對帳**：在保顧+ 的 `/stats/team` 看同一月份、同一位成員的計數是否一致。
   本站採半開區間 `[該月1號, 次月1號)` 切月；與保顧+ 舊版 RPC 的「含頭含尾」在**月初／月底邊界**可能差 1 筆。
7. **權限回歸**：
   - 未登入（anon）讀 `agent_stats` → 0 列。
   - 一般同仁讀 `agent_stats` → 只會拿到自己那一列。
   - 用一般登入身分呼叫 `ingest_agent_stats` → `42501`（只有 service_role 能寫）。
   - 用一般登入身分呼叫保顧+ 的 `export_agent_stats` → `permission denied`。
8. **目標模組回歸**：`goal-system.html` 的「一、我的目標」「二、每週行動計畫」「整個通訊處加總」
   與 `index.html` 的「本月目標」都應照常運作（本次未動 `goal_targets` 與 `get_unit_goal_totals`）。

---

## 四、常見問題

**Q1. 「讀取保顧+ 實績失敗：…」**
→ `supabase-schema-agent-stats.sql` 還沒執行，或 PostgREST schema 快取未更新。執行後重新整理：

```sql
notify pgrst, 'reload schema';
```

**Q2. 一直顯示「本月尚無保顧+ 實績資料」，但我在保顧+ 明明有記錄**
可能原因（依機率排序）：
1. **兩邊 Email 不同**：保顧+ 用 A、本站用 B → `agent_stats.user_id` 為 `null`，你讀不到自己的列。
   請以相同 Email 登入兩邊（或請管理員調整帳號）。
2. **你既沒團隊、也沒付費**：保顧+ 只匯出「團隊成員（團隊統計已解鎖）」與「個人付費者」兩類
   （條件見「誰會被同步」）。免費帳號、或團隊 `stats_status` 未解鎖而自己又沒付費，都不會被同步。
3. **排程還沒跑**：手動觸發一次即可——
   `gh workflow run sync-agent-stats.yml --repo ns2148634/insurance-tools -f months=2`（詳見「二、3」）。
4. 保顧+ 沒有行事曆——實績來源是**客戶記事的分類**。沒有記任何記事的那個月就是 0 筆。

**Q3. 為什麼只有筆數，沒有客戶清單？**
→ 本站是純靜態網站、沒有後端，任何資料放上來都是公開可讀的靜態檔風險；
   因此跨系統只傳「計數」，客戶與記事內容留在保顧+。

**Q4. 達成率顯示「—」或「0%」**
→ 「—」代表該月**目標為 0**（無法算比率）；「0%」代表有目標但實績為 0。
   目標欄數字跟著「二、每週行動計畫」的件數即時變動（接觸 ×5、面談 ×3、約訪 ×10）。

**Q5. 可以看同仁的實績嗎？**
→ 不行（除非你是管理員）。前端只查 `user_id = 自己`，資料庫 RLS 也只放行自己那一列；
   管理員帳號（`profiles.is_admin = true`）則可讀全部（方便核對同步是否正常）。

**Q6. 重跑 cron 會不會把數字加兩倍？**
→ 不會。`agent_stats` 以 `unique(email, stat_month)` 為鍵做 upsert，重跑只會覆蓋成最新值。

**Q7. 一天要跑幾次？誰在跑？**
→ **目前設定一天 3 次**（台北 07:30／12:30／17:30），由 **GitHub Actions** 排程觸發
   （`insurance-tools` 的 `.github/workflows/sync-agent-stats.yml`，UTC `30 23`／`30 4`／`30 9`）。
   實績是月累計、不是即時看板，不需要每分鐘同步；3 次已讓白天記的行程最慢 4~5 小時內出現在本站。
   GitHub 的排程偶爾會延遲幾分鐘；想「準點到分」或不想用 GitHub，改用 cron-job.org（見「二、3」做法 B）即可——
   端點是冪等 upsert，兩個都開只是多打幾次、不會重複計算。想更即時（例如每小時）就多加幾行 cron，成本仍極低。

**Q8. 在 SQL Editor 執行 `supabase-schema-agent-stats.sql` 時出現
`42P01 relation "public.profiles" does not exist`**
→ **幾乎一定是貼錯專案。** 這份檔只能貼在**本站**專案 `dwesqvutdlvnmajxdcpn`；
「ShowAll 保顧+」是另一個專案 `uditztyjqbpzxzgquiym`，那裡**沒有** `profiles`／`agent_stats`
（保顧+ 要貼的是 `0057_agent_stats_export.sql`，兩份不要互換）。
現行版本在檔頭加了 fail-fast 守衛，貼錯時會直接顯示「貼錯專案：找不到 public.profiles」。
Supabase SQL Editor 整段是單一交易，失敗會全段回滾、不會留下半成品，換到正確專案重貼即可。
若確定在正確專案卻仍報這個錯 → 先執行 `video-training/supabase-schema.sql`（`public.profiles` 由它建立）。

**Q9. 我沒加入任何團隊、只自己買專業會員，會被同步嗎？**
→ 會（2026-10-10 起）。保顧+ 的匯出函式把「個人付費者」與「團隊成員」並列為母體，
只要自己的訂閱是 `pro`／`team` 且 `status = 'active'` 就會被同步，不需要團隊。
反之，之後退訂或到期未續（`status` 不再是 `active`）就不會再被更新——
但**已同步的舊月份仍留在本站**（要清掉請管理員刪除該列）。
