# 작업 계획서: coderunner (코드 실행·다이어그램 렌더링·내보내기) (1/2 병행)

- 이슈: `.issues/open/issue-coderunner.md`
- 작성: 2026-10-30
- 작업 순서 (2026-10-30 변경): **coderunner (이 문서)**와 mdloom ([`~/workspace/markdown_lsp/doc/work-plans/lsp-scope.md`](../../markdown_lsp/doc/work-plans/lsp-scope.md))은 **병행**하고, 둘이 끝난 뒤 rendermark ([rendermark_plan.md](rendermark_plan.md))를 한다.
- 병행 규칙: mdloom 쪽에서 기능이 제거되어도 이 작업의 원본은 태그 `before-lsp-scope`다. 동작 비교(기능 동등성 검증)가 필요하면 그 태그를 별도 worktree로 빌드해 쓴다: `git -C ~/workspace/markdown_lsp worktree add /tmp/mdloom-before before-lsp-scope && cargo build -p mdloom --manifest-path /tmp/mdloom-before/Cargo.toml`. 사용자 환경에는 두 작업이 모두 끝나기 전까지 mdloom 제거 브랜치를 적용하지 않으므로 `:Mdloom*`와 `:Code*` 명령은 공존할 수 있다(이름이 달라 충돌 없음). 공존 기간에는 진단 중복을 피하기 위해 coderunner 옵션 `diagnostics = false`(기본 true)를 둔다.
- 세 작업은 분리해서 구현하고 각각 테스트한다. 이 작업은 rendermark 변경 없이 끝나야 하고, rendermark에 대한 의존은 6절의 "공급 인터페이스" 하나뿐이다.
- 이식 원본(사양과 코드): mdloom 저장소의 태그 `before-lsp-scope`(2026-10-30 생성, 커밋 fc4d402)와 `doc/archive/before-lsp-scope/` (계약 27~31절의 실행 계층 부분, 34~40절, 설계 "코드 실행"·"다이어그램 렌더링", 결정 CF-10·EX·CR·CC·XP·OP). 아래 "사양 출처"에서 `archive/contracts.md N절`로 줄여 쓴다.

## 1. 배경과 결정

mdloom이 LSP 기능으로 한정되면서 다음 기능이 서버에서 제거된다. 이 계획은 그 기능을 Lua로 새로 구현한다.

| 번호 | 결정 |
| --- | --- |
| D1 | 구현 위치는 `lua/nvim_config/coderunner/`이다. 서버와 통신하지 않는다 (LSP 비의존). |
| D2 | 코드 실행, 다이어그램 렌더링, 내보내기를 한 모듈이 맡는다. |
| D3 | 링크 진단(`broken-image`, 이동 추적)은 mdloom이 일반 링크로서 처리한다. coderunner는 링크 진단을 만들지 않는다. 단, 렌더 실패와 내보낸 이미지 오래됨(`stale-export`)은 서버가 더 이상 알려 주지 않으므로 coderunner가 `vim.diagnostic`으로 알린다. |
| D4 | 신뢰는 `vim.secure.read`까지 쓴다: 워크스페이스 설정은 `vim.secure.read`로 읽고, 전역 설정(사용자 Lua 설정)은 신뢰 확인 없이 쓴다. |
| D5 | 이 작업에서 다시 논의하기로 한 항목: 신뢰·자동 렌더 상호작용(4절 Q1), Windows 프로세스 트리 종료(Q2), 캐시 위치·형식(Q3). |
| D6 | 그리기는 하지 않는다. 렌더 결과 이미지 경로를 rendermark에 넘기는 데이터와 이벤트만 제공한다. |
| D7 | 외부 포맷터는 이번 범위가 아니다 (mdloom에서 제거됨). 코드 포맷은 별도 에디터 플러그인(conform 등) 영역이다. |

## 2. 범위

### 2.1 구현 대상

| 영역 | 내용 |
| --- | --- |
| 코드 실행 | 커서 블록(또는 지정 블록) 실행, 취소, 출력 상한, 타임아웃, 프로세스 트리 종료, 결과 창 |
| 결과 삽입 | 인접 `output` 펜스 생성·교체, 오류 속성, 펜스 길이 |
| 렌더링 | 렌더러 설정으로 SVG/PNG 생성, 해시 키 영속 캐시, 용량 정리, 저장 시 자동 렌더 |
| 내보내기 | 첨부 폴더로 복사, 코드블록 아래 이미지 링크 삽입, 파일명 충돌·동일 바이트 재사용, 갱신 |
| 진단 | `render-failed`(렌더 실패), `stale-export`(내보낸 이미지가 현재 캐시와 다름), `duplicate-code-id` |
| 신뢰 | 전역/워크스페이스 설정, `vim.secure.read` |
| 공급 인터페이스 | rendermark가 소비하는 "블록 → 렌더 이미지" 데이터와 변경 이벤트 |
| 운영 | 프로세스 목록 연동(선택), 진행 표시, 명령, 문서, 테스트 |

### 2.2 구현하지 않는 것

- 이미지 그리기·공간 확보·미리보기 창 (rendermark)
- LSP 연동 (불필요)
- CLI 사용 (헤드리스 `run/render/export/gc`는 mdloom에서 삭제됨. 필요하면 후속 작업으로 `nvim --headless` 래퍼를 검토한다)
- 외부 포맷터
- 여러 에디터 지원 (VS Code 등)
- 세션 간 결과 이력, 재접속 후 결과 복원 (mdloom도 제공하지 않았음)

## 3. 사양 출처 요약 (이식할 규칙)

구현자가 원문을 열지 않고도 큰 틀을 알 수 있도록 핵심 규칙을 모았다. 세부와 근거는 출처 절을 따른다.

### 3.1 코드블록 모델 (archive/design.md "코드블록 속성", contracts.md 10절)

- 펜스 코드블록의 info는 `언어 {#id .class key=value}` 꼴이다 (Pandoc/Quarto 호환).
- 블록 키: `{#id}`가 있으면 `상대경로#id`, 없으면 `상대경로:언어:순번`. 상대경로는 워크스페이스 기준, 구분자 `/`, 순번은 1부터이며 `output` 블록은 순번에 세지 않는다.
- 내용 해시: 코드 본문(컨테이너 표식 제거 후) UTF-8 바이트의 SHA-256. 해시는 키가 아니라 버전이다.
- `output`은 예약 언어다. 실행·렌더 대상이 아니며 다른 언어의 순번에 영향을 주지 않는다.
- 연결: 같은 컨테이너에서 코드블록 바로 다음 블록이 빈 줄 **0~1개**로 떨어져 있고 그 블록이 `output` 펜스이면 그 코드블록의 결과 블록이다. 문단(또는 HTML 블록)이면 그 안의 이미지 링크(표준·위키·`<img src>`)가 내보낸 이미지 후보다. 빈 줄 2개 이상이면 연결하지 않는다.
- 같은 문서에 같은 `{#id}`가 둘 이상이면 중복 (`duplicate-code-id`, error). 중복 블록은 실행·내보내기 대상이 아니다. 다른 문서의 같은 ID는 허용한다.

### 3.2 명령 설정 (archive/contracts.md 27절 "명령 항목", decisions CF-10)

`runners.<이름>`, `renderers.<이름>`:

| 키 | 값 | runners | renderers |
| --- | --- | --- | --- |
| `match` | 비지 않은 문자열 배열 (언어 이름, 빈 문자열 없음) | 필수 | 필수 |
| `ext` | 문자열 | 선택 | 선택 |
| `cmd` / `steps` | 문자열 배열 / 문자열 배열의 배열. 둘 중 하나만 필수 | 필수 | 필수 |
| `timeout` | 시간 | 선택 | 선택 |
| `input` | `"file"`(기본) / `"stdin"` | 선택 | 선택 |
| `output` | `"file"`(기본, `{output}` 경로) / `"stdout"` | — | 선택 |
| `formats` | `"svg"`·`"png"` 배열, 중복 없음 | — | 필수 |
| `env` | 값이 문자열인 표 | 선택 | 선택 |
| `cwd` | 문자열 | 선택 | 선택 |

- 플레이스홀더: `{file}`, `{tmpdir}`, `{docdir}`, `{workspace}`, `{attr.<키>}`, 렌더러 전용 `{format}`·`{output}`. 그 밖의 `{...}`는 그대로 둔다. 치환은 인자 하나 안에서만 하며 결과가 인자를 나누거나 합치지 않고, 치환한 값은 다시 치환하지 않는다. `cmd`·`steps`의 각 인자, `env` 값, `cwd`에 적용한다.
- `{attr.<키>}`가 없으면 실행 전에 거부한다. **렌더러**의 `cmd`/`steps`/`env`/`cwd`에는 `{attr.*}`를 쓸 수 없다 (자동 렌더에서 문서 내용이 명령에 들어가지 않게).
- 같은 언어에 여러 항목이 매치하면 워크스페이스 항목 우선, 같은 출처에서는 이름의 UTF-8 바이트 순 첫 항목. 미신뢰 항목을 전역 항목으로 대체하지 않는다.
- 기본값: 작업 디렉터리 — 러너 `{docdir}`, 렌더러 `{tmpdir}`; `cwd`의 상대 경로는 워크스페이스 기준. 타임아웃 — 항목 `timeout` → 전역 `timeout`(기본 30s). `max_jobs` 4, `max_output` 1MB (스트림별).

### 3.3 실행 계층 (archive/contracts.md 29·30절)

