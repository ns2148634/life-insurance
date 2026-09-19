-- =========================================================
-- 業務員影片研習系統 — Supabase Schema（2026-09 修訂版）
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
--
-- 本次修訂重點：
--   1. 修掉 profiles policy 的自我遞迴（原本會讓 profiles / watch_progress 查詢回 500）
--   2. 業務員可自行修改自己的姓名（profiles 新增 insert / update policy）
--   3. 業務員可自行更改密碼（走 Supabase Auth，前端呼叫 auth.updateUser）
--   4. 主管可在 admin.html 代為重設業務員密碼（admin_reset_user_password RPC）
--   5. policy 改用 Supabase 官方建議寫法：to authenticated + (select auth.uid())
-- =========================================================

-- =========================================================
-- 0. 需要 pgcrypto（Supabase 的 extensions schema，重設密碼做 bcrypt 雜湊用）
-- =========================================================
create extension if not exists pgcrypto with schema extensions;

-- =========================================================
-- 1. profiles：對應 auth.users，多加 is_admin / email 欄位
-- =========================================================
create table if not exists public.profiles (
  id uuid references auth.users(id) on delete cascade primary key,
  full_name text,
  email text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

-- 既有專案補上 email 欄位（新裝專案上面已建好，此行會自動略過）
alter table public.profiles add column if not exists email text;

-- 2. videos：影片清單（youtube_id 用「不公開 Unlisted」影片，不要用私人）
create table if not exists public.videos (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  youtube_id text not null,
  duration_sec integer not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

-- 3. watch_progress：每位業務員對每支影片的觀看進度
create table if not exists public.watch_progress (
  user_id uuid references auth.users(id) on delete cascade not null,
  video_id uuid references public.videos(id) on delete cascade not null,
  watched_sec integer not null default 0,
  percent numeric not null default 0,
  completed_at timestamptz,
  last_watched_at timestamptz not null default now(),
  primary key (user_id, video_id)
);

-- =========================================================
-- 4. private schema + is_admin()：
--    這是修掉「infinite recursion detected in policy for relation profiles」的關鍵。
--    policy 內若直接 select profiles 會無限遞迴；改用 security definer 函式
--    （owner = postgres，查自己的表時可繞過 RLS）就只會查一次。
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
-- 5. 新帳號自動建立 profiles 資料列（含 email，
--    讓 admin 後台在業務員還沒填姓名時顯示 email 而不是 UUID）
-- =========================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (new.id, new.raw_user_meta_data ->> 'full_name', new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- =========================================================
-- 6. Row Level Security
-- =========================================================
alter table public.profiles enable row level security;
alter table public.videos enable row level security;
alter table public.watch_progress enable row level security;

-- 只給真正需要的權限（anon 不該碰到這些表）
revoke all on public.profiles from anon;
revoke all on public.videos from anon;
revoke all on public.watch_progress from anon;

grant select, insert, update on public.profiles to authenticated;
grant select on public.videos to authenticated;
grant select, insert, update, delete on public.watch_progress to authenticated;

grant select, insert, update, delete on public.profiles to service_role;
grant select, insert, update, delete on public.videos to service_role;
grant select, insert, update, delete on public.watch_progress to service_role;

-- ---- profiles ----------------------------------------------------------
-- 自己可讀自己
drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles
  for select to authenticated
  using ( (select auth.uid()) = id );

-- admin 可讀全部（改用 private.is_admin()，避免遞迴）
drop policy if exists "admin read all profiles" on public.profiles;
create policy "admin read all profiles" on public.profiles
  for select to authenticated
  using ( (select private.is_admin()) );

-- 自己可新增自己的 profile（保險：舊帳號可能沒有資料列）
drop policy if exists "insert own profile" on public.profiles;
create policy "insert own profile" on public.profiles
  for insert to authenticated
  with check ( (select auth.uid()) = id );

-- 自己可改自己的資料（using + with check 都要有，否則可把 id 改掉）
drop policy if exists "update own profile" on public.profiles;
create policy "update own profile" on public.profiles
  for update to authenticated
  using ( (select auth.uid()) = id )
  with check ( (select auth.uid()) = id );

-- ---- videos -----------------------------------------------------------
-- 登入使用者皆可讀（維護請直接在 Supabase 後台操作）
drop policy if exists "authenticated read videos" on public.videos;
create policy "authenticated read videos" on public.videos
  for select to authenticated
  using ( true );

-- ---- watch_progress ---------------------------------------------------
-- 使用者只能讀寫自己的進度
drop policy if exists "user manage own progress" on public.watch_progress;
create policy "user manage own progress" on public.watch_progress
  for all to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

-- admin 可讀全部人的進度（不給寫，避免誤改）
drop policy if exists "admin read all progress" on public.watch_progress;
create policy "admin read all progress" on public.watch_progress
  for select to authenticated
  using ( (select private.is_admin()) );

-- =========================================================
-- 7. 防止業務員把自己升成管理員
--    RLS 只能管「列」不能管「欄」，所以用 trigger 擋 is_admin 的變更。
--    有 JWT 的請求（PostgREST）必須是 admin 或 service_role；
--    沒有 JWT 的情境（SQL Editor / migration / psql）直接放行。
-- =========================================================
create or replace function private.protect_is_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.is_admin is distinct from old.is_admin
     and (select auth.uid()) is not null
     and coalesce((select auth.jwt()) ->> 'role', '') <> 'service_role'
     and not private.is_admin()
  then
    raise exception '只有管理員可以變更 is_admin' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke execute on function private.protect_is_admin() from public, anon;
grant execute on function private.protect_is_admin() to authenticated, service_role;

drop trigger if exists trg_protect_is_admin on public.profiles;
create trigger trg_protect_is_admin
  before update on public.profiles
  for each row execute procedure private.protect_is_admin();

-- =========================================================
-- 8. 主管代為重設業務員密碼（admin.html 用 sb.rpc 呼叫）
--    注意：這是直接改 auth.users.encrypted_password（未在官方文件中保證的做法），
--    上線前請實測一次「重設後可用新密碼登入」。
-- =========================================================
create or replace function public.admin_reset_user_password(
  p_user_id uuid,
  p_new_password text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
begin
  if not private.is_admin() then
    raise exception '只有管理員可以重設他人密碼' using errcode = '42501';
  end if;

  if p_new_password is null or length(p_new_password) < 8 then
    raise exception '密碼至少需要 8 個字元' using errcode = '22023';
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception '找不到這個業務員' using errcode = 'P0002';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_user_id
   returning email into v_email;

  if v_email is null then
    raise exception '找不到這個帳號' using errcode = 'P0002';
  end if;

  -- 撤銷該業務員所有登入狀態，強制改用新密碼重新登入
  delete from auth.sessions where user_id = p_user_id;

  return v_email;
end;
$$;

revoke execute on function public.admin_reset_user_password(uuid, text) from public, anon;
grant execute on function public.admin_reset_user_password(uuid, text) to authenticated;

-- =========================================================
-- 9. 回填既有帳號的 profiles（姓名 / email）
-- =========================================================
insert into public.profiles (id, full_name, email)
select u.id, u.raw_user_meta_data ->> 'full_name', u.email
from auth.users u
on conflict (id) do update
  set full_name = coalesce(public.profiles.full_name, excluded.full_name),
      email     = coalesce(excluded.email, public.profiles.email);

-- =========================================================
-- 事後手動操作提醒：
-- 1. 到 Authentication > Users 手動新增業務員帳號（email + 密碼），
--    不開放自行註冊，帳號都由你這邊建立。
--    建立時可在 User Metadata 填 {"full_name":"王小明"}，之後業務員也能自己登入填寫。
-- 2. 要指定自己為管理員：
--      update public.profiles set is_admin = true where id = '<你的 user id>';
-- 3. 新增影片：
--      insert into public.videos (title, youtube_id, duration_sec, sort_order)
--      values ('第一課：保單健檢基礎', 'XXXXXXXXXXX', 600, 1);
-- =========================================================
