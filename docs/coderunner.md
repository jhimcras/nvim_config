# coderunner

코드 실행·다이어그램 렌더링·내보내기를 위한 독립 Lua 모듈이다.
현재 C0–C8(실행·렌더링·내보내기·공급 API)를 구현했다.
`CodeRun`·`CodeRender`·`CodeExport`와 `diagrams`·`request_live`를 사용할 수 있다.
기존 mdloom·rendermark 설정은 계속 사용한다.

루트 init.lua에서 초기화한다. 사용자 설정의 예시는 다음과 같다.

```lua
require('nvim_config.coderunner').setup {
    diagnostics = false, -- mdloom과 공존하는 동안 중복 진단 방지
    runners = {
        python = { match = { 'python', 'py' }, ext = 'py', cmd = { 'python3', '{file}' } },
    },
    renderers = {
        plantuml = {
            match = { 'plantuml', 'puml' }, formats = { 'png', 'svg' },
            input = 'stdin', output = 'stdout',
            cmd = { 'plantuml', '-t{format}', '-pipe' },
        },
        mermaid = {
            match = { 'mermaid' }, ext = 'mmd', formats = { 'png', 'svg' },
            cmd = { 'mmdc', '-i', '{file}', '-o', '{output}' },
        },
        dot = {
            match = { 'dot', 'graphviz' }, ext = 'dot', formats = { 'png', 'svg' },
            cmd = { 'dot', '-T{format}', '{file}', '-o', '{output}' },
        },
    },
}
```

워크스페이스 설정은 프로젝트 루트의 `.coderunner.lua`에서 같은 형태의 설정 표를 반환한다.
전역 설정은 사용자 Lua로 신뢰하며, 워크스페이스 설정은 `vim.secure.read`가 허용한 바이트만 평가한다.
신뢰는 Lua 전체 실행을 허용하는 것이다. 별도 샌드박스가 아니다.

- `:CodeRunnerLoad`: 워크스페이스 설정을 명시적으로 읽고 필요한 신뢰 프롬프트를 표시한다.
- `:CodeRunnerTrust`: 현재 상태와 설정 경로를 표시한다. 신뢰 승인은 Load에서 한다.
- `:CodeRunnerUntrust`: Neovim 신뢰 기록과 메모리의 로드 상태를 지운다.

자동 경로는 신뢰 프롬프트를 표시하지 않는다. 설정 내용이 바뀌면 해시 비교로 메모리 설정을 무효화한다.
다음 명시 로드에서 다시 승인을 확인한다. 잘못된 명령 항목은 제외하고 정상 항목은 유지한다.
같은 이름은 항목 전체를 교체하며 timeout/env를 전역 항목에서 섞어 가져오지 않는다.
알 수 없는 키는 경고한다.

시간은 `30s`, `200ms`, `2m`, `1h`; 크기는 `1MB`, `512KB`처럼 양의 정수와 단위를 쓴다.
크기 단위는 1024 배수이며 `render_max_size`만 `'unlimited'`를 허용한다.
기본값은 max_jobs=4, timeout=30s, max_output=1MB(스트림별), auto_render=true,
auto_render_debounce=200ms, render_max_size=512MB, attachments='./assets',
link_style='markdown', create_attachments_dir='ask', diagnostics=true, render_on_open=false다.

mdloom TOML의 `[runners.python]`은 `runners.python = {...}`, `[renderers.plantuml]`은
`renderers.plantuml = {...}`로 옮긴다. `match`, `cmd`, `steps`, `formats`는 Lua 배열을 쓴다.
mdloom의 기존 명령은 병행 기간 동안 유지한다.
rendermark의 plantuml 실행 명령은 위 `renderers.plantuml`로 옮긴다.
`preview`의 창/자동 표시 옵션은 rendermark에 유지한다. 이미지 그리기 연결과 이전 설정 제거는 별도 rendermark 작업에서 한다.