- 셸 없이 인자 배열로 직접 실행한다. 환경 변수는 상속 후 `env`로 덮어쓴다.
- `{tmpdir}`: 실행마다 새 임시 디렉터리 (Unix 0700). `{file}`: `{tmpdir}/input.<ext>`에 코드를 쓴다 (`ext`가 없으면 `input`). `input = "stdin"`이면 stdin으로 넣고 `file`이면 stdin은 비운다. `{output}`: 렌더러에서 `output = "file"`일 때 `{tmpdir}/output.<format>`.
- `steps`: 순서대로 실행, 0이 아닌 코드로 끝나면 뒤 단계는 실행하지 않는다. 타임아웃은 steps 전체에 한 번.
- 슬롯: 전역 동시 실행 상한 `max_jobs`, 넘는 작업은 FIFO 대기, 대기 중 취소 가능(프로세스를 띄우지 않음). 타임아웃은 슬롯을 얻은 때부터 잰다.
- 타임아웃·취소는 유예 없이 프로세스 트리를 바로 종료한다. 리더 종료 후 남은 자손도 종료한다.
- 출력 상한은 stdout/stderr 각각 `max_output`. 넘는 출력도 끝까지 읽어 버려 자식이 막히지 않게 하고, 스트림별 잘림 여부를 기록한다.
- 결과 종류: 성공 / 실패(코드, 신호면 코드 없음) / 도구 없음 / 시작 실패(작업 디렉터리 없음·권한) / 타임아웃 / 취소. 시작 실패와 도구 미설치를 구분한다 (없는 cwd도 OS는 NotFound로 알림).
- 취소·타임아웃 결과의 출력은 그때까지 읽은 내용이다. 출력은 UTF-8로 정리해 잘못된 바이트는 `�`로 바꾼다.

### 3.4 실행 서비스 (archive/contracts.md 34절)

- 요청: 블록 키, (선택) 내용 해시. 중복 ID, `output` 블록, 러너 없는 언어, 오래된 해시는 거부한다.
- 결과: 상태(`success`/`failed`/`cancelled`/`timeout`), 종료 코드, 경과(슬롯 획득 후), stdout/stderr와 잘림 여부, 임시 폴더의 산출물 파일 목록(일반 파일만, symlink 미추적, 실행용 입력 `input.*`만 제외하되 사용자가 만든 `input.*`는 이름만으로 제외하지 않음), 오류 사유 문자열.
- 열기·저장·인덱싱은 러너를 실행하지 않는다. 실행은 명시적 요청에서만.
- 결과·임시 산출물 보존: 연결(세션)이 살아 있는 동안은 시간 만료 없이 보존하되 **완료 작업 100개 · 256MiB** 상한, 초과 시 오래된 완료 결과부터 정리(진행 작업 제외, 최신 결과 하나가 상한을 넘으면 그것은 보존하고 초과를 알림). 종료 후 임시 산출물은 24시간 보존, 만료 정리는 시작 시와 1시간마다. 영구 보관은 사용자가 복사한다.
- 해제: 완료 결과만 명시적으로 삭제할 수 있다. 진행 중 작업은 취소 안내.

### 3.5 렌더링과 캐시 (archive/contracts.md 35·36절)

- 렌더 키 = hash(코드, 렌더러 설정, 포맷, 치환한 명령 인자/env/cwd). 실행별 경로(file/tmpdir/output)는 토큰으로 남겨 키가 실행마다 달라지지 않게 한다. `{docdir}`를 쓰지 않는 렌더러는 문서 폴더가 달라도 캐시를 공유한다. 외부 참조 파일과 도구 버전은 키에 넣지 않는다 (바뀌면 force).
- 조회: 현재 키 파일 우선, 없으면 manifest의 마지막 성공 이미지를 `stale = true`로 반환. 실패는 현재 키와 메시지 앞 1024자를 저장하고 같은 키 성공 시 지운다. 다른 키의 실패는 조회하지 않는다.
- `force`는 같은 경로를 원자 교체. 취소 결과는 게시하지 않는다. 교체 실패 시 기존 이미지를 유지한다.
- 같은 키는 직렬화(기다리는 동안 취소 가능, 선행 작업 후 캐시 재확인), 다른 키는 병렬. 출력은 비어 있지 않은 바이트여야 한다.
- 용량: 기본 512MB, 워크스페이스별 이미지 크기 합계에 적용, 저장 완료 후 초과분을 보호 대상 밖에서 **수정 시각이 오래된 순**으로 삭제. 보호: 저장 문서의 현재 이미지, 현재 이미지가 없을 때 마지막 성공 미리보기, 사용·갱신 중인 이미지. 보호 이미지만으로 초과하면 유지하고 알린다.
- 저장 시 자동 렌더: 열 때 실행 없이 디스크의 렌더 키를 기준선으로 기록. 저장 시 바뀐 키의 블록만 예약, 같은 블록의 앞 작업은 취소. 새 저장·닫기는 진행 작업을 취소하고 편집만으로는 취소하지 않는다(C6). 자동 실패는 같은 저장 키로 반복하지 않고 명시적 렌더나 코드 변경으로 재시도. 설정: `auto_render`(기본 true), `auto_render_debounce`(기본 200ms).
- 진단: 현재 키의 렌더가 실패하면 코드블록 첫 줄에 `render-failed`(warning, 메시지에 stderr 첫 줄). 성공하거나 키가 바뀌면 사라진다. 렌더링이 실제로 실행된 블록에만 생긴다.

### 3.6 내보내기 (archive/contracts.md 37·38절)

- 이미지 인접성은 3.1의 규칙을 따른다. 인접 이미지 중 첨부 폴더 아래 첫 이미지를 재사용한다. 없는 대상도 기존 인접 링크로 복구한다.
- 첨부 폴더: 기본 `./assets` (`./`로 시작하면 문서 폴더 기준, 그 밖의 상대 경로는 워크스페이스 루트 기준). `/` 구분자만 허용, 역슬래시·절대 경로·독립된 `..`는 설정 오류. 실제 경로 확인으로 루트 이탈과 심볼릭 링크 탈출을 거부한다. **폴더가 없으면 사본 생성 전에 거부**한다 (자동 생성하지 않음). 기존 이미지의 자동 이동은 하지 않는다.
- 새 파일명 = 문서 stem + 블록 ID(없으면 언어와 같은 언어 순번), 파일명 구분자·제어 문자는 `-`. 기존 파일을 덮어쓰지 않고 번호(`-2`, `-3`)를 붙인다. 모든 번호 후보를 먼저 검사해 중간 번호가 비어도 **동일 바이트 파일을 재사용**(링크만 삽입)한다.
- 인접 이미지 확장자와 요청 포맷이 다르면 거부. 일괄 갱신은 기존 확장자를 유지한다.
- 새 링크는 링크 스타일(markdown 기본/wiki)을 따르고, 닫는 펜스 줄의 인용·리스트 들여쓰기 접두사를 보존한다. 삽입 후 재파싱해 기존 코드 내용·언어·ID·블록 수 보존과 새 이미지의 해당 블록 연결을 검사한다. 보존할 수 없으면 거부. CRLF 보존.
- 적용 순서: (1) 사본 생성 (2) 이미지 이동(덮어쓰기 여부 구분) (3) 링크 편집. 실패 시 사본만 정리하고 워크스페이스 이미지는 지우지 않는다. 이동 후 링크 실패는 재시도 시 동일 바이트에 링크만 넣는다.
- `exportAll`: 이미 연결된 내보내기만 갱신 (신규 첨부 없음). 모든 대상을 먼저 준비하고 일부 실패는 미적용 목록을 보고한다.
- `stale-export`(info): 현재 캐시가 있을 때만 내보낸 이미지 바이트와 비교, 다르면 이미지 링크 위치에 알리고 "다시 내보내기" 동작을 제공. 캐시 없음은 미판정.

### 3.7 UI (archive/contracts.md 40절, nvim.md)

- 명령: 실행 / 실행 후 output 삽입 / 취소 / 마지막 결과 다시 열기 / 해제 / 렌더 / 강제 렌더 / 전체 렌더 / 내보내기 / 전체 갱신 / 신뢰 상태·신뢰·철회.
- 결과 창: 읽기 전용 floating scratch. 상태·stdout·stderr·잘림·오류·산출물 경로. 진행 작업과 마지막 결과만 제공. `q`는 창만 닫고 결과는 해제 전까지 남는다.
- 삽입은 stdout만. 요청 당시 소스·인접 output과 완료 뒤 현재 블록을 비교: 다른 영역 편집으로 **위치만 바뀌면 허용**, 소스·기존 output이 바뀌면 거부. 인접 결과가 없으면 빈 줄 하나 뒤에 생성. 맨 왼쪽 최상위 펜스만 지원하고 인용·리스트 안 블록은 표시만 한다.
- 삽입 형식: 펜스는 출력 안 최장 백틱 런보다 길게(최소 3), 실패는 `output {.error}`, 실행 시각·해시는 넣지 않는다.

## 4. 결정이 필요한 항목 (이 작업에서 다시 논의)

