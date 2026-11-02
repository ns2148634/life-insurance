-- =========================================================
-- 歷史資料（月／季／年）— Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn（與 goal-system / agent-stats / unit-* 共用同一專案）
--
-- 前置條件：
--   1. 已執行 video-training/supabase-schema.sql（public.profiles、private.is_admin()）
--   2. 已執行 supabase-schema-goals.sql（public.goal_targets）
--   3. 已執行 supabase-schema-agent-stats.sql（public.agent_stats）
--   4. 已執行 supabase-schema-unit-stats.sql／unit-ranking.sql（同系列的隱私慣例）
--
-- 背景：
--   goal-system.html 的「歷史資料」分區要回查月／季／年的目標與實績。
--   既有函式都是「單一月份」，若在前端逐月呼叫，選「年」要打 12 次 API，
--   因此這裡把「期間彙總」放在資料庫做，一次回傳整段期間。
--
--   季／年一律由「月」加總：
--     目標（FYC／保費／件數）＝期內月目標相加
--     實績（八分類＋總計）  ＝期內月實績相加
--     名下客戶（clients_count）＝**期內最新月份**的現況值，不是相加
--
-- 隱私：
--   1. get_unit_history()：只回傳「全體合計」，不揭露任何個人那一列。
--   2. get_unit_agent_stats_ranking_range()：與既有排行同樣是刻意例外，
--      回傳名次、顯示名稱、數值（不含完整 email、客戶個資）。
--      另外多回一個 is_me，讓前端可以顯示「我的名次」——
--      即使我的名次在 Top N 之外，也會把我那一列一起回傳。
--
-- 本檔新增兩支函式（不新增資料表）：
--   public.get_unit_history(date, date)
--   public.get_unit_agent_stats_ranking_range(date, date, text, integer)
-- =========================================================

-- =========================================================
-- ⚠️ 步驟 -1：先確認「貼對專案」（fail-fast 守衛）
-- =========================================================
do $guard$
begin
  if to_regclass('public.agent_stats') is null then
    raise exception '貼錯專案或尚未執行前置 SQL：找不到 public.agent_stats'
      using
        errcode = 'undefined_table',
        hint = '本檔請貼到本站 Supabase 專案 dwesqvutdlvnmajxdcpn，並先執行 supabase-schema-agent-stats.sql。';
  end if;

  if to_regclass('public.goal_targets') is null then
    raise exception '尚未執行前置 SQL：找不到 public.goal_targets'
      using
        errcode = 'undefined_table',
        hint = '請先執行 supabase-schema-goals.sql。';
  end if;

  if to_regclass('public.profiles') is null then
    raise exception '貼錯專案或尚未執行前置 SQL：找不到 public.profiles'
      using
        errcode = 'undefined_table',
        hint = '本檔請貼到本站 Supabase 專案 dwesqvutdlvnmajxdcpn，並先執行 video-training/supabase-schema.sql。';
  end if;
end
$guard$;

