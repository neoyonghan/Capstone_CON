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
