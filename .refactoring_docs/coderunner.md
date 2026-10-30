# coderunner 작업 인계

기준일: 2026-10-30. C0–C8 구현과 C9의 Linux 자동·실도구·neopp·실제 신뢰 UI·mdloom 연결 검증을 완료했다. Windows 검증이 남아 작업은 미완료다. 기존 coderunner 이슈도 이 문서로 통합하며 이후 진행 상태는 여기서 관리한다.
설정·명령·키맵은 [사용자 매뉴얼](../docs/coderunner.md)을 참고한다. 이 문서는 기존 계획·이식 시나리오·성능 기록을 통합한다.

## 범위와 기준

- `lua/nvim_config/coderunner/`가 코드 실행, 결과 삽입, 다이어그램 렌더·캐시·내보내기를 맡는다. LSP 없이 동작하며 이미지를 그리지 않는다.
- rendermark는 이미지를 표시하고 `lua/nvim_config/markdown.lua`가 두 모듈을 연결한다. 링크 유효성·이동 추적은 mdloom 담당이다.
- 이식 기준은 `~/workspace/markdown_lsp`의 `before-lsp-scope` 태그, 커밋 `fc4d402072f191c9a3f73a8f2088a67244813975`다. 해당 저장소의 현재 브랜치에서 기능이 삭제되어도 기준은 바뀌지 않는다.
- 원문은 태그의 `doc/archive/before-lsp-scope/` 계약 27–31·34–40절과 실행·렌더·내보내기 테스트다. 필요하면 별도 worktree에서 원본을 비교한다.
- mdloom의 LSP 전용 버전에 연결해 `diagnostics=true`로 전환했다. mdloom은 링크 진단, coderunner는 실행·렌더·내보내기 진단을 담당한다. 옛 서버와의 공존용 `diagnostics=false`는 현재 기본 설정이 아니다.
- CLI·daemon·LSP 전송/소유권/capabilities, 외부 포맷터, 세션 간 실행 이력 복원은 범위 밖이다.

## 유지할 동작

### 설정과 신뢰

- 전역 Lua 설정은 신뢰하고 `<root>/.coderunner.lua`는 명시 명령에서 `vim.secure.read`로 허용된 바이트만 평가한다. 자동·미리보기 경로에서는 로드하거나 프롬프트를 띄우지 않는다.
- 파일 해시가 바뀌면 메모리 설정을 무효화한다. 미로드·거부·오류 파일이 있으면 단일 요청도 전역 명령으로 대체하지 않는다. 공용 판정은 `trust.can_select(status)`다.
- 같은 이름은 워크스페이스 항목 전체가 전역 항목을 대체한다. 잘못된 같은 이름 항목도 전역으로 복구하지 않는다. 다른 정상 항목은 유지하고 알 수 없는 키는 경고한다.
- 언어가 겹치면 워크스페이스 우선, 같은 출처에서는 이름의 UTF-8 바이트 순 첫 항목을 선택한다.
- 루트는 `prjroot.GetProjectRoot`로 판정한다. 기존 `.prjroot`의 무확인 실행은 별개이므로 실행 명령 설정은 `.coderunner.lua`에 둔다.

### 블록과 실행

- Tree-sitter로 Pandoc 속성·컨테이너·본문을 파싱한다. 블록 키는 `상대경로#id`, ID가 없으면 `상대경로:언어:순번`이다. `output`은 실행과 순번에서 제외한다.
- 내용 해시는 컨테이너를 제거하고 LF로 정규화한 본문의 SHA-256이다. 같은 문서의 중복 ID는 첫 블록까지 모두 거부한다.
- output·이미지는 같은 컨테이너에서 다음 블록과 빈 줄 0–1개로 연결한다. 빈 줄 2개 이상은 연결하지 않는다. 닫히지 않은 펜스는 파싱하되 output 삽입하지 않는다.
- 러너는 명시 요청에서만 실행한다. 명령은 셸 없이 인자 배열로 실행하며 치환은 한 번만 한다. 누락된 `{attr.*}`는 실행 전 거부하고 렌더러에서는 해당 토큰 자체를 금지한다.
- 공유 FIFO 큐는 기본 4슬롯이다. 대기 취소는 프로세스를 만들지 않고 timeout은 슬롯 획득 후 steps 전체에 한 번 적용한다. 단계 실패 시 뒤 단계를 실행하지 않는다.
- stdout/stderr는 각각 기본 1MiB까지만 보관하되 끝까지 읽는다. 러너 출력은 UTF-8로 정리하고 렌더러 stdout은 PNG 보존을 위해 원시 바이트로 받는다.
- 결과 창은 읽기 전용이며 `q`는 창만 닫는다. 완료 결과는 세션 중 100개/256MiB까지 보관하고 최신 초과 결과 하나는 유지한다. 산출물은 일반 파일만 수집하며 생성한 입력 파일만 제외한다.
- 임시 산출물은 정상 종료 후 24시간 보존하고 시작·시간별로 정리한다. 비정상 종료의 기준은 마지막 시간별 보존 마커다.
- output 삽입은 최상위 닫힌 펜스에서 stdout만 사용한다. 소스·기존 output 변경은 거부하고 위치 이동만 허용한다. 실패는 `output {.error}`, 펜스는 출력의 최장 백틱보다 길게 만든다. 버퍼 편집은 undo 한 번이다.

