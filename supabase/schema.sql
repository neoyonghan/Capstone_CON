-- =====================================================================
-- 명지전문대학 2026학년도 캡스톤디자인 경진대회 평가시스템 · Supabase
-- 1) 스키마 · 보안(RLS) · RPC   2) 데이터는 data.sql
-- Supabase 대시보드 → SQL Editor 에 이 파일 → data.sql 순서로 붙여 넣고 Run
-- 학생 학번·연락처는 저장하지 않음(성명만). 위원 전화번호는 bcrypt 해시만 저장.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- 기본 테이블 ----------
create table if not exists divisions (
  name       text primary key,
  sort_order smallint not null unique
);

create table if not exists judges (
  id         text primary key,                       -- j1a, j1b ...
  division   text not null references divisions(name),
  name       text not null,
  org        text,
  title      text,
  phone_hash text,                                   -- crypt(전화번호 숫자, gen_salt('bf')) · 원문 저장 안 함
  active     boolean not null default true
);

create table if not exists teams (
  booth      smallint primary key check (booth between 1 and 99),
  division   text not null references divisions(name),
  dept       text not null,
  advisor    text,
  team_name  text not null,
  work_title text not null,
  company    text                                    -- 참여업체(상장 표기용, 없으면 null)
);

create table if not exists team_members (
  id         bigint generated always as identity primary key,
  booth      smallint not null references teams(booth) on delete cascade,
  seq        smallint not null,
  name       text not null,
  is_leader  boolean not null default false,
  note       text,                                   -- 명단 비고(대표·중복 등)
  unique (booth, seq)
);

create table if not exists award_quota (
  division text primary key references divisions(name),
  grand    smallint not null default 0 check (grand  between 0 and 1),  -- 대상
  gold     smallint not null default 0 check (gold   >= 0),             -- 금상
  silver   smallint not null default 0 check (silver >= 0),             -- 은상
  bronze   smallint not null default 0 check (bronze >= 0),             -- 동상
  merit    smallint not null default 0 check (merit  >= 0)              -- 장려상
);

create table if not exists settings (
  id        boolean primary key default true check (id),   -- 한 줄만
  locked    boolean not null default false,                -- 심사 마감
  slot_min  smallint not null default 10,
  updated_at timestamptz not null default now()
);

create table if not exists scores (
  judge_id   text not null references judges(id),
  booth      smallint not null references teams(booth),
  items      smallint[] not null,
  total      smallint generated always as (items[1]+items[2]+items[3]+items[4]+items[5]+items[6]+items[7]+items[8]+items[9]+items[10]) stored,
  absent     boolean not null default false,
  memo       text check (char_length(memo) <= 300),
  rev        integer not null default 1,                   -- 동시 저장 감지용
  updated_at timestamptz not null default now(),
  updated_by text,                                         -- 'judge:j1a' 또는 'admin:<uid>'
  primary key (judge_id, booth),
  constraint items_valid check (
    array_length(items, 1) = 10 and 5 <= all(items) and 10 >= all(items))
);

create table if not exists score_history (
  id         bigint generated always as identity primary key,
  judge_id   text not null,
  booth      smallint not null,
  items      smallint[],
  absent     boolean,
  memo       text,
  rev        integer,
  changed_at timestamptz not null default now(),
  changed_by text,
  action     text not null                                -- update / delete
);

create table if not exists judge_sessions (
  token      uuid primary key default gen_random_uuid(),
  judge_id   text not null references judges(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '2 days'
);

create table if not exists login_attempts (               -- 무차별 대입 방지
  id         bigint generated always as identity primary key,
  name_key   text not null,
  ok         boolean not null,
  at         timestamptz not null default now()
);

-- 관리자: Supabase Auth 사용자 중 이 표에 있는 사람
create table if not exists admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  note    text
);

