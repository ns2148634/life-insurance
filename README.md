# life-insurance

宸功保險的業務工具總覽：純靜態網站（無建置流程），部署於 GitHub Pages 的專案子路徑 `/life-insurance/`。

- `index.html` 工具總覽首頁（含登入區塊；分類依序為客戶顧問、制度、目標管理、訓練）
- `login.html` 全站登入頁（**所有頁面都需登入**）＋ `auth-guard.js` 登入守衛
- `insurance-needs.html`／`career-system.html`／`income-system.html`／`manager-income.html`／`promotion-system.html`／`90day.html` 各項諮詢與訓練工具
  - `insurance-needs.html`（人生收支曲線圖）第 3 頁可把客戶姓名、月收入、風險順序與保障內容「儲存客戶資料」，每次儲存都是新的一筆（保留歷程），存在 Supabase `public.insurance_plans`（RLS 只限本人；不含生日、性別等個資）；儲存後可在「人生圖資料」搜尋與回看
- `client-plans.html` 人生圖資料（業務同仁登入後，搜尋自己儲存的客戶人生圖規劃：第 2 頁的風險優先順序、各項保障建議與月收入；可依姓名／風險／保障項目／金額關鍵字與期間篩選，展開查看每次規劃快照；RLS 只讀本人，管理員可讀全部）
  - 相關 SQL：`supabase-schema-insurance-plans.sql`（**第一次使用「儲存客戶資料」前需先執行**）
- `estate-planning.html` 資產傳承三步驟（法定繼承人分配與特留分試算（兄弟姊妹特留分依 116/2/17 施行日自動切換：施行前為應繼分 1/3、施行後為 0，註記文字同步更新）、遺產稅＋每戶 3,740 萬死亡給付額度的最低稅負試算（額度依繼承人數計算）、保險稅務三題確認與健康度、諮詢摘要列印；元件在 `components/`：`inheritance-steps.js`、`heir-allocator.js`、`tax-calculator.js`）
- `90day.html`（宸功出擊90天）的個人進度（目標設定、週次與模組打勾）跟著登入帳號存在 Supabase `public.cg90_progress`（一人一筆，RLS 保護），並在本機留一份 mirror
  - 相關 SQL：`supabase-schema-90day-progress.sql`（**第一次使用前需先在 SQL Editor 執行**）
- `goal-system.html` 一定要宸功專區（分「個人專區」、「通訊處專區」、「通訊處排行」與「歷史資料」：個人區設定每月目標 FYC／保費／件數 → 自動換算每週行動量，並對照個人實績；另有年度目標與「12 個月目標一覽」，可把年度值平均帶入空白月份；通訊處區彙整全體同仁的目標總額與合計實績，只顯示合計、不列個人明細；排行區列出各項實績指標的前 10 名與數值；歷史資料區可回查月／季／年的個人目標與實績、通訊處合計與排行歷史（含「我的名次」））
  - 相關 SQL：`supabase-schema-goals.sql`（目標）、`supabase-schema-goal-annual.sql`（年度目標）、`supabase-schema-agent-stats.sql`（個人實績）、`supabase-schema-unit-stats.sql`（通訊處合計實績）、`supabase-schema-unit-ranking.sql`（通訊處排行）、`supabase-schema-history.sql`（歷史資料的期間彙總＋排行歷史）
- `members.html` 宸功人士（分「組織圖」與「我的檔案」：組織圖是傳統組織樹，以最高職級 `AM`（處經理）為根節點、依「所屬主管」往下分支、節點顏色代表職級並可收合，點任一節點會開啟該同仁的個人網頁與年度心願時間軸；「我的檔案」預設也是個人網頁檢視（左側直式大照片、右側姓名／職級／主管／夥伴／簡介／社群連結，手機版上下排列；上方漸層僅為裝飾帶、不覆蓋照片與姓名），按「編輯我的檔案」可改姓名、照片、簡介、社群連結、職級與所屬主管（最高職級 `AM` 保留給管理員），並用「年度心願」按年／月寫下多項想完成的事，下方即時顯示個人時間軸。組織圖與心願都走 `security definer` RPC，只回顯示欄位、不含 email 與 `is_admin`）
  - 相關 SQL：`supabase-schema-members.sql`（職級、成員資料、組織圖防迴圈、頭像 bucket）、`supabase-schema-member-wishes.sql`（年度心願）、`supabase-schema-goal-annual.sql`（年度目標）。設定與驗證見 `members-SETUP.md`
- `accounts.html` 帳號管理（限管理員；可改姓名、設定職級與所屬主管、代為重設密碼）
- `video-training/` 影片研習系統（Supabase 登入／觀看進度）
- `sharing/` 業務分享專區（Supabase）
- `libs/` 前端套件（html2pdf）
- `sw.js`／`manifest.json` 　PWA（Service Worker、加入主畫面）

## 本機測試

```powershell
npm run dev
```

然後開啟 <http://localhost:5500/life-insurance/>（路徑與正式站一致）。

詳細說明、注意事項與常見問題請見 **[DEV.md](./DEV.md)**。
