# launcher focus 옵션 동작 확인

1. 현황
launcher 설정에 `focus` 옵션이 있음 (`launcher.lua` `lcfg.focus`). 설정 시 실행 시작과 함께 launcher 버퍼로 포커스를 옮겨야 함.
의도대로 동작하는지 확인되지 않음.

2. 목표
`focus = true` 인 launcher 실행 시 launcher 버퍼에 포커스, 아니면 원래 창 유지.
- 터미널 모드 실행(`LaunchOnTerm`), 기존 버퍼 재사용 등 경우별 확인 필요

3. 해결
`LaunchObject`의 기존 버퍼 재사용 및 교체 취소 경로에서 `focus` 설정을 적용함.
새 버퍼, 표시 중인 버퍼, 숨겨진 버퍼, 교체 취소, 터미널 모드를 테스트함.
