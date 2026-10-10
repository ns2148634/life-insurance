-- =========================================================
-- 宸功出擊90天 — 進度儲存 Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn（與 video-training / sharing / goal-system 共用同一個專案）
--
-- 前置條件：請先執行過 video-training/supabase-schema.sql
--   （本檔沿用其中的 auth.users / public.profiles / private schema，
--     以及 private.is_admin()、private.set_updated_at() 這些 security definer 函式）
--
-- 本檔只新增一張表：public.cg90_progress + trigger + RLS。
-- 用途：把 90day.html 的個人進度（目標設定、週次打勾、模組打勾）
--       從 Firebase RTDB 搬過來，改由「登入者 uid + RLS」保護。
-- 前端：90day.html 以
--         sb.from('cg90_progress').select('state, saved_at').eq('user_id', uid)
--         sb.from('cg90_progress').upsert({ user_id, state, saved_at }, { onConflict: 'user_id' })
--       讀寫自己那一份。
-- =========================================================

-- =========================================================
-- 0. 前置：確保 private schema 與 is_admin() / set_updated_at() 存在
--    （正常情況 video-training/supabase-schema.sql 已建好，這裡只是保險）
-- =========================================================
create schema if not exists private;

create or replace function private.is_admin()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select coalesce(
    (select p.is_admin from public.profiles p where p.id = (select auth.uid())),
    false
  );
$$;

revoke execute on function private.is_admin() from public;
grant usage on schema private to authenticated;
grant execute on function private.is_admin() to authenticated;

create or replace function private.set_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke execute on function private.set_updated_at() from public, anon;
grant execute on function private.set_updated_at() to authenticated, service_role;

-- =========================================================
-- 1. cg90_progress：每位業務員「一份」90 天進度
--    user_id 直接當主鍵，一人一筆（前端 upsert + onConflict 覆蓋）。
--    state 原樣存前端那份 JSON：
--      { goals:[{income,count}...], weeks:{'1-1':true...}, modules:{'cat-item':true...} }
--    saved_at 是前端 Date.now()，用來和本機 mirror 比新舊。
-- =========================================================
create table if not exists public.cg90_progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  saved_at bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cg90_progress_saved_at_nonneg check (saved_at >= 0)
);

-- =========================================================
-- 2. updated_at 自動維護
-- =========================================================
drop trigger if exists trg_cg90_progress_updated on public.cg90_progress;
create trigger trg_cg90_progress_updated
  before update on public.cg90_progress
  for each row execute procedure private.set_updated_at();

-- =========================================================
-- 3. Row Level Security
-- =========================================================
alter table public.cg90_progress enable row level security;

-- anon 不該碰到這張表
revoke all on public.cg90_progress from anon;
grant select, insert, update, delete on public.cg90_progress to authenticated;

-- ---- 讀：自己的 -------------------------------------------------------
drop policy if exists "read own cg90 progress" on public.cg90_progress;
create policy "read own cg90 progress" on public.cg90_progress
  for select to authenticated
  using ( (select auth.uid()) = user_id );

-- ---- 讀：管理員可看全部（主管檢視新人進度用）-------------------------
drop policy if exists "admin read cg90 progress" on public.cg90_progress;
create policy "admin read cg90 progress" on public.cg90_progress
  for select to authenticated
  using ( (select private.is_admin()) );

-- ---- 新增：只能以自己的身分 -------------------------------------------
drop policy if exists "insert own cg90 progress" on public.cg90_progress;
create policy "insert own cg90 progress" on public.cg90_progress
  for insert to authenticated
  with check ( (select auth.uid()) = user_id );

-- ---- 改：只能改自己的，且不能改 user_id -------------------------------
drop policy if exists "update own cg90 progress" on public.cg90_progress;
create policy "update own cg90 progress" on public.cg90_progress
  for update to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

-- ---- 刪：只能刪自己的 -------------------------------------------------
drop policy if exists "delete own cg90 progress" on public.cg90_progress;
create policy "delete own cg90 progress" on public.cg90_progress
  for delete to authenticated
  using ( (select auth.uid()) = user_id );

-- =========================================================
-- 4. Realtime（讓同一帳號的「其他裝置」即時收到較新版本）
--    90day.html 用 sb.channel().on('postgres_changes', ...) 訂閱；
--    沒訂閱到也不會壞，只是退回「載入時比對 saved_at」。
-- =========================================================
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'cg90_progress'
  ) then
    alter publication supabase_realtime add table public.cg90_progress;
  end if;
end $$;

-- =========================================================
-- 5. 讓 PostgREST 立即認得新表（避免 schema cache 找不到）
-- =========================================================
notify pgrst, 'reload schema';

-- =========================================================
-- 事後手動操作提醒：
-- 1. 本模組沿用 video-training 的帳號，不需要另外建立使用者。
-- 2. 舊 Firebase 資料（cg90/users、cg90/students）若已匯出成 JSON，
--    可改用下方 SQL 匯入（uid 為鍵）：
--      insert into public.cg90_progress (user_id, state, saved_at)
--      values ('<user id>'::uuid, '<progress JSON>'::jsonb, <savedAt>)
--      on conflict (user_id) do update
--        set state    = excluded.state,
--            saved_at = excluded.saved_at;
-- 3. 若畫面顯示「找不到資料表 cg90_progress」：
--      在 SQL Editor 執行  notify pgrst, 'reload schema';  再重新整理。
-- 4. 驗證（可在 SQL Editor 直接呼叫，會以目前登入者身分套用 RLS）：
--      select user_id, saved_at, updated_at from public.cg90_progress;
-- =========================================================
