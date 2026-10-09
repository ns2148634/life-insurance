-- =========================================================
-- 我的實績（來自保顧+）— Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn（與 goal-system / video-training / sharing 共用同一個專案）
--
-- 前置條件：
--   1. 已執行過 video-training/supabase-schema.sql（提供 public.profiles 與 private.is_admin()）
--   2. 已執行過 supabase-schema-goals.sql（本檔沿用同一套風格，但不依賴它）
--
-- 本檔只新增一張表 public.agent_stats + 索引 + RLS，
-- 以及一個「只給伺服端 service_role 使用」的寫入函式 public.ingest_agent_stats(jsonb)。
--
-- 資料來源：「ShowAll 保顧+」（Next.js + Supabase，另一個專案 uditztyjqbpzxzgquiym）
--   保顧+ 的排程會呼叫本站的 ingest_agent_stats，把「每月八分類記事筆數」寫進來。
--   ⚠️ 只同步「筆數」，不含客戶姓名、記事內容等任何個資。
--
-- 為什麼要有 ingest 函式（而不是直接開放 insert）？
--   - 寫入端是伺服端（service_role），本站前端完全沒有寫入權限；
--   - user_id 由 email 在資料庫內解析（auth.users / public.profiles），
--     前端無法也不需要知道別人的 uid；
--   - 唯一鍵 (email, stat_month) 讓重跑同步是 idempotent（upsert，不會重複累加）。
-- =========================================================

-- =========================================================
-- ⚠️ 步驟 -1：先確認「貼對專案」（fail-fast 守衛）
--    本檔只能貼在**本站**專案 dwesqvutdlvnmajxdcpn（與 goal-system / video-training /
--    sharing 共用同一個專案），**不能**貼到「ShowAll 保顧+」專案 uditztyjqbpzxzgquiym。
--    貼錯專案時，原本會在下一段建立 private.is_admin() 時炸
--    `42P01 relation "public.profiles" does not exist`——訊息完全沒提到專案，
--    很容易被誤判成「少跑了某支 SQL」。這裡先自己檢查一次，把話講清楚。
--    （Supabase SQL Editor 整段是單一交易，這裡 raise 之後不會留下半成品。）
-- =========================================================
do $guard$
begin
  if to_regclass('public.profiles') is null then
    raise exception '貼錯專案：找不到 public.profiles'
      using
        errcode = 'undefined_table',
        hint = '本檔請貼到「一定要宸功專區」的 Supabase 專案 dwesqvutdlvnmajxdcpn（保顧+ 是 uditztyjqbpzxzgquiym，那裡沒有 profiles／agent_stats）。若確定已在正確專案，請先執行 video-training/supabase-schema.sql。';
  end if;
end
$guard$;

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
-- 1. agent_stats：每位業務員「每月」的實績計數（來自保顧+）
--    stat_month 一律存該月 1 號（與 goal_targets.period_month 同慣例），
--    以 unique(email, stat_month) 保證「同一人同一月」只有一筆，重跑同步不會重複。
--    email 是跨系統的對應鍵（保顧+ 的團隊關係也是用 email 綁定）。
-- =========================================================
create table if not exists public.agent_stats (
  id uuid primary key default gen_random_uuid(),
  stat_month date not null,
  -- 以 email 對應到的本站帳號；對不上（同仁兩邊用不同 email）時為 null，只有管理員看得到
  user_id uuid references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  -- 保顧+ 的記事八分類計數（順序＝保顧+ 的 CLIENT_NOTE_TYPE_ORDER）
  new_client integer not null default 0,
  first_visit integer not null default 0,
  follow_up integer not null default 0,
  claim integer not null default 0,
  service integer not null default 0,
  discuss_case integer not null default 0,
  signed integer not null default 0,
  recruit integer not null default 0,
  total integer not null default 0,
  -- 名下客戶總數（不分月份的現況值）
  clients_count integer not null default 0,
  -- 來源系統代號（日後若有多個來源可區分）
  source text not null default 'baogu',
  synced_at timestamptz not null default now(),
  -- 只接受每月 1 號，避免同月不同日造成重複紀錄
  constraint agent_stats_month_first check (extract(day from stat_month) = 1),
  constraint agent_stats_counts_nonneg check (
    new_client >= 0 and first_visit >= 0 and follow_up >= 0 and claim >= 0
    and service >= 0 and discuss_case >= 0 and signed >= 0 and recruit >= 0
    and total >= 0 and clients_count >= 0
  ),
  constraint agent_stats_email_month_uniq unique (email, stat_month)
);

create index if not exists agent_stats_month_idx on public.agent_stats (stat_month);
create index if not exists agent_stats_user_month_idx on public.agent_stats (user_id, stat_month);
create index if not exists agent_stats_email_idx on public.agent_stats (email);

-- =========================================================
-- 2. Row Level Security
--    anon 完全碰不到；authenticated 只能「讀」——寫入一律走 service_role 專用函式，
--    所以這裡刻意「不」建立任何 insert / update / delete policy。
-- =========================================================
alter table public.agent_stats enable row level security;

revoke all on public.agent_stats from anon;
grant select on public.agent_stats to authenticated;

