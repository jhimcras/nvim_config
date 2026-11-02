# 작업 문서

기준일: 2026-11-02. 다음 세션은 이 문서에서 시작한다. 현재 Windows 상태는 W1~W5 통과(W4의 다른 SID pipe 선점은 보류 예외), W6 일부 진행·전체 미완료, W7~W8 미실행이다. 이슈 종료는 별도 결정이다. 구현 계약·남은 작업·검증 기록의 기준은 아래 문서이며, 오래된 계획이나 이슈의 상태를 다시 적용하지 않는다.

## 문서와 현재 상태

| 문서 | 내용 | 상태 |
| --- | --- | --- |
| [coderunner.md](coderunner.md) | 실행·결과 삽입·렌더·캐시·내보내기·신뢰 계약과 검증 | Linux 자동·실도구·neopp·실제 신뢰 UI 검증 완료, Windows 대기 |
| [rendermark.md](rendermark.md) | 이미지 표시·공급자·배치·실패 처리, 성능과 M1~M15 수동 확인 | Linux stub·neopp 검증 완료, 비동기 디코더 실패 전달 한계 기록, Windows 대기 |
| [followups.md](followups.md) | Mermaid 설정, 표 이미지 중복 전송, PlantUML 감지, 이미지 붙여넣기 | 개별 후속 작업 대기 |
| [module_refactoring.md](module_refactoring.md) | 공통 모듈 구조·이벤트·호환과 과거 검증 요약 | 2026-10-07 종료, 현재 의존성 검사 결과 별도 기록 |

## 다음 세션 진행 순서

1. `git status --short`와 관련 구현을 확인한다. 외부 `~/workspace/markdown_lsp`의 브랜치·설정·daemon 상태는 마지막 기록과 다를 수 있으므로 다시 확인한다.
2. 작업에 맞는 문서의 남은 검증 또는 후속 항목 하나를 선택한다. coderunner·rendermark의 코드 구현은 이미 있으므로 최초 이식 계획부터 다시 시작하지 않는다.
3. 코드 변경 전 해당 스펙으로 문제를 재현하고 변경 후 관련 검증을 실행한다. GUI·Windows 미검증을 headless 통과로 대체하지 않는다.
4. 결과에 날짜·환경·명령·통과/실패를 기록한다. 항목을 완료하면 해당 문서의 상태와 이 표를 함께 갱신한다.

과거 테스트 수와 성능은 각 작업 시점의 기록이다. 아래 통합 검증은 앞선 문서 정리와 구분한다. require graph는 재실행에서도 108모듈·276간선·레이어 위반 0·기존 coderunner 순환 그룹 1, 종료 1이었다. 순환을 해소한 결과가 아니다.

## 2026-10-30 mdloom 통합 검증

