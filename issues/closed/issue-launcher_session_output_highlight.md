# launcher 출력을 하이라이트와 함께 세션에 저장/복원

1. 현황
세션 저장 시 launcher 출력은 텍스트(`content`)와 status/matches 만 저장됨 (`session.lua` `save_launcher`).
ANSI 색상 등 하이라이트는 저장되지 않아 복원 시 색이 사라짐.

2. 목표
launcher 출력의 하이라이트까지 세션에 저장하고 세션 로드 시 동일하게 복원.
- 출력량이 클 때의 저장 용량은 issue-session_large_list_data 와 함께 고려

3. 작업 노트
- launcher 전용 extmark의 위치와 하이라이트 그룹을 세션 파일에 저장하고 복원.
- 사용자 지정 색상 그룹은 복원 시 색상 값을 다시 등록.
- 세션/launcher 테스트 통과. 큰 출력의 용량 제한은 별도 이슈에서 다룸.