| ID | 질문 | 선택지 | 권장 |
| --- | --- | --- | --- |
| Q1 | 워크스페이스 설정과 신뢰의 상호작용. `vim.secure.read`는 알 수 없는 파일에서 대화형 프롬프트를 띄우므로 저장 시 자동 렌더에서 부를 수 없다 | (a) 워크스페이스 설정은 사용자의 명시적 명령(`:CodeRunnerLoad` 또는 첫 `:CodeRun`)에서만 `vim.secure.read`로 읽고, 읽은 결과를 해시와 함께 메모리에 캐시한다. 자동 렌더는 메모리에 로드된 설정만 쓴다. (b) 신뢰 DB 파일을 직접 읽어 프롬프트 없이 판정한다. | **(a)**. (b)는 Neovim 내부 파일 형식에 의존한다. 설정 파일 내용이 바뀌면 해시가 달라 메모리 캐시를 무효화하고 다시 로드 명령을 요구한다. |
| Q2 | Windows 프로세스 트리 종료. mdloom은 Job Object(`KILL_ON_JOB_CLOSE`)를 썼다 | (a) `taskkill /F /T /PID`. (b) LuaJIT FFI로 Job Object 직접 사용. (c) 트리 종료를 Windows에서는 최선 노력으로 문서화 | **(a)로 시작**하고 테스트(손자 프로세스 종료 확인)로 한계를 기록한다. (b)는 (a)가 불충분할 때만. |
| Q3 | 캐시 위치와 형식 | (a) `stdpath('cache')/coderunner/<루트 해시>/diagrams`, manifest는 JSON. (b) 문서 옆 `.coderunner/` | **(a)**. mdloom 캐시(`~/.cache/mdloom/...`)와 호환하지 않고 새로 시작한다 (마이그레이션 불필요). |
| Q4 | 워크스페이스 설정 파일 이름과 위치 | (a) `<root>/.coderunner.lua` (`vim.secure.read`로 로드, 반환값은 설정 표). (b) `.prjroot`의 `coderunner` 키 | **(a)**. `.prjroot`는 이미 `BufRead`에서 신뢰 확인 없이 로드되므로 명령 정의를 거기에 두면 신뢰 모델이 무력화된다. 루트는 `prjroot.GetProjectRoot`를 쓴다. (`.prjroot`의 무확인 로드 자체는 기존 동작이며 이 작업의 범위가 아니지만 위험을 `docs/coderunner.md`에 적는다.) |
| Q5 | 결과 창 구현 | (a) 새 플로팅 창(mdloom 방식) (b) 기존 `launcher.output` 버퍼 재사용 | **(a)**. launcher는 프로젝트 태스크용이고 결과 수명·해제 모델이 다르다. 대신 프로세스 목록에는 등록한다 (C8). |
| Q6 | `duplicate-code-id` 진단 방식 | (a) `vim.diagnostic` 네임스페이스 `coderunner` (b) 실행 시도 때만 알림 | **(a)**. mdloom의 error 심각도를 유지한다. |
| Q8 | 문서를 열 때 캐시에 없는 다이어그램을 자동으로 렌더할지 (기존 rendermark는 보이는 PlantUML 블록을 열 때 자동 렌더했다) | (a) 열 때 렌더하지 않고 캐시 조회만 (mdloom 규칙) (b) 전역 설정의 렌더러에 한해 `render_on_open` 옵션으로 허용 | **(b)**, 기본값 `false`, 사용자의 `init.lua`에서 `true`로 켜서 기존 경험을 유지한다. 워크스페이스 설정 렌더러에는 적용하지 않는다(로드 안 된 설정은 실행 불가). 뷰포트 밖 블록은 렌더하지 않고 `BufWinEnter`/스크롤 때 보이는 블록만 요청한다. |
| Q7 | 내보내기에서 첨부 폴더가 없을 때 | (a) 거부(mdloom과 동일) (b) 확인 후 생성 | **(b)**. 사용자가 이미 같은 에디터에 있으므로 `vim.fn.confirm`으로 묻는 편이 낫다. 설정으로 `create_attachments_dir = 'ask'|'never'|'always'`를 둔다 (기본 `ask`). mdloom은 에디터 편집 경계 때문에 거부했지만 coderunner에는 그 제약이 없다. |

## 5. 구조

```
lua/nvim_config/coderunner/
  init.lua        setup(opts), 명령 등록, 공개 API
  config.lua      옵션 기본값, 항목 검증, 전역/워크스페이스 병합, 플레이스홀더 검증
  trust.lua       vim.secure.read 래퍼, 로드된 워크스페이스 설정 캐시(해시), 신뢰 상태
  blocks.lua      treesitter로 펜스 코드블록 파싱: lang, 속성, 범위, 코드, 키, 해시, output·이미지 연결
  exec.lua        단일 프로세스 실행 엔진: spawn, 타임아웃, 출력 상한, 트리 종료
  queue.lua       전역 슬롯(max_jobs) FIFO, 대기 중 취소
  command.lua     명령 항목 → 실행 요청: 플레이스홀더 치환, tmpdir, 단계 실행
  run.lua         러너 실행 서비스: 요청 검증, 작업 상태, 결과 보관(100개/256MiB), 해제
  result_view.lua 결과 플로팅 창
  output_fence.lua output 펜스 삽입·교체
  render.lua      렌더 서비스: 키, 조회, force, 실패 기록
  cache.lua       영속 캐시, manifest, 잠금, 용량 정리, gc
  autorender.lua  저장 시 자동 렌더, 기준선, 디바운스, 취소
  export.lua      내보내기 계획·적용, 파일명, 동일 바이트 재사용, 링크 삽입
  diagnostics.lua vim.diagnostic: render-failed, stale-export, duplicate-code-id
  provider.lua    rendermark 공급 인터페이스(6절)
  progress.lua    spinner·알림 (기존 spinner.lua 재사용)
tests/spec/coderunner/*_spec.lua
tests/fixtures/coderunner/ (가짜 도구 스크립트, 샘플 문서)
docs/coderunner.md (사용자 문서)
```

기존 모듈 재사용:
- `nvim_config.util.cache`, `nvim_config.util.job`(`AsyncProcess`는 프로세스 그룹/타임아웃이 없으므로 exec.lua는 `vim.uv.spawn`을 직접 쓴다), `nvim_config.spinner`, `nvim_config.prjroot`(루트 판정), `nvim_config.launcher.registry`(프로세스 목록 등록).
- 시간·크기 파서(`30s`, `1MB`)는 새로 작성한다 (mdloom은 CF-4 형식: `<양의 정수><단위>`, 단위 `ms`·`s`·`m`·`h` / `B`·`KB`·`MB`·`GB`, 1024 배수, 공백·소수·0 불가).

## 6. 공급 인터페이스 (rendermark와의 계약)

coderunner는 rendermark를 `require`하지 않는다. 데이터와 이벤트만 제공한다.

```lua
-- 한 버퍼의 다이어그램 블록과 현재 렌더 상태. 렌더나 캐시 조회를 하지 않고 메모리/캐시 조회만 한다.
---@class coderunner.DiagramItem
---@field start_row integer   0-based, 펜스 여는 줄
---@field end_row integer     0-based, 펜스 닫는 줄
---@field key string          블록 키
---@field lang string
---@field path string?        렌더된 이미지 절대 경로 (없으면 nil)
---@field format 'svg'|'png'? 
---@field stale boolean       현재 키가 아닌 마지막 성공 이미지
---@field status 'ready'|'pending'|'failed'|'none'
---@field error string?       실패 사유 첫 줄
require('nvim_config.coderunner').diagrams(buf) --> coderunner.DiagramItem[]
```

- 이벤트: `User` 자동명령 패턴 `CodeRunnerDiagrams`, `data = { buf = <bufnr> }`. 렌더 완료·실패·캐시 갱신·블록 목록 변화 때 발행한다. 편집 중 블록 위치는 `diagrams(buf)` 호출 시점의 treesitter 파싱 결과로 계산하므로 호출자가 위치를 따로 추적하지 않아도 된다.
- 이미지 포맷은 `png` 우선(`vim.ui.img` 지원 범위). 렌더러 설정의 첫 포맷이 `png`가 아니면 `diagrams()`는 `format = 'svg'` 항목을 그대로 돌려주고 소비자가 표시 가능 여부를 정한다.
- 미저장 텍스트 미리보기(rendermark의 커서 블록 미리보기용):

```lua
-- 지금 버퍼의 블록 텍스트(저장 여부와 무관)를 렌더한다. 같은 렌더 키는 캐시를 재사용하므로 반복 호출해도 도구는 한 번만 실행된다.
-- 디바운스는 호출자가 한다. 완료되면 CodeRunnerDiagrams 이벤트가 발행되고 diagrams(buf)의 해당 항목이 ready가 된다.
require('nvim_config.coderunner').request_live(buf, row) --> boolean (요청이 접수됐는지)
```

  `request_live`는 사용자가 그 블록을 보고 있다는 신호이므로 신뢰 판정은 단일 요청 규칙(3.2·C1)을 따른다. 즉 로드된 워크스페이스 설정 또는 전역 설정의 렌더러만 쓴다.
- 이 인터페이스 외에 rendermark와 공유하는 코드는 없다. 합치는 glue는 rendermark 작업(3/3)에서 `lsp/servers/markdown.lua` 대신 별도 glue 파일에 둔다.

## 7. 단계

각 단계는 (a) 구현 (b) 단위/통합 스펙 (c) 완료 조건을 가진다. 스펙 파일은 `tests/spec/coderunner/` 아래 `*_spec.lua`이고 `bash run_tests.sh tests/spec/coderunner/<파일>`로 개별 실행한다. 모든 단계 끝에서 `bash run_tests.sh`(전체)가 통과해야 한다.

### C0 — 준비와 시나리오 추출

