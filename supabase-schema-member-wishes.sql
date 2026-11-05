-- =========================================================
-- 宸功人士 — 年度心願（時間軸）Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn
--
-- 前置條件（請先依序執行）：
--   1. video-training/supabase-schema.sql
--      → auth.users / public.profiles / private.is_admin() / private.set_updated_at()
--   2. supabase-schema-members.sql
--      → public.member_profiles / public.get_member_directory()
--
-- 本檔建立：
--   public.member_wishes           每人每月可寫多筆「想完成的事」
--   public.save_my_wishes(int,jsonb) 一次覆寫自己某一年度的心願（單一交易）
--   public.get_member_wishes(uuid)  讀某位同仁的心願（時間軸用）
--
-- 隱私設計：
--   - 資料表本身只有「本人」與「管理員」能讀寫（RLS）。
--   - 組織圖點人要看對方的檔案與時間軸，因此另外提供
--     security definer 的 get_member_wishes()，只回「年／月／內容／更新時間」，
--     不含 email、is_admin、或其他帳號資料；且必須登入才能呼叫。
--
-- 執行順序：supabase-schema-members.sql → 本檔 → supabase-schema-goal-annual.sql
-- =========================================================

-- =========================================================
-- 0. 前置檢查（缺東西就立刻停下）
-- =========================================================
do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception '缺少 public.profiles：請先執行 video-training/supabase-schema.sql';
  end if;
  if to_regclass('public.member_profiles') is null then
    raise exception '缺少 public.member_profiles：請先執行 supabase-schema-members.sql';
  end if;
  if to_regprocedure('private.is_admin()') is null then
    raise exception '缺少 private.is_admin()：請先執行 video-training/supabase-schema.sql';
  end if;
  if to_regprocedure('private.set_updated_at()') is null then
    raise exception '缺少 private.set_updated_at()：請先執行 supabase-schema-goals.sql 或 supabase-schema-members.sql';
  end if;
end
$$;

-- =========================================================
-- 1. public.member_wishes
--    - 一列＝一筆心願；同一人／同一年／同一月可以有多列
--    - sort_order 保留使用者輸入的順序（0 起算）
--    - 空白內容由前端與 save_my_wishes() 過濾，DB 再擋一次
-- =========================================================
create table if not exists public.member_wishes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  wish_year  integer not null,
  wish_month integer not null,
  content    text not null,
  sort_order smallint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint member_wishes_year_check  check (wish_year between 2000 and 2100),
  constraint member_wishes_month_check check (wish_month between 1 and 12),
  constraint member_wishes_content_check
    check (char_length(btrim(content)) between 1 and 200),
  constraint member_wishes_order_check check (sort_order >= 0)
);

comment on table public.member_wishes is
  '宸功人士「我的檔案」的年度心願：一人一年一月可有多筆文字，時間軸依年／月／sort_order 顯示。';

create index if not exists member_wishes_user_year_idx
  on public.member_wishes (user_id, wish_year, wish_month, sort_order);

drop trigger if exists trg_member_wishes_updated on public.member_wishes;
create trigger trg_member_wishes_updated
  before update on public.member_wishes
  for each row execute procedure private.set_updated_at();

-- =========================================================
-- 2. RLS：本人＋管理員
-- =========================================================
alter table public.member_wishes enable row level security;
revoke all on public.member_wishes from anon;
grant select, insert, update, delete on public.member_wishes to authenticated;

drop policy if exists "member wishes select own" on public.member_wishes;
create policy "member wishes select own" on public.member_wishes
  for select to authenticated
  using ( (select auth.uid()) = user_id );

drop policy if exists "member wishes insert own" on public.member_wishes;
create policy "member wishes insert own" on public.member_wishes
  for insert to authenticated
  with check ( (select auth.uid()) = user_id );

drop policy if exists "member wishes update own" on public.member_wishes;
create policy "member wishes update own" on public.member_wishes
  for update to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

drop policy if exists "member wishes delete own" on public.member_wishes;
create policy "member wishes delete own" on public.member_wishes
  for delete to authenticated
  using ( (select auth.uid()) = user_id );

drop policy if exists "admin select member wishes" on public.member_wishes;
create policy "admin select member wishes" on public.member_wishes
  for select to authenticated
  using ( (select private.is_admin()) );

drop policy if exists "admin insert member wishes" on public.member_wishes;
create policy "admin insert member wishes" on public.member_wishes
  for insert to authenticated
  with check ( (select private.is_admin()) );

drop policy if exists "admin update member wishes" on public.member_wishes;
create policy "admin update member wishes" on public.member_wishes
  for update to authenticated
  using ( (select private.is_admin()) )
  with check ( (select private.is_admin()) );

drop policy if exists "admin delete member wishes" on public.member_wishes;
create policy "admin delete member wishes" on public.member_wishes
  for delete to authenticated
  using ( (select private.is_admin()) );

