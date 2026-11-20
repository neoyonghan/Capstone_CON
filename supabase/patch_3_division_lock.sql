-- =====================================================================
-- 패치 3: 학부별 마감 · SQL Editor에서 1회 Run (여러 번 실행해도 안전)
--  settings.locked      : 전체 마감
--  settings.locked_divs : 마감된 학부 이름 목록
-- 위원 제출·관리자 대리 입력은 그 위원 학부가 마감됐으면 서버에서 거부
-- =====================================================================
alter table settings add column if not exists locked_divs text[] not null default '{}';

create or replace function division_locked(p_division text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select locked or p_division = any(locked_divs) from settings), false);
$$;
grant execute on function division_locked(text) to anon, authenticated;

create or replace function submit_score(p_token uuid, p_booth smallint, p_items smallint[],
                                        p_absent boolean, p_memo text, p_base_rev integer)
returns json language plpgsql security definer set search_path = public as $$
declare j judges := session_judge(p_token); cur scores; it smallint[];
begin
  if division_locked(j.division) then raise exception '이 학부 심사가 마감되어 제출할 수 없습니다.'; end if;
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

create or replace function admin_submit_score(p_judge text, p_booth smallint, p_items smallint[],
                                              p_absent boolean, p_memo text, p_base_rev integer)
returns json language plpgsql security definer set search_path = public as $$
declare cur scores; it smallint[];
begin
  if not is_admin() then raise exception '관리자만 할 수 있습니다.'; end if;
  if division_locked((select division from judges where id = p_judge)) then raise exception '이 학부 심사가 마감되어 제출할 수 없습니다.'; end if;
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

create or replace function judge_sheet(p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare j judges := session_judge(p_token);
begin
  return json_build_object(
    'judge',  json_build_object('id', j.id, 'name', j.name, 'org', j.org, 'title', j.title, 'division', j.division),
    'locked', division_locked(j.division),
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