루트 탐색은 `prjroot.GetProjectRoot`를 사용한다. 기존 `.prjroot`의 무확인 Lua 로드는 이 모듈의
신뢰 기능과 별개이므로, 명령 정의는 `.coderunner.lua`에 둔다.

플랫폼 상태: Linux/Neovim 0.12.4에서 C0–C9 자동 스펙 697개 통과(Failed/Errors 0).
Windows는 미검증이다. Windows 실행 엔진은 `taskkill /F /T /PID`로 트리를 종료한다.
리더가 이미 종료한 뒤에는 taskkill이 자손을 찾지 못할 수 있으므로 정상 리더 종료 후 자손 정리는
최선 노력이다. Windows 검증에서 이 한계가 확인되면 Job Object 적용을 후속 검토한다.
Unix는 detached 프로세스 그룹에 SIGKILL을 보내고 리더 exit 콜백에서 남은 자손도 종료한다.
uv가 리더를 수거한 뒤 exit 콜백을 호출하므로 PID/그룹 ID 재사용의 작은 경쟁 창이 남는다.
스스로 다른 프로세스 그룹으로 이탈한 자손은 이 방식으로 종료할 수 없다.

실행 엔진 내부 API는 `exec.run_step(argv, opts, callback)`과
`command.run(entry, context, opts, callback)`이다. 반환 객체의 `cancel()`로 취소한다.
`context`는 `code`, `attrs`, `workspace`, `docdir`, `kind`(`runner`/`renderer`),
렌더러의 `format`을 포함한다. `opts`의 `timeout`은 ms, `max_output`은 스트림별 바이트다.
`on_output(stream, chunk)`는 원시 바이트 조각을 전달하고, 최종 결과에서 UTF-8을 정리한다.
UI는 누적 바이트를 `exec.clean_utf8`로 변환해 표시할 수 있다.
완료 결과의 `tmpdir`은 `command.release(result)` 전까지 남는다. 러너 서비스는 아래 보관 수명 정책으로 이를 관리한다.
`command.prepare(entry, context)`는 파일·프로세스를 만들지 않고 치환된 steps/env/cwd를 반환한다.

세부 이식 목록과 미결 동작은 [시나리오 문서](coderunner_scenarios.md),
전체 단계는 [계획서](coderunner_plan.md)를 따른다.

## 코드 실행과 결과

- `:CodeRun [selector]`: 커서 블록 실행. selector는 블록 키, `#id`, `python:1` 같은 언어 순번이다.
- `:CodeRun! [selector]`: 실행 후 stdout을 인접 output 펜스로 삽입/교체한다. 실패는 `output {.error}`다.
- `:CodeCancel`: 진행 중 작업 취소. 결과 창 안에서도 사용할 수 있다.
- `:CodeOutput`: 마지막 작업/결과 창 다시 열기. q는 창만 닫는다.
- `:CodeRelease`: 완료 결과와 임시 산출물 삭제. 진행 중이면 먼저 취소한다.

열기·저장으로 러너가 실행되지는 않는다. 결과 창은 stdout/stderr·잘림·상태·오류·산출물 경로를 표시한다.
output 삽입은 들여쓰기 없는 최상위 닫힌 펜스만 지원한다. 실행 중 소스 또는 기존 output이 바뀌면 삽입을 거부하고,
다른 영역 편집으로 위치만 옮겨진 경우에는 허용한다. 삽입/교체는 undo 한 번으로 되돌린다.
완료 결과는 세션 중 시간 만료 없이 100개/256MiB 상한으로 보관하며 진행 작업은 정리하지 않는다.
최신 결과 하나가 상한을 넘으면 보존하고 알린다. 임시 산출물은 정상 세션 종료 후 24시간 보존하고 시작/시간별로 정리한다.
비정상 종료의 보존 기간은 마지막 시간별 마커 갱신 기준이다. 영구 보관할 파일은 별도로 복사한다.