-- ---- 讀：自己的 -------------------------------------------------------
drop policy if exists "read own agent stats" on public.agent_stats;
create policy "read own agent stats" on public.agent_stats
  for select to authenticated
  using ( (select auth.uid()) = user_id );

-- ---- 讀：管理員可看全部（含 user_id 尚未對應到的列）-------------------
drop policy if exists "admin read agent stats" on public.agent_stats;
create policy "admin read agent stats" on public.agent_stats
  for select to authenticated
  using ( (select private.is_admin()) );

-- =========================================================
-- 3. ingest_agent_stats(p_rows jsonb)：僅限 service_role 呼叫
--    參數格式（JSON 陣列，欄位可缺，缺的以 0 計）：
--      [{ "stat_month":"2026-10-01", "email":"a@b.com", "display_name":"王小明",
--         "new_client":3, "first_visit":5, "follow_up":8, "claim":1,
--         "service":2, "discuss_case":4, "signed":2, "recruit":0,
--         "total":25, "clients_count":12, "source":"baogu" }]
--    回傳：實際寫入（新增或更新）的列數
-- =========================================================
create or replace function public.ingest_agent_stats(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  -- 只有帶 service_role JWT 的請求可以寫入（前端拿不到這把金鑰）
  if coalesce((select auth.jwt()) ->> 'role', '') <> 'service_role' then
    raise exception '只有 service_role 可以寫入 agent_stats' using errcode = '42501';
  end if;

  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows 必須是 JSON 陣列' using errcode = '22023';
  end if;

  insert into public.agent_stats (
    stat_month, user_id, email, display_name,
    new_client, first_visit, follow_up, claim, service, discuss_case, signed, recruit,
    total, clients_count, source, synced_at
  )
  select
    r.stat_month,
    -- user_id 由 email 解析。**必須用純量子查詢**，不能寫成 left join：
    -- public.profiles 的 email 沒有 unique，同一個 email 有兩列時 left join 會把
    -- 一筆輸入展開成兩列，後面的 on conflict 就對同一筆 (email, stat_month) 更新兩次，
    -- 整批同步直接失敗（`ON CONFLICT DO UPDATE command cannot affect row a second time`）。
    -- 順序維持原樣：先問 public.profiles（本站自己的帳號資料），對不到才退回 auth.users，
    -- 兩者都對不到就是 null（本人看不到自己那列，只有管理員看得到）。
    coalesce(
      (select pr.id from public.profiles pr
        where lower(pr.email) = lower(r.email)
        order by pr.created_at
        limit 1),
      (select au.id from auth.users au
        where lower(au.email) = lower(r.email)
        order by au.created_at
        limit 1)
    ),
    lower(r.email),
    r.display_name,
    coalesce(r.new_client, 0),
    coalesce(r.first_visit, 0),
    coalesce(r.follow_up, 0),
    coalesce(r.claim, 0),
    coalesce(r.service, 0),
    coalesce(r.discuss_case, 0),
    coalesce(r.signed, 0),
    coalesce(r.recruit, 0),
    coalesce(r.total, 0),
    coalesce(r.clients_count, 0),
    coalesce(nullif(r.source, ''), 'baogu'),
    now()
  from jsonb_to_recordset(p_rows) as r(
    stat_month date, email text, display_name text,
    new_client integer, first_visit integer, follow_up integer, claim integer,
    service integer, discuss_case integer, signed integer, recruit integer,
    total integer, clients_count integer, source text
  )
  where r.email is not null and r.email <> '' and r.stat_month is not null
  on conflict (email, stat_month) do update set
    user_id       = excluded.user_id,
    display_name  = excluded.display_name,
    new_client    = excluded.new_client,
    first_visit   = excluded.first_visit,
    follow_up     = excluded.follow_up,
    claim         = excluded.claim,
    service       = excluded.service,
    discuss_case  = excluded.discuss_case,
    signed        = excluded.signed,
    recruit       = excluded.recruit,
    total         = excluded.total,
    clients_count = excluded.clients_count,
    source        = excluded.source,
    synced_at     = now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.ingest_agent_stats(jsonb) from public, anon, authenticated;
grant execute on function public.ingest_agent_stats(jsonb) to service_role;

-- =========================================================
-- 4. 讓 PostgREST 立即認得新表 / 新函式（避免 schema cache 找不到）
-- =========================================================
notify pgrst, 'reload schema';

-- =========================================================
-- 事後手動操作提醒：
-- 1. 實際資料由「保顧+」的排程寫入，本站不需要（也沒有權限）手動新增。
-- 2. 手動測試寫入：SQL Editor 沒有 JWT，上面的 service_role 檢查會擋下來
--    （這是預期行為）。若要在 SQL Editor 測，請暫時註解那三行檢查：
--      select public.ingest_agent_stats(
--        '[{"stat_month":"2026-10-01","email":"你的email","signed":1}]'::jsonb);
-- 3. 檢查同步結果：
--      select stat_month, email, user_id, total, signed, synced_at
--      from public.agent_stats order by stat_month desc, email;
-- 4. 若畫面顯示「讀取保顧+ 實績失敗」：
--      在 SQL Editor 執行  notify pgrst, 'reload schema';  再重新整理。
-- 5. 同仁兩邊 email 不同 → user_id 為 null（本人看不到、管理員看得到）；
--    請管理員統一兩邊的登入 email。
-- =========================================================
