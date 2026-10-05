// 全站共用的 Supabase 設定（首頁 index.html 與 accounts.html 使用）
// 與 video-training/config.js、sharing/config.js 為同一個專案
// 到 Supabase 專案 Settings > API 可以重新複製
// 注意：本檔可能被載入不只一次（例如頁面自己載入，auth-guard.js 也載入），
// 因此改用「已宣告就略過」的寫法，避免 const 重複宣告造成 SyntaxError。
if (typeof SUPABASE_URL === "undefined") {
  var SUPABASE_URL = "https://dwesqvutdlvnmajxdcpn.supabase.co";
}
if (typeof SUPABASE_ANON_KEY === "undefined") {
  var SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImR3ZXNxdnV0ZGx2bm1hanhkY3BuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk1NjE5NjgsImV4cCI6MjEwNTEzNzk2OH0.naeca3crJDsC-Stsj7wBVtX2849V2-Frhzjt1z8eXvk";
}
