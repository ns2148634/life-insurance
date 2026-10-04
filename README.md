# life-insurance

宸功保險的業務工具總覽：純靜態網站（無建置流程），部署於 GitHub Pages 的專案子路徑 `/life-insurance/`。

- `index.html` 工具總覽首頁（含登入區塊）
- `insurance-needs.html`／`career-system.html`／`income-system.html`／`manager-income.html`／`promotion-system.html`／`90day.html` 各項諮詢與訓練工具
- `accounts.html` 帳號管理（限管理員）
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