미로드 Lua의 항목 이름은 신뢰 전에 알 수 없으므로 `.coderunner.lua`가 있는데 로드하지 못한 경우
전역 러너로 대체하지 않고 단일 실행도 거부한다. `:CodeRunnerLoad`로 먼저 승인해야 한다.
설정 파일이 없거나 로드된 경우에는 전역 단일 항목을 사용할 수 있다. 서비스 공용 판정은 `trust.can_select(status)`다.

C4 Linux 검증: 신규 스펙 25개, 전체 616개 통과. Python 실제 명령·결과 창·output·undo smoke 통과.
Windows는 미검증이다.

## 다이어그램 렌더링과 캐시

- `:CodeRender [selector]`: 커서 또는 지정 블록을 렌더한다. 기본 포맷은 renderer.formats 첫 항목이다.
- `:CodeRender! [selector]`: 현재 캐시가 있어도 다시 렌더하고 같은 경로를 원자 교체한다.
- `:CodeRenderAll`: 설정된 렌더러가 있는 현재 버퍼의 블록을 일괄 렌더한다.
- `:CodeGc dry-run`: 현재 루트에서 삭제할 참조 없는 캐시 이미지를 표시한다.
- `:CodeGc`: 현재 루트의 참조 없는 이미지를 삭제한다. `:CodeGc! all`은 모든 캐시 루트를 검증한 뒤 처리한다.

저장 시 자동 렌더는 디스크의 블록 키를 기준선과 비교해 변경된 블록만 예약한다.
`auto_render_debounce` 동안 연속 저장은 병합하고 이전 저장의 진행 작업은 취소한다.
편집만으로는 취소하지 않으며 버퍼를 닫으면 예약·진행 작업을 취소한다.
자동 실패는 같은 저장 키에서 반복하지 않는다. `:CodeRender` 또는 코드 변경으로 재시도한다.
`auto_render=false`로 저장 렌더를 끌 수 있다.
`render_on_open=true`는 보이는 블록 중 현재 캐시가 없는 것을 전역 렌더러로만 렌더한다.
기본값은 false이며, 자동 경로는 미로드·거부된 workspace 설정을 로드하거나 프롬프트를 띄우지 않는다.
기준선을 수집할 수 없던 미신뢰 상태에서 설정을 로드한 경우 다음 저장은 현재 키를 새로 수집한다.
렌더링 결과를 그리는 기능은 별도 rendermark 작업이다.
이미지는 `stdpath('cache')/coderunner/<루트 해시>/diagrams`에 저장한다.
키는 코드·설정·포맷·치환 명령으로 계산하고 실행마다 다른 임시 경로는 고정 토큰으로 둔다.
외부 참조 파일이나 도구 버전 변경은 자동 탐지하지 않으므로 force로 갱신한다.
현재 키가 없으면 마지막 성공 이미지를 stale로 조회한다. 렌더 실패는 현재 키에만 기록하며
`render-failed` warning을 코드블록 첫 줄에 표시한다. 성공하거나 키가 바뀌면 사라진다.
`duplicate-code-id`는 각 중복 블록에 error로 표시한다. `diagnostics=false`면 모두 숨긴다.

용량 정리는 저장 후 오래된 수정 시각 순으로 삭제하며, 저장 문서의 현재 이미지와 필요한 마지막 성공 이미지,
사용·갱신 중인 이미지를 보존한다. 보호 이미지만으로 상한을 넘으면 유지하고 알린다.
GC는 디스크의 `.md`·`.markdown` 문서를 재파싱하며, 읽기·파서·신뢰 판정이 불완전하면 삭제를 거부한다.
진행 중 렌더가 있는 루트는 GC에서 건너뛴다. 심볼릭 링크 이미지를 따라가지 않는다.
동일 키의 렌더는 PID 소유 잠금으로 직렬화하고 다른 키는 공유 슬롯 범위에서 병렬 실행한다.
manifest는 별도 잠금 안에서 읽기·병합·쓰기를 한다. 죽은 PID의 잠금만 회수하며,
소유 정보를 읽을 수 없는 손상된 잠금은 자동 회수하지 않는다(다른 실행이 없는지 확인 후 수동 제거).

