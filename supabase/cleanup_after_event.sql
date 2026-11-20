-- =====================================================================
-- 행사 후 정리 · SQL Editor에서 Run (여러 번 실행해도 안전)
--  기본: 만료된 위원 세션, 7일 지난 로그인 시도 기록만 지움
--  점수·점수 수정 이력·명단은 지우지 않음
-- =====================================================================

-- 1) 지우기 전 현황
select 'judge_sessions(만료)' as 항목, count(*) as 건수 from judge_sessions where expires_at < now()
union all
select 'judge_sessions(유효)', count(*) from judge_sessions where expires_at >= now()
union all
select 'login_attempts(7일 지남)', count(*) from login_attempts where at < now() - interval '7 days'
union all
select 'login_attempts(최근 7일)', count(*) from login_attempts where at >= now() - interval '7 days';

-- 2) 정리
delete from judge_sessions where expires_at < now();
delete from login_attempts where at < now() - interval '7 days';

-- 3) (선택) 대회가 완전히 끝났을 때만: 주석(--)을 지우고 실행
-- 모든 위원을 로그아웃시킴 (다음 행사 전 태블릿 정리)
-- delete from judge_sessions;
-- 로그인 시도 기록을 모두 지움
-- delete from login_attempts;

-- 4) 정리 후 현황
select (select count(*) from judge_sessions) as 남은_세션,
       (select count(*) from login_attempts) as 남은_로그인기록;

-- 참고
--  · 점수 수정 이력(score_history)은 이의 제기 확인용이라 여기서 지우지 않습니다.
--  · 작품설명 이미지(team-posters)는 SQL로 지우면 파일이 남으니,
--    대시보드 Storage → team-posters 에서 파일을 모두 선택해 Delete 하세요.