### 렌더·캐시·내보내기

- 캐시는 `stdpath('cache')/coderunner/<루트 해시>/diagrams`와 JSON manifest에 저장한다. mdloom 캐시와 호환하지 않는다.
- 키는 코드·렌더러 설정·포맷·치환 명령/env/cwd를 반영하고 실행마다 다른 임시 경로는 토큰으로 고정한다. 외부 참조 파일·도구 버전 변경은 force가 필요하다.
- 현재 키 이미지가 없으면 마지막 성공 이미지를 stale로 제공한다. 실패는 현재 키에만 기록하고 취소 결과는 게시하지 않는다. force 실패 시 이전 이미지를 유지한다.
- 같은 키는 PID 소유 잠금으로 직렬화하고 다른 키는 병렬 실행한다. manifest는 별도 잠금 안에서 병합하며 이미지는 원자 교체한다. 죽은 PID 잠금만 회수하고 손상된 잠금은 자동 삭제하지 않는다.
- 저장 자동 렌더는 디스크 기준선과 다른 키만 예약한다. 새 저장·닫기는 이전 작업을 취소하고 편집만으로는 취소하지 않는다. 같은 실패 저장 키는 자동 재시도하지 않는다.
- `render_on_open` 기본값은 false다. 저장소 `init.lua`는 true로 켜며 보이는 블록의 캐시가 없을 때 전역 렌더러만 사용한다.
- 용량 기본 512MiB는 오래된 mtime부터 정리한다. 디스크 현재 이미지·필요한 stale 미리보기·사용 중 이미지는 보호한다. GC 수집이 불완전하면 삭제를 거부하고 진행 작업 루트는 건너뛴다. symlink는 따라가지 않는다.
- 첨부 폴더 `./assets`는 문서 기준, `assets`는 루트 기준이다. 절대 경로·역슬래시·독립 `..`·realpath 루트 이탈·symlink 쓰기를 거부한다. 폴더 생성은 `ask` 기본, `never`/`always` 선택이다.
- 신규 내보내기는 모든 번호 후보의 동일 바이트를 먼저 재사용하고 없으면 첫 빈 번호를 쓴다. 기존 연결은 링크·확장자를 유지한다. 일괄 내보내기는 연결된 대상만 갱신하며 독립 성공을 보존한다.
- 렌더 중 문서·대상 이미지 변경은 적용을 거부한다. 사본→이미지 이동→버퍼 링크 순서이며 링크 실패 후 이미지는 남겨 재시도에서 재사용한다. 컨테이너·CRLF를 보존하고 재파싱으로 블록 보존을 확인한다.
- basename wiki는 첨부 폴더 바로 아래 svg/png만 조회하고 동일 stem이 여러 개면 거부한다. 확장자를 명시한 누락 대상은 복구한다. workspace 전체 검색·ignore·Unicode 정규화·동일 폴더 우선 규칙은 이식하지 않았다.
- 진단은 `duplicate-code-id` error, `render-failed` warning, `stale-export` info다. stale-export는 현재 키 캐시가 있을 때만 바이트를 비교한다.

## rendermark 공급 계약

`require('nvim_config.coderunner').diagrams(buf)`는 프로세스를 실행하지 않고 현재 버퍼 위치와 캐시 상태를 반환한다.
각 항목은 `start_row/end_row`(0부터), `key`, `lang`, 선택적 `path/format/error`, `stale`, `status`(`none/pending/ready/failed`)를 가진다.
SVG도 그대로 반환하므로 표시 가능 여부는 소비자가 판단한다.

`request_live(buf, row)`는 미저장 본문 렌더의 접수 여부를 반환한다. 같은 키는 병합·캐시 재사용하며 호출자가 디바운스한다. 미로드 설정을 승인하지 않는다.
`User CodeRunnerDiagrams`, `data={buf=bufnr}`는 완료·실패·블록 목록/본문/위치 변경을 알린다. 완료 이벤트는 render가 요청당 한 번 발행하며 provider는 중복 발행하지 않는다.

## 구현·검증 위치