내부 API는 `render.describe(block, opts)`, `render.key(block, entry, format)`,
`render.lookup(block, opts)`, `render.start(block, opts, callback)`과
`render.request(buf, selector, opts, callback)`이다. block은 blocks.get/parse가 반환한 객체다.
opts는 format, force, buf, explicit(명시 신뢰 로드), batch, global_only를 받는다.
start/request는 job 또는 nil,error를 반환하며 job.cancel()로 취소한다.
완료 callback(job)의 job.result는 status(ready/failed/cancelled), path, error, cached, stale을 제공한다.
lookup은 도구를 실행하지 않으며 status(none/pending/ready/failed), path, key, format, stale, error를 반환한다.
완료 때 `User CodeRunnerDiagrams`, data={buf=bufnr}가 한 번 발행된다.

C5 Linux 검증: 신규 스펙 23개, 전체 639개 통과(실패·오류 0). 가짜 도구 렌더→캐시 적중→내용 수정→재렌더, force 실패 보존, 두 인스턴스 manifest 병합을 확인했다. Windows는 미검증이다.


내보내기는 `:CodeExport [selector]`로 현재 블록을 렌더하고 첨부 폴더에 복사한다.
기존 인접 이미지가 있으면 그 확장자(svg/png)와 링크를 유지하며 바이트를 갱신한다.
새 링크는 `link_style='markdown'` 또는 `'wiki'`를 따르며 인용·리스트 접두사와 CRLF를 보존한다.
버퍼 편집은 한 번의 undo로 되돌릴 수 있다. 이미지 파일은 undo로 삭제하지 않는다.
`:CodeExportAll`은 현재 문서에서 이미 연결된 내보내기만 준비한 뒤 갱신한다.
일부 대상이 실패해도 독립적인 성공은 유지하고 미적용 블록과 이유를 알린다.

`attachments='./assets'`는 문서 폴더 기준, `'assets'`는 workspace 루트 기준이다.
절대 경로·역슬래시·독립 `..` 구성 요소와 realpath 기준 루트 이탈을 거부한다.
첨부 폴더/대상 symlink에는 쓰지 않으며 캐시 symlink도 내보내지 않는다.
폴더가 없으면 `create_attachments_dir='ask'`로 확인하고, `'never'`는 거부하며 `'always'`는 생성한다.
이름 없는 문서는 먼저 저장해야 한다.

새 파일 이름은 문서 stem과 블록 ID(없으면 언어·순번)로 만든다.
기존 파일 전체의 번호 후보에서 동일 바이트를 먼저 찾고, 없으면 첫 빈 번호를 사용한다.
새 파일 이동은 기존 파일을 덮어쓰지 않는다. 기존 연결 이미지만 원자 교체한다.
이동 실패는 임시 사본을 정리하고 기존 이미지를 유지한다. 이미지 저장 뒤 링크 편집 실패는
이미지를 보존하므로 재시도하면 동일 바이트 파일을 재사용해 링크만 삽입한다.
렌더 중 문서나 기존 대상 이미지가 바뀌면 오래된 결과 적용을 거부한다.

`stale-export`는 현재 키 캐시가 있을 때 내보낸 바이트와 비교해 이미지 링크에 info 진단을 낸다.
현재 캐시가 없거나 마지막 성공 이미지(stale)만 있으면 판정하지 않는다.
메시지의 `:CodeExport`로 갱신하면 진단이 사라진다. `diagnostics=false`는 이 진단도 끈다.

