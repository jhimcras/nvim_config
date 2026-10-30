# 작업 문서

기준일: 2026-10-30. 다음 세션은 이 문서에서 시작한다. 구현 계약·남은 작업·검증 기록의 기준은 아래 문서이며, 오래된 계획이나 이슈의 상태를 다시 적용하지 않는다.

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
- Windows는 사용자가 직접 수행한다. 별도 진행 파일 없이 이 세션에서 W1~W8을 순서대로 진행하며, 명령·통과 기준은 mdloom [현행 Windows 절차](../../markdown_lsp/doc/manual-test.md#현행-windows-검증-순서-w1w8)에 둔다. Windows·MSRV 1.88·Windows CI 결과는 아직 없다. 전체 작업은 미완료다.

### Windows W1 소스 불일치 보고

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
