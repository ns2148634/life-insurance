-- =========================================================
-- 客戶規劃歷程（人生收支曲線圖 → 第 3 頁「儲存客戶資料」）
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
--
-- 前置條件：需先執行過 video-training/supabase-schema.sql
--   （提供 auth.users / public.profiles / private.is_admin()）
--
-- 背景：
--   insurance-needs.html 的第 3 頁（總表與保費）可把「客戶姓名、月收入、
--   四項風險順序、保障內容快照」存成一筆。**每次儲存都是新增一筆**，
--   不覆蓋舊資料（保留歷程）。
--   client-plans.html（人生圖資料）依 RLS 只讀自己的資料；管理員可讀全部。
--
-- 隱私：
--   本表只存姓名、月收入、風險順序與保障內容（顯示用快照，字串保留
--   「20-40」這類區間原文），**不存生日、性別、聯絡方式**。
--   一般同仁只能 select / insert / delete 自己的那一列；管理員可 select 全部。
--
-- 本檔只新增一張表：public.insurance_plans（+ 索引 + trigger + RLS）。
-- =========================================================

-- 0. 前置檢查：public.profiles 必須存在（沒有就先跑 video-training/supabase-schema.sql）
do $guard$
begin
  if to_regclass('public.profiles') is null then
    raise exception '找不到 public.profiles，請先執行 video-training/supabase-schema.sql 再跑本檔';
  end if;

  if to_regprocedure('private.is_admin()') is null then
    raise exception '找不到 private.is_admin()，請先執行 video-training/supabase-schema.sql 再跑本檔';
  end if;
end
$guard$;

create schema if not exists private;

-- 1. 資料表
create table if not exists public.insurance_plans (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  client_name    text not null,
  monthly_income numeric(12, 0) not null default 0,
  risk_order     jsonb not null,
  coverage       jsonb not null default '[]'::jsonb,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint insurance_plans_name_len
    check (char_length(btrim(client_name)) between 1 and 40),
  constraint insurance_plans_income_nonneg
    check (monthly_income >= 0),
  constraint insurance_plans_risk_order_is_array
    check (jsonb_typeof(risk_order) = 'array' and jsonb_array_length(risk_order) = 4),
  constraint insurance_plans_coverage_is_array
    check (jsonb_typeof(coverage) = 'array')
);

comment on table public.insurance_plans is
  '人生收支曲線圖第 3 頁儲存的客戶規劃（每次儲存新增一筆，保留歷程；人生圖資料頁讀取，RLS 只讀自己的）';
comment on column public.insurance_plans.client_name is '客戶姓名（1–40 字，僅供辨識，不存其他個資）';
comment on column public.insurance_plans.monthly_income is '月收入（元）';
comment on column public.insurance_plans.risk_order is
  '四項風險的優先順序，例如 ["interrupt","death","disability","medical"]';
comment on column public.insurance_plans.coverage is
  '保障內容顯示快照：[{"cat":"death","title":"活的太短","priority":1,"items":[{"key":"death-0","name":"一般身故","value":"450","unit":"萬元"}]}]';

-- 2. 索引（人生圖資料永遠是「我的資料，依時間新→舊」）
create index if not exists insurance_plans_user_created_idx
  on public.insurance_plans (user_id, created_at desc);

-- 3. updated_at 自動更新
create or replace function private.set_updated_at()
returns trigger
language plpgsql
as $fn$
begin
  new.updated_at := now();
  return new;
end;
$fn$;

revoke execute on function private.set_updated_at() from public, anon;
grant execute on function private.set_updated_at() to authenticated, service_role;

drop trigger if exists insurance_plans_set_updated_at on public.insurance_plans;
create trigger insurance_plans_set_updated_at
  before update on public.insurance_plans
  for each row execute function private.set_updated_at();

-- 4. RLS：本人 read / insert / delete；管理員 read
alter table public.insurance_plans enable row level security;

revoke all on public.insurance_plans from anon;
grant select, insert, update, delete on public.insurance_plans to authenticated;

drop policy if exists insurance_plans_select_own on public.insurance_plans;
create policy insurance_plans_select_own
  on public.insurance_plans
  for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists insurance_plans_select_admin on public.insurance_plans;
create policy insurance_plans_select_admin
  on public.insurance_plans
  for select
  to authenticated
  using (private.is_admin());

drop policy if exists insurance_plans_insert_own on public.insurance_plans;
create policy insurance_plans_insert_own
  on public.insurance_plans
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists insurance_plans_update_own on public.insurance_plans;
create policy insurance_plans_update_own
  on public.insurance_plans
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists insurance_plans_delete_own on public.insurance_plans;
create policy insurance_plans_delete_own
  on public.insurance_plans
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- 5. PostgREST 重新載入 schema（新表才馬上看得到）
notify pgrst, 'reload schema';

-- =========================================================
-- 驗證（可選）：執行後貼上這段，會列出表與 policy
-- =========================================================
-- select tablename, policyname, cmd
--   from pg_policies
--  where schemaname = 'public' and tablename = 'insurance_plans'
--  order by cmd, policyname;
