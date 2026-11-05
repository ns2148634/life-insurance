-- =========================================================
-- 年度目標 + 團隊目標牆 — Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn
--
-- 前置條件（請先依序執行）：
--   1. video-training/supabase-schema.sql（auth.users / public.profiles）
--   2. supabase-schema-goals.sql（public.goal_targets）
--   3. supabase-schema-agent-stats.sql（public.agent_stats）
--   4. supabase-schema-members.sql（member_profiles / member_ranks）
--
-- 本檔建立：
--   public.goal_annual_targets     每人每年的年度目標（FYC／保費／件數）
--   public.get_goal_board(date)    團隊目標牆用（security definer，只回顯示欄位）
--
-- 隱私設計：
--   年度目標「公開在團隊目標牆」是刻意需求，但**不是**把 RLS 放寬，
--   而是由 security definer 的 get_goal_board() 只回傳
--   「姓名／職級／目標／簽約筆數」等顯示欄位，不含 email、is_admin。
--   資料表本身仍維持「本人可讀寫、管理員可讀全部」。
--
-- 實績來源說明：
--   目前只有「簽約筆數」有真實資料（agent_stats.signed）；
--   FYC 與保費沒有實際達成值，畫面必須標示為「目標值」。
-- =========================================================

-- =========================================================
-- 0. 前置檢查
-- =========================================================
do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception '缺少 public.profiles：請先執行 video-training/supabase-schema.sql';
  end if;
  if to_regclass('public.goal_targets') is null then
    raise exception '缺少 public.goal_targets：請先執行 supabase-schema-goals.sql';
  end if;
  if to_regclass('public.agent_stats') is null then
    raise exception '缺少 public.agent_stats：請先執行 supabase-schema-agent-stats.sql';
  end if;
  if to_regclass('public.member_profiles') is null then
    raise exception '缺少 public.member_profiles：請先執行 supabase-schema-members.sql';
  end if;
  if to_regclass('public.member_ranks') is null then
    raise exception '缺少 public.member_ranks：請先執行 supabase-schema-members.sql';
  end if;
end
$$;

create schema if not exists private;

-- updated_at 共用函式（若 goals 檔已建立則 replace）
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
-- 1. goal_annual_targets：每人每年的年度目標
--    與 goal_targets（每月）並存：
--      - 年度目標是「整年規劃」
--      - 每月目標仍是當月執行值
--    前端「平均帶入 12 個月」只是把年度值 ÷ 12 寫進空白月份，
--    不會自動覆蓋已設定的月份。
-- =========================================================
create table if not exists public.goal_annual_targets (
  user_id         uuid not null references auth.users(id) on delete cascade,
  target_year     integer not null,
  fyc_target      numeric(12,0) not null default 0,
  premium_target  numeric(12,0) not null default 0,
  case_target     integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  primary key (user_id, target_year),
  constraint goal_annual_targets_year_range check (target_year between 2000 and 2100),
  constraint goal_annual_targets_fyc_nonneg check (fyc_target >= 0),
  constraint goal_annual_targets_premium_nonneg check (premium_target >= 0),
  constraint goal_annual_targets_case_nonneg check (case_target >= 0)
);

create index if not exists goal_annual_targets_year_idx
  on public.goal_annual_targets (target_year);

drop trigger if exists trg_goal_annual_targets_updated on public.goal_annual_targets;
create trigger trg_goal_annual_targets_updated
  before update on public.goal_annual_targets
  for each row execute procedure private.set_updated_at();

-- =========================================================
-- 2. Row Level Security
-- =========================================================
alter table public.goal_annual_targets enable row level security;
revoke all on public.goal_annual_targets from anon;
grant select, insert, update, delete on public.goal_annual_targets to authenticated;

drop policy if exists "read own annual goal" on public.goal_annual_targets;
create policy "read own annual goal" on public.goal_annual_targets
  for select to authenticated
  using ( (select auth.uid()) = user_id );

drop policy if exists "admin read annual goals" on public.goal_annual_targets;
create policy "admin read annual goals" on public.goal_annual_targets
  for select to authenticated
  using ( (select private.is_admin()) );

drop policy if exists "insert own annual goal" on public.goal_annual_targets;
create policy "insert own annual goal" on public.goal_annual_targets
  for insert to authenticated
  with check ( (select auth.uid()) = user_id );

drop policy if exists "update own annual goal" on public.goal_annual_targets;
create policy "update own annual goal" on public.goal_annual_targets
  for update to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

drop policy if exists "delete own annual goal" on public.goal_annual_targets;
create policy "delete own annual goal" on public.goal_annual_targets
  for delete to authenticated
  using ( (select auth.uid()) = user_id );

drop policy if exists "admin update annual goals" on public.goal_annual_targets;
create policy "admin update annual goals" on public.goal_annual_targets
  for update to authenticated
  using ( (select private.is_admin()) )
  with check ( (select private.is_admin()) );

