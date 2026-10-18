-- =========================================================
-- 通訊處排行（單一指標 Top 10）— Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn（與 goal-system / agent-stats / unit-stats 共用同一專案）
--
-- 前置條件：
--   1. 已執行過 video-training/supabase-schema.sql（提供 public.profiles、private.is_admin()）
--   2. 已執行過 supabase-schema-agent-stats.sql（提供 public.agent_stats）
--   3. 建議已執行 supabase-schema-unit-stats.sql（通訊處合計實績）
--
-- 背景：
--   goal-system.html 的「通訊處排行」要列出各指標的前 10 名。
--   agent_stats 的 RLS 只讓一般同仁讀到自己那一列，
--   因此這裡比照 get_unit_agent_stats_totals 的做法，用 security definer 函式代查，
--   只回傳「名次、顯示名稱、該指標數值、該列同步時間」，
--   **不輸出完整 email、客戶姓名或記事內容**。
--
--   ⚠️ 隱私界線的刻意例外：
--      「通訊處專區」仍只顯示合計、不列個人明細；
--      「通訊處排行」依需求改為顯示同仁姓名與數值（仍不含客戶個資）。
--      若之後不想讓一般同仁看到姓名，可：
--        ① 在下方函式把 person_name 改成遮罩（例如只留姓氏）；
--        ② 或把檔尾的 grant execute 改成只給 service_role／管理員。
--
-- 本檔只新增一支函式：
--   public.get_unit_agent_stats_ranking(date, text, integer)
-- =========================================================

-- =========================================================
-- ⚠️ 步驟 -1：先確認「貼對專案」（fail-fast 守衛）
--    本檔只能貼在本站專案 dwesqvutdlvnmajxdcpn，
--    不能貼到「ShowAll 保顧+」專案 uditztyjqbpzxzgquiym（那裡沒有 agent_stats）。
-- =========================================================
do $guard$
begin
  if to_regclass('public.agent_stats') is null then
    raise exception '貼錯專案或尚未執行前置 SQL：找不到 public.agent_stats'
      using
        errcode = 'undefined_table',
        hint = '本檔請貼到本站 Supabase 專案 dwesqvutdlvnmajxdcpn，並先執行 supabase-schema-agent-stats.sql（它會建立 public.agent_stats）。';
  end if;

  if to_regclass('public.profiles') is null then
    raise exception '貼錯專案或尚未執行前置 SQL：找不到 public.profiles'
      using
        errcode = 'undefined_table',
        hint = '本檔請貼到本站 Supabase 專案 dwesqvutdlvnmajxdcpn，並先執行 video-training/supabase-schema.sql（它會建立 public.profiles）。';
  end if;
end
$guard$;

-- =========================================================
-- 1. 通訊處排行：指定月份＋指定指標的前 N 名（預設 10）
--    參數：
--      p_month  該月任一日期（內部統一取 date_trunc('month')）
--      p_metric 排行指標，僅接受下列白名單（避免動態 SQL 注入）
--      p_limit  取前幾名，預設 10、上限 50
--    回傳：
--      rk           名次（同分依顯示名稱排序，結果固定）
--      display_name 顯示名稱（agent_stats.display_name → profiles.full_name →
--                   email @ 前段 →「未具名同仁」，不會輸出完整 email）
--      metric_value 該指標數值
--      synced_at    該列的同步時間（前端取最大值顯示「資料更新」）
--
--    註：
--    - 只納入該指標 > 0 的同仁，避免整排 0 佔位。
--    - clients_count 是「名下客戶總數」的現況值，不是本月新增。
--    - 只有登入者可以呼叫（與 get_unit_goal_totals / get_unit_agent_stats_totals 一致）。
-- =========================================================
create or replace function public.get_unit_agent_stats_ranking(
  p_month  date,
  p_metric text    default 'total',
  p_limit  integer default 10
)
returns table (
  rk           integer,
  display_name text,
  metric_value integer,
  synced_at    timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 10), 50));
begin
  -- 空字串／NULL 一律視為預設指標，避免呼叫端漏傳
  p_metric := coalesce(nullif(btrim(p_metric), ''), 'total');

  -- 指標白名單（與前端 goal-system.html 的 RANK_METRICS 一致）
  if p_metric not in (
    'total', 'new_client', 'first_visit', 'follow_up', 'discuss_case',
    'signed', 'service', 'claim', 'recruit', 'clients_count'
  ) then
    raise exception '不支援的排行指標：%', p_metric using errcode = '22023';
  end if;

  -- 未登入一律回空（前端也只有在登入後才會呼叫）
  if (select auth.uid()) is null then
    return;
  end if;

  return query
  with src as (
    select
      coalesce(
        nullif(btrim(a.display_name), ''),
        nullif(btrim(p.full_name), ''),
        nullif(split_part(a.email, '@', 1), ''),
        '未具名同仁'
      ) as person_name,
      a.email as tie_key,
      (case p_metric
        when 'new_client'    then a.new_client
        when 'first_visit'   then a.first_visit
        when 'follow_up'     then a.follow_up
        when 'discuss_case'  then a.discuss_case
        when 'signed'        then a.signed
        when 'service'       then a.service
        when 'claim'         then a.claim
        when 'recruit'       then a.recruit
        when 'clients_count' then a.clients_count
        else a.total
      end)::integer as val,
      a.synced_at
    from public.agent_stats a
    left join public.profiles p on p.id = a.user_id
    where a.stat_month = date_trunc('month', p_month)::date
  ),
  ranked as (
    select
      row_number() over (order by s.val desc, s.person_name asc, s.tie_key asc)::integer as rk,
      s.person_name,
      s.val,
      s.synced_at
    from src s
    where s.val > 0
  )
  select
    r.rk,
    r.person_name as display_name,
    r.val        as metric_value,
    r.synced_at
  from ranked r
  where r.rk <= v_limit
  order by r.rk;
end;
$$;

revoke all on function public.get_unit_agent_stats_ranking(date, text, integer) from public, anon;
grant execute on function public.get_unit_agent_stats_ranking(date, text, integer) to authenticated;

-- =========================================================
-- 2. 讓 PostgREST 立即認得新函式（避免 schema cache 找不到）
-- =========================================================
notify pgrst, 'reload schema';

-- =========================================================
-- 事後手動操作提醒：
-- 1. 驗證本月排行（可在 SQL Editor 直接呼叫）：
--      select * from public.get_unit_agent_stats_ranking(
--        date_trunc('month', now())::date, 'signed', 10);
-- 2. 驗證其他指標：
--      select * from public.get_unit_agent_stats_ranking(
--        date_trunc('month', now())::date, 'total', 10);
--      select * from public.get_unit_agent_stats_ranking(
--        date_trunc('month', now())::date, 'clients_count', 10);
-- 3. 若不支援的指標名稱會直接報錯（22023），不會默默查 total。
-- 4. 若畫面顯示「讀取排行失敗」：
--      在 SQL Editor 執行  notify pgrst, 'reload schema';  再重新整理。
-- 5. 本函式只讀 public.agent_stats 與 public.profiles，不會寫入任何資料。
-- =========================================================