-- =========================================================
-- 3. save_my_wishes(p_year, p_items)
--    p_items 範例：
--      [{"month":3,"content":"通過考核"},{"month":3,"content":"簽下第一件"}]
--    - 一次處理「整年」：先刪掉自己在該年度的心願，再依陣列順序重新寫入
--      （前端按「儲存這一年」時只有一次往返，不會存一半）
--    - 空白內容視為「刪除」；月份不合法／單月超過 10 筆／單筆超過 200 字直接擋下
--    - 任何檢查都在 DELETE 之前完成，避免驗證失敗卻已清空資料
-- =========================================================
create or replace function public.save_my_wishes(p_year integer, p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_count integer := 0;
begin
  if v_uid is null then
    raise exception '請先登入再儲存心願' using errcode = '42501';
  end if;

  if p_year is null or p_year < 2000 or p_year > 2100 then
    raise exception '年份不正確（需在 2000–2100 之間）' using errcode = '22023';
  end if;

  if p_items is not null and jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items 必須是 JSON 陣列' using errcode = '22023';
  end if;

  -- 檢查 1：有內容的項目一定要有合法月份
  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) as item
    where nullif(btrim(coalesce(item ->> 'content', '')), '') is not null
      and coalesce(item ->> 'month', '') !~ '^(1[0-2]|[1-9])$'
  ) then
    raise exception '每筆心願都要指定 1–12 月' using errcode = '22023';
  end if;

  -- 檢查 2：同一個月最多 10 筆
  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) as item
    where nullif(btrim(coalesce(item ->> 'content', '')), '') is not null
    group by (item ->> 'month')
    having count(*) > 10
  ) then
    raise exception '同一個月最多 10 筆心願' using errcode = '22023';
  end if;

  -- 檢查 3：單筆最多 200 字
  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) as item
    where char_length(btrim(coalesce(item ->> 'content', ''))) > 200
  ) then
    raise exception '單筆心願最多 200 個字' using errcode = '22023';
  end if;

  delete from public.member_wishes w
   where w.user_id = v_uid
     and w.wish_year = p_year;

  insert into public.member_wishes (user_id, wish_year, wish_month, content, sort_order)
  select v_uid,
         p_year,
         x.month,
         x.content,
         (row_number() over (partition by x.month order by x.ord) - 1)::smallint
  from (
    select case when (item ->> 'month') ~ '^(1[0-2]|[1-9])$'
                then (item ->> 'month')::integer end as month,
           btrim(item ->> 'content')   as content,
           ord
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality as t(item, ord)
    where nullif(btrim(coalesce(item ->> 'content', '')), '') is not null
  ) x;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.save_my_wishes(integer, jsonb) from public, anon;
grant execute on function public.save_my_wishes(integer, jsonb) to authenticated;

-- =========================================================
-- 4. get_member_wishes(p_user)：時間軸的唯一資料來源
--    - security definer：可讀任何人的心願，但只輸出顯示欄位。
--    - 必須登入（anon 直接收回執行權限）。
--    - 排序：年份新→舊、月份 1→12、使用者輸入順序。
-- =========================================================
drop function if exists public.get_member_wishes(uuid);

create or replace function public.get_member_wishes(p_user uuid)
returns table (
  wish_year  integer,
  wish_month integer,
  content    text,
  sort_order smallint,
  updated_at timestamptz
)
language sql
security definer
set search_path = ''
stable
as $$
  select w.wish_year,
         w.wish_month,
         w.content,
         w.sort_order,
         w.updated_at
  from public.member_wishes w
  where w.user_id = p_user
    and (select auth.uid()) is not null
  order by w.wish_year desc,
           w.wish_month asc,
           w.sort_order asc,
           w.created_at asc;
$$;

revoke all on function public.get_member_wishes(uuid) from public, anon;
grant execute on function public.get_member_wishes(uuid) to authenticated;

-- =========================================================
-- 5. 讓 PostgREST 立即認得新表 / 新函式
-- =========================================================
notify pgrst, 'reload schema';

-- =========================================================
-- 驗證（可貼在 SQL Editor 單獨執行）
-- ---------------------------------------------------------
--   select * from public.member_wishes order by wish_year desc, wish_month, sort_order limit 20;
--
--   -- 以登入者身分模擬儲存（SQL Editor 的 auth.uid() 為 null，這段只是示範）：
--   -- select public.save_my_wishes(2026, '[{"month":3,"content":"通過考核"}]'::jsonb);
--
-- 常見狀況：
-- 1. 前端顯示「找不到函式 save_my_wishes」→ 執行  notify pgrst, 'reload schema';  後重新整理。
-- 2. 前端顯示「請先登入」→ 登入狀態失效，請重新登入。
-- 3. 時間軸看不到別人的心願 → 對方尚未在「我的檔案」寫入任何內容。
-- 4. 只想讓本人看到心願 → 把 get_member_wishes() 的條件改成
--    where w.user_id = p_user and w.user_id = (select auth.uid())；
--    前端「點人看檔案」就只會顯示本人時間軸。
-- =========================================================