- [x] mdloom 태그 `before-lsp-scope` 존재 확인 (2026-10-30 생성됨)
- [x] 사양 출처의 수용 시나리오를 coderunner 시나리오 표로 옮긴다. 이 문서 9절 "이식 시나리오" 표를 기준으로, 원본 테스트(`crates/mdloom-core/tests/{exec,run,render,export}.rs`, `crates/mdloom-lsp/tests/{run,export}.rs`, `crates/mdloom/tests/execute.rs`, `editors/nvim/tests/{execute,execute_unit}.lua`)를 읽고 케이스를 빠짐없이 나열해 `docs/coderunner_scenarios.md`에 남긴다 (각 케이스: 입력, 동작, 기대, 대응 스펙 파일)
- [x] 가짜 도구 설계: `tests/fixtures/coderunner/tool.lua` — `nvim -l`로 실행되는 스크립트. 모드 인자로 (echo 입력) (지정 종료 코드) (지정 시간 대기) (stdout/stderr 대량 출력) (손자 프로세스 생성 후 대기) (stdin 반사) (인자·env·cwd 덤프) (출력 파일 쓰기). `vim.v.progpath`로 자기 자신을 호출하므로 플랫폼 독립적이다. mdloom의 "테스트가 자기 자신을 자식으로 띄우는" 방식과 같다 (`crates/mdloom-core/tests/exec.rs`)
- [x] 스펙 도우미: 임시 워크스페이스 생성(.git 표식), 문서 쓰기, 버퍼 열기, 대기(`vim.wait`) 유틸 `tests/spec/coderunner/helpers.lua`
- 완료 조건: 시나리오 문서가 mdloom 원본 테스트 케이스를 모두 포함하고 리뷰됨. 가짜 도구가 Linux에서 동작.

### C1 — 설정과 신뢰 (config.lua, trust.lua)

구현:
- [x] `setup(opts)`: 전역 옵션 — `runners`, `renderers`, `max_jobs`, `timeout`, `max_output`, `auto_render`, `auto_render_debounce`, `render_max_size`, `attachments`, `link_style`, `create_attachments_dir`
- [x] 항목 검증(3.2절 표): 필수/선택, 값 형식, `cmd`/`steps` 택일, `formats`, 렌더러의 `{attr.*}` 금지, 알 수 없는 키 경고. 오류 메시지에 항목 이름(`runners.python`)을 포함
- [x] 병합: 내장 기본값 → 전역 → 워크스페이스(로드된 경우). 같은 이름이면 높은 순위가 항목 전체 교체, 항목마다 출처(`global`/`workspace`) 기록
- [x] 선택 규칙: match가 겹치면 워크스페이스 우선, 같은 출처 안에서는 이름 바이트 순 첫 항목
- [x] 워크스페이스 설정(Q1·Q4): `<root>/.coderunner.lua`를 `vim.secure.read`로 읽어 `load` 후 표를 검증. 읽기는 명시적 명령(`:CodeRunnerLoad`, 첫 `:CodeRun`/`:CodeRender`)에서만. 결과를 `{hash=vim.fn.sha256(text), config=...}`로 메모리에 보관. 파일 내용이 바뀌면 다음 사용 때 해시 불일치로 무효화하고 로드를 다시 요구
- [x] `:CodeRunnerTrust`(상태 표시), `:CodeRunnerUntrust`(`vim.secure.trust({action='remove', path=...})`)
- [x] 허용 판정(3.2 및 archive/contracts.md 27절 표를 Lua에 맞게 단순화):

  | 항목 출처 | 단일 요청(사용자가 블록 하나 지정) | 일괄·자동 |
  | --- | --- | --- |
  | 전역 | 허용 | 허용 (전역 설정은 사용자의 Lua 설정이므로 신뢰함) |
  | 워크스페이스, 로드됨 | 허용 | 허용 |
  | 워크스페이스, 로드 안 됨/거부됨 | 거부 | 거부 |

  mdloom은 "미신뢰 워크스페이스의 전역 렌더러는 일괄 거부"였다. coderunner의 전역 설정은 모든 워크스페이스에 적용되므로 **미신뢰 워크스페이스(워크스페이스 설정 파일은 있으나 로드 거부됨)에서는 전역 렌더러의 자동·일괄 렌더를 거부하고 단일만 허용**하는 규칙을 유지한다. 워크스페이스 설정 파일이 없으면 신뢰 문제가 없으므로 허용한다.
- C4 서비스 선택 정책 확정: 위 표의 전역 단일 허용은 **워크스페이스 설정 파일이 없거나 로드된 경우**에 적용한다. Lua를 신뢰 전에 평가해 이름을 알아낼 수 없으므로, 파일이 있는데 로드 거부·실패·미로드 상태면 전역으로 대체하지 않고 단일 요청도 거부한다. `trust.can_select(status)`를 실행·후속 렌더/provider의 공용 진입 판정으로 사용한다. 이는 미신뢰 항목의 전역 fallback 금지를 우선한 의도적 제한이다.
- [x] 스펙: `config_spec.lua`(검증 표 전 항목, 병합, 선택 순서, 시간·크기 파서 경계), `trust_spec.lua`(로드/거부/내용 변경 후 무효화/철회; `vim.secure.read`는 스텁으로 대체)

완료 조건: 위 스펙 통과. 잘못된 설정은 이 항목만 거부하고 다른 항목·플러그인 동작에는 영향이 없다.

### C2 — 블록 파서 (blocks.lua)

구현:
- [x] treesitter `markdown` 파서로 `fenced_code_block` 순회. 필요한 정보: info 문자열(`info_string`), 여는/닫는 펜스 범위, 내용 범위, 들여쓰기·컨테이너 접두사(인용 `>`, 리스트 들여쓰기)
- [x] 속성 파서: `{#id .class key=value key="따옴표 값"}` (Pandoc 호환). 잘못된 속성은 블록을 속성 없는 것으로 취급하고 진단은 내지 않는다
- [x] 코드 본문: 컨테이너 표식과 펜스 들여쓰기만큼의 앞 공백 제거, 코드 자체의 들여쓰기 유지, 줄바꿈은 `\n`으로 정규화(CRLF 문서도 같은 해시)
- [x] 블록 키와 순번(3.1), 내용 해시(`vim.fn.sha256`)
- [x] 연결: output 블록(빈 줄 0~1), 이미지 문단(빈 줄 0~1; 표준·위키·HTML 이미지; `output` 블록 자신은 연결하지 않음)
- [x] 중복 ID 검출
- [x] 닫히지 않은 펜스(문서 끝까지)를 mdloom과 같은 방식으로 다루는지 treesitter 결과를 확인
- [x] 틸드 펜스(`~~~`), 펜스 길이 4 이상, 백틱 포함 info 등 엣지
- [x] 성능: 큰 문서(예: 5,000줄)에서 `changedtick` 캐시로 반복 파싱을 피한다 (rendermark `image/blocks.lua`의 `block_cache` 방식 참고)
- [x] 스펙: `blocks_spec.lua` — archive/design.md의 속성 문법 예시, 키 규칙(순번이 output을 세지 않음), 해시 동일성(컨테이너·CRLF 차이), 연결 판정(빈 줄 0·1·2), 중복 ID, 컨테이너 안 블록, 엣지 케이스

완료 조건: 스펙 통과. mdloom 원본 `facts.rs` 테스트의 코드블록 관련 케이스가 모두 대응된다.

### C3 — 실행 엔진 (exec.lua, queue.lua, command.lua)

구현:
- [x] `exec.run_step(argv, opts)`: `vim.uv.spawn`, stdio 파이프 3개, `cwd`, `env`(상속 + 덮어쓰기), 유닉스에서는 `detached = true`로 새 프로세스 그룹. stdin 입력 쓰기 후 닫기
- [x] 출력 수집: 스트림별 `max_output`까지 보관, 초과분은 읽어서 버림, 잘림 플래그
- [x] 타임아웃: 슬롯 획득 후 `vim.uv.new_timer`, 만료 시 트리 종료 후 `timeout` 상태
- [x] 취소: 동일하게 트리 종료 후 `cancelled`
- [x] 트리 종료:
  - Linux/macOS: `vim.uv.kill(-pid, 'sigkill')` (그룹 전체). 리더 종료 후 남은 자손도 종료하기 위해 리더 종료 콜백에서 그룹에 `SIGKILL` 전송 (mdloom 동작). 그룹 ID 재사용 위험: 리더를 거두기 전에 그룹을 죽인다는 mdloom의 규약은 `uv` 비동기 모델에서는 `exit` 콜백 안에서 pid 재사용 창이 작다. 위험을 문서화하고, 가능하면 `exit` 콜백 안에서 먼저 그룹 kill을 호출한다
  - Windows: Q2 (a) `taskkill /F /T /PID <pid>` 실행. 종료 확인 로직(손자 프로세스 소멸 확인)을 스펙에서 검증. 실패하면 (b) 검토
- [x] 결과 종류: `success`, `failed{code|signal}`, `not_found{program}`, `spawn_failed{message}`, `timeout`, `cancelled`. `spawn` 실패 시 cwd 존재를 먼저 확인해 `not_found`와 구분
- [x] 출력 UTF-8 정리: 잘못된 바이트를 `\xEF\xBF\xBD`로 치환 (조각 경계 보존: 스트리밍 청크는 완결된 문자 단위로만 전달하거나 최종 결과에서만 정리)
- [x] `queue.lua`: `max_jobs` 슬롯, FIFO, 대기 중 취소 시 대기열에서 제거(프로세스 미생성), `set_max_jobs`로 재설정 시 실행 중 작업은 유지하고 대기 작업부터 새 상한 적용
- [x] `command.lua`: 항목 → 실행 요청
  - 플레이스홀더 치환(3.2): `{file}`, `{tmpdir}`, `{docdir}`, `{workspace}`, `{attr.*}`, `{format}`, `{output}`. 한 번 치환, 재치환 없음, 모르는 `{...}` 보존, 인자 경계 불변
  - `{tmpdir}`는 `vim.fn.tempname()` 기반이 아니라 전용 디렉터리: `<tmp>/coderunner-<pid>-<n>` (유닉스 0700, 존재하면 다음 번호). 슬롯을 얻은 뒤 생성하고 그 시간도 타임아웃에 포함
  - `{file}` 쓰기: `{tmpdir}/input.<ext>`. `input='stdin'`이면 stdin에 코드 전달, `file`이면 stdin 비움
  - `steps`: 순차 실행, 실패 시 중단
  - `cwd`: 치환 뒤 상대 경로이면 워크스페이스 기준, 디렉터리가 아니면 `spawn_failed`
  - 플레이스홀더 `{attr.*}`가 없으면 실행 전 오류(`missing_attr`), 어떤 단계도 실행하지 않음