-- =========================================================
-- 1. 通訊處歷史：逐月回傳「目標合計 + 實績合計」（只回有資料的月份）
--    參數：
--      p_start / p_end 期間（任一天即可，內部統一取當月 1 號；先後順序不拘）
--    回傳（每列＝一個月）：
--      month          該月 1 號
--      goal_members   該月有設定目標的人數
--      fyc_target / premium_target / case_target  該月目標合計
--      perf_members   該月有實績列的人數（含 email 尚未對上本站帳號的列）
--      new_client / first_visit / follow_up / claim /
--      service / discuss_case / signed / recruit / total  該月實績合計
--      clients_count  該月「名下客戶」合計（各人取當月值再加總）
--      synced_at      該月最後同步時間
--
--    註：
--    - 季／年的「名下客戶」請取**期間內最新月份**那一列（不是相加），
--      前端已照此規則彙總。
--    - 只有登入者可以呼叫（與 unit-stats / unit-ranking 一致）。
--    - goals 與 perf 用 full join：只有目標沒有實績（或反之）的月份也會回傳。
-- =========================================================
create or replace function public.get_unit_history(p_start date, p_end date)
returns table (
  month          date,
  goal_members   integer,
  fyc_target     numeric,
  premium_target numeric,
  case_target    integer,
  perf_members   integer,
  new_client     integer,
  first_visit    integer,
  follow_up      integer,
  claim          integer,
  service        integer,
  discuss_case   integer,
  signed         integer,
  recruit        integer,
  total          integer,
  clients_count  integer,
  synced_at      timestamptz
)
language sql
security definer
set search_path = ''
stable
as $$
  with bounds as (
    select
      date_trunc('month', least(coalesce(p_start, p_end), coalesce(p_end, p_start)))::date as m_from,
      date_trunc('month', greatest(coalesce(p_start, p_end), coalesce(p_end, p_start)))::date as m_to
    where (select auth.uid()) is not null
      and (p_start is not null or p_end is not null)
  ),
  goals as (
    select
      g.period_month                            as m,
      count(*)::integer                         as members,
      coalesce(sum(g.fyc_target), 0)            as fyc_target,
      coalesce(sum(g.premium_target), 0)        as premium_target,
      coalesce(sum(g.case_target), 0)::integer  as case_target
    from public.goal_targets g
    join bounds b on g.period_month between b.m_from and b.m_to
    group by g.period_month
  ),
  perf as (
    select
      a.stat_month                                 as m,
      count(*)::integer                            as members,
      coalesce(sum(a.new_client), 0)::integer      as new_client,
      coalesce(sum(a.first_visit), 0)::integer     as first_visit,
      coalesce(sum(a.follow_up), 0)::integer       as follow_up,
      coalesce(sum(a.claim), 0)::integer           as claim,
      coalesce(sum(a.service), 0)::integer         as service,
      coalesce(sum(a.discuss_case), 0)::integer    as discuss_case,
      coalesce(sum(a.signed), 0)::integer          as signed,
      coalesce(sum(a.recruit), 0)::integer         as recruit,
      coalesce(sum(a.total), 0)::integer           as total,
      max(a.synced_at)                             as perf_synced_at
    from public.agent_stats a
    join bounds b on a.stat_month between b.m_from and b.m_to
    group by a.stat_month
  ),
  clients as (
    -- 每人取「期間內最新月份」的名下客戶數，再依該月份加總
    select x.m, sum(x.c)::integer as clients_count
    from (
      select distinct on (a.email)
        a.stat_month    as m,
        a.clients_count as c
      from public.agent_stats a
      join bounds b on a.stat_month between b.m_from and b.m_to
      order by a.email, a.stat_month desc
    ) x
    group by x.m
  )
  select
    coalesce(g.m, p.m)                     as month,
    coalesce(g.members, 0)                 as goal_members,
    coalesce(g.fyc_target, 0)              as fyc_target,
    coalesce(g.premium_target, 0)          as premium_target,
    coalesce(g.case_target, 0)             as case_target,
    coalesce(p.members, 0)                 as perf_members,
    coalesce(p.new_client, 0)              as new_client,
    coalesce(p.first_visit, 0)             as first_visit,
    coalesce(p.follow_up, 0)               as follow_up,
    coalesce(p.claim, 0)                   as claim,
    coalesce(p.service, 0)                 as service,
    coalesce(p.discuss_case, 0)            as discuss_case,
    coalesce(p.signed, 0)                  as signed,
    coalesce(p.recruit, 0)                 as recruit,
    coalesce(p.total, 0)                   as total,
    coalesce(c.clients_count, 0)           as clients_count,
    p.perf_synced_at                       as synced_at
  from goals g
  full join perf p on p.m = g.m
  left join clients c on c.m = coalesce(g.m, p.m)
  order by 1;
$$;

revoke all on function public.get_unit_history(date, date) from public, anon;
grant execute on function public.get_unit_history(date, date) to authenticated;

-- =========================================================
-- 2. 通訊處排行歷史：期間彙總後的 Top N ＋「我」那一列
--    參數：
--      p_start / p_end 期間（任一天即可，內部統一取當月 1 號）
--      p_metric 排行指標，僅接受下列白名單（與 goal-system.html 的 RANK_METRICS 一致）
--      p_limit  取前幾名，預設 10、上限 50
--    回傳：
--      rk           名次（期間彙總後重新排名；同分依名稱排序，結果固定）
--      display_name 顯示名稱（agent_stats.display_name → profiles.full_name →
--                   email @ 前段 →「未具名同仁」，不會輸出完整 email）
--      metric_value 期間彙總後的數值
--      synced_at    該人期間內最後同步時間（前端取最大值顯示「資料更新」）
--      is_me        是否為目前登入者（用來標記「你」與顯示我的名次）
--
--    註：
--    - 只納入該指標 > 0 的同仁。
--    - clients_count 是現況值，取期間內最新月份那一列（不是相加）。
--    - 回傳條件是「rk <= p_limit 或 is_me」，所以就算我排在第 11 名之後，
--      也會回傳我那一列，前端可顯示「我的名次」。
--    - 只有登入者可以呼叫。
-- =========================================================
create or replace function public.get_unit_agent_stats_ranking_range(
  p_start  date,
  p_end    date,
  p_metric text    default 'total',
  p_limit  integer default 10
)
returns table (
  rk           integer,
  display_name text,
  metric_value integer,
  synced_at    timestamptz,
  is_me        boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 10), 50));
  v_from  date;
  v_to    date;
