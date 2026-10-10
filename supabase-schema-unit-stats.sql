-- =========================================================
-- 通訊處專區（合計實績）— Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn（與 goal-system / agent-stats / video-training / sharing 共用同一專案）
--
-- 前置條件：
--   1. 已執行過 video-training/supabase-schema.sql（提供 public.profiles、private.is_admin()）
--   2. 已執行過 supabase-schema-agent-stats.sql（提供 public.agent_stats）
--
-- 背景：
--   goal-system.html 分成「個人專區」與「通訊處專區」。
--   個人實績讀 agent_stats 自己那一列（RLS 已限制）；
--   通訊處專區要顯示「全體同仁的合計實績」，但 RLS 讓一般同仁看不到別人的列，
--   所以這裡比照 get_unit_goal_totals 的做法，用 security definer 函式代查，
--   只回傳「加總數字」與「同步時間」，**不揭露任何個人明細**。
--
-- 本檔只新增一支函式：public.get_unit_agent_stats_totals(date)。
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
end
$guard$;

-- =========================================================
-- 1. 整個通訊處的「合計實績」
--    回傳：人數、八分類中的五項（與畫面一致）＋總計＋最後同步時間。
--    與 get_unit_goal_totals 同一套隱私界線：只回傳加總，不揭露個人那一列。
--    （目前 profiles 沒有「單位」欄位，因此「整個通訊處」＝全體同仁加總。）
--    註：members ＝ 本月有實績列的同仁數（含 email 尚未對上本站帳號的列；
--        個人專區只讀得到自己 user_id 那一列，兩者範圍不同是刻意的）。
-- =========================================================
create or replace function public.get_unit_agent_stats_totals(p_month date)
returns table (
  members       integer,
  new_client    integer,
  first_visit   integer,
  follow_up     integer,
  discuss_case  integer,
  signed        integer,
  total         integer,
  synced_at     timestamptz
)
language sql
security definer
set search_path = ''
stable
as $$
  select
    count(*)::integer                        as members,
    coalesce(sum(a.new_client), 0)::integer  as new_client,
    coalesce(sum(a.first_visit), 0)::integer as first_visit,
    coalesce(sum(a.follow_up), 0)::integer   as follow_up,
    coalesce(sum(a.discuss_case), 0)::integer as discuss_case,
    coalesce(sum(a.signed), 0)::integer      as signed,
    coalesce(sum(a.total), 0)::integer       as total,
    max(a.synced_at)                         as synced_at
  from public.agent_stats a
  where a.stat_month = date_trunc('month', p_month)::date
    -- 只有登入者可以呼叫（與 get_unit_goal_totals 一致）
    and (select auth.uid()) is not null;
$$;

revoke all on function public.get_unit_agent_stats_totals(date) from public, anon;
grant execute on function public.get_unit_agent_stats_totals(date) to authenticated;

-- =========================================================
-- 2. 讓 PostgREST 立即認得新函式（避免 schema cache 找不到）
-- =========================================================
notify pgrst, 'reload schema';

-- =========================================================
-- 事後手動操作提醒：
-- 1. 驗證通訊處合計實績（可在 SQL Editor 直接呼叫）：
--      select * from public.get_unit_agent_stats_totals(date_trunc('month', now())::date);
-- 2. 若畫面顯示「讀取通訊處合計實績失敗」：
--      在 SQL Editor 執行  notify pgrst, 'reload schema';  再重新整理。
-- 3. 本函式只讀 public.agent_stats，不會寫入任何資料。
-- =========================================================
