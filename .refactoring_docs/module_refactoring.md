# 공통 모듈 재구성

기준일: 2026-10-30. 이 작업은 2026-10-07에 사용자 확인으로 종료했다. 아래 과거 검증 수치는 이후 coderunner·rendermark 변경의 검증 결과와 구분한다.

## 유지할 구조와 계약

- 자체 모듈은 `lua/nvim_config/` 아래에 둔다. `require` 경로와 RPC 문자열도 같은 네임스페이스를 쓴다.
- 의존 방향은 L0(env·util), L1(prjroot·git·ANSI·프로세스 레지스트리·spinner), L2(기능), L3(status·tabline), L4(설정·키맵·플러그인·조립) 순이다. 하위에서 상위를 참조하지 않는다.
- launcher는 출력·터미널·프로젝트 설정·이동·가드·레지스트리, session은 명령·목록 저장·종료 가드로 나뉜다. quickfix 공통 기능은 `qflist/`에 둔다.
- LSP는 attach·float·progress·서버 설정으로 나뉜다. 로드만으로 floating-preview 핸들러를 교체하지 않으며 setup은 멱등성을 유지한다.
- status는 한 렌더 컨텍스트를 축소 과정에서 공유한다. FileInfo는 status 대신 symbol·LSP 상태 헬퍼를 쓴다.
- rendermark는 wrap·표 상태·이미지 배치 책임을 나눈다. 최신 이미지 계약은 [rendermark.md](rendermark.md)를 따른다.
- 인스턴스 이동은 주입받은 대상 선택 콜백을 사용한다. Telescope picker는 플러그인을 먼저 로드한 뒤 접근한다.
- 저장된 세션·목록 형식과 기존 setup 순서를 유지한다. RPC 경로가 바뀐 버전을 적용하면 실행 중인 인스턴스를 함께 재시작한다.

## 이벤트 계약

모두 동기 `User` autocmd다. 취소·실패한 작업에는 알리지 않는다.

| 이벤트 | 데이터 | 발생 시점 |
| --- | --- | --- |
| `SessionChanged` | `{ action, path, session }` | save/remove/close의 파일·목록·현재 세션 상태 반영 후 |
| `SessionLoaded` | `{ action = 'open', path, session }` | 세션 source, 목록·창·커서·cmdheight 복원 후 |
| `ReadModeChanged` | `{ win, buf, active }` | 창 옵션과 읽기 모드 상태 반영 후 |
| `MarkdownDetailsChanged` | `{ win, buf }` | details 재그리기 후 |

tabline은 세션 이벤트를 즉시 반영한다. wrap은 이벤트의 창이 해당 버퍼를 표시할 때만 갱신한다. native `nvim -S`는 기존 `SessionLoadPost` 경로를 유지한다.

## 검증 기록과 현재 차이

- 2026-10-07, Linux Neovim 0.12.4: unit 538개 성공·실패/오류 0, integration 11/11 통과. require graph는 90모듈·211간선·레이어 위반/순환 0이었다.
- 실제 설치된 Telescope의 키·명령·Config·이동 선택창 첫 사용을 확인했다. 두 headless 프로세스 사이 파일·탭 RPC 이동은 공백 포함 경로, 원본 제거, 목적지 분할 복원을 통과했다.
- 사용자는 Windows GUI에서 문제 없이 사용 중이라고 확인했다. 이미지 표시·GUI 이동·종료 확인 흐름의 개별 수용 결과는 따로 기록되지 않았다.
- 당시 로그의 가짜 launcher handle 정리 경고·임시 파일 E211과 InsertEnter 플러그인 오류는 기존 문제로 분류했다. 임시 `/tmp` 로그는 후속 작업의 근거 파일로 의존하지 않는다.
- 2026-10-30 문서 정리 중 `python3 scripts/check_require_graph.py` 재실행: **108모듈·276간선·레이어 위반 0·순환 그룹 1, 종료 1**. coderunner와 autorender·diagnostics·export·provider·render·run 사이 참조가 묶인다. 텍스트 스캐너 결과이며 동적 require는 놓칠 수 있다. 후속 코드 작업에서 의도와 해소 필요성을 확인한다.

## 후속 세션에서 지킬 사항

- `lua/env.lua`, `lua/msbuild.lua`는 외부 `~/workspace/image/.prjroot`를 위한 임시 전달 모듈이다. 외부 호출이 `nvim_config.*`로 전환된 뒤 제거한다. 같은 모듈 테이블을 반환하고 setup을 호출하지 않는다.
- `msbuild`와 VS2013 환경 호환은 외부 사용 확인 전까지 유지한다.
- `tests/` 최상위의 종료·launcher·lazy-load 수동 진단 스크립트 10개(T01~T10)는 사용자 선택 대기다. 이번 정리에서 삭제하거나 이동하지 않았다.
- GUI·Windows 개별 수용 검증과 real-init 시작 성능은 headless 테스트로 대체하지 않는다.

재검증은 저장소 루트에서 실행한다. 문서 정리에서는 unit/integration을 다시 실행하지 않았다.

```sh
bash run_tests.sh
bash run_integration_tests.sh
python3 scripts/check_require_graph.py
```

성능 스크립트는 `tests/manual/benchmark_{launcher,grep_timer,statusline_shrink,spinner}.*`에 남아 있다. Markdown·이미지 성능 재현은 [rendermark.md](rendermark.md)를 따른다. 비교할 때 XDG config/state/cache와 Neovim 로그는 임시 경로로 분리하고 설치된 플러그인 데이터는 유지한다. 과거 단일 실행 시간만으로 성능 회귀나 향상을 판정하지 않는다.