begin
  -- 空字串／NULL 一律視為預設指標
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

  v_from := date_trunc('month', least(coalesce(p_start, p_end), coalesce(p_end, p_start)))::date;
  v_to   := date_trunc('month', greatest(coalesce(p_start, p_end), coalesce(p_end, p_start)))::date;
  if v_from is null then
    return;
  end if;

  return query
  with src as (
    select
      a.email as tie_key,
      -- 顯示名稱：取期間內最新月份的那一列（display_name 優先，其次 profiles.full_name）
      coalesce(
        nullif(btrim((array_agg(a.display_name order by a.stat_month desc))[1]), ''),
        nullif(btrim((array_agg(p.full_name    order by a.stat_month desc))[1]), ''),
        nullif(split_part(a.email, '@', 1), ''),
        '未具名同仁'
      ) as person_name,
      coalesce(sum(a.new_client), 0)::integer   as m_new_client,
      coalesce(sum(a.first_visit), 0)::integer  as m_first_visit,
      coalesce(sum(a.follow_up), 0)::integer    as m_follow_up,
      coalesce(sum(a.claim), 0)::integer        as m_claim,
      coalesce(sum(a.service), 0)::integer      as m_service,
      coalesce(sum(a.discuss_case), 0)::integer as m_discuss_case,
      coalesce(sum(a.signed), 0)::integer       as m_signed,
      coalesce(sum(a.recruit), 0)::integer      as m_recruit,
      coalesce(sum(a.total), 0)::integer        as m_total,
      -- 名下客戶是現況值：取期間內最新月份那一列
      (array_agg(a.clients_count order by a.stat_month desc))[1]::integer as m_clients_count,
      coalesce(bool_or(a.user_id = (select auth.uid())), false) as is_me,
      max(a.synced_at) as m_synced_at
    from public.agent_stats a
    left join public.profiles p on p.id = a.user_id
    where a.stat_month between v_from and v_to
    group by a.email
  ),
  metrics as (
    select
      s.person_name,
      s.tie_key,
      s.is_me,
      s.m_synced_at,
      (case p_metric
        when 'new_client'    then s.m_new_client
        when 'first_visit'   then s.m_first_visit
        when 'follow_up'     then s.m_follow_up
        when 'discuss_case'  then s.m_discuss_case
        when 'signed'        then s.m_signed
        when 'service'       then s.m_service
        when 'claim'         then s.m_claim
        when 'recruit'       then s.m_recruit
        when 'clients_count' then s.m_clients_count
        else s.m_total
      end)::integer as val
    from src s
  ),
  ranked as (
    select
      row_number() over (order by v.val desc, v.person_name asc, v.tie_key asc)::integer as rk,
      v.person_name,
      v.val,
      v.is_me,
      v.m_synced_at
    from metrics v
    where v.val > 0
  )
  select
    r.rk,
    r.person_name   as display_name,
    r.val           as metric_value,
    r.m_synced_at   as synced_at,
    r.is_me
  from ranked r
  where r.rk <= v_limit or r.is_me
  order by r.rk;
end;
$$;

revoke all on function public.get_unit_agent_stats_ranking_range(date, date, text, integer) from public, anon;
grant execute on function public.get_unit_agent_stats_ranking_range(date, date, text, integer) to authenticated;

-- =========================================================
-- 3. 讓 PostgREST 立即認得新函式（避免 schema cache 找不到）
-- =========================================================
notify pgrst, 'reload schema';

-- =========================================================
-- 事後手動驗證（可在 SQL Editor 直接呼叫）：
-- 1. 通訊處近 12 個月：
--      select * from public.get_unit_history(
--        (date_trunc('month', now()) - interval '11 months')::date,
--        date_trunc('month', now())::date);
-- 2. 本季排行（Top 10 + 我）：
--      select * from public.get_unit_agent_stats_ranking_range(
--        date_trunc('quarter', now())::date,
--        date_trunc('month', now())::date,
--        'signed', 10);
-- 3. 若不支援的指標名稱會直接報錯（22023）。
-- 4. 若畫面顯示「讀取歷史資料失敗」，先執行 notify pgrst, 'reload schema'; 再重新整理。
-- 5. 本檔兩支函式都只讀 goal_targets / agent_stats / profiles，不會寫入任何資料。
-- =========================================================
