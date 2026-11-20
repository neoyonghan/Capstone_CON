# 캡스톤디자인 경진대회 평가시스템

명지전문대학 2026학년도 캡스톤디자인 경진대회(2026. 11. 19.–20.) 온라인 심사 프로그램입니다.
같은 화면을 두 가지 저장소로 운영할 수 있습니다.

| 폴더 | 저장소 | 접속 |
|---|---|---|
| `/` (루트) | **Supabase** | 배포한 링크로 누구나 접속 → 위원은 성명+전화번호, 관리자는 이메일+비밀번호 |
| `claude-artifact/` | claude.ai 아티팩트 | claude.ai 계정으로만 접속 (대회 당일 사용본) |

## 파일
- `index.html` — **파일 하나로 된 전체 화면**(심사 입력 · 집계 · 설정 · PDF · 상장 + Supabase 연결).
  파일 위쪽 `window.SB_CONFIG`에 **Supabase 주소와 anon key**를 넣습니다(`YOUR_PROJECT_ID`, `YOUR_ANON_PUBLIC_KEY` 자리).
- `supabase/schema.sql` — 표·보안(RLS)·로그인/제출 기능 전체(새 프로젝트용)
- `supabase/patch_1_login.sql`, `patch_2_admin.sql`, `patch_3_division_lock.sql`, `patch_4_posters.sql`, `patch_5_improve.sql` — 이미 schema를 실행한 프로젝트에 차례로 추가 실행
- `supabase/cleanup_after_event.sql` — 행사 후 만료된 위원 세션·7일 지난 로그인 기록 정리 (점수·이력은 보존)

## 설치 순서
1. Supabase SQL Editor에서 `supabase/schema.sql` 실행
   (이미 예전 schema를 실행했다면 `patch_1_login.sql` → `patch_2_admin.sql` → `patch_3_division_lock.sql` → `patch_4_posters.sql` → `patch_5_improve.sql`만 실행)
2. 팀·위원 데이터 입력(학생 명단이 들어 있는 data.sql은 개인정보라 저장소에 올리지 않음)
3. Authentication → Users에서 관리자 계정을 만들고 `admins` 표에 등록
4. 상장 직인: Storage → `private-assets` 버킷에 `cert-seal.png` 업로드(관리자만 읽기 가능)
5. `index.html`의 `window.SB_CONFIG`에 Project URL과 anon public key 입력 → 커밋
6. Vercel에서 이 저장소를 Import → Framework: Other, Build 없음 → Deploy

## 보안
- 위원·익명 접속자는 표를 직접 읽거나 쓸 수 없고, `judge_login` · `judge_sheet` · `submit_score` RPC로만 자기 학부 팀과 자기 점수를 다룹니다.
- 마감, 담당 학부, 점수 범위(5~10), 동시 저장(rev)은 서버가 검사합니다.
- 위원 전화번호는 bcrypt 해시만 저장합니다. 10분에 5번 틀리면 잠깁니다.
- 점수 수정·삭제는 `score_history`에 남습니다.
- `service_role` key는 절대 이 저장소나 화면에 넣지 마세요.

## 주요 기능
위원 로그인, 10개 항목 채점(미참여 시 5점 자동), 동시 저장 감지, 학부별 순위와 수상 배정(평균 → 기술성·완성도 → 창의성·기획성, 대상 1팀과 해당 학부 상향, 미참여 팀 수상 제외), 위원 간 15점 이상 차이 표시, 엑셀, 심사표 PDF, 상장 PDF·메일머지, 심사 마감, 수상 정원, 위원 전화번호 등록, 위원별 점수 초기화, 관리자 심사위원 변경(대리 입력).
