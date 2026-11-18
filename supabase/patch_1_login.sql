-- 패치: 로그인 실패 기록이 오류와 함께 취소되어 잠금이 작동하지 않던 문제 수정
-- 실패 시 오류를 내지 않고 {"ok": false, "error": "..."} 를 돌려주어 실패 기록이 남게 함
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
