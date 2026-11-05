-- =========================================================
-- 宸功人士（名單 / 組織圖 / 我的檔案）— Supabase Schema
-- 在 Supabase 專案的 SQL Editor 貼上整段執行即可（可重複執行，不會壞）
-- 專案：dwesqvutdlvnmajxdcpn（與 video-training / sharing / 宸功專區共用）
--
-- 前置條件（請先執行過）：
--   1. video-training/supabase-schema.sql
--      → 提供 auth.users / public.profiles / private schema / private.is_admin()
--   2. supabase-schema-goals.sql（選用，但建議先跑；本檔會重用 private.set_updated_at()）
--
-- 本檔建立：
--   public.member_ranks          職級對照表（AG / AS / SAS / UM / AM）
--   public.member_profiles       1:1 成員資料（與 profiles 分開，避免 email / is_admin 外洩）
--   private.member_profiles_*    自動建列、組織圖防迴圈、職級/主管欄位保護
--
-- 職級鏈（sort_order 由小到大）：AG 專員 → AS 業務主任 → SAS 業務襄理
--                               → UM 區經理 → AM 處經理（最高，組織圖根節點）
-- 職級與所屬主管：本人可在「我的檔案」自行調整（最高職級 AM 除外，只有管理員能設定）。
--   public.get_member_directory() 名單／組織圖用（security definer，只回顯示欄位）
--   storage bucket avatars       頭像（public bucket，僅本人可寫）
--
-- 「團隊目標牆」與「年度目標」請接著執行 supabase-schema-goal-annual.sql
-- 執行順序：本檔 → supabase-schema-goal-annual.sql
-- =========================================================

-- =========================================================
-- 0. 前置檢查（缺東西就立刻停下，避免建出半套結構）
-- =========================================================
do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception '缺少 public.profiles：請先執行 video-training/supabase-schema.sql';
  end if;
  if to_regprocedure('private.is_admin()') is null then
    raise exception '缺少 private.is_admin()：請先執行 video-training/supabase-schema.sql';
  end if;
end
$$;

create schema if not exists private;

-- private.is_admin()：沿用既有定義（若不存在則補上）
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

-- updated_at 共用函式（goals 檔已建立過就 replace）
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

-- =========================================================
-- 1. member_ranks：職級對照表
--    code 只在程式內部使用，畫面一律顯示 label。
--    要新增職級（例如「業務襄理A」）只要 insert 一列，不必改 schema。
-- =========================================================
create table if not exists public.member_ranks (
  code        text primary key,
  label       text not null,
  sort_order  integer not null default 0,
  is_manager  boolean not null default false,
  created_at  timestamptz not null default now(),
  constraint member_ranks_code_format check (code ~ '^[A-Z][A-Z0-9_]{1,15}$'),
  constraint member_ranks_label_len check (char_length(btrim(label)) between 1 and 20)
);

-- 舊代碼遷移（若之前跑過舊版：REP → AG、CM → AM）
-- member_profiles.rank_code 的 FK 是 on update cascade，改名時成員會一起被搬過去。
do $$
begin
  if exists (select 1 from public.member_ranks where code = 'REP')
     and not exists (select 1 from public.member_ranks where code = 'AG') then
    update public.member_ranks set code = 'AG' where code = 'REP';
  end if;
  if exists (select 1 from public.member_ranks where code = 'CM')
     and not exists (select 1 from public.member_ranks where code = 'AM') then
    update public.member_ranks set code = 'AM' where code = 'CM';
  end if;
end
$$;

-- 正式職級鏈：AG → AS → SAS → UM → AM
-- label 只是顯示文字，要改名稱只要 update 這張表，不必動程式。
insert into public.member_ranks (code, label, sort_order, is_manager) values
  ('AG',  '專員',     1, false),
  ('AS',  '業務主任', 2, true),
  ('SAS', '業務襄理', 3, true),
  ('UM',  '區經理',   4, true),
  ('AM',  '處經理',   5, true)
on conflict (code) do update
  set label      = excluded.label,
      sort_order = excluded.sort_order,
      is_manager = excluded.is_manager;