- Linux 6.1.177-3-MANJARO, Rust 1.97.1, Neovim 0.12.4. mdloom `lsp-scope` / `802b9a5`, nvim_config `feature/coderunner` 작업 트리에서 수행했다.
- mdloom build·fmt·clippy와 필수 Neovim 포함 전체 테스트 476개, nvim_config unit 866개·TUI 통합 11개가 통과했다. 실제 init·pckr·Oil·mdloom 연결 스모크도 11그룹 통과했다.
- `init.lua`에서 coderunner 진단을 활성화하고 미리 지정한 `vim.g.mdloom_dir`를 보존한다. 전역 mdloom 설정의 옛 runners/renderers만 제거하고 `[links] scope="filesystem"`은 유지했다.
- TUI 정리 시 Neovim 캐시 쓰기와 임시 폴더 삭제가 충돌한 `ENOTEMPTY`를 재현했다. `tests/integration/tmux_case.py`에서 Neovim 종료를 기다리도록 수정한 뒤 전체 통합 검사가 통과했다.
- 실제 Python·PlantUML, TUI stub, neopp 실이미지·키 입력·신뢰 UI를 확인했다. 도구 환경과 손상 PNG의 한계는 각 작업 문서에 남긴다. 테스트 전용 데몬은 정리했다.
- Windows는 사용자가 직접 수행한다. 별도 진행 파일 없이 이 세션에서 W1~W8을 순서대로 진행하며, 명령·통과 기준은 mdloom [현행 Windows 절차](../../markdown_lsp/doc/manual-test.md#현행-windows-검증-순서-w1w8)에 둔다. W1·W2는 통과했고 W3는 미통과(1차 65건 실패, 픽스처·export 경로 수정 `16441cf` 뒤 39건 → 21건 실패, Windows에서 870개 통과를 확인한 수정안을 원본에 반영하고 재실행 대기)이고 W4~W8, MSRV 1.88, Windows CI 결과는 아직 없다. 전체 작업은 미완료다.

### Windows 진행 (2026-10-30)

- W1~W3 통과. W2 최종 재실행(mdloom `a6eafdf` 포함): build·fmt·clippy 종료 0, workspace 443개·필수 Neovim 5개 통과, `--help`/`-h` 종료 0. W3(`640aa17` 반영 코드): 72개 스펙·870개 성공·실패 0·종료 0(launcher_focus terminal 검사는 Windows 건너뜀). W4~W8, MSRV 1.88, Windows CI는 미실행·미확인. 상세는 mdloom [Windows 기록](../../markdown_lsp/doc/windows-test-log.md#w1w2-결과-2026-10-30).

### Windows W1 소스 불일치 보고 (해소됨)

- 사용자 보고: Windows `mdloom_integration` / `8348dd6`에는 coderunner가 있지만 새 통합 smoke, `diagnostics=true`, 외부 `mdloom_dir` 보존, tmux 종료 대기가 빠져 W1 준비가 완료되지 않았다. W2는 보류한다. 이는 제품 테스트 실패가 아니라 검증할 소스의 불일치다.
- Linux도 현재 같은 브랜치·HEAD이며 위 변경은 미커밋/미추적 상태에 있다. 브랜치 체크아웃만으로 전달되지 않으므로 `init.lua`, `tests/integration/tmux_case.py`, `tests/manual/mdloom_integration_smoke.lua` 세 파일을 작업 트리에서 복사하고 SHA256을 대조한다. 기대 해시와 재확인 방법은 mdloom [Windows 기록](../../markdown_lsp/doc/windows-test-log.md#w1-재확인-소스-불일치)에 둔다.
- Windows에서 추가한 `doc/windows-test-log.md` 기록은 Linux 원본에 아직 없으므로 문서 전체를 덮어쓰지 않는다. 현장 기록을 유지하고 새 결과만 병합한다. 소스 재동기화 확인과 W1의 실제 경로·도구·Java/jar 환경 출력이 모두 확보된 뒤 W2로 진행한다.

## 정리 범위

- `docs/`의 작업 문서 9개를 위 작업별 문서로 통합했다. coderunner 계획·시나리오·성능, rendermark 계획·이미지/커서/HTML 성능, 공통 모듈 재구성 기록이 대상이다. 중복된 단계별 보고와 원시 로그는 제거했다.
- `.issues/open/`의 coderunner·rendermark 본 작업과 Mermaid·표 중복 전송·PlantUML 감지·이미지 붙여넣기 이슈 6개도 통합하고 원본을 정리했다. 미완료 항목은 삭제된 것이 아니라 위 문서에서 계속 관리한다.
- 링크 이동 시 갱신·unresolved 링크 파일 생성 등 LSP 이슈와 다른 open 이슈는 기존 위치에 유지한다. 외부 mdloom 작업 문서는 이 저장소 정리 대상이 아니다.
- `docs/`에는 [프로젝트 루트 설정](../docs/prjroot.md), [clangd](../docs/clangd.md), [coderunner 사용법](../docs/coderunner.md), [rendermark 이미지 사용법](../docs/rendermark_image.md)을 유지한다. 본문은 이번에 재작성하지 않고 이동한 문서 링크만 고쳤다.
- `tests/manual/`과 자산·스크립트는 유지한다. 수동 문서의 작업 체크리스트 링크만 새 위치로 연결했다.
- `.refactoring_docs/`는 Git ignore 예외를 두어 다음 세션과 버전 관리에서 참조할 수 있게 했다. 기존에 추적하던 작업 문서의 원본은 Git 이력에 남는다. ignore 대상이던 이슈의 유효 내용은 이 폴더에 통합했다.

## Windows W4 최초 실패 (2026-11-02)

- 사용자 보고: Windows 10.0.26100.7171 / Neovim 0.12.4에서 실제 init smoke가 initial definition 대기 중 실패했다. PASS 0/11, 종료 1. LSP 초기화·pckr/Oil·codeLens 없음·gW 바인딩까지 확인했고 이후 재실행 및 W5~W8은 진행하지 않았다.
- 실제 definition 응답은 미기록이므로 제품 탐색 실패와 테스트 경로 비교 실패 중 원인은 미확정이다. smoke의 URI 변환 경로와 기대 경로를 각각 정규화해 비교하고 첫 응답·실패 시 최종 응답 및 정규화 경로를 출력하도록 했다. Windows 재검증은 아직 하지 않았다.
- Windows에서 수정 커밋을 동기화한 뒤 W4 smoke를 처음부터 재실행하고 INITIAL DEFINITION PROBE 및 종료 코드를 확보한다. 이동 후 버퍼 경로·wall 후 원본 재생성 여부와 나머지 W4 수동 항목은 계속 미검증이며 기존 이동 버퍼 이슈는 열린 상태다.
- 현장 로그: `%TEMP%\mdloom-w4-20261102\smoke.log`, 실행 환경·명령: 같은 폴더의 `run.cmd`.

### W4 재실행 및 이동 버퍼 실패 (2026-11-02)

- 사용자 보고: 수정 smoke는 PASS 11/11, 종료 0. definition의 실제/기대 경로는 구분자만 달랐으므로 최초 실패는 테스트 비교 문제로 확인됐다.
- 별도 실제 init headless 검증에서 MdloomMove 후 버퍼는 옛 경로에 남았고, 편집 후 wall이 옛 파일을 재생성했다. 이동 검증 종료 1, 테스트 데몬 종료 0. 도구 timeout과 각 검사 종료 코드를 구분한다. W4 전체는 미통과이며 나머지 W4 및 W5 이후는 미실행이다.
- mdloom 플러그인에 이동 후 남은 버퍼 이름 갱신을 추가했다. remote가 없어 [적용 패치와 절차](../patches/README.md)로 전달한다. Linux 실제 Neovim 이동 회귀 테스트 통과. smoke에도 이동 버퍼 이름·편집 후 wall·옛 파일 재생성 방지 검사를 추가했다. Windows 재검증 전 기존 이슈는 닫지 않는다.
- 현장 로그: `%TEMP%\mdloom-w4-retry-20261102-0925\smoke.log`, `%TEMP%\mdloom-w4-move-20261102-0930\move.log`.


### W4 자동·headless 재검증 통과 (2026-11-02, 현재 상태)

사용자 Windows 실행 보고를 반영한 기록이며 이 Linux 세션에서 Windows 검사를 실행한 결과는 아니다. mdloom 수정은 rsync로 전달할 수 있으므로 패치 중복 적용은 필요 없다.

| 검증 | 결과 |
| --- | --- |
| 실제 init 통합 smoke | 11/11그룹, 종료 0 |
| 이동 버퍼와 저장 | 새 버퍼 경로로 변경, 편집·wall 후 새 파일 저장, 옛 파일 재생성 없음 |
| Windows 경로 | 24종 CLI/LSP 판정 통과 |
| 대소문자·symlink | 드라이브 대소문자 동일 루트, 소문자 URI 버퍼 반영, symlink 별도 문서 식별 통과 |
| 한글·공백 경로 | 정의 이동·미저장 버퍼 갱신·참조 4개 확인 |
| 다중 Neovim | 데몬 공유·미저장 격리·캐시 복원·재연결·직접 연결 10단계, 종료 0 |
| 외부 감시 | 저장·rename·삭제·생성 후 진단/정의 갱신 통과 |
| 잠금 중 fmt/mv | 정상 거부(fmt 종료 2·오류 5, mv 종료 2·오류 32), 잠금 해제 후 모두 종료 0 |
| CLI 이동 | 열린 참조 문서 보호 거부, 버퍼를 닫은 뒤 이동·링크 갱신 성공 |
| 강제 종료 복구 | 테스트 데몬 종료 뒤 프록시 자동 재연결·탐색 복구 |
| 실제 init 직접 named pipe | 탐색·hover·참조·완성·심볼·rename·양 문법 생성·표·진단·접기·포맷/undo 통과 |

테스트 데몬 정리 완료, 잔존 테스트 nvim/mdloom/java 프로세스 0개. 출력 파이프 대기와 임시 검사의 환경·기대값 오류는 실행기 수정 후 재검증했으며, 사용자 검증 세션에서는 저장소 제품·테스트·문서 파일을 수정하지 않았다.

**W4 자동·headless 검증 통과. W4 전체 수동 수용과 기존 이동 버퍼 이슈 종료는 유보한다.** 다른 사용자 SID의 named pipe 선점, 실제 UNC 네트워크 접근 감시(문법 판정만 확인), 사람이 직접 키를 입력하는 수동 확인은 미실행이다. W5~W8도 미실행이다. 다음 작업은 남은 W4 수용 항목의 검증 또는 제외 판정이며, W5 진행 시 이 유보 상태를 유지한다.

로그 기준 경로: `C:\Users\Admin\AppData\Local\Temp\`.

- `mdloom-w4-retry2-20261102-0937\move\output.log`
- `mdloom-w4-retry2-20261102-0937\smoke\output.log`
- `mdloom-w4-extra2-20261102-0945\c2-*.log`
- `mdloom-w4-multi-20261102-0950\multi.log`
- `mdloom-w4-final2-20261102-0955\output.log`
- `mdloom-w4-direct-20261102-1000\output.log`

### W4 실제 콘솔 TUI 키 입력 자동화 통과 (2026-11-02)

사용자 Windows 실행 보고: headless가 아닌 별도 Neovim 콘솔에 Windows 키 down/up 이벤트를 전송해 확인했다. nvim_input·feedkeys·편집기 제어용 RPC는 사용하지 않았다. **사람의 물리 키보드 수동 입력이 아닌 실제 TUI 키 입력 자동화**로 분류한다.

- MdloomMove moved/note.md 후 저장 질문에서 No 선택, echo expand('%:p')가 새 경로를 표시했다.
- Go로 본문 입력 후 Esc·wall 실행. 파일 존재 결과는 0 1(옛 파일 없음·새 파일 있음), 새 파일 마지막 줄은 `W4 manual input`, 참조 문서는 `[note](moved/note.md)`였다.
- 콘솔 메시지 행과 실제 저장 파일을 대조했다. Neovim 종료 0, 데몬 종료 0, 잔존 시험 프로세스 0개.
- 증거: `C:\Users\Admin\AppData\Local\Temp\mdloom-w4-tui2-20261102-1030\`의 `result.json`, `transcript.txt`, `exit-record.txt`, 단계별 `*.screen.txt`.
- 다른 SID의 named pipe 선점은 여전히 미실행이다. 실제 UNC 네트워크 감시는 앞선 미실행 상태를 유지한다. W4 전체 수용·기존 이슈 종료는 유보하고 W5~W8 미실행도 유지한다. 이번 사용자 검증에서는 저장소 파일을 수정하지 않았다.


### W4 최종 판정: 통과, 다음 W5 (2026-11-02)

사용자 최종 판정으로 위의 W4 전체 수용 유보 상태를 갱신한다. **W4 통과. 다른 SID의 named pipe 선점 검사는 보류 예외로 남기고 W5로 진행한다.** 현재 환경에서 수행이 어렵고 당분간 발생 가능성이 낮다는 사용자 판단에 따른 예외이며, 보류 항목을 통과로 집계하지 않는다. 서버 SID 검증의 실제 수용 여부는 미확인이다. 실제 콘솔 TUI 키 입력 자동화를 수동 확인의 대체로 인정했으며 사람의 물리 키보드 입력으로 분류하지 않는다. 기존 이슈 종료는 별도 결정이다. W5~W8은 아직 미실행이다.

환경·소스 기준: Windows 10.0.26100.7171, Neovim 0.12.4, OpenJDK 22.0.2와 PlantUML jar 준비. mdloom은 `D:\workspace\mdloom`, nvim_config는 `D:\workspace\nvim_config`. Windows 사본에 Git 메타데이터가 없어 커밋을 직접 확인하지 못했다. 사용자 보고 작업 기록 기준은 `mdloom_integration` / `f3b3e57`이며, 이후 검사는 이동 버퍼 수정이 반영된 로컬 소스에서 수행했다. 이를 특정 커밋의 소스 일치 검증으로 확대하지 않는다.

기존에 기록한 smoke 11/11·종료 0, Windows 24종 경로 판정, URI·symlink·한글/공백, 다중 Neovim 10단계, 감시·잠금·CLI 이동 보호·강제 종료 복구·직접 named pipe 연결 검사는 최종 통과로 보고됐다. 직접 연결에는 표 Code Action·명령과 포맷/undo도 포함한다. 이동 후 편집·wall과 참조 갱신은 headless 및 실제 TUI 키 입력 자동화 모두 통과했다. 초기 definition 경로 비교 실패와 이동 버퍼 실패는 수정 후 재검증됐으며, 임시 실행기의 출력 파이프 대기·캐시 경로 불일치·열린 문서 보호 기대값·빈 LSP 응답 처리 문제는 제품 실패와 구분한다.

UNC는 앞선 미실행 상태에서 **Windows 파일 I/O 수준 검증 통과**로 갱신한다. `127.0.0.1` UNC 시험 주소에 대해 CLI 일회성·데몬 경유 검사와 실제 init LSP에서 검사 제외를 확인했다. mdloom의 시험 UNC 접근 이벤트 0건, 실제 UNC 접근을 시도한 양성 대조군 이벤트 1건, 정상 시험 문서 접근 관측, 두 추적 모두 유실 이벤트 0건이었다. 패킷 전체 캡처나 실제 원격 공유 접근 성공을 검증한 결과는 아니다.

추가 증거: `%TEMP%\mdloom-w4-unc-20261102-1008\`의 UNC 요약·양성 대조군 증거. 다른 검사 로그는 위 W4 기록의 retry2·extra2·multi·final2·direct·tui2 경로에 있다. 시험 데몬·추적 세션·콘솔 정리 완료, 잔존 시험 프로세스 0개. 대형 원시 ETW 파일은 삭제하고 요약과 시험 경로 증거만 보존했다. 후속 사용자 검증 중 저장소 제품·테스트·문서 파일은 수정하지 않았다.

### W5 중단: 분할 창 오류 줄 중복 (2026-11-02)

- 사용자 Windows 실제 TUI(120×30) 보고: M1 통과(mdloom 연결·codeLensProvider=nil·이미지 단일 표시·소스 숨김/커서 진입 시 노출·뒤 문장 유지). 버퍼 내용·nomodified·픽스처 SHA256 불변 확인. M2는 표·한 줄 여러 이미지·없는 PNG/미지원 SVG 오류·코드 내부 제외만 확인했고 폭 초과 공동 축소는 미확인이다.
- M4 관련 실패: 없는 PNG·미지원 SVG 위치에서 vsplit 시 각 창에 오류 줄이 두 번 보이고, only 시 복구되며 재분할 시 재발했다. 동일 위치 virt_lines extmark 2개를 확인했다. W5는 미통과이며 나머지 항목 및 W6~W8은 미실행이다. 증거는 `%TEMP%\mdloom-w5-n4ii2ee9\`. 사용자 실행 후 시험 편집기·임시 루트 데몬 종료, 저장소 파일 변경 없음.
- 원인: 창별 LayoutWindow에서 버퍼 공용 오류 extmark를 반복 생성했다. 동기화 pass마다 버퍼·행·열 기준으로 오류 생성을 중복 제거했다. 창별 이미지 payload 처리는 유지한다.
- 회귀 검증: missing PNG와 실제 SVG 파일을 표시하는 버퍼에서 분할·닫기·재분할 후 오류 위치당 extmark 1개를 확인한다. 수정 전 2개로 실패, 수정 후 통과. Linux `bash run_tests.sh tests/spec/rendermark/image` 통과 및 SVG 픽스처 보강 후 display_failure_spec 18개 통과. Windows 실제 TUI 재검증 전 W5 완료로 처리하지 않는다.

### W5 재중단: 서로 다른 분할 창 폭의 stub 배치 (2026-11-02)

- 사용자 재검증: 오류 줄 중복 수정 확인(분할 닫기·재분할 후에도 위치당 extmark 1개), M1 재통과, 원문·nomodified·픽스처 SHA256 불변.
- 새 실패: (b)의 한 줄 세 이미지에서 79열·40열 분할 시 좁은 창이 넓은 창의 stub 배치를 따라 두 번째·세 번째 이미지가 잘렸다. 넓은 창을 enew로 전환하면 좁은 창이 정상 축소되고, 같은 문서를 복원하면 재발했다. M2 공동 축소/M4 독립 표시 미충족으로 W5 중단. 전체 M3 및 이후는 미검증이다. 증거는 `%TEMP%\mdloom-w5-n4ii2ee9\`의 `repro_width.py`, `width-both-same-buffer.txt`, `width-only-narrow-image-buffer.txt`, `width-both-restored.txt`. 사용자 세션과 임시 루트 데몬 종료, 저장소 수정 없음.
- 원인: 창별로 계산한 stub 예약과 label을 버퍼·행 기준으로 합쳐 첫 창의 배치가 공유됐다. stub 예약을 창별로 유지하고 같은 버퍼를 여러 창에서 볼 때 창에 한정한 namespace에 표시한다. namespace별 차등 갱신·정리도 처리하고, 해당 장식을 이미지 소스나 외부 장식으로 다시 읽지 않도록 제외했다. 단일 창의 기존 namespace와 GUI 이미지 배치 방식은 유지한다.
- Linux 검증: 서로 다른 폭의 창에서 stub 범위·namespace 창 범위와 넓은 창 문서 전환/복원 시 정리·재생성 회귀 테스트. 기존 place.lua로 실패(종료 1), 수정 후 display_failure_spec 19개 통과. `bash run_tests.sh tests/spec/rendermark` 전체 417개 통과, 실패·오류 0. 창별 namespace는 현재 검증 환경 Neovim 0.12의 `nvim__ns_set`을 사용한다. Windows 실제 TUI는 재검증 대기이며 W5 전체는 미통과다.

### W5 재중단: 인라인 코드 이미지 오인식과 native wrap 중복 (2026-11-02)

- 사용자 Windows 확인: 79열·40열 stub 독립 크기와 넓은 창 버퍼 전환/복귀 유지, 한 줄·반 화면 스크롤·상단 클리핑·정지 후 안정성, 접기 제거/펼치기 복구·버퍼 전환 정리 통과. 원문·nomodified·픽스처 SHA256 불변.
- 새 실패: 15행 (b) 제목에서 zt → zM/zR → vsplit → 새 창 9행 설명문에서 zt 시 인라인 코드 `![...](...)`에 not found 오류 virt_lines가 생겼다. resize 45 → set wrap 후 설명문 원문과 가상 줄 표시가 겹쳤다. W5 미통과, M5 이후 미실행. 증거는 `%TEMP%\mdloom-w5-n4ii2ee9\`의 `repro_wrap.py`, `wrap-baseline.txt`, `wrap-split.txt`, `wrap-resized.txt`, `wrap-on.txt`. 사용자 저장소 변경 없음, 시험 편집기와 임시 루트 데몬 종료.
- 원인과 수정: 원문 스캐너는 code span을 제외하지만 markdown_visual_wrap의 가상 텍스트를 다시 수집하면 백틱 없는 표시 텍스트가 이미지 구문으로 해석됐다. 이 namespace는 원문에서 이미 수집했으므로 virt_text/virt_lines 재수집에서 제외한다. native wrap은 기존 시각적 줄바꿈의 nowrap 전제와 충돌하므로, 시각적 줄바꿈이 활성화된 상태에서는 OptionSet wrap을 처리해 nowrap을 유지한다. 기본 줄바꿈을 사용하려면 먼저 시각적 줄바꿈을 비활성화해야 한다.
- 검증: 가상 virt_lines/overlay에 표시된 code span을 수집하지 않는 테스트와 시각적 continuation 활성 시 set wrap 중복 방지 테스트가 각각 수정 전 실패했다. 수정 후 `bash run_tests.sh tests/spec/rendermark` 419개 통과, 실패·오류 0. Windows 실제 TUI 재검증 대기이며 W5 완료로 처리하지 않는다.

### W5 재중단: 소스 버퍼 전환 후 자동 미리보기 split 잔존 (2026-11-02)

- 사용자 Windows 재검증: 인라인 코드 오류 extmark와 wrap 겹침 해소. M5·M12의 실제 PNG·비활성 대체·자동 미리보기/토글·저장 갱신·같은 문서 블록 이탈 닫힘 확인. M6 실패 소스·오류 줄·render-failed 진단 유지 및 수정/저장·CodeRender! 회복, M7 인접 export 억제·빈 줄 두 개 시 양쪽 표시·실제 CodeExport 중복 억제 확인.
- 새 실패: c.md의 PlantUML 블록에서 자동 split을 연 뒤 소스 창을 edit e.md로 전환하고 블록 밖에 있어도 이전 미리보기와 이미지가 남았다. 2초 대기 후 동일, `_preview_user=nil`, preview_source 메타데이터도 이전 버퍼·이미지였다. W5 미통과, M8·M9·M10·M14·M15 미실행. 사용자 프로젝트 코드·문서·원본 픽스처 수정 없음, 시험 세션·임시 루트 데몬 종료.
- 원인: 미리보기 닫힘 판정이 보이는 소스 버퍼의 이미지 수집에 의존해 숨겨진 이전 버퍼를 검사하지 않았다. 동기화의 visible window 수집 전에 cursor lifecycle split의 소스 창이 유효하고 같은 소스 버퍼를 표시하는지 확인하고, 연결이 끊겼으면 split·이미지 payload를 정리한다. persistent lifecycle의 마지막 그림 유지 동작은 보존한다.
- 회귀 테스트: 자동 split을 연 뒤 다른 버퍼로 전환하면 cursor 모드의 창·이미지가 제거되고, 원본 버퍼로 돌아오면 다시 열림을 확인한다. persistent 모드의 유지도 확인한다. cursor 전환 검사는 수정 전 실패했고, 수정 후 rendermark 전체 421개 통과·실패/오류 0. Windows TUI 동일 순서 재검증 전 W5 통과로 처리하지 않는다.

### W5 재중단: M15 오류 문구가 같은 줄의 정상 stub을 밀어냄 (2026-11-02)

- 사용자 Windows 확인: 기존 인라인 코드/wrap 문제 해소. M5·M12 실제 PlantUML PNG·비활성 대체·활성 미리보기·저장 갱신·이탈 닫힘·토글, M6 실패 소스/진단 유지·회복, M7 인접 이미지 억제·빈 줄 2개 양쪽 표시·반복 export 중복 없음 확인.
- M8은 공급자 해제 시 일반 이미지만 표시·재등록 복구 확인, glue 없는 새 세션 시작은 미실행. M9·M10 읽기 모드·참조/HTML/위키·크기·이름 검색/오류·정의 줄 유지 확인. M14 일반/다이어그램 확대·탭 전환·q/Esc 정리·오류 대상 탭 거부 확인, 실제 터미널 창 resize는 미확인.
- M15 실패: 한 줄의 빨강→손상 PNG→초록 중 손상 PNG에만 제공자 거부를 주입하면 긴 오류 문구가 정상 초록 stub을 오른쪽으로 밀어 화면 밖으로 잘랐다. 정상 파일 교체 시 복구, 별도 줄 이미지는 무영향. 예약 높이·뒤 문장 화면 행 유지, 같은 리비전/스크롤 재시도 0회. 실제 neopp 이미지 배치 실패로 확대하지 않는다. W5 전체 미통과.
- 원인과 수정: stub 박스 준비 단계에서 오류 문자열 폭이 다음 박스 위치 계산에 사용됐다. 다음 박스가 있으면 오류 문구를 그 시작 열 이전의 공간으로 제한해 정상 이미지 위치를 보존한다. 한글 등 UTF-8 문자를 바이트 중간에서 자르지 않고 화면 폭으로 잘라낸다. 뒤에 박스가 없는 기존 오류 문구 표시는 유지한다.
- 검증: 세 박스의 가운데만 긴 한글 오류로 바꾸는 회귀 테스트를 높이 1/3에서 실행했다. 수정 전 오른쪽 stub 위치가 달라 실패했고, 수정 후 정상 stub의 suffix·전체 화면 폭·오류 해제 복원이 일치했다. `bash run_tests.sh tests/spec/rendermark` 422개 통과, 실패·오류 0. Windows 실제 TUI 재검증 전 W5 완료로 표시하지 않는다.


### W5 통과·W6 일부 진행: GUI 인라인 이미지 뒤 문장 복구 (2026-11-02)

- 사용자 최종 보고로 W5 통과. W6은 이번 수정 확인까지만 진행했으며 전체 미완료다. 이 판정은 앞선 W5 미통과 상태를 갱신한다.
- 사용자 전달 변경은 place.lua 1개와 신규 prose_occlusion_spec.lua 1개이며 neopp 코드는 변경하지 않았다. text_layout 경로는 Neovim이 원문을 conceal한 뒤 이미지 앞·사이·뒤 문장을 다시 그리는데, GUI가 원래 링크 폭을 추가로 가려 재구성한 문장까지 숨겼다.
- text_layout이 있으면 payload의 text_col/text_end_col을 -1로 보내 추가 GUI 가림을 생략한다. 이미지 위치·크기·예약 높이와 text_layout 없는 다이어그램 경로는 유지한다. 단일·다중 인라인 이미지의 payload와 원문·nomodified 불변을 신규 테스트로 확인한다.
- Linux 원본 재검증: 새 테스트 수정 전 2개 실패, 수정 후 rendermark 전체 16개 스펙·424개 통과, 실패·오류 0, 종료 0. 사용자 Windows 기록도 같은 결과다.
- 사용자 실제 neopp 확인: 원본 픽스처의 인라인 파랑 이미지 뒤 `뒤에 글이 이어진다.`가 다시 표시됐고 원문 불변·nomodified 유지. 실제 GUI 확인은 사용자 보고이며 Linux에서 다시 실행한 결과는 아니다. 임시 검사 스크립트·스크린샷은 제품 변경에 포함하지 않는다.