- [x] 산출물 정리: 결과 객체가 해제되거나 정리 규칙에 따라 삭제될 때 `{tmpdir}` 삭제
- [x] 스펙: `exec_spec.lua`(가짜 도구로 인자·stdin·env·cwd 전달, 실패 코드, 신호 종료, 타임아웃, 취소, 손자 프로세스 종료, 대량 출력의 상한과 잘림, 파이프 막힘 없음, 도구 없음·cwd 없음 구분), `queue_spec.lua`(슬롯 FIFO, 대기 취소, 상한 변경), `command_spec.lua`(치환 규칙 전 케이스, `steps` 중단, `{attr}` 누락, 재치환 방지, 인자 합치기 방지, 쉘 메타문자(`; rm -rf`, `$(…)`)가 인자로 그대로 전달됨)

완료 조건: 위 스펙 통과(Linux). Windows 환경에서도 같은 스펙이 통과하거나 알려진 한계가 `docs/coderunner.md`에 기록됨.

### C4 — 러너 서비스와 UI (run.lua, result_view.lua, output_fence.lua)

구현:
- [x] `run.start(buf, selector)`: 블록 선택 — 커서가 속한 블록 또는 키/`#id`/`언어:순번` 지정. 후보(같은 블록에 매치하는 러너)가 여럿이면 3.2의 선택 규칙으로 하나를 고른다
- [x] 요청 검증: 중복 ID, `output` 블록, 러너 없음, 오래된 해시, 신뢰(C1) — 거부 시 이유를 알림
- [x] 작업 객체: `id`, 상태, 시작/경과, stdout/stderr 스트림 이벤트, 최종 결과(3.4), 산출물 목록. 완료된 작업은 보관(100개/256MiB), 해제 명령으로 삭제. 임시 폴더 24시간 보존 후 정리(시작 시와 1시간마다 `vim.uv.new_timer`)
- [x] 결과 창: 플로팅 scratch, 상태·stdout·stderr·잘림·오류·산출물 경로. `q`는 창만 닫는다. 진행 중 스트리밍 갱신, 늦은 스트리밍이 최종 출력을 덮지 않게 한다
- [x] 명령: `:CodeRun [selector]`, `:CodeRun! [selector]`(성공/실패 모두 output 삽입), `:CodeCancel`, `:CodeOutput`, `:CodeRelease`
- [x] output 삽입(`output_fence.lua`): 3.7의 규칙
  - 대상 블록은 시작 시 extmark로 추적. 완료 시 현재 소스·기존 output을 요청 당시와 비교: 소스가 바뀌었거나 기존 output이 바뀌었으면 거부, 위치만 바뀌었으면 허용
  - 인접 output이 있으면 내용 교체(펜스 길이 재계산), 없으면 닫는 펜스 아래 빈 줄 하나 뒤에 생성
  - 펜스 길이 = max(3, 출력 안 최장 백틱 런 + 1). 실패는 info에 `{.error}`
  - 단일 `nvim_buf_set_lines` 호출로 한 번의 undo 단위. `modifiable`이 아니면 거부
  - 최상위(들여쓰기 0) 펜스만 지원, 컨테이너 안은 표시만
- [x] 진행 표시: `progress.lua`가 `spinner.lua`로 상태줄/알림에 실행 중 표시
- [x] 스펙: `run_spec.lua`(블록 선택·거부 사유, 실행→결과, 취소, 타임아웃, 해제, 보관 상한, 열기/저장이 실행을 일으키지 않음), `output_fence_spec.lua`(삽입·교체·긴 펜스·`{.error}`·위치 이동 허용·소스/기존 output 변경 거부·컨테이너 안 블록 표시만·undo 한 단계), `result_view_spec.lua`(q로 닫기, 다시 열기, 해제 후 상태)

완료 조건: 스펙 통과. 수동: 파이썬 블록에서 `:CodeRun`, `:CodeRun!`을 실행해 output이 생성/교체되고 undo 한 번으로 되돌려진다.

### C5 — 렌더링과 캐시 (render.lua, cache.lua)

구현:
- [x] 렌더 요청: 블록 + 렌더러 + 포맷(생략 시 `formats` 첫 항목) + `force`
- [x] 렌더 키 계산(3.5). 구현 세부: 치환된 argv/env/cwd 중 실행별 경로(`{file}`·`{tmpdir}`·`{output}`)는 고정 토큰으로 치환한 문자열을 키 입력에 포함
- [x] 캐시 레이아웃(Q3): `stdpath('cache')/coderunner/<루트 해시>/diagrams/<lang>-<키>.<fmt>`, `manifest.json`(블록 키 → {마지막 성공 키·경로·시각, 현재 실패{키, 메시지 앞 1024자}}). 루트 해시는 정규화한 루트 경로의 sha256 앞부분
- [x] 조회(`lookup(block)`): 현재 키 파일 → 없으면 manifest의 마지막 성공(stale) → 없으면 none. 도구 실행 없음
- [x] 렌더: 슬롯 획득 → 도구 실행 → 출력 파일 검증(존재, 크기>0) → 임시 이름에 쓰고 `uv.fs_rename`으로 원자 교체. `force`면 기존 파일 교체(실패 시 기존 유지). 취소된 결과는 게시하지 않음. 실패는 manifest에 기록하고 같은 키 성공 시 삭제
- [x] 동시성: 같은 키는 프로세스 내 직렬화(Promise 유사 대기 목록, 기다리는 동안 취소 가능, 선행 완료 후 재확인), 다른 키는 병렬. 여러 Neovim 인스턴스 간 보호는 `O_EXCL` 잠금 파일 + 소유 pid 확인(stale 잠금 회수). manifest 갱신은 읽기-병합-쓰기를 잠금 안에서
- [x] 용량 정리: 렌더 저장 후 워크스페이스 이미지 크기 합계가 `render_max_size`를 넘으면 보호 대상 밖에서 수정 시각 오래된 순 삭제. `unlimited` 허용(`0`은 무제한이 아님)
- [x] gc: `:CodeGc [dry-run]`, `:CodeGc! all` — 현재 디스크 키·사용 중 이미지·필요한 마지막 성공 이미지는 보존, 참조 없는 캐시 삭제. 진행 중 작업이 있는 워크스페이스는 건너뜀. `all`은 모든 루트 폴더를 검증 후 처리
- [x] 명령: `:CodeRender[!] [selector]`, `:CodeRenderAll`
- [x] 진단(`diagnostics.lua`): `render-failed` — 현재 키가 실패 상태이고 실제 렌더가 실행된 블록의 첫 줄, 메시지 = stderr 첫 줄. 성공/키 변경 시 제거. `duplicate-code-id`(Q6)
- [x] 이벤트: 렌더 완료/실패/캐시 갱신 시 `User CodeRunnerDiagrams` 발행(6절)
- [x] 스펙: `render_spec.lua`(키가 설정·내용·포맷·docdir 사용에 따라 달라지는지, 실행별 경로 토큰화, 같은 키 캐시 적중, force 교체, 블록 재배치 후 조회, stale 반환, 실패 기록·복구), `cache_spec.lua`(원자 교체, manifest 병합, 잠금 회수, 용량 정리 순서와 보호 대상, gc 보호 규칙, 불완전 수집 시 삭제 거부), `diagnostics_spec.lua`

완료 조건: 스펙 통과. 수동: plantuml(또는 가짜 렌더러)로 렌더→캐시 적중→문서 수정→재렌더.

### C6 — 저장 시 자동 렌더 (autorender.lua)

구현:
- [x] 기준선: `BufReadPost` 시 실행 없이 현재 블록들의 렌더 키를 기록 (디스크 문서 기준)
- [x] `BufWritePost`: 디스크를 다시 읽어 키를 계산하고 기준선과 다른 블록만 예약. 같은 블록의 앞 작업은 취소. 디바운스 `auto_render_debounce`
- [x] 편집(`TextChanged`)·`BufUnload`·`BufDelete`는 진행 작업을 취소하지 않고 **저장 기준으로만 동작**하도록 mdloom 동작과 비교한다: mdloom은 didChange·didClose·세션 종료에서 진행 작업을 취소했다. 같은 동작을 유지할지 결정 필요 → **기본: 버퍼 닫기에서만 취소, 편집은 취소하지 않음** (Neovim에서는 저장 후 편집이 흔하고 재렌더 낭비가 크지 않다)
- [x] 허용 판정(C1): 일괄 규칙을 따르며 미신뢰 워크스페이스에서는 렌더하지 않음. 로드된 설정 메모리만 사용(Q1)
- [x] 자동 실패는 같은 저장 키로 반복하지 않음. 명시적 렌더나 코드 변경으로만 재시도
- [x] `auto_render = false`로 끌 수 있음
- [x] `render_on_open`(Q8): `BufWinEnter`에서 현재 창에 보이는 블록 중 캐시가 없는 것만 전역 렌더러로 렌더 요청 (디바운스 `auto_render_debounce`, 같은 키 중복 방지). 기본 `false`
- [x] 스펙: `autorender_spec.lua` — 변경된 블록만 렌더, 연속 저장 시 이전 작업 취소·오래된 결과 미반영, 미신뢰 시 렌더 없음, 같은 실패 키 반복 안 함, 열기만으로 실행 없음