alter table public.member_ranks enable row level security;
revoke all on public.member_ranks from anon;
grant select, insert, update, delete on public.member_ranks to authenticated;

drop policy if exists "read ranks" on public.member_ranks;
create policy "read ranks" on public.member_ranks
  for select to authenticated
  using ( true );

drop policy if exists "admin write ranks" on public.member_ranks;
create policy "admin write ranks" on public.member_ranks
  for all to authenticated
  using ( (select private.is_admin()) )
  with check ( (select private.is_admin()) );

-- =========================================================
-- 2. member_profiles：成員的公開資料（1:1 對 profiles）
--    - 刻意獨立成另一張表：名單只需要姓名／職級／主管／照片／簡介，
--      不需要把 profiles.email、profiles.is_admin 一起曝露出去。
--    - supervisor_id 自我參照，根節點 = null。
-- =========================================================
create table if not exists public.member_profiles (
  user_id           uuid primary key references auth.users(id) on delete cascade,
  rank_code         text not null default 'AG'
                      references public.member_ranks(code) on update cascade on delete restrict,
  supervisor_id     uuid references public.member_profiles(user_id) on delete set null,
  avatar_path       text,
  avatar_updated_at timestamptz,
  bio               text,
  ig_url            text,
  fb_url            text,
  line_url          text,
  linkedin_url      text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint member_profiles_not_own_supervisor check (supervisor_id is null or supervisor_id <> user_id),
  constraint member_profiles_bio_len check (bio is null or char_length(bio) <= 500),
  -- 頭像路徑固定 <uid>/<檔名>，避免有人把檔案指到別人資料夾
  constraint member_profiles_avatar_path check (
    avatar_path is null
    or avatar_path ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[A-Za-z0-9._-]+$'
  ),
  constraint member_profiles_ig_url check (ig_url is null or ig_url ~ '^https?://'),
  constraint member_profiles_fb_url check (fb_url is null or fb_url ~ '^https?://'),
  constraint member_profiles_line_url check (line_url is null or line_url ~ '^https?://'),
  constraint member_profiles_linkedin_url check (linkedin_url is null or linkedin_url ~ '^https?://')
);

create index if not exists member_profiles_supervisor_idx on public.member_profiles (supervisor_id);
create index if not exists member_profiles_rank_idx on public.member_profiles (rank_code);

comment on table public.member_profiles is
  '宸功人士名單／組織圖用的公開資料；刻意與 public.profiles 分開，避免 email 與 is_admin 外洩。';

drop trigger if exists trg_member_profiles_updated on public.member_profiles;
create trigger trg_member_profiles_updated
  before update on public.member_profiles
  for each row execute procedure private.set_updated_at();

-- =========================================================
-- 3. 新帳號自動建立 member_profiles 一列（預設職級 AG、無主管）
--    並回填既有帳號。
--    注意：這是 security definer，因此可以寫入 RLS 後面的表。
-- =========================================================
create or replace function private.create_member_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.member_profiles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke execute on function private.create_member_profile() from public, anon;
grant execute on function private.create_member_profile() to authenticated, service_role;

drop trigger if exists trg_auth_user_create_member on auth.users;
create trigger trg_auth_user_create_member
  after insert on auth.users
  for each row execute procedure private.create_member_profile();

-- 回填：已經存在的 profiles 補上 member_profiles
insert into public.member_profiles (user_id)
select p.id from public.profiles p
on conflict (user_id) do nothing;

-- 舊代碼收尾：若同時存在 REP/AG 或 CM/AM（跑過半套的情況），
-- 先把成員搬到新代碼，再刪掉沒人用的舊職級列。
do $$
begin
  if to_regclass('public.member_ranks') is not null and to_regclass('public.member_profiles') is not null then
    update public.member_profiles set rank_code = 'AG' where rank_code = 'REP';
    update public.member_profiles set rank_code = 'AM' where rank_code = 'CM';
    delete from public.member_ranks
     where code in ('REP', 'CM')
       and not exists (select 1 from public.member_profiles mp where mp.rank_code = public.member_ranks.code);
  end if;
end
$$;