basename wiki(`![[picture]]`)는 설정 첨부 폴더 바로 아래의 svg/png 파일만 조회한다.
확장자를 쓴 `![[picture.png]]`는 파일이 없어도 같은 폴더의 복구 대상으로 연결한다.
같은 stem의 png/svg가 함께 있으면 모호성 오류로 거부한다. 하위 폴더나 workspace 전체 검색,
mdloom resolver의 ignore/Unicode 정규화·동일 폴더 우선 규칙은 이식하지 않는다.
경로를 명시한 `![[assets/picture.png]]`는 문서 상대 경로로 해석한다.

내부 `export.plan(block, opts)`는 `opts.fs={stat,realpath,read,list}` 관찰 함수를 받아
`action`(new/reuse/update), `target`, `edits`를 반환하며 파일/버퍼를 바꾸지 않는다.
새 링크 계획에는 `opts.lines`가 필요하고 attachments/format/link_style/bytes/existing_only를 받는다.
`export.start(buf, selector, opts, callback(result,error))`는 준비·렌더·적용을 수행한다.
`export.all(buf, callback(report))`는 report.applied/failed를 반환한다.

C7 Linux 검증: 신규 계획 13개·적용 17개, 전체 683개 통과(실패·오류 0).
Windows와 실제 mdloom broken-image 진단 연동은 미검증이다.


## 공급 API와 프로세스 목록

```lua
local coderunner = require('nvim_config.coderunner')
local items = coderunner.diagrams(buf) -- 조회만: 실행/신뢰 프롬프트 없음
local accepted = coderunner.request_live(buf, row) -- 0 기반 줄, 미저장 본문 렌더
vim.api.nvim_create_autocmd('User', {
    pattern = 'CodeRunnerDiagrams',
    callback = function(args)
        local current = coderunner.diagrams(args.data.buf)
        -- 소비자가 current의 path/format/status를 사용한다.
    end,
})
```

각 항목은 `start_row`, `end_row`, `key`, `lang`, `path`, `format`, `stale`,
`status`(`none/pending/ready/failed`), `error`(첫 줄)를 제공한다.
위치는 현재 버퍼 기준이며 이미지가 없으면 path는 nil이다. SVG는 그대로 반환한다.
공급 API는 그리기나 미리보기 창을 만들지 않는다. `request_live`는 명시 신뢰 프롬프트 없이
로드된 워크스페이스/전역 설정만 사용하며, 미로드 workspace 설정이 있으면 false를 반환한다.
진행 중 같은 키 요청은 합치고 완료 이벤트를 한 번 보낸다. 완료된 동일 키는 캐시를 재사용한다.
블록 목록·본문·위치 변화도 별도 이벤트를 발행한다. 렌더러의 `{docdir}`는 절대 문서 폴더다.

실행·렌더 작업은 launcher 프로세스 목록에 `coderunner`로 등록되고 완료 시 제거된다.
목록에서 종료하면 runner는 `run.cancel(id)`, renderer는 해당 렌더 작업 취소로 연결된다.

Markdown 버퍼의 기본 키맵은 다음과 같다(leader 뒤 키).

| 키 | 명령 |
| --- | --- |
| cr / cR | CodeRun / CodeRun! |
| cc / co | CodeCancel / CodeOutput |
| cd / cD | CodeRender / CodeRender! |
| ce / cE | CodeExport / CodeExportAll |

전역 기본값 `render_on_open=false`와 달리 이 저장소 init.lua는 true로 설정한다.
보이는 전역 PlantUML 블록 중 캐시가 없는 항목을 렌더한다. 기존 mdloom/rendermark의
표시 흐름은 병행 기간에 유지한다.

## 워크스페이스 설정과 이전 예시

프로젝트 루트 `.coderunner.lua`는 표를 반환한다. 명령 실행 전 `CodeRunnerLoad`로 신뢰한다.

```lua
return {
    runners = {
        python = { match = { 'python' }, ext = 'py', cmd = { 'python3', '-u', '{file}' } },
    },
    attachments = './assets',
    create_attachments_dir = 'ask',
}
```