완료 조건: 스펙 통과. 수동: 다이어그램 블록 수정 후 `:w` → 이미지 갱신(렌더링 이벤트 확인).

### C7 — 내보내기 (export.lua)

구현:
- [x] 계획(`plan(block, opts)`) 순수 함수: 입력(블록, 인접 이미지, 첨부 폴더, 요청 포맷, 링크 스타일, 기존 파일 목록 조회 함수) → 출력(`reuse`/`new`/`update`, 대상 경로, 링크 편집 목록, 오류). 파일시스템 접근은 주입 가능한 함수로 해 스펙에서 가짜로 대체
- [x] 3.6의 모든 규칙: 인접 연결(빈 줄 0·1), 첨부 폴더 해석·검증·루트 이탈 거부(realpath 비교), 심볼릭 링크 탈출 거부, 파일명 생성·번호 충돌·동일 바이트 재사용, 포맷 불일치 거부, 링크 스타일(markdown/wiki), 컨테이너 접두사 보존, CRLF 보존, 삽입 후 재파싱 검증
- [x] 적용: 사본을 대상 폴더 안 임시 이름으로 복사(`uv.fs_copyfile`)한 뒤 `uv.fs_rename`(같은 파일시스템이라 mdloom의 파일시스템 경계 문제 없음). 새 파일은 `hard_link`/`O_EXCL`로 기존 파일 덮어쓰기 방지. 그다음 버퍼에 링크 삽입(`nvim_buf_set_lines`, 한 번의 undo 단위). 링크 삽입 실패 시 새로 만든 이미지가 있으면 보존(재시도 시 동일 바이트로 링크만 삽입)
- [x] 첨부 폴더가 없으면 Q7에 따라 `ask`면 `vim.fn.confirm`, `never`면 거부, `always`면 생성
- [x] 열린 버퍼 확인: 파일이 아직 저장되지 않은 문서(이름 없음)는 문서 폴더가 없으므로 거부
- [x] 명령: `:CodeExport [selector]`, `:CodeExportAll` (이미 연결된 내보내기만 갱신, 신규 없음, 일부 실패 시 미적용 목록 보고)
- [x] `stale-export` 진단: 현재 캐시가 있을 때만 내보낸 이미지 바이트와 비교 (캐시 없음은 미판정). 이미지 링크 위치에 info. 코드 액션 대신 `:CodeExport` 안내를 메시지에 포함
- [x] 스펙: `export_plan_spec.lua`(순수 계획: 위 규칙 전부), `export_apply_spec.lua`(실제 파일시스템: 새/갱신/재사용, 충돌 번호, 부분 실패 후 재시도 중복 없음, 폴더 없음 처리, exportAll 일부 실패, undo)

완료 조건: 스펙 통과. 수동: 렌더된 다이어그램을 `:CodeExport` → 링크 삽입 → mdloom 진단 `broken-image` 없음 → 블록 수정·재렌더 후 `stale-export` 표시 → `:CodeExport` 재실행으로 갱신.

### C8 — 공급 인터페이스, 프로세스 목록, 마무리 (provider.lua)

구현:
- [x] `provider.diagrams(buf)`, `provider.request_live(buf, row)`와 `User CodeRunnerDiagrams` 이벤트(6절). `request_live`는 현재 버퍼 텍스트의 블록을 같은 렌더 키 규칙으로 렌더(캐시 재사용)하고, 블록 텍스트가 바뀌어도 키가 같으면 도구를 다시 실행하지 않는다. 스펙 `provider_spec.lua`: `request_live`의 캐시 재사용·신뢰 판정(로드 안 된 워크스페이스 설정이면 거부)·미저장 텍스트 렌더, 블록 편집 후 위치 갱신, 상태 전이(`none → pending → ready`, `failed`, stale), 이벤트 발행 횟수(렌더 하나당 1회), 포맷 svg 처리
- [x] 프로세스 목록 연동(선택): `launcher.registry.register`로 실행 중 작업을 등록해 기존 프로세스 목록 UI에서 보고 종료 가능. 종료 요청은 `run.cancel(id)`로 연결
- [x] 키맵(`keymap.lua`)과 `docs/coderunner.md`: 설정 예시(python, plantuml, mermaid, dot), 신뢰 모델, `.coderunner.lua` 예시, mdloom `.mdloom/config.toml`의 `[runners]`·`[renderers]` → Lua 이전 방법, 알려진 한계(Windows 트리 종료, 신뢰 가능한 설정 파일 위치, `.prjroot` 무확인 로드 위험)
- [x] `init.lua`(nvim_config 루트)에 `require'nvim_config.coderunner'.setup{...}`를 추가하고 사용자 설정 예시를 넣는다. 현재 `rendermark.setup{ plantuml = ... }` 설정과 중복되는 plantuml 옵션을 coderunner `renderers.plantuml`로 옮기는 안내를 적는다 (rendermark 쪽 정리는 3/3 작업에서)

완료 조건: 위 스펙과 문서 완료.

### C9 — 통합 검증

- [x] 전체 스펙: `bash run_tests.sh` — Linux 697개 통과, Failed/Errors 0
- [ ] 수동 시나리오 (Linux): 아래 10절의 체크리스트
- [ ] Windows: 가짜 도구 스펙 전부, 프로세스 트리 종료, 경로·줄 끝, `vim.secure.read` 프롬프트 흐름. 결과를 `docs/coderunner.md`의 "플랫폼 상태"에 기록
- [x] 성능: 5,000줄/200블록에서 반복 조회 0.0012ms·무변경 저장 검사 0.1004ms, 추가 파싱 없음. 변경 저장 79.7ms는 남음. [측정·재현](coderunner_performance.md)
- [ ] 이슈 `issue-coderunner.md` 종료 — Linux 구현·자동 검증과 진행 기록은 완료, 아래 실환경 검증이 남아 이슈 유지

## 8. 위험과 대응

| 위험 | 영향 | 대응 |
| --- | --- | --- |
| 프로세스 트리 종료의 플랫폼 차이 | 높음: 손자 프로세스가 남음 | C3에서 손자 프로세스를 만드는 가짜 도구 스펙을 먼저 만들고 플랫폼별로 검증. Windows는 Q2 |
| output 교체가 사용자의 동시 편집과 충돌 | 높음: 데이터 손실 | extmark 추적, 완료 시 소스·기존 output 비교, 불일치 시 거부, 한 번의 undo |
| 신뢰 모델 약화 (워크스페이스 설정으로 명령 실행) | 높음: 보안 | `.coderunner.lua`는 반드시 `vim.secure.read`로만 로드, 해시 변경 시 재확인, 자동 렌더는 로드된 설정만 사용, `.prjroot`에는 명령을 두지 않음 |
| 다중 Neovim 인스턴스가 같은 캐시를 동시에 갱신 | 중간 | 잠금 파일 + 원자 rename + manifest 병합 |
| treesitter markdown 파서 가용성(미설치·버전 차이) | 중간 | 파서 로드 실패 시 명시적 오류와 비활성화. 단위 스펙에서 파서가 없을 때의 동작 확인 |
| mdloom의 세부 동작을 놓침 | 중간 | C0의 시나리오 추출을 완료 조건으로 두고 리뷰. 구현 후 시나리오 표의 모든 행을 스펙에 연결 |
| 렌더 이미지가 rendermark의 기존 PlantUML 자동 렌더와 중복 표시 | 낮음(3/3에서 정리) | 3/3 작업 전까지는 rendermark가 자체 렌더를 계속한다. coderunner는 공급 인터페이스만 제공하고 그리지 않는다 |

## 9. 이식 시나리오 (mdloom 수용 ID → coderunner 스펙)

원본 ID는 `doc/archive/before-lsp-scope/acceptance.md`에 있다.