-- =========================================================
-- 4. 組織圖防迴圈
--    例：A 的主管設 B，之後又想把 B 的主管設成 A → 拒絕。
--    以 security definer 往上追，最多 32 層（超過視為異常）。
-- =========================================================
create or replace function private.member_profiles_check_supervisor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cursor uuid := new.supervisor_id;
  v_parent uuid;
  v_depth  integer := 0;
begin
  if new.supervisor_id is null then
    return new;
  end if;

  if new.supervisor_id = new.user_id then
    raise exception '主管不能是自己' using errcode = '23514';
  end if;

  while v_cursor is not null and v_depth < 32 loop
    if v_cursor = new.user_id then
      raise exception '組織圖不可形成迴圈：設定的主管鏈最後會回到自己'
        using errcode = '23514';
    end if;

    select mp.supervisor_id into v_parent
      from public.member_profiles mp
     where mp.user_id = v_cursor;

    v_cursor := v_parent;
    v_depth := v_depth + 1;
  end loop;

  if v_cursor is not null then
    raise exception '組織圖層級超過 32 層，請檢查主管設定是否異常'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke execute on function private.member_profiles_check_supervisor() from public, anon;
grant execute on function private.member_profiles_check_supervisor() to authenticated, service_role;

drop trigger if exists trg_member_profiles_no_cycle on public.member_profiles;
create trigger trg_member_profiles_no_cycle
  before insert or update of supervisor_id on public.member_profiles
  for each row execute procedure private.member_profiles_check_supervisor();

-- =========================================================
-- 5. 職級 / 所屬主管：本人可自行調整（最高職級除外）
--    - 一般同仁可以改自己的照片、簡介、社群連結，也可以調整自己的職級與所屬主管
--      （members.html →「我的檔案」→「編輯我的檔案」）。
--    - 最高職級（sort_order 最大者，目前 AM 處經理）只有管理員能設定，
--      而且拿到最高職級後也不能自己降級（避免降級後再也設不回來），
--      避免多人把自己設成根節點，組織圖就會長出好幾個根。
--    - 管理員可以改任何人；service_role 與 SQL Editor（無 JWT 的直接連線）不受限制。
--    - 「不能選自己當主管」由 CHECK、「不可造成迴圈」由第 4 節的 trigger 把關。
-- =========================================================
create or replace function private.member_profiles_protect_fields()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    ''
  );
  v_uid  uuid := (select auth.uid());
  v_top_rank text := (
    select r.code from public.member_ranks r
     order by r.sort_order desc, r.code
     limit 1
  );
begin
  -- service_role（保顧+ / 排程 / 後台）與 SQL Editor 直接放行
  if v_role = 'service_role' then
    return new;
  end if;
  if v_role = '' and v_uid is null then
    return new;
  end if;
  if (select private.is_admin()) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- 本人補建自己的資料列（正常情況由 auth.users trigger 建好，這裡只是保險）
    if v_uid is null or new.user_id is distinct from v_uid then
      raise exception '不可代其他成員建立資料列' using errcode = '42501';
    end if;
    if v_top_rank is not null and new.rank_code = v_top_rank then
      raise exception '最高職級（% 處經理）只能由管理員設定', v_top_rank using errcode = '42501';
    end if;
    return new;
  end if;

  -- 不允許把資料列改成別人的（RLS 也會擋，這裡再加一層）
  if new.user_id is distinct from old.user_id then
    raise exception '不可變更成員帳號' using errcode = '42501';
  end if;

  if new.rank_code is distinct from old.rank_code then
    if old.user_id is distinct from v_uid then
      raise exception '只能調整自己的職級' using errcode = '42501';
    end if;
    if v_top_rank is not null
       and (new.rank_code = v_top_rank or old.rank_code = v_top_rank) then
      raise exception '最高職級（% 處經理）只能由管理員調整', v_top_rank using errcode = '42501';
    end if;
  end if;

  if new.supervisor_id is distinct from old.supervisor_id then
    if old.user_id is distinct from v_uid then
      raise exception '只能調整自己的所屬主管' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function private.member_profiles_protect_fields() from public, anon;
grant execute on function private.member_profiles_protect_fields() to authenticated, service_role;

