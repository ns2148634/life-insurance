-- =========================================================
-- 業務分享專區 — Supabase Schema（Phase 1 MVP）
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn（與 video-training 共用同一個專案）
--
-- 前置條件：請先執行過 video-training/supabase-schema.sql
--   （本檔沿用其中的 auth.users / public.profiles / private schema，
--     以及 private.is_admin() 這個 security definer 函式）
--
-- 本檔只新增一張表：public.shared_links + 索引 + trigger + RLS。
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
-- 1. shared_links：分享的連結（新聞 / 文章）
--    is_hidden 先預留給 Phase 2 的管理員下架功能使用，
--    前端 MVP 不會寫入 true。
-- =========================================================
create table if not exists public.shared_links (
  id uuid primary key default gen_random_uuid(),
  url text not null,
  title text not null,
  summary text,
  category text not null default '其他',
  tags text[] not null default '{}',
  source text,
  shared_by uuid references auth.users(id) on delete set null,
  shared_by_name text,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- 只允許 http/https，擋掉 javascript: 之類的危險網址
  constraint shared_links_url_http check (url ~* '^https?://[^[:space:]]+$'),
  constraint shared_links_title_len check (char_length(title) between 1 and 200),
  constraint shared_links_category_chk check (
    category in ('醫療健康', '退休理財', '稅務法令', '時事趨勢', '業務心法', '其他')
  )
);

create index if not exists shared_links_created_idx on public.shared_links (created_at desc);
create index if not exists shared_links_category_idx on public.shared_links (category);

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

drop trigger if exists trg_shared_links_updated on public.shared_links;
create trigger trg_shared_links_updated
  before update on public.shared_links
  for each row execute procedure private.set_updated_at();

-- =========================================================
-- 3. Row Level Security
-- =========================================================
alter table public.shared_links enable row level security;

-- anon 不該碰到這張表
revoke all on public.shared_links from anon;
grant select, insert, update, delete on public.shared_links to authenticated;
grant select, insert, update, delete on public.shared_links to service_role;

-- ---- 讀：登入者皆可讀「未被下架」的；管理員可讀全部（含已下架）--------
drop policy if exists "authenticated read visible links" on public.shared_links;
create policy "authenticated read visible links" on public.shared_links
  for select to authenticated
  using ( (not is_hidden) or (select private.is_admin()) );

-- ---- 增：只能以自己身分分享，且不能一開始就標記為隱藏 -----------------
drop policy if exists "insert own share" on public.shared_links;
create policy "insert own share" on public.shared_links
  for insert to authenticated
  with check ( (select auth.uid()) = shared_by and is_hidden = false );

-- ---- 改：自己的（with check 再限制 shared_by 與 is_hidden，避免被改掉）----
drop policy if exists "update own share" on public.shared_links;
create policy "update own share" on public.shared_links
  for update to authenticated
  using ( (select auth.uid()) = shared_by )
  with check ( (select auth.uid()) = shared_by and is_hidden = false );

-- ---- 刪：自己的 -------------------------------------------------------
drop policy if exists "delete own share" on public.shared_links;
create policy "delete own share" on public.shared_links
  for delete to authenticated
  using ( (select auth.uid()) = shared_by );

-- ---- 管理員可改任何一列（Phase 2 的下架用）----------------------------
drop policy if exists "admin update any share" on public.shared_links;
create policy "admin update any share" on public.shared_links
  for update to authenticated
  using ( (select private.is_admin()) )
  with check ( (select private.is_admin()) );

-- ---- 管理員可刪任何一列 ----------------------------------------------
drop policy if exists "admin delete any share" on public.shared_links;
create policy "admin delete any share" on public.shared_links
  for delete to authenticated
  using ( (select private.is_admin()) );

-- =========================================================
-- 3.5 取得分享人的「即時」顯示姓名
--     問題：public.profiles 的 RLS 只允許讀自己或管理員，
--           前端無法即時 join 出分享人姓名，只能靠 shared_by_name 快照，
--           導致同仁改名後，舊分享仍顯示舊名。
--     解法：用 security definer 函式代查，但只回傳「呼叫者指定的那幾個 id」，
--           不會把全體同仁的名單倒給一般使用者。
--     前端：share.html 以 sb.rpc('get_user_display_names', { p_ids: [...] }) 呼叫，
--           查不到（或本函式尚未建立）時自動退回 shared_by_name 快照。
-- =========================================================
create or replace function public.get_user_display_names(p_ids uuid[])
returns table (user_id uuid, display_name text)
language sql
security definer
set search_path = ''
stable
as $$
  select p.id as user_id,
         coalesce(
           nullif(btrim(p.full_name), ''),
           nullif(btrim(p.email), ''),
           '同仁'
         ) as display_name
  from public.profiles p
  where p.id = any(p_ids)
    -- 僅限登入者，且一次最多 500 筆，避免被當成大量列舉的跳板
    and (select auth.uid()) is not null
    and coalesce(array_length(p_ids, 1), 0) <= 500;
$$;

revoke all on function public.get_user_display_names(uuid[]) from public, anon;
grant execute on function public.get_user_display_names(uuid[]) to authenticated;

-- =========================================================
-- 4. 讓 PostgREST 立即認得新表 / 新欄位（避免 schema cache 找不到）
-- =========================================================
notify pgrst, 'reload schema';

-- =========================================================
-- 事後手動操作提醒：
-- 1. 分享專區沿用 video-training 的帳號，不需要另外建立使用者。
--    沒填姓名的同仁，列表會顯示 email。
-- 2. 測試資料（可選）：
--      insert into public.shared_links
--        (url, title, summary, category, tags, source, shared_by, shared_by_name)
--      values ('https://example.com/article', '超高齡社會來了',
--              '可用來說明長照與退休現金流規劃', '退休理財',
--              array['長照','退休'], 'example.com',
--              '<你的 user id>', '王小明');
-- 3. 若分享清單出現「找不到資料表 shared_links」：
--      在 SQL Editor 執行  notify pgrst, 'reload schema';  再重試。
-- 4. 要驗證「分享人姓名即時更新」，可在改了某人的 full_name 後重新整理 share.html，
--    舊分享應顯示新名。若仍顯示舊名，檢查下列兩點：
--      a. 本檔（含 3.5 節的 get_user_display_names）是否已整份重跑。
--      b. 前端 sb.rpc('get_user_display_names', { p_ids: [...] }) 是否有錯誤
--         （開發者工具 Console / Network 可看，未登入會被 RLS 條件擋成空結果）。
--    也可在 SQL Editor 直接呼叫測試：
--      select * from public.get_user_display_names(array['<某個 user id>']::uuid[]);
-- =========================================================