| mdloom 수용 ID | 내용 | coderunner 스펙 |
| --- | --- | --- |
| A9-8 | 블록 선택(`언어:순번`, `#id`)→ 실행 → 결과, 블록 없음 오류 | `run_spec` |
| A9-9 | 미신뢰에서 일괄 거부, 단일 허용 | `trust_spec`, `config_spec` |
| A9-10 | 내보내기 충돌·중간 실패·일괄 독립 | `export_apply_spec` |
| A9-11 | gc 보호 규칙 | `cache_spec` |
| A10-5, A10-6 | 신뢰 상태×출처×종류 허용표 | `trust_spec` |
| A10-7 | 렌더러에 `{attr.x}` → 설정 오류 | `config_spec` |
| A10-8 | 단계 실패·무한 실행·손자 생성·대량 출력·도구 미설치 | `exec_spec` |
| A10-9 | 문서 내용의 `; rm -rf`·`$(…)`가 인자·셸로 해석되지 않음 | `command_spec` |
| A10-10 | 해시 불일치·중복 ID·러너 없음·output 블록 거부 | `run_spec` |
| A10-11 | 실행 시작 즉시 작업 id, 출력 스트리밍, 완료 알림 | `run_spec` |
| A10-12 | 열기·저장·인덱싱은 실행하지 않음 | `run_spec`, `autorender_spec` |
| A10-14 | `max_jobs=1`, 대기 취소, 상한 변경 | `queue_spec` |
| A10-15 | 슬롯 대기 시간 제외 타임아웃, steps 전체 예산 | `exec_spec`, `command_spec` |
| A10-16 | 기본 cwd(`{docdir}`/`{tmpdir}`), 상대 cwd | `command_spec` |
| A11-1 | 렌더 키 docdir 의존 | `render_spec` |
| A11-2 | 블록 재배치→현재 키 캐시, 키 없음→마지막 이미지 | `render_spec` |
| A11-3 | force, 일회성 정책(→ coderunner에서는 force만) | `render_spec` |
| A11-4, A11-5 | 연속 저장 취소·바뀐 블록만, 미신뢰 시 렌더 없음 | `autorender_spec` |
| A11-6 | 위키·표준·HTML 인접 이미지(빈 줄 0·1·2) | `blocks_spec`, `export_plan_spec` |
| A11-7 | 파일명 번호, 동일 바이트 재사용 | `export_plan_spec` |
| A11-8 | 첨부 폴더 `..`·밖으로 향하는 심볼릭 링크 거부 | `export_plan_spec` |
| A11-9, A11-11 | 일부 실패, 링크만 실패 후 재시도 | `export_apply_spec` |
| A11-10 | 다른 파일시스템 RenameFile 실패 | **제외** (coderunner는 같은 파일시스템에서 복사) — 대신 대상 폴더 쓰기 실패 케이스 |
| A11-12, A11-13 | 통합 수용, 실제 도구 smoke | C9 수동 |
| A6-14 | `render-failed` 진단 | `diagnostics_spec` |
| A6-15 | `stale-export` 진단 | `diagnostics_spec`, `export_apply_spec` |
| A12-3 | stale 응답 후 재시도 | **제외** (LSP 의존) — 대신 오래된 해시 요청 거부 |
| A12-4 | output 교체, `{.error}`, 긴 펜스 | `output_fence_spec` |
| A12-5 | 결과 대기 중 사용자 편집 | `output_fence_spec` |
| A8-12~A8-20 | 외부 포맷터 | **제외** (D7) |

## 10. 수동 확인 체크리스트 (C9)

아래 체크는 실제 대화형 환경 확인용으로 남긴다. Linux headless 대체 검증은 C9 진행 기록과
[coderunner.md](coderunner.md)의 검증 표에 구분했다. 실제 GUI·신뢰 프롬프트·Windows·mdloom 진단은 수행하지 않았다.

