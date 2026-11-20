-- =====================================================================
-- 패치 4: 작품설명 이미지(포스터) · SQL Editor에서 1회 Run (여러 번 실행해도 안전)
--  버킷 team-posters (비공개: 고정 공개 주소 없음, 화면에서 6시간짜리 임시 주소로만 표시)
--  파일 이름 = 부스 번호 두 자리 + .jpg  (01.jpg … 80.jpg)
--  읽기: 사이트 화면(위원·관리자)에서 목록 조회·임시 주소 발급
--  올리기·바꾸기·지우기: 관리자 계정만
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('team-posters', 'team-posters', false, 5242880, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg'];

drop policy if exists "read team-posters" on storage.objects;
create policy "read team-posters" on storage.objects for select to anon, authenticated
  using (bucket_id = 'team-posters');

drop policy if exists "admin insert team-posters" on storage.objects;
create policy "admin insert team-posters" on storage.objects for insert to authenticated
  with check (bucket_id = 'team-posters' and public.is_admin());

drop policy if exists "admin update team-posters" on storage.objects;
create policy "admin update team-posters" on storage.objects for update to authenticated
  using (bucket_id = 'team-posters' and public.is_admin())
  with check (bucket_id = 'team-posters' and public.is_admin());

drop policy if exists "admin delete team-posters" on storage.objects;
create policy "admin delete team-posters" on storage.objects for delete to authenticated
  using (bucket_id = 'team-posters' and public.is_admin());

-- 확인: 버킷 설정과 올라간 이미지 수 (80이면 완료)
select id, public, file_size_limit, allowed_mime_types,
       (select count(*) from storage.objects o where o.bucket_id = 'team-posters') as uploaded
from storage.buckets where id = 'team-posters';