-- ---------- 무결성 트리거 ----------
-- 위원은 담당 학부 팀만 채점
create or replace function trg_scores_division() returns trigger
language plpgsql as $$
begin
  if (select division from judges where id = new.judge_id) is distinct from
     (select division from teams  where booth = new.booth) then
    raise exception '담당 학부가 아닌 팀입니다 (위원 %, 부스 %)', new.judge_id, new.booth;
  end if;
  return new;
end $$;
drop trigger if exists scores_division on scores;
create trigger scores_division before insert or update on scores
  for each row execute function trg_scores_division();

-- 수정·삭제 이력 보관
create or replace function trg_scores_history() returns trigger
language plpgsql as $$
begin
  insert into score_history(judge_id, booth, items, absent, memo, rev, changed_by, action)
  values (old.judge_id, old.booth, old.items, old.absent, old.memo, old.rev,
          case when tg_op = 'UPDATE' then new.updated_by else old.updated_by end, lower(tg_op));
  return coalesce(new, old);
end $$;
drop trigger if exists scores_history on scores;
create trigger scores_history after update or delete on scores
  for each row execute function trg_scores_history();

-- ---------- 권한(RLS) ----------
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

do $$ declare t text; begin
  foreach t in array array['divisions','judges','teams','team_members','award_quota','settings',
                           'scores','score_history','judge_sessions','login_attempts','admins'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (is_admin()) with check (is_admin())', t);
  end loop;
end $$;
-- 위원(익명)은 테이블에 직접 접근하지 못하고, 아래 RPC로만 읽고 씀

-- ---------- 위원용 RPC ----------
-- 로그인: 성명 + 전화번호 → 세션 토큰 (10분에 5회 실패 시 잠금, 실패는 ok:false로 반환)
create or replace function judge_login(p_name text, p_phone text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare k text := regexp_replace(coalesce(p_name,''), '\s', '', 'g');
        d text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
        j judges; tok uuid;
begin
  if (select count(*) from login_attempts where name_key = k and not ok and at > now() - interval '10 minutes') >= 5 then
    return json_build_object('ok', false, 'error', '입력이 여러 번 틀려 잠시 잠겼습니다. 10분 뒤 다시 시도하세요.');
  end if;
  select * into j from judges
   where active and regexp_replace(name, '\s', '', 'g') = k
     and phone_hash is not null and phone_hash = crypt(d, phone_hash)
   limit 1;
  insert into login_attempts(name_key, ok) values (k, j.id is not null);
  if j.id is null then
    return json_build_object('ok', false, 'error', '성명 또는 전화번호가 맞지 않습니다.');
  end if;
  insert into judge_sessions(judge_id) values (j.id) returning token into tok;
  return json_build_object('ok', true, 'token', tok, 'judge_id', j.id, 'name', j.name, 'division', j.division);
end $$;

create or replace function session_judge(p_token uuid) returns judges
language plpgsql stable security definer set search_path = public as $$
declare j judges;
begin
  select jd.* into j from judge_sessions s join judges jd on jd.id = s.judge_id
   where s.token = p_token and s.expires_at > now() and jd.active;
  if j.id is null then raise exception '로그인이 만료되었습니다. 다시 로그인하세요.'; end if;
  return j;
end $$;

-- 내 담당 팀과 내가 제출한 점수
create or replace function judge_sheet(p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare j judges := session_judge(p_token);
begin
  return json_build_object(
    'judge',  json_build_object('id', j.id, 'name', j.name, 'org', j.org, 'division', j.division),
    'locked', (select locked from settings),
    'teams',  coalesce((select json_agg(json_build_object(
                  'booth', t.booth, 'dept', t.dept, 'advisor', t.advisor, 'team_name', t.team_name,
                  'work_title', t.work_title,
                  'score', (select json_build_object('items', s.items, 'total', s.total, 'absent', s.absent,
                                                     'memo', s.memo, 'rev', s.rev, 'updated_at', s.updated_at)
                              from scores s where s.judge_id = j.id and s.booth = t.booth))
                order by t.booth) from teams t where t.division = j.division), '[]'::json));
end $$;

-- 점수 제출: 마감·담당 학부·점수 범위·동시 저장(rev)을 서버에서 검사
create or replace function submit_score(p_token uuid, p_booth smallint, p_items smallint[],
                                        p_absent boolean, p_memo text, p_base_rev integer)
returns json language plpgsql security definer set search_path = public as $$
declare j judges := session_judge(p_token); cur scores; it smallint[];
begin
  if (select locked from settings) then raise exception '심사가 마감되어 제출할 수 없습니다.'; end if;
  it := case when p_absent then array_fill(5::smallint, array[10]) else p_items end;
  if array_length(it, 1) is distinct from 10 or not (5 <= all(it) and 10 >= all(it)) then
    raise exception '10개 항목 모두 5~10점으로 입력하세요.';
  end if;
  select * into cur from scores where judge_id = j.id and booth = p_booth for update;
  if coalesce(cur.rev, 0) <> coalesce(p_base_rev, 0) then
    raise exception 'conflict: 다른 기기에서 먼저 저장되었습니다 (현재 rev %).', coalesce(cur.rev, 0);
  end if;
  insert into scores(judge_id, booth, items, absent, memo, rev, updated_at, updated_by)
  values (j.id, p_booth, it, coalesce(p_absent,false), left(p_memo, 300), 1, now(), 'judge:' || j.id)
  on conflict (judge_id, booth) do update
     set items = excluded.items, absent = excluded.absent, memo = excluded.memo,
         rev = scores.rev + 1, updated_at = now(), updated_by = excluded.updated_by
  returning * into cur;
  return json_build_object('booth', cur.booth, 'total', cur.total, 'rev', cur.rev, 'updated_at', cur.updated_at);
end $$;

create or replace function judge_logout(p_token uuid) returns void
language sql security definer set search_path = public as $$
  delete from judge_sessions where token = p_token;
$$;

revoke all on function judge_login(text,text), session_judge(uuid), judge_sheet(uuid),
  submit_score(uuid,smallint,smallint[],boolean,text,integer), judge_logout(uuid) from public;
grant execute on function judge_login(text,text), judge_sheet(uuid),
  submit_score(uuid,smallint,smallint[],boolean,text,integer), judge_logout(uuid) to anon, authenticated;

-- ---------- 관리자용 보기 ----------
create or replace view team_results with (security_invoker = true) as
select t.booth, t.division, t.dept, t.team_name, t.work_title,
       count(s.*)                                         as sheets,
       round(avg(s.total)::numeric, 2)                    as avg_total,
       round(avg(s.items[4] + s.items[5]), 2)             as tech_avg,     -- 기술성 및 완성도 소계
       round(avg(s.items[1] + s.items[2] + s.items[3]), 2) as creat_avg,    -- 창의성 및 기획성 소계
       max(s.total) - min(s.total)                        as judge_gap,
       bool_and(s.absent)                                 as all_absent    -- true면 수상 제외
from teams t left join scores s on s.booth = t.booth
group by t.booth;


-- =====================================================================
-- 패치 2: 웹 화면(관리자 기능) 연결용 · SQL Editor에서 1회 Run
--  - 관리자 여부 확인, 위원 전화번호 등록, 관리자 대리 입력
--  - 위원 화면에 학부 이름·참여업체 포함
--  - 상장 직인 이미지용 비공개 저장소(관리자만 읽기)
-- 여러 번 실행해도 안전합니다.
-- =====================================================================

-- 관리자 여부: 로그인한 관리자 계정이면 true
grant execute on function is_admin() to anon, authenticated;

-- 위원 전화번호 등록(관리자만) · 원문은 저장하지 않고 bcrypt 값만 저장
create or replace function admin_set_phone(p_judge text, p_phone text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare d text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
begin
  if not is_admin() then raise exception '관리자만 할 수 있습니다.'; end if;
  if length(d) not between 10 and 11 then raise exception '전화번호는 숫자 10~11자리로 입력하세요.'; end if;
  update judges set phone_hash = crypt(d, gen_salt('bf')) where id = p_judge;
  if not found then raise exception '없는 위원입니다: %', p_judge; end if;
end $$;

-- 관리자 대리 입력(위원 태블릿 고장 등) · 마감·범위·동시 저장 검사는 위원과 같음
create or replace function admin_submit_score(p_judge text, p_booth smallint, p_items smallint[],
                                              p_absent boolean, p_memo text, p_base_rev integer)
returns json language plpgsql security definer set search_path = public as $$
declare cur scores; it smallint[];
begin
  if not is_admin() then raise exception '관리자만 할 수 있습니다.'; end if;
  if (select locked from settings) then raise exception '심사가 마감되어 제출할 수 없습니다.'; end if;
  it := case when p_absent then array_fill(5::smallint, array[10]) else p_items end;
  if array_length(it, 1) is distinct from 10 or not (5 <= all(it) and 10 >= all(it)) then
    raise exception '10개 항목 모두 5~10점으로 입력하세요.';
  end if;
  select * into cur from scores where judge_id = p_judge and booth = p_booth for update;
  if coalesce(cur.rev, 0) <> coalesce(p_base_rev, 0) then
    raise exception 'conflict: 다른 기기에서 먼저 저장되었습니다 (현재 rev %).', coalesce(cur.rev, 0);
  end if;
  insert into scores(judge_id, booth, items, absent, memo, rev, updated_at, updated_by)
  values (p_judge, p_booth, it, coalesce(p_absent,false), left(p_memo, 300), 1, now(), 'admin:' || auth.uid())
  on conflict (judge_id, booth) do update
     set items = excluded.items, absent = excluded.absent, memo = excluded.memo,
         rev = scores.rev + 1, updated_at = now(), updated_by = excluded.updated_by
  returning * into cur;
  return json_build_object('booth', cur.booth, 'total', cur.total, 'rev', cur.rev, 'updated_at', cur.updated_at);
end $$;

revoke all on function admin_set_phone(text,text),
  admin_submit_score(text,smallint,smallint[],boolean,text,integer) from public;
grant execute on function admin_set_phone(text,text),
  admin_submit_score(text,smallint,smallint[],boolean,text,integer) to authenticated;

-- 위원 화면용: 학부·참여업체·마감 포함 (기존 judge_sheet 교체)
create or replace function judge_sheet(p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare j judges := session_judge(p_token);
begin
  return json_build_object(
    'judge',  json_build_object('id', j.id, 'name', j.name, 'org', j.org, 'title', j.title, 'division', j.division),
    'locked', (select locked from settings),
    'slot_min', (select slot_min from settings),
    'teams',  coalesce((select json_agg(json_build_object(
                  'booth', t.booth, 'division', t.division, 'dept', t.dept, 'advisor', t.advisor,
                  'team_name', t.team_name, 'work_title', t.work_title, 'company', t.company,
                  'score', (select json_build_object('items', s.items, 'total', s.total, 'absent', s.absent,
                                                     'memo', s.memo, 'rev', s.rev, 'updated_at', s.updated_at,
                                                     'updated_by', s.updated_by)
                              from scores s where s.judge_id = j.id and s.booth = t.booth))
                order by t.booth) from teams t where t.division = j.division), '[]'::json));
end $$;

-- 상장 직인 이미지: 비공개 버킷 private-assets (관리자만 읽기·올리기)
-- 대시보드 Storage → private-assets 에 cert-seal.png 를 올리면 상장에 찍힙니다.
insert into storage.buckets (id, name, public) values ('private-assets', 'private-assets', false)
on conflict (id) do nothing;
drop policy if exists "admin read private-assets" on storage.objects;
create policy "admin read private-assets" on storage.objects for select to authenticated
  using (bucket_id = 'private-assets' and public.is_admin());
drop policy if exists "admin write private-assets" on storage.objects;
create policy "admin write private-assets" on storage.objects for insert to authenticated
  with check (bucket_id = 'private-assets' and public.is_admin());
