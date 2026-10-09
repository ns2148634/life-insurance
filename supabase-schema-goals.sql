-- =========================================================
-- 一定要宸功專區 — Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn（與 video-training / sharing 共用同一個專案）
--
-- 前置條件：請先執行過 video-training/supabase-schema.sql
--   （本檔沿用其中的 auth.users / public.profiles / private schema，
--     以及 private.is_admin() 這個 security definer 函式）
--
-- 本檔只新增一張表：public.goal_targets + 索引 + trigger + RLS，
-- 以及一個「只回傳加總」的函式 public.get_unit_goal_totals()。
-- =========================================================

-- =========================================================
-- 0. 前置：確保 private schema 與 is_admin() 存在
--    （正常情況 video-training/supabase-schema.sql 已經建好，這裡只是保險）
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

-- =========================================================
-- 1. goal_targets：每位業務員「每月」的目標
--    period_month 一律存「該月 1 號」（前端也這樣送），
--    並以 unique(user_id, period_month) 保證一人一月只有一筆。
-- =========================================================
create table if not exists public.goal_targets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  period_month date not null,
  fyc_target numeric(12,0) not null default 0,
  premium_target numeric(12,0) not null default 0,
  case_target integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint goal_targets_fyc_nonneg check (fyc_target >= 0),
  constraint goal_targets_premium_nonneg check (premium_target >= 0),
  constraint goal_targets_case_nonneg check (case_target >= 0),
  -- 只接受每月 1 號，避免同月不同日造成重複紀錄
  constraint goal_targets_month_first check (extract(day from period_month) = 1),
  constraint goal_targets_user_month_uniq unique (user_id, period_month)
);

create index if not exists goal_targets_month_idx on public.goal_targets (period_month);

-- =========================================================
-- 2. updated_at 自動維護
-- =========================================================
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

drop trigger if exists trg_goal_targets_updated on public.goal_targets;
create trigger trg_goal_targets_updated
  before update on public.goal_targets
  for each row execute procedure private.set_updated_at();

-- =========================================================
-- 3. Row Level Security
-- =========================================================
alter table public.goal_targets enable row level security;

-- anon 不該碰到這張表
revoke all on public.goal_targets from anon;
grant select, insert, update, delete on public.goal_targets to authenticated;

-- ---- 讀：自己的 -------------------------------------------------------
drop policy if exists "read own goal" on public.goal_targets;
create policy "read own goal" on public.goal_targets
  for select to authenticated
  using ( (select auth.uid()) = user_id );

-- ---- 讀：管理員可看全部（列表用）-------------------------------------
drop policy if exists "admin read goals" on public.goal_targets;
create policy "admin read goals" on public.goal_targets
  for select to authenticated
  using ( (select private.is_admin()) );

-- ---- 新增：只能以自己的身分 -------------------------------------------
drop policy if exists "insert own goal" on public.goal_targets;
create policy "insert own goal" on public.goal_targets
  for insert to authenticated
  with check ( (select auth.uid()) = user_id );

-- ---- 改：只能改自己的，且不能改 user_id -------------------------------
drop policy if exists "update own goal" on public.goal_targets;
create policy "update own goal" on public.goal_targets
  for update to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

-- ---- 刪：只能刪自己的 -------------------------------------------------
drop policy if exists "delete own goal" on public.goal_targets;
create policy "delete own goal" on public.goal_targets
  for delete to authenticated
  using ( (select auth.uid()) = user_id );

-- =========================================================
-- 4. 整個通訊處的「加總」
--    問題：RLS 讓一般同仁看不到別人的目標，但首頁要顯示「通訊處總目標」。
--    解法：用 security definer 函式代查，只回傳「加總數字」，不揭露個人明細。
--    前端：index.html / goal-system.html 以
--          sb.rpc('get_unit_goal_totals', { p_month: '2026-10-01' }) 呼叫。
--    （目前系統沒有「單位」欄位，因此「整個通訊處」＝全體同仁加總。）
-- =========================================================
create or replace function public.get_unit_goal_totals(p_month date)
returns table (fyc numeric, premium numeric, cases integer, members integer)
language sql
security definer
set search_path = ''
stable
as $$
  select
    coalesce(sum(g.fyc_target), 0)     as fyc,
    coalesce(sum(g.premium_target), 0) as premium,
    coalesce(sum(g.case_target), 0)::integer as cases,
    count(*)::integer                  as members
  from public.goal_targets g
  where g.period_month = date_trunc('month', p_month)::date
    and (select auth.uid()) is not null;
$$;

revoke all on function public.get_unit_goal_totals(date) from public, anon;
grant execute on function public.get_unit_goal_totals(date) to authenticated;

-- =========================================================
-- 5. 讓 PostgREST 立即認得新表 / 新欄位（避免 schema cache 找不到）
-- =========================================================
notify pgrst, 'reload schema';

-- =========================================================
-- 事後手動操作提醒：
-- 1. 本模組沿用 video-training 的帳號，不需要另外建立使用者。
-- 2. 測試資料（可選）：
--      insert into public.goal_targets (user_id, period_month, fyc_target, premium_target, case_target)
--      values ('<你的 user id>', date_trunc('month', now())::date, 60000, 300000, 4)
--      on conflict (user_id, period_month) do update
--        set fyc_target = excluded.fyc_target,
--            premium_target = excluded.premium_target,
--            case_target = excluded.case_target;
-- 3. 若畫面顯示「找不到資料表 goal_targets」：
--      在 SQL Editor 執行  notify pgrst, 'reload schema';  再重新整理。
-- 4. 驗證通訊處加總（可在 SQL Editor 直接呼叫）：
--      select * from public.get_unit_goal_totals(date_trunc('month', now())::date);
-- =========================================================
