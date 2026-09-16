-- =========================================================
-- 業務員影片研習系統 — Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可
-- =========================================================

-- 1. profiles：對應 auth.users，多加 is_admin 欄位
create table if not exists public.profiles (
  id uuid references auth.users(id) on delete cascade primary key,
  full_name text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

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
-- 新帳號註冊時自動建立 profiles 資料列
-- =========================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- =========================================================
-- Row Level Security
-- =========================================================
alter table public.profiles enable row level security;
alter table public.videos enable row level security;
alter table public.watch_progress enable row level security;

-- profiles：自己可讀自己；admin 可讀全部
create policy "read own profile" on public.profiles
  for select using (auth.uid() = id);

create policy "admin read all profiles" on public.profiles
  for select using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin)
  );

-- videos：登入使用者皆可讀（維護請直接在 Supabase 後台操作，或另開 admin 專用寫入政策）
create policy "authenticated read videos" on public.videos
  for select using (auth.role() = 'authenticated');

-- watch_progress：使用者只能讀寫自己的進度
create policy "user manage own progress" on public.watch_progress
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- watch_progress：admin 可讀全部人的進度（不給寫，避免誤改）
create policy "admin read all progress" on public.watch_progress
  for select using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin)
  );

-- =========================================================
-- 事後手動操作提醒：
-- 1. 到 Authentication > Users 手動新增業務員帳號（email + 密碼），
--    不開放自行註冊，帳號都由你這邊建立。
-- 2. 要指定自己為管理員：
--      update public.profiles set is_admin = true where id = '<你的 user id>';
-- 3. 新增影片：
--      insert into public.videos (title, youtube_id, duration_sec, sort_order)
--      values ('第一課：保單健檢基礎', 'XXXXXXXXXXX', 600, 1);
-- =========================================================