예를 들어 mdloom `.mdloom/config.toml`의 다음 설정은

```toml
[runners.python]
match = ["python"]
ext = "py"
cmd = ["python3", "{file}"]

[renderers.dot]
match = ["dot"]
formats = ["png", "svg"]
cmd = ["dot", "-T{format}", "{file}", "-o", "{output}"]
```

위 Lua 예시의 `runners.python` 및 `renderers.dot` 표로 옮긴다.
TOML 대괄호 배열은 Lua 중괄호 배열로, 섹션은 중첩 표로 바꾼다.
`steps`, `env`, `cwd`, `input`, `output`, `timeout`도 같은 이름으로 옮기며,
렌더러의 `{attr.*}` 사용은 제거해야 한다. 캐시 형식은 공유하지 않아 최초 렌더가 필요하다.
신뢰는 새 `.coderunner.lua`에 다시 부여한다. `.prjroot`는 기존 코드에서 신뢰 확인 없이
실행되므로 다운로드한 프로젝트의 `.prjroot` 자체를 신뢰할 수 있는지도 별도로 확인한다.


C9 Linux 통합 검증(2026-10-30):

| 범위 | 결과 |
| --- | --- |
| Python 실제 명령 | 실행·결과창/q·재열기·해제·output·실패 속성·긴 펜스·undo 통과 |
| PlantUML 실제 SVG | 캐시 적중·저장 자동 렌더·내보내기·stale·전체 갱신·실패 진단/복구 통과 |
| GC | dry-run·삭제·현재 이미지 보호 통과 |
| 프로세스·경합·안전 | 가짜 도구 스펙에서 취소/타임아웃/자손 종료/2인스턴스/신뢰 거부/부분 실패 검증 |
| CRLF | Linux 파일·버퍼 스펙 통과, Windows 네이티브 미검증 |
| 대화형 GUI·신뢰 프롬프트 | 미검증, 신뢰 단위 스펙은 secure.read 스텁 사용 |
| mdloom 공존 broken-image 진단 | 미검증 |
| Windows | 가짜 도구·트리 종료·경로·신뢰 프롬프트 모두 미검증 |

실제 도구 smoke 재현은 `tests/manual/coderunner_smoke.lua`다. 이 환경의 plantuml wrapper가
없는 `/usr/bin/java`를 사용하므로 설치된 JDK와 jar를 직접 지정했다. 시스템 설정을 바꾸지 않았다.

```sh
smoke_runtime=$(mktemp -d)
CODERUNNER_SMOKE_JAVA=/home/ilmoek/.local/jdk-21/bin/java \
CODERUNNER_SMOKE_JAR=/usr/share/java/plantuml/plantuml.jar \
XDG_CACHE_HOME="$smoke_runtime/cache" XDG_STATE_HOME="$smoke_runtime/state" \
NVIM_LOG_FILE="$smoke_runtime/nvim.log" \
  nvim --headless -u tests/minimal_init.lua -i NONE -l tests/manual/coderunner_smoke.lua
rm -rf "$smoke_runtime"
```

정상 `plantuml` 명령이 있는 환경에서는 두 `CODERUNNER_SMOKE_*` 환경변수를 생략한다.
5,000줄/200블록 파싱·저장 검사 수치와 재현은 [성능 문서](coderunner_performance.md)에 있다.
반복 조회와 무변경 저장은 캐시를 사용한다. 초기·변경 파싱 비용은 남는다.

테스트 실행기는 고의 실패 시 파일/디렉터리 모두 종료 코드 1을 반환함을 확인했다.
전체 로그에는 기존 launcher 테스트 상태의 가짜 handle 정리에서 `is_closing` 콜백 경고가 남지만
스펙 Failed/Errors는 0이다. Windows·GUI·mdloom 확인 전까지 관련 이슈는 열린 상태로 유지한다.
