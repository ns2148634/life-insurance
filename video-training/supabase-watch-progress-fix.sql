-- =========================================================
-- 觀看進度（watch_progress）寫入失敗 — 診斷 + 修復
--
-- 適用症狀：影片頁的進度條會動，但 public.watch_progress 一直是空的，
--           每位業務員都查不到自己的進度。
--
-- 常見原因（前端原本把錯誤吞掉了，所以完全看不出來）：
--   42P10  表沒有 (user_id, video_id) 的主鍵 / unique 條件
--          → upsert 的 onConflict=user_id,video_id 對不上，每次寫入都失敗
--   42501  RLS policy 不存在或寫錯（SQL 沒跑完）
--   42501  authenticated 缺少 insert/update 權限，或表沒 expose 到 Data API
--
-- 這份 SQL 可重複執行，不會壞。
-- 在 Supabase Dashboard → SQL Editor → New query 整份貼上 → Run。
-- =========================================================

-- ---------------------------------------------------------
-- ① 診斷：先看現況（照順序看這四段結果，就知道是哪一種）
-- ---------------------------------------------------------

-- 1-1 表是否存在？主鍵是什麼？RLS 有沒有開？
select c.relname                                as table_name,
       c.relrowsecurity                         as rls_enabled,
       pg_get_constraintdef(con.oid)            as primary_key
  from pg_class c
  left join pg_constraint con
    on con.conrelid = c.oid and con.contype = 'p'
 where c.oid = 'public.watch_progress'::regclass;

-- 1-2 這張表上有哪些 policy？
select policyname, cmd, roles, qual, with_check
  from pg_policies
 where schemaname = 'public' and tablename = 'watch_progress';

-- 1-3 authenticated 有沒有讀寫權限？（正常應該全是 true）
select has_table_privilege('authenticated', 'public.watch_progress', 'SELECT') as can_select,
       has_table_privilege('authenticated', 'public.watch_progress', 'INSERT') as can_insert,
       has_table_privilege('authenticated', 'public.watch_progress', 'UPDATE') as can_update,
       has_table_privilege('authenticated', 'public.watch_progress', 'DELETE') as can_delete;

-- 1-4 目前有幾筆進度？（修好之前應該是 0）
select count(*) as rows_now from public.watch_progress;

-- ---------------------------------------------------------
-- ② 修復
-- ---------------------------------------------------------

-- 2-1 補齊欄位（若表是舊版或手動建立的，可能少了欄位）
alter table public.watch_progress add column if not exists watched_sec integer not null default 0;
alter table public.watch_progress add column if not exists percent numeric not null default 0;
alter table public.watch_progress add column if not exists completed_at timestamptz;
alter table public.watch_progress add column if not exists last_watched_at timestamptz not null default now();

-- 2-2 補主鍵：upsert(..., { onConflict: "user_id,video_id" }) 需要這個
--     這是最常見的 42P10 元兇。若不是 (user_id, video_id) 就重建。
do $$
declare
  v_def text;
  v_name text;
begin
  select con.conname, pg_get_constraintdef(con.oid)
    into v_name, v_def
    from pg_constraint con
   where con.conrelid = 'public.watch_progress'::regclass
     and con.contype = 'p';

  if v_def is distinct from 'PRIMARY KEY (user_id, video_id)' then
    if v_name is not null then
      execute 'alter table public.watch_progress drop constraint ' || quote_ident(v_name);
    end if;
    alter table public.watch_progress add primary key (user_id, video_id);
  end if;
end $$;

-- 2-3 權限（anon 不該碰到，authenticated 需要讀寫）
alter table public.watch_progress enable row level security;
revoke all on public.watch_progress from anon;
grant select, insert, update, delete on public.watch_progress to authenticated;

-- 2-4 RLS policy：每人只能讀寫自己的進度
drop policy if exists "user manage own progress" on public.watch_progress;
create policy "user manage own progress" on public.watch_progress
  for all
  to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

-- 2-5 讓 PostgREST / Data API 重新載入 schema 快取
notify pgrst, 'reload schema';

-- ---------------------------------------------------------
-- ③ 驗證
--   1. 在網站上開一支影片播放約 15 秒（或暫停一下）。
--   2. 回來執行下面這段，應該要看到剛剛那位業務員的資料列。
--   3. 若仍是 0 筆，到瀏覽器 DevTools → Console 看
--      [watch_progress] 儲存失敗: ... 的錯誤內容。
-- ---------------------------------------------------------
-- select * from public.watch_progress order by last_watched_at desc limit 20;
