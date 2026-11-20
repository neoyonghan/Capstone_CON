-- =====================================================================
-- 패치 5: 운영 보완 · SQL Editor에서 1회 Run (여러 번 실행해도 안전)
--  1) 위원 표기 정정: 플라잉스톤 · 김태용 · 임새헌
--  2) 로그인 잠금을 기기별로: 한 기기 10분 5회 실패 → 그 기기만 잠김
--     같은 이름으로 10분 30회 실패(여러 기기) → 그 위원 전체 잠김, 관리자가 해제
--  3) 행사 정보: 학년도·시상일을 설정 화면에서 바꿈
--  4) 점수 수정 이력 조회용 색인
-- =====================================================================

-- 1) 위원 표기 정정
update judges set org  = '플라잉스톤' where id = 'j2a' and org  = '플랑스톤';
update judges set name = '김태용'     where id = 'j3a' and name = '김태웅';
update judges set name = '임새헌'     where id = 'j3b' and name = '임새현';

-- 2) 로그인 잠금
alter table login_attempts add column if not exists device text not null default '';
create index if not exists login_attempts_recent on login_attempts (name_key, at);

drop function if exists judge_login(text, text);
create or replace function judge_login(p_name text, p_phone text, p_device text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare k  text := regexp_replace(coalesce(p_name,''), '\s', '', 'g');
        d  text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
        dv text := left(regexp_replace(coalesce(p_device,''), '[^A-Za-z0-9-]', '', 'g'), 64);
        j judges; tok uuid;
begin
  -- 이 기기에서만 10분에 5회 실패 → 이 기기 잠금
  if (select count(*) from login_attempts
       where name_key = k and device = dv and not ok and at > now() - interval '10 minutes') >= 5 then
    return json_build_object('ok', false, 'error', '이 기기에서 입력이 여러 번 틀려 10분 동안 잠겼습니다. 운영본부에 해제를 요청하거나 10분 뒤 다시 시도하세요.');
  end if;
  -- 같은 이름으로 여러 기기에서 10분에 30회 실패 → 그 위원 전체 잠금 (번호 맞히기 방지)
  if (select count(*) from login_attempts
       where name_key = k and not ok and at > now() - interval '10 minutes') >= 30 then
    return json_build_object('ok', false, 'error', '이 위원의 로그인이 잠겼습니다. 운영본부에 해제를 요청하세요.');
  end if;
  select * into j from judges
   where active and regexp_replace(name, '\s', '', 'g') = k
     and phone_hash is not null and phone_hash = crypt(d, phone_hash)
   limit 1;
  insert into login_attempts(name_key, ok, device) values (k, j.id is not null, dv);
  if j.id is null then
    return json_build_object('ok', false, 'error', '성명 또는 전화번호가 맞지 않습니다.');
  end if;
  insert into judge_sessions(judge_id) values (j.id) returning token into tok;
  return json_build_object('ok', true, 'token', tok, 'judge_id', j.id, 'name', j.name, 'division', j.division);
end $$;
revoke all on function judge_login(text, text, text) from public;
grant execute on function judge_login(text, text, text) to anon, authenticated;

-- 관리자: 위원별 최근 10분 실패 현황
create or replace function admin_login_locks() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception '관리자만 할 수 있습니다.'; end if;
  return coalesce((
    select json_agg(x order by x.judge_id) from (
      select j.id as judge_id, j.name, j.division,
             count(a.id)::int as fails,
             count(distinct a.device)::int as devices,
             count(a.id) >= 30 as locked,
             coalesce((select max(c) >= 5 from (select count(*) c from login_attempts b
                        where b.name_key = regexp_replace(j.name, '\s', '', 'g') and not b.ok
                          and b.at > now() - interval '10 minutes' group by b.device) z), false) as device_locked
        from judges j
        left join login_attempts a on a.name_key = regexp_replace(j.name, '\s', '', 'g')
                                  and not a.ok and a.at > now() - interval '10 minutes'
       where j.active
       group by j.id, j.name, j.division) x), '[]'::json);
end $$;

-- 관리자: 위원 잠금 해제 (실패 기록 삭제, 지운 건수 반환)
create or replace function admin_unlock_judge(p_judge text) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not is_admin() then raise exception '관리자만 할 수 있습니다.'; end if;
  delete from login_attempts
   where not ok and name_key = (select regexp_replace(name, '\s', '', 'g') from judges where id = p_judge);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function admin_login_locks(), admin_unlock_judge(text) from public, anon;
grant execute on function admin_login_locks(), admin_unlock_judge(text) to authenticated;

-- 3) 행사 정보
alter table settings add column if not exists event_year smallint not null default 2026;
alter table settings add column if not exists award_date date     not null default '2026-11-20';

create or replace function event_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('year', event_year, 'award_date', award_date) from settings limit 1;
$$;
revoke all on function event_info() from public;
grant execute on function event_info() to anon, authenticated;

-- 4) 점수 수정 이력 조회용 색인 (관리자만 읽음: admin_all 정책)
create index if not exists score_history_booth on score_history (booth, changed_at);

-- (선택) 행사가 끝난 뒤 정리: 만료된 위원 세션과 7일 지난 로그인 기록 삭제
-- delete from judge_sessions where expires_at < now();
-- delete from login_attempts where at < now() - interval '7 days';

-- 확인
select (select json_agg(json_build_object('id', id, 'name', name, 'org', org) order by id) from judges) as judges,
       event_info() as event;