drop trigger if exists trg_member_profiles_protect on public.member_profiles;
create trigger trg_member_profiles_protect
  before insert or update on public.member_profiles
  for each row execute procedure private.member_profiles_protect_fields();

-- =========================================================
-- 6. Row Level Security
--    名單／組織圖走 security definer 的 get_member_directory()，
--    因此資料表本身維持「只能讀自己那一列」，隱私界線最清楚。
-- =========================================================
alter table public.member_profiles enable row level security;
revoke all on public.member_profiles from anon;
grant select, insert, update, delete on public.member_profiles to authenticated;

drop policy if exists "read own member profile" on public.member_profiles;
create policy "read own member profile" on public.member_profiles
  for select to authenticated
  using ( (select auth.uid()) = user_id );

drop policy if exists "admin read member profiles" on public.member_profiles;
create policy "admin read member profiles" on public.member_profiles
  for select to authenticated
  using ( (select private.is_admin()) );

drop policy if exists "insert own member profile" on public.member_profiles;
create policy "insert own member profile" on public.member_profiles
  for insert to authenticated
  with check ( (select auth.uid()) = user_id );

drop policy if exists "admin insert member profiles" on public.member_profiles;
create policy "admin insert member profiles" on public.member_profiles
  for insert to authenticated
  with check ( (select private.is_admin()) );

drop policy if exists "update own member profile" on public.member_profiles;
create policy "update own member profile" on public.member_profiles
  for update to authenticated
  using ( (select auth.uid()) = user_id )
  with check ( (select auth.uid()) = user_id );

drop policy if exists "admin update member profiles" on public.member_profiles;
create policy "admin update member profiles" on public.member_profiles
  for update to authenticated
  using ( (select private.is_admin()) )
  with check ( (select private.is_admin()) );

drop policy if exists "admin delete member profiles" on public.member_profiles;
create policy "admin delete member profiles" on public.member_profiles
  for delete to authenticated
  using ( (select private.is_admin()) );

-- =========================================================
-- 7. get_member_directory()：名單與組織圖的唯一資料來源
--    - security definer：可讀取全部成員，但只輸出「顯示用」欄位。
--    - 不回傳 email、is_admin。
--    - 必須登入才能呼叫（anon 直接收回執行權限）。
--    - 顯示名稱：profiles.full_name 空白時給「未具名同仁」，不拿 email 當名字。
-- =========================================================
drop function if exists public.get_member_directory();

create or replace function public.get_member_directory()
returns table (
  user_id           uuid,
  display_name      text,
  rank_code         text,
  rank_label        text,
  rank_order        integer,
  is_manager        boolean,
  supervisor_id     uuid,
  supervisor_name   text,
  avatar_path       text,
  avatar_updated_at timestamptz,
  bio               text,
  ig_url            text,
  fb_url            text,
  line_url          text,
  linkedin_url      text,
  updated_at        timestamptz
)
language sql
security definer
set search_path = ''
stable
as $$
  select
    mp.user_id,
    coalesce(nullif(btrim(p.full_name), ''), '未具名同仁') as display_name,
    mp.rank_code,
    coalesce(r.label, mp.rank_code)                        as rank_label,
    coalesce(r.sort_order, 0)                              as rank_order,
    coalesce(r.is_manager, false)                          as is_manager,
    mp.supervisor_id,
    case
      when sp.id is null then null
      else coalesce(nullif(btrim(sp.full_name), ''), '未具名主管')
    end                                                    as supervisor_name,
    mp.avatar_path,
    mp.avatar_updated_at,
    mp.bio,
    mp.ig_url,
    mp.fb_url,
    mp.line_url,
    mp.linkedin_url,
    mp.updated_at
  from public.member_profiles mp
  join public.profiles p on p.id = mp.user_id
  left join public.member_ranks r on r.code = mp.rank_code
  left join public.profiles sp on sp.id = mp.supervisor_id
  where (select auth.uid()) is not null
  order by coalesce(r.sort_order, 0), coalesce(p.full_name, ''), mp.user_id;
$$;