구현은 `lua/nvim_config/coderunner/`, 스펙은 `tests/spec/coderunner/` 아래에 있다.
아래 스펙 이름에는 `_spec.lua`를 붙인다. 가짜 도구와 공통 도우미는 `tests/fixtures/coderunner/tool.lua`, `tests/spec/coderunner/helpers.lua`다.

| 원본·수용 범위 | 대응 스펙 | 핵심 검증 |
| --- | --- | --- |
| config.rs·trust.rs, A9-9/A10-5–7 | config, trust | 항목 검증·전체 대체·출처·해시 무효화·신뢰 거부 |
| facts.rs | blocks | 속성·컨테이너·빈 줄 연결·중복·EOF 개행·changedtick 캐시 |
| core exec.rs, A10-8–9/A10-14–16 | exec, command, queue, tool | 인자·stdin/env/cwd·steps·출력 상한·timeout·트리 종료·FIFO |
| core/LSP run.rs, A9-8/A10-10–12 | run, result_view | 선택/해시 거부·스트리밍·결과 보관/해제·종료 정리 |
| Neovim execute*.lua, A12-4–5 | output_fence, run, result_view | 긴 펜스·실패·위치 이동·동시 편집 거부·undo |
| core render.rs, A11-1–5/A9-11 | render, cache, autorender | 키·force/stale·동시성·잠금·GC 보호·저장 취소·신뢰 재판정 |
| core/LSP export.rs, A9-10/A11-6–13 | export_plan, export_apply | 링크·경로·동일 바이트·부분 실패·기존 포맷·변경 중 거부 |
| A6-14–15와 공급 API | diagnostics, provider | 진단 해제·미저장 렌더·이벤트·registry·키맵 |

원본 CLI의 JSON/RPC/daemon/oneshot 전용 검사는 제외하고 실행·취소·경합·캐시 보호 의미를 위 서비스 스펙으로 옮겼다.
A11-10의 다른 파일시스템 RenameFile은 같은 파일시스템 복사·이동 및 대상 쓰기 실패 검사로 대체했다.
원본 시나리오별 상세 대조가 필요하면 태그의 `crates/mdloom-core/tests/{exec,run,render,export}.rs`,
`crates/mdloom-lsp/tests/{run,export}.rs`, `crates/mdloom/tests/execute.rs`, `editors/nvim/tests/{execute,execute_unit}.lua`를 연다.

2026-10-30 Linux/Neovim 0.12.4 전체 스펙은 697개 통과, 실패·오류 0이었다. 실제 Python·PlantUML SVG headless smoke도 통과했다.
CRLF·신뢰 거부(secure.read 스텁)·자손 종료·두 인스턴스 manifest 병합은 자동 검증했다. 기존 launcher 가짜 handle의 `is_closing` 정리 경고는 별도 문제다.

```sh
bash run_tests.sh tests/spec/coderunner
bash run_tests.sh
smoke_runtime=$(mktemp -d)
XDG_CACHE_HOME="$smoke_runtime/cache" XDG_STATE_HOME="$smoke_runtime/state" \
  NVIM_LOG_FILE="$smoke_runtime/nvim.log" \
  nvim --headless -u tests/minimal_init.lua -i NONE -l tests/manual/coderunner_smoke.lua
rm -rf "$smoke_runtime"
```

smoke에는 `python3`와 `plantuml` 명령이 필요하다. 이 환경의 PlantUML wrapper는 없는 `/usr/bin/java`를 가리켜 `CODERUNNER_SMOKE_JAVA=/home/ilmoek/.local/jdk-21/bin/java`, `CODERUNNER_SMOKE_JAR=/usr/share/java/plantuml/plantuml.jar`를 추가 지정했다. 시스템 파일은 바꾸지 않았다.

## 성능 기준

2026-10-30 Linux 6.1.177-3-MANJARO/Neovim 0.12.4/LuaJIT, 5,000줄·ID 있는 dot 200블록 입력이다.
콜드 1회, 캐시 1,000회, 나머지 30회 평균이며 프로세스 실행·이미지 디코딩은 제외했다.

| 시나리오 | 개선 전 ms/회 | 개선 후 ms/회 | 개선 후 파싱/전체 버퍼 읽기 |
| --- | ---: | ---: | --- |
| 첫 블록 조회 | 92.240 | 55.614 | 1/1 |
| 변경 없는 조회 | 0.001074 | 0.001223 | 합계 0/0 |
| 문단 편집 후 조회 | 92.334 | 57.472 | 합계 30/30 |
| 디스크·설정·신뢰가 같은 저장 검사 | 114.849 | 0.100404 | 합계 0/0 |
| 매번 한 블록 저장 키 변경 | 114.566 | 79.669 | 합계 30/0 |