- [ ] python 블록 `:CodeRun` → 결과 창, `q`로 닫고 `:CodeOutput`으로 다시 열기, `:CodeRelease`로 해제
- [ ] `:CodeRun!` → output 펜스 생성, 다시 실행하면 교체, 실패하면 `{.error}`
- [ ] 출력에 ```` ``` ````가 있으면 펜스가 더 길게 생성
- [ ] 실행 중 `:CodeCancel`, 타임아웃(`sleep` 블록) 후 프로세스가 남지 않음 (`ps`/작업 관리자 확인)
- [ ] 실행 중 같은 블록을 편집하고 완료 → 삽입 거부 알림, 다른 영역 편집이면 삽입됨
- [ ] plantuml 렌더 → 캐시 적중(두 번째는 즉시) → 수정 후 `:w` 자동 렌더 → 이미지 갱신 이벤트
- [ ] 렌더 실패(잘못된 plantuml 구문) → `render-failed` 진단에 stderr 첫 줄, 고치면 사라짐
- [ ] `:CodeExport` → 첨부 폴더에 이미지, 코드블록 아래 링크, mdloom `broken-image` 없음
- [ ] 같은 블록을 수정·재렌더 → `stale-export` 표시 → `:CodeExport` 재실행 → 사라짐
- [ ] `:CodeExportAll`이 연결된 것만 갱신
- [ ] 워크스페이스 `.coderunner.lua` 신뢰 흐름: 처음 로드 시 프롬프트, 내용 변경 후 재프롬프트, 거부 시 워크스페이스 러너 실행 불가
- [ ] `:CodeGc` dry-run과 실제 삭제
- [ ] 설정의 `max_jobs = 1`에서 여러 렌더가 순서대로 실행
- [ ] Neovim 두 인스턴스가 같은 문서를 동시에 렌더해도 캐시가 깨지지 않음

## 11. 진행 기록

| 단계 | 상태 | 날짜 | 비고 |
| --- | --- | --- | --- |
| 선행 | 없음 (첫 작업) | | |
| C0 준비·시나리오 추출 | 완료 | 2026-10-30 | 태그 테스트별 시나리오·제외 근거 작성/자체 대조, 가짜 도구 Linux 스펙 4개 통과 |
| C1 설정·신뢰 | 완료 | 2026-10-30 | config/trust/명시 로드 명령, 설정·신뢰 스펙 16개 통과. 실행 서비스 연결은 C3~C5 |
| C2 블록 파서 | 완료 | 2026-10-30 | treesitter 블록·속성·본문/해시·연결·중복·changedtick 캐시, blocks 스펙 11개 통과 |
| C3 실행 엔진 | 완료 | 2026-10-30 | exec/queue/command, 신규 21개 및 전체 591개 통과. Windows taskkill 한계 문서화 |
| C4 러너 서비스·UI | 완료 | 2026-10-30 | 실행·결과창·안전한 output 삽입, 신규 25개/전체 616개 통과 |
| C5 렌더링·캐시 | 완료 | 2026-10-30 | 렌더·영속 캐시·PID 잠금·gc·진단, 신규 23개/전체 639개 통과 |
| C6 자동 렌더 | 완료 | 2026-10-30 | 저장 키 기준 자동 렌더·열기 opt-in·취소/신뢰 스펙 14개 통과 |
| C7 내보내기 | 완료 | 2026-10-30 | 신규 30개·전체 683개 통과, 내보내기·부분 실패·진단 검증 |
| C8 공급 인터페이스·마무리 | 완료 | 2026-10-30 | 공급 API·이벤트·registry·키맵·사용자 설정/문서, 신규 11개 스펙 |
| C9 통합 검증 | Linux 자동 검증 완료·실환경 대기 | 2026-10-30 | 전체 697개·실제 Python/PlantUML smoke·성능 측정 완료. Windows/GUI/mdloom 미검증으로 이슈 유지 |

### 2026-10-30 — C0·C1

- `before-lsp-scope`의 원본 테스트를 [coderunner_scenarios.md](coderunner_scenarios.md)에 입력·동작·기대·대응 스펙으로 정리했다. CLI/LSP 전용 기능과 rendermark 담당 기능의 제외 근거를 기록했다.
- 가짜 도구와 임시 workspace/문서/버퍼/대기 도우미를 추가했다. C1은 `config.lua`, `trust.lua`, 모듈 `setup/resolve`, 명시 신뢰 명령까지 구현했다.
- 신규 스펙 20개 통과. 전체 `bash run_tests.sh` 554개 통과(Linux, Neovim 0.12.4). Windows 미검증.
- 원본의 basename wiki 해석은 LSP resolver/수집기에 의존한다. C7에서 대체 규칙 결정이 필요하다. 미로드 Lua 항목 이름 가리기와 전역 단일 허용의 조합도 실행 서비스에서 해결해야 한다. 세부는 시나리오 문서 마지막 절.
- root init.lua 연결·실행/렌더/내보내기 명령·rendermark 공급 API는 후속 단계다. 기존 사용자 변경은 유지했다.

### 2026-10-30 — C2

- `blocks.lua`에 treesitter markdown 기반 펜스/내용 범위, Pandoc 속성, 컨테이너 제거 및 LF 정규화, 언어별 순번·블록 키·중복 ID, 인접 output·표준/wiki/HTML 이미지 연결을 구현했다. 닫히지 않은 펜스는 EOF까지의 코드로 유지하며, 실행·삽입 소비자는 `closed`로 구분할 수 있다.
- 원본 `facts.rs`의 관련 5개 테스트(`code_block_attributes`, `first_code_id_wins`, `code_block_content_range_and_hash`, `code_block_keys_skip_output_and_flag_duplicate_ids`, `output_and_image_linking_by_blank_lines`)를 대조하고 원본 `fixtures/facts/code.md`를 테스트 fixture로 보존했다. 중복 ID는 실행 거부를 위해 첫 블록을 포함해 모두 표시한다(원본 진단은 후속 중복만 표시).
- 신규 blocks 스펙 11개 통과. 전체 `bash run_tests.sh` 570개 통과(Linux). markdown 파서 미설치 시 오류를 반환하고 비활성화하며, 파싱 결과는 버퍼 changedtick·경로·루트로 캐시한다. Windows 미검증, 성능 수치는 C9에서 측정한다.

### 2026-10-30 — C3

- `exec.lua`는 셸 없는 uv spawn, 상속 환경·stdin, 양 스트림 drain/상한, 최종 UTF-8 정리, 취소·타임아웃과 Unix 프로세스 그룹 종료를 구현했다. 리더 정상 종료 시 남은 자손도 종료한다.
- `queue.lua`는 공유 FIFO 슬롯, 대기 취소, 진행 작업을 유지하는 동시성 상한 변경을 제공한다. `command.lua`는 단일 치환·사전 attr 검증, 슬롯 후 0700 임시 폴더/입력 생성, steps 전체 timeout, 산출물 폴더 명시 해제를 제공한다.
- 원본 exec.rs의 실행 계층 시나리오를 21개 신규 스펙으로 검증했다. Linux 전체 스펙 591개 통과(실패·오류 0). Windows는 실행 환경이 없어 미검증이며 taskkill 리더 종료 후 한계를 `coderunner.md`에 기록했다.

### 2026-10-30 — C4

- `run.lua`에 커서/키/ID/언어 순번 선택, 중복·output·오래된 해시·러너 없음 거부, 명시 신뢰 로드와 명령 5개를 구현했다. 서비스 결과 상태는 success/failed/cancelled/timeout이며 세부 실행 오류는 kind/message에 보존한다.
- `result_view.lua`는 읽기 전용 floating scratch, 스트리밍과 최종 출력 우선, q 닫기/재열기/해제를 제공한다. 결과 창에서도 실행 작업을 찾을 수 있다. `progress.lua`는 spinner 갱신과 시작/완료 알림을 제공한다.
- `output_fence.lua`는 extmark로 소스를 추적하고 소스·기존 output 원문을 재검증한다. 위치 이동은 허용하고 동시 편집은 거부한다. stdout만 한 번의 버퍼 편집으로 삽입/교체하며 긴 백틱·실패 속성을 처리한다. 컨테이너 안 블록은 표시만 한다.
- 완료 결과는 100개/256MiB 상한으로 오래된 것부터 해제하고 최신 초과 결과는 보존·알림한다. 산출물은 일반 파일만 수집하고 symlink를 추적하지 않으며 생성한 입력 경로만 제외한다. 정상 세션 종료 후 24시간 보존하고 시작/시간별로 만료 정리한다. 비정상 종료 시에는 마지막 시간별 보존 마커 갱신 기준이다.
- 미로드 Lua 항목 이름 가리기 문제는 미로드/거부 파일이 있는 workspace의 단일 전역 fallback도 거부하는 정책으로 확정했다(C1 항목 참고).
- 신규 스펙 25개, Linux 전체 616개 통과(실패·오류 0). Python 실제 `CodeRun`/`CodeRun!`/q/`CodeOutput`/`CodeRelease`와 한 번 undo를 headless 명령 smoke로 확인했다. Windows 미검증.

### 2026-10-30 — C5

- 렌더 키·조회·force·실패 복구, SVG/stdout·파일 출력, 같은 키 직렬화와 다른 키 병렬 실행을 구현했다.
- PID 소유 O_EXCL 잠금, 죽은 소유자 회수, manifest 잠금 내 병합, 원자 이미지 교체와 취소 중 게시 방지를 구현했다.
- 용량 정리와 GC는 저장 문서의 현재 포맷별 키·필요한 마지막 성공 이미지·사용 중 이미지를 보호한다. 문서/파서/신뢰 수집 실패는 삭제를 거부하고 busy 루트는 건너뛴다.
- `CodeRender[!]`·`CodeRenderAll`·`CodeGc`, render-failed/duplicate-code-id 진단과 완료 이벤트를 연결했다. C4의 trust.can_select 정책을 공용으로 사용한다.
- 신규 render 12개·cache 8개·diagnostics 3개 스펙 통과. 전체 `bash run_tests.sh` 639개 통과, 실패·오류 0. 두 Neovim 인스턴스의 manifest 병합과 실제 다른 키 병렬 실행을 포함한다. Windows는 미검증이다.

### 2026-10-30 — C6

- `autorender.lua`는 BufReadPost/BufNewFile에서 도구 실행 없이 디스크 기준선을 기록하고 BufWritePost에서 디스크를 다시 읽어 바뀐 렌더 키만 디바운스 예약한다. 새 저장은 해당 블록의 이전 예약·실행을 취소하며 삭제된 블록도 정리한다.
- 편집만으로는 취소하지 않는다. BufUnload/BufDelete는 예약·진행 작업을 취소한다. 미로드·거부·변경된 workspace 설정은 자동 실행·신뢰 프롬프트 없이 거부한다.
- 같은 실패 저장 키는 반복하지 않으며 명시적 렌더나 코드 변경으로 재시도한다. auto_render=false 및 render_on_open의 전역 렌더러·현재 창 범위·현재 캐시 부재 조건을 적용했다. 열기 렌더는 기본 비활성화한다.
- 신규 스펙 14개 및 전체 `bash run_tests.sh` 653개 통과(실패·오류 0). 실제 가짜 도구로 연속 저장 후 이전 키 파일 미게시·최신 이미지 바이트를 검증했다. Windows는 미검증이다.


### 2026-10-30 — C7

- `export.lua`에 FS 관찰 함수를 받는 순수 계획과 렌더→사본→원자 이동→버퍼 링크 적용을 구현했다. 첨부 폴더 realpath와 symlink/루트 이탈을 확인하고 Q7의 ask/never/always를 적용한다.
- 기존 인접 이미지의 포맷/링크 유지·없는 대상 복구, 모든 번호 후보의 동일 바이트 우선 재사용, 새 파일 덮어쓰기 방지, 이동 실패 사본 정리와 링크 실패 후 이미지 보존·재시도를 구현했다.
- 새 링크는 컨테이너 접두사·CRLF를 보존하고 재파싱으로 기존 블록 내용·언어·ID·개수와 새 이미지 연결을 검증한다. 렌더 중 문서/대상 변경은 적용하지 않는다.
- CodeExport/CodeExportAll과 stale-export 진단을 연결했다. 일괄은 기존 연결만 모두 준비한 뒤 적용하며 부분 실패를 보고하고 기존 확장자를 유지한다. basename wiki는 첨부 폴더 직접 파일만 조회하고 모호하면 거부한다. 원본 workspace resolver의 ignore/Unicode·동일 폴더 우선 검색은 제외하며 시나리오 문서에 차이를 기록했다.
- 신규 export_plan 13개·export_apply 17개, 전체 `bash run_tests.sh` 683개 통과(실패·오류 0). 가짜 렌더러로 실제 명령 서비스·파일 복사·링크·진단 해제·CRLF·undo·경합·실패 재시도를 확인했다. 외부 mdloom broken-image 진단과 Windows는 C9/실환경 확인 대상으로 남긴다.


### 2026-10-30 — C8

- `provider.diagrams/request_live`와 public API를 연결했다. 현재 버퍼 위치, 미저장 본문, 같은 키 병합/캐시 재사용, 신뢰 거부/로드, SVG·stale·실패 첫 줄을 검증했다. 완료 이벤트는 render가 요청당 한 번 발행하고 provider는 중복 발행하지 않는다.
- 블록 목록/위치/본문 변경 이벤트와 Markdown 키맵, 실행·렌더의 launcher registry 등록/취소를 추가했다. root init.lua에 Python/PlantUML 설정을 연결하고 Mermaid/Dot·워크스페이스·TOML 이전 예시를 문서화했다. rendermark는 수정하지 않았다.
- 상대 `block.path`를 루트 기준으로 결합해 렌더 키와 실제 실행의 `{docdir}`를 절대 문서 폴더로 일치시켰다. 신규 공급 스펙 11개와 전체 `bash run_tests.sh` 694개 통과, Failed/Errors 0.
- C9에서 끝 개행 없는 펜스, 테스트 runner 내부 실패 종료 코드와 기존 launcher 스텁 경고를 확인한다. Windows/실제 GUI는 미검증이다.


### 2026-10-30 — C9

- Linux 전체 `bash run_tests.sh` 697개 통과, Failed/Errors 0. 개별·디렉터리·혼합 파일의 고의 실패 probe가 모두 종료 코드 1을 반환해 테스트 실행기는 변경하지 않았다. 기존 launcher 테스트 상태의 가짜 handle에 `is_closing`이 없어 정리 콜백 경고가 남는다(스펙 실패 아님, 별도 기존 문제).
- 끝 개행 없는 닫는 펜스가 코드에 포함되던 오류를 수정했다. EOF 개행을 파서에만 보완하고 실제 미완성 코드의 바이트·해시는 보존한다. endofline 옵션 변경도 캐시에 반영하며 회귀 스펙 2개를 추가했다.
- 5,000줄/200블록의 반복 조회는 0.0012ms, 동일 디스크·설정·신뢰의 저장 검사는 0.1004ms이고 모두 추가 파싱이 없다. 이미지 표식 없는 문단의 불필요 inline 파싱을 제거했다. 초기 파싱 55.6ms·변경 저장 79.7ms는 남는다. 저장 snapshot 신뢰 무효화 회귀 스펙을 추가했다. [수치·재현](coderunner_performance.md).
- 실제 Python과 PlantUML SVG로 결과 창/q/재열기/해제, output·undo·실패·긴 펜스, 렌더 캐시·저장 자동 렌더·실패 진단/복구, 내보내기·stale·일괄 갱신, GC dry-run·삭제·현재 이미지 보호를 headless 명령으로 확인했다. 재현 스크립트는 `tests/manual/coderunner_smoke.lua`다.
- 이 환경의 `/usr/bin/plantuml`은 없는 `/usr/bin/java`를 가리킨다. smoke는 설치된 JDK21과 PlantUML jar를 직접 지정하고 AWT headless 옵션을 사용했다. 사용자 시스템 파일은 변경하지 않았다.
- 실제 GUI 조작·신뢰 프롬프트, mdloom broken-image 공존 진단, Windows 실행/경로/CRLF/자손 종료는 미검증이다. Linux CRLF·신뢰 흐름(secure.read 스텁)·자손 종료·2인스턴스 경합은 자동 스펙으로 확인했다. C9를 완전 완료로 표시하거나 이슈를 닫지 않는다.