revoke all on function public.get_member_directory() from public, anon;
grant execute on function public.get_member_directory() to authenticated;

-- =========================================================
-- 8. Storage：avatars 頭像 bucket（public 讀取、本人可寫）
--    - 公開 bucket：任何拿到網址的人都能看圖（未登入也可），
--      但名單其他欄位仍走 RLS / RPC 保護。
--    - 寫入限制在自己的 <uid>/ 資料夾底下。
--    - 若這段因權限失敗，請依 members-SETUP.md 用 Dashboard 手動建立。
-- =========================================================
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
  on conflict (id) do update
    set public             = true,
        file_size_limit    = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;
exception
  when insufficient_privilege then
    raise notice '無法自動建立 avatars bucket（權限不足），請改用 Dashboard → Storage 手動建立（public、2MB、image/jpeg/png/webp）';
  when others then
    raise notice '建立 avatars bucket 時發生錯誤：%（可改用 Dashboard 手動建立）', sqlerrm;
end
$$;

-- 讀：登入者可以列出頭像（public bucket 的圖片網址本來就不經 policy）
-- 寫：只能動自己 <uid>/ 底下的檔案
-- （storage.objects 屬於 storage 擴充，若目前角色沒有建立 policy 的權限，
--   這裡只會提出 notice，不會中斷整支腳本；也可改用 Dashboard 手動建立。）
do $$
begin
  execute 'drop policy if exists "avatars read for members" on storage.objects';
  execute 'create policy "avatars read for members" on storage.objects '
       || 'for select to authenticated using (bucket_id = ''avatars'')';

  execute 'drop policy if exists "avatars owner insert" on storage.objects';
  execute 'create policy "avatars owner insert" on storage.objects '
       || 'for insert to authenticated with check (bucket_id = ''avatars'' '
       || 'and (storage.foldername(name))[1] = (select auth.uid())::text)';

  execute 'drop policy if exists "avatars owner update" on storage.objects';
  execute 'create policy "avatars owner update" on storage.objects '
       || 'for update to authenticated using (bucket_id = ''avatars'' '
       || 'and (storage.foldername(name))[1] = (select auth.uid())::text) '
       || 'with check (bucket_id = ''avatars'' '
       || 'and (storage.foldername(name))[1] = (select auth.uid())::text)';

  execute 'drop policy if exists "avatars owner delete" on storage.objects';
  execute 'create policy "avatars owner delete" on storage.objects '
       || 'for delete to authenticated using (bucket_id = ''avatars'' '
       || 'and (storage.foldername(name))[1] = (select auth.uid())::text)';
exception
  when insufficient_privilege then
    raise notice '無法建立 storage.objects 的頭像 policy（權限不足），請改用 Dashboard → Storage → avatars → Policies 手動建立';
  when others then
    raise notice '建立頭像 policy 時發生錯誤：%（可改用 Dashboard 手動建立）', sqlerrm;
end
$$;

-- =========================================================
-- 9. 讓 PostgREST 立即認得新表 / 新欄位 / 新函式
-- =========================================================
notify pgrst, 'reload schema';

-- =========================================================
-- 事後手動操作提醒：
-- 1. 指定某人的職級與主管（本人可在 members.html →「我的檔案」→ 編輯自行調整；
--    最高職級 AM 處經理只有管理員能設定；SQL Editor 直接改也可以）：
--      update public.member_profiles
--         set rank_code = 'UM', supervisor_id = '<上層的 user id>'
--       where user_id = '<本人的 user id>';
--    （管理員前端：accounts.html 的「職級」「所屬主管」下拉選單）
--
-- 2. 檢查組織圖是否還有沒接上的人：
--      select p.full_name, mp.rank_code, mp.supervisor_id
--        from public.member_profiles mp
--        join public.profiles p on p.id = mp.user_id
--       where mp.supervisor_id is null
--       order by p.full_name;
--
-- 3. 驗證名單函式（以登入者身分呼叫）：
--      select * from public.get_member_directory();
--
-- 4. 若前端顯示「找不到函式 get_member_directory」：
--      在 SQL Editor 執行  notify pgrst, 'reload schema';  再重新整理。
-- =========================================================