changedtick 캐시와 저장 snapshot으로 무변경 비용을 줄였다. 초기·변경 파싱의 56–80ms는 남아 있다.
저장 검사는 디스크를 읽으며 변경 저장 수치에는 테스트 디스크 쓰기도 포함한다. 자동 렌더 debounce는 1시간, 외부 프로세스는 0개였다. GUI 성능 개선을 뜻하지 않는다.

```sh
bench_runtime=$(mktemp -d)
XDG_CACHE_HOME="$bench_runtime/cache" XDG_STATE_HOME="$bench_runtime/state" \
  NVIM_LOG_FILE="$bench_runtime/nvim.log" \
  nvim --headless -u NONE -i NONE -l tests/manual/benchmark_coderunner.lua
rm -rf "$bench_runtime"
```

## 2026-10-30 통합 검증

환경: Linux 6.1.177-3-MANJARO / Rust 1.97.1 / Neovim 0.12.4 / mdloom `lsp-scope`의 `802b9a5` / nvim_config `feature/coderunner` 작업 트리.

| 검증 | 명령·방법 | 결과 |
| --- | --- | --- |
| 전체 자동 | `bash run_tests.sh`, `bash run_integration_tests.sh` | unit 866개·TUI 11개 통과, 실패·오류 0 |
| 실도구 | 위 `tests/manual/coderunner_smoke.lua` | 실제 Python 실행·결과 수명주기·output/undo·실패/긴 펜스, PlantUML SVG·캐시·저장 갱신·export/stale·일괄 갱신·실패 복구·GC dry-run/삭제·현재 이미지 보호·max_jobs=1 통과 |
| 실제 LSP 접합 | `tests/manual/mdloom_integration_smoke.lua`를 실제 init로 실행 | 11그룹 통과. 실제 PNG export의 삭제/복원에 따른 `broken-image`, 이미지 이동 링크 갱신 포함 |
| 실제 neopp | Xvfb + `neopp/build/neopp`, 실제 키 입력·스크린샷 확인 | 결과창/q/재열기/해제, output 삽입·undo·실패/긴 펜스, 렌더·저장 갱신·실패 복구·내보내기 중복 억제 통과 |
| 실제 신뢰 UI | 격리 state에서 `CodeRunnerLoad` → View → `:trust` → 재로드 | 최초 승인·내용 변경 후 무효화/재승인·Deny 시 전역 fallback 차단·Untrust 후 재승인·로드된 승인 철회 통과. `vim.secure.read`를 대체하지 않음 |
| 의존성 검사 | `python3 scripts/check_require_graph.py` | 108모듈·276간선·위반 0·기존 순환 1, 종료 1 |

실제 init 스모크 재실행은 mdloom [검증 기록](../../markdown_lsp/doc/verification.md#2b-nvim_config-실통합-2026-10-30)의 격리 환경 명령을 따른다. GUI는 `RENDERMARK_IMG_STUB`를 해제하고 같은 도구 환경으로 실행했다. Linux 기본 PlantUML wrapper의 Java 경로가 깨져 있어 실도구 검증은 JDK21 PATH, `RENDERMARK_PLANTUML_JAR=/usr/share/java/plantuml/plantuml.jar`, `JAVA_TOOL_OPTIONS=-Djava.awt.headless=true`를 명시했다. 시스템 Java 경로나 머신별 하드코딩은 바꾸지 않았다.

동시 편집 거부·CRLF·자손 종료·두 인스턴스 manifest 병합은 전체 자동 스펙으로 확인했으며, 이를 GUI에서 모두 조작한 결과로 확대하지 않는다. TUI cleanup의 `ENOTEMPTY`는 재현 후 Neovim 종료 대기로 고쳤다. 기본 sandbox의 소켓/설치 parser 쓰기 제한은 권한을 확장한 실행으로 구분했다.

## 남은 검증

1. 사용자가 Windows [W1~W8](../../markdown_lsp/doc/manual-test.md#현행-windows-검증-순서-w1w8)을 순서대로 수행한다. 전체 스펙, 실도구·GUI·신뢰·경로·CRLF·취소/timeout/리더 종료 뒤 자손 정리를 포함한다.
2. Windows의 `taskkill /F /T /PID`는 이미 종료한 리더의 자손을 찾지 못할 수 있다. W7에서 실제 잔존 프로세스를 확인하기 전 트리 정리를 완료로 표시하지 않는다.
3. 기존 coderunner 순환 그룹 1은 미해소다. 이번 통합 작업에서 구조를 바꾸지 않았다. Windows 결과까지 기록한 뒤 C9 전체 완료 여부를 판단한다.

Unix도 다른 프로세스 그룹으로 이탈한 자손은 종료하지 못하며 리더 수거 후 그룹 ID 재사용 경쟁 창이 남는다.