drop policy if exists "admin delete annual goals" on public.goal_annual_targets;
create policy "admin delete annual goals" on public.goal_annual_targets
  for delete to authenticated
  using ( (select private.is_admin()) );

-- =========================================================
-- 3. get_goal_board()：團隊目標牆的資料來源
--    ※ 目前前端已不再呼叫（members.html 改成組織圖＋年度心願）。
--      函式保留給舊連結／臨時查詢使用；若確定不需要，可整段刪除。
--    - 回傳「每位成員」一列：職級、當月目標、年度目標、本月簽約、YTD 簽約。
--    - 只有登入者能呼叫（anon 收回執行權限）。
--    - 不含 email、is_admin、客戶資料。
--    - p_month 省略時以當月為準；內部一律取當月 1 號。
-- =========================================================
drop function if exists public.get_goal_board(date);

create or replace function public.get_goal_board(p_month date default null)
returns table (
  user_id              uuid,
  display_name         text,
  rank_code            text,
  rank_label           text,
  rank_order           integer,
  supervisor_id        uuid,
  avatar_path          text,
  avatar_updated_at    timestamptz,
  month_target_fyc     numeric,
  month_target_premium numeric,
  month_target_cases   integer,
  annual_fyc           numeric,
  annual_premium       numeric,
  annual_cases         integer,
  has_month_goal       boolean,
  has_annual_goal      boolean,
  signed_cases         integer,
  ytd_signed           integer,
  synced_at            timestamptz
)
language sql
security definer
set search_path = ''
stable
as $$
  with bounds as (
    select date_trunc('month', coalesce(p_month, current_date))::date as m,
           date_trunc('year',  coalesce(p_month, current_date))::date as y0,
           extract(year from coalesce(p_month, current_date))::integer as y
  ),
  monthly as (
    select g.user_id, g.fyc_target, g.premium_target, g.case_target
      from public.goal_targets g, bounds b
     where g.period_month = b.m
  ),
  annual as (
    select a.user_id, a.fyc_target, a.premium_target, a.case_target
      from public.goal_annual_targets a, bounds b
     where a.target_year = b.y
  ),
  perf as (
    select s.user_id,
           coalesce(sum(s.signed) filter (where s.stat_month = b.m), 0)::integer as signed_cases,
           coalesce(sum(s.signed) filter (where s.stat_month between b.y0 and b.m), 0)::integer as ytd_signed,
           max(s.synced_at) as synced_at
      from public.agent_stats s, bounds b
     where s.stat_month between b.y0 and b.m
     group by s.user_id
  )
  select
    mp.user_id,
    coalesce(nullif(btrim(p.full_name), ''), '未具名同仁') as display_name,
    mp.rank_code,
    coalesce(r.label, mp.rank_code)                        as rank_label,
    coalesce(r.sort_order, 0)                              as rank_order,
    mp.supervisor_id,
    mp.avatar_path,
    mp.avatar_updated_at,
    coalesce(mo.fyc_target, 0)                             as month_target_fyc,
    coalesce(mo.premium_target, 0)                         as month_target_premium,
    coalesce(mo.case_target, 0)::integer                   as month_target_cases,
    coalesce(an.fyc_target, 0)                             as annual_fyc,
    coalesce(an.premium_target, 0)                         as annual_premium,
    coalesce(an.case_target, 0)::integer                   as annual_cases,
    (mo.user_id is not null)                               as has_month_goal,
    (an.user_id is not null)                               as has_annual_goal,
    coalesce(pf.signed_cases, 0)                           as signed_cases,
    coalesce(pf.ytd_signed, 0)                             as ytd_signed,
    pf.synced_at
  from public.member_profiles mp
  join public.profiles p on p.id = mp.user_id
  left join public.member_ranks r on r.code = mp.rank_code
  left join monthly mo on mo.user_id = mp.user_id
  left join annual an on an.user_id = mp.user_id
  left join perf pf on pf.user_id = mp.user_id
  where (select auth.uid()) is not null
  order by coalesce(r.sort_order, 0), coalesce(p.full_name, ''), mp.user_id;
$$;

revoke all on function public.get_goal_board(date) from public, anon;
grant execute on function public.get_goal_board(date) to authenticated;

-- 讓 PostgREST 立即認得新表與新函式
notify pgrst, 'reload schema';

-- =========================================================
-- 事後驗證（SQL Editor）：
--   select * from public.goal_annual_targets order by target_year desc;
--   select * from public.get_goal_board(date_trunc('month', now())::date);
--
-- 常見狀況：
-- 1. 前端顯示「找不到函式 get_goal_board」→ 執行 notify pgrst, 'reload schema';
-- 2. 目標牆看不到某人 → 該人沒有 member_profiles 列（重跑 members 檔會回填），
--    或 profiles.full_name 空白（顯示為「未具名同仁」）。
-- 3. 年度目標與 12 個月合計不一致是正常的：年度目標是「規劃值」，
--    每月目標才是「執行值」；前端會同時顯示兩個數字並說明差異。
-- =========================================================
