# 작업 계획서: rendermark — 모든 그리기를 담당 (3/3)

- 이슈: `.issues/open/issue-rendermark_all_drawing.md`
- 작성: 2026-10-30
- 작업 순서 (2026-10-30 변경): coderunner ([coderunner_plan.md](coderunner_plan.md))와 mdloom ([`~/workspace/markdown_lsp/doc/work-plans/lsp-scope.md`](../../markdown_lsp/doc/work-plans/lsp-scope.md))이 병행으로 끝난 뒤 → **rendermark (이 문서)**
- 세 작업은 분리해서 구현하고 각각 테스트한다. 이 작업은 coderunner와 mdloom 작업이 모두 끝난 뒤 시작한다. 따라서 mdloom 플러그인의 그리기 코드는 이미 삭제돼 있고 coderunner 공급 인터페이스는 확정돼 있다.
- 이 문서의 줄 번호는 2026-10-30 작업 트리 기준이다. 구현 시점에 `grep`으로 다시 확인한다.

## 1. 배경과 결정

| 번호 | 결정 |
| --- | --- |
| D1 | 모든 이미지·다이어그램 그리기는 rendermark가 한다. mdloom 플러그인의 그리기 코드는 삭제된다 (mdloom 작업 L1). |
| D2 | 이미지 항목은 rendermark가 기존 스캔 코드(`image/scan.lua`)로 얻는다. mdloom의 `documentLink` 이미지 조회는 쓰지 않는다 (mdloom 쪽도 삭제됨). |
| D3 | 다이어그램 이미지는 coderunner가 렌더링하고, rendermark는 "블록 → 렌더된 이미지 경로" 데이터를 받아 그리기만 한다. rendermark는 coderunner·mdloom을 `require`하지 않는다. 연결은 glue 파일 하나가 맡는다. |
| D4 | 지금 작업 트리에 있는 임시 우회(`images = false`, `image.enabled`)는 이 작업에서 제거한다. |

## 2. 현재 상태 (2026-10-30 작업 트리)

미커밋 변경 (`git diff HEAD`):

| 파일 | 변경 | 처리 |
| --- | --- | --- |
| `init.lua` | `rendermark.setup{ images = false, ... }` 추가 | R1에서 제거 |
| `lua/nvim_config/rendermark/init.lua` | `image.enabled = not opts or opts.images ~= false`, `if image.enabled then image.setup(opts) end` | R1에서 되돌림 |
| `lua/nvim_config/rendermark/image/init.lua` | `is_active()`에 `M.enabled ~= false` | R1에서 되돌림 |
| `lua/nvim_config/rendermark/image/place.lua` | `_send_images_impl`에 `M.enabled == false` 조기 반환 | R1에서 되돌림 |
| `lua/nvim_config/lsp/servers/markdown.lua` | markdown-oxide 설정을 mdloom 로컬 경로(`~/workspace/markdown_lsp`) 연결로 교체 | R1에서 정리(경로 설정화) |
| `lua/nvim_config/plugins/complete.lua` | `markdown_link`·`markdown_image` cmp 소스 등록·사용 제거 | R1에서 확정 |
| `.gitignore`, `docs/module_refactoring.md`, `issues/closed/*` | 이슈 폴더 개명 등 | 이 작업과 무관 |

rendermark 이미지 모듈 구성 (`lua/nvim_config/rendermark/image/`, 합계 약 3,100줄):

| 파일 | 줄 | 역할 | 이 작업의 영향 |
| --- | --- | --- | --- |
| `init.lua` | 384 | 공개 API, 자동명령, 설정 | 공급자 등록 API 추가, plantuml 상태 제거 |
| `scan.lua` | 216 | 버퍼 텍스트에서 `![alt](path)` 찾기, 경로 해석, 크기 읽기 | 그대로 사용 (D2) |
| `place.lua` | 676 | 이미지 수집·배치·예약·전송 | `collect_plantuml_images` 호출을 공급자 기반으로 교체 |
| `plantuml.lua` | 435 | plantuml **실행·캐시·임시 폴더·디바운스** + 활성 블록 미리보기 float/split | 실행 제거, 표시·미리보기만 남겨 `diagram.lua`로 개명 |
| `blocks.lua` | 92 | 펜스 블록 위치·높이 스캔(plantuml 한정) | 공급자 항목으로 대체, 제거 또는 축소 |
| `preview.lua` | 340 | 미리보기 배치 계산(float/split) | 거의 그대로 |
| `layout.lua`·`size.lua`·`screen.lua`·`extmarks.lua`·`backend.lua`·`stub.lua` | 134·107·198·70·91·354 | 크기 계산·화면·extmark·`vim.ui.img` 백엔드·텍스트 박스 stub | 그대로 |

주변:
- `rendermark/deco.lua`: 코드블록 장식에서 `plantuml`·`puml`·`uml`을 비활성화하는 목록(31행)
- `rendermark/complete/{image,link}.lua`: nvim-cmp 소스. 작업 트리에서 이미 등록 해제
- `rendermark/actions.lua`, `rendermark/rename.lua`: markdown-oxide 전용 보정(파일 생성 액션, rename). mdloom 연결로 바뀐 지금 `on_attach`가 호출되지 않는다.
- 테스트: `tests/spec/rendermark/{image/init_spec,image/diff_spec,table_image_spec,events_spec,actions_spec,rename_spec,complete/image_spec,...}.lua`
- 성능 기준: `docs/image_reapply_performance.md`, `tests/manual/benchmark_image_reapply.lua`, `docs/plantuml_scan_performance.md`

## 3. 결정이 필요한 항목

| ID | 질문 | 선택지 | 권장 |
| --- | --- | --- | --- |
| Q1 | 이미지 소스 범위. 기존 mdloom은 위키(`![[x]]`)·HTML `<img>`·참조형(`![a][r]`) 이미지도 표시했다. rendermark 스캔은 `![alt](path)`(표 행 포함)만 찾는다 | (a) 기능 축소를 감수 (b) HTML `<img src>`와 참조형(로컬 경로)을 `scan.lua`에 추가 (c) 위키까지 추가 | **(c)로 확대 적용 (2026-10-30 사용자 결정: rendermark에 확대 적용)**. HTML `<img src>`, 참조형 이미지, 위키 이미지를 모두 rendermark 스캔이 지원한다. 위키 이름형(`![[img.png]]`)은 mdloom 인덱스 없이 풀어야 하므로 R6에서 규칙을 정한다: 문서 폴더 → 워크스페이스 루트 아래 이름 검색(`vim.fs.find`, 숨김·`node_modules`·`.git` 제외, 결과 캐시, 동명이면 문서와 가까운 것 우선, 없으면 오류 박스) |
| Q2 | 다이어그램을 그릴 때 위치 방식. 기존 rendermark: 비활성 블록은 **소스를 이미지로 대체**(`source_span_height`로 높이 예약, 소스 conceal), 커서가 들어오면 소스를 드러내고 미리보기 float/split. mdloom: 소스 아래에 이미지 | (a) 기존 rendermark 방식 유지 (b) mdloom 방식 | **(a)**. 사용자가 익숙한 동작을 유지한다 |
| Q3 | 내보낸 이미지(블록 바로 아래 이미지 링크)가 있는 블록 | (a) 둘 다 그린다 (b) 인접 이미지 링크가 있으면 그 블록의 다이어그램 이미지는 그리지 않고 소스를 그대로 둔다(링크 이미지가 표시를 맡음) (c) 인접 이미지가 있으면 블록 이미지만 그리고 링크 이미지는 숨긴다 | **(b)**. 결과가 렌더된 문서와 같고 중복이 없으며 구현이 단순하다(rendermark 쪽에서 인접 판정만 필요). 내보낸 이미지가 오래됐을(`stale-export`) 때의 표시는 진단이 알린다 |
| Q4 | 설정 키 `plantuml.preview` | (a) `diagram.preview`로 개명하고 `plantuml.preview`는 호환 별칭으로 한 버전 유지 (b) 이름 유지 | **(a)**. `init.lua`의 사용자 설정은 이 작업에서 같이 바꾼다 |
| Q5 | 오염된 기존 코드: `complete/image.lua`, `complete/link.lua`, `actions.lua`, `rename.lua` | (a) 삭제(관련 스펙도 삭제) (b) 보존 | **(a)**. mdloom이 같은 기능을 LSP로 제공한다(이미지 경로 완성 포함, 계약 17절 `![…](` 완성). 단, 삭제 전에 사용처(`lsp/attach.lua` 등) 확인 |
| Q6 | glue 파일 위치 | (a) `lua/nvim_config/markdown.lua` 신규 (b) `lsp/servers/markdown.lua`에 추가 | **(a)**. rendermark↔coderunner 연결과 mdloom 연결(LSP)을 분리한다. `lsp/servers/markdown.lua`는 LSP 연결만 담당 |
| Q7 | mdloom 경로 하드코딩(`~/workspace/markdown_lsp`) | (a) 설정 키 `vim.g.mdloom_dir`/`setting`으로 이동 (b) 현상 유지 | **(a)** (R1). 기본값은 `vim.fn.exepath('mdloom')`이 있으면 PATH의 바이너리, 없으면 설정된 개발 경로 |
| Q8 | 미리보기를 렌더 안 된 블록에서 어떻게 시작하나 | `coderunner.request_live(buf, row)` (coderunner_plan 6절)를 커서 진입 400ms 뒤에 호출 | 기존 `plantuml_debounce_active`와 같은 400ms 디바운스를 rendermark가 유지 |

## 4. 구조 (목표)

```
rendermark/
  init.lua                 setup — image.setup 항상 호출 (임시 우회 제거)
  image/
    init.lua               + set_diagram_source(source), refresh(buf)
    scan.lua               그대로 (Markdown 이미지)
    diagram.lua            (구 plantuml.lua) 공급자 항목 → 그리기 항목 변환, 활성 블록 미리보기, 오류 표시
    place.lua              CollectImages: 이미지 + 다이어그램 항목 병합
    preview.lua, layout.lua, size.lua, screen.lua, extmarks.lua, backend.lua, stub.lua  그대로
    blocks.lua             삭제 (블록 위치는 공급자가 제공)
  (삭제) complete/, actions.lua, rename.lua  — Q5
nvim_config/markdown.lua   glue: coderunner ↔ rendermark.image, mdloom LSP 연결 보조
```

### 4.1 rendermark 쪽 공급자 API

```lua
-- 공급자: 한 버퍼의 다이어그램 항목을 돌려주는 함수 하나 + 선택적 live 요청 함수.
-- coderunner를 몰라도 되도록 항목 형식만 약속한다 (coderunner_plan 6절과 동일한 필드).
require('nvim_config.rendermark.image').set_diagram_source({
  items = function(buf) return { --[[ DiagramItem[] ]] } end,
  request_live = function(buf, row) end,  -- 선택. 활성 블록 미리보기가 필요할 때 호출
})
require('nvim_config.rendermark.image').refresh(buf)  -- 공급자 결과 변경 시 glue가 호출
```

`DiagramItem` = `{ start_row, end_row, key, lang, path?, format?, stale, status = 'ready'|'pending'|'failed'|'none', error? }` (0-based 행).

### 4.2 glue (`nvim_config/markdown.lua`)

```lua
-- 의사 코드
local image = require('nvim_config.rendermark.image')
local runner = require('nvim_config.coderunner')
image.set_diagram_source({
  items = function(buf) return runner.diagrams(buf) end,
  request_live = function(buf, row) runner.request_live(buf, row) end,
})
vim.api.nvim_create_autocmd('User', {
  pattern = 'CodeRunnerDiagrams',
  callback = function(args) image.refresh(args.data.buf) end,
})
```

두 모듈이 서로를 모른 채 glue 한 곳에서만 연결된다. 한쪽을 교체하거나 끄면 다른 쪽은 영향이 없다 (coderunner가 없으면 공급자 없음 → 다이어그램 항목 없음 → Markdown 이미지만 그림).

## 5. 단계

각 단계 끝에서 `bash run_tests.sh`(전체 스펙)가 통과해야 한다. 이미지 관련 단계(R3 이후)는 `bash run_tests.sh tests/spec/rendermark`와 성능 벤치도 확인한다.

### R0 — 기준선

- [ ] 작업 트리 미커밋 변경(2절 표)을 정리한다: 이 작업과 무관한 항목(`.gitignore`, `docs/module_refactoring.md`, `issues/closed/*`)은 별도 커밋으로 분리하거나 사용자 판단에 맡긴다. 임시 우회 변경(`images = false` 관련)은 R1에서 되돌리므로 커밋하지 않는다
  - 점검만 수행(2026-10-30): 2절 표와 일치함(`git status` 기준 변경 14개 + 미추적 `nvim.log`). 무관 항목은 손대지 않음. 분리 커밋은 사용자 판단 대기라 체크하지 않음. `nvim.log`는 2절 표에 없는 미추적 파일(`.gitignore` 대상 여부 확인 필요)
- [x] 기준 테스트: `bash run_tests.sh` 결과와 `tests/spec/rendermark` 통과 수 기록
  - 전체: 69개 스펙 파일, 통과 696 / 실패 0 / 오류 0 (coderunner_plan C9 기록 697과 1 차이). `tests/spec/rendermark`: 13개 파일, 통과 259 / 실패 0 / 오류 0
- [x] 기준 성능: `nvim --headless -u NONE -l tests/manual/benchmark_image_reapply.lua` 결과 기록(1,000회 누적 호출 수와 중앙값)
  - 5회 실행 중앙값: 변경 없음 680.0 ms (671.98~696.66), 이미지 하나 너비 변경 690.8 ms (681.36~705.88). 1,000회 누적 호출: 변경 없음 set/mark/clear/redraw/del 전부 0; 이미지 하나 변경 set 1000, mark 2000, clear 1000, redraw 1000, del 0. `docs/image_reapply_performance.md`의 수정 후 수치(683.9/700.2 ms, 0 / 1000·2000·1000·1000)와 일치
  - 벤치는 `vim.ui.img`·`rpcnotify`·`collect_markdown_images`를 스텁으로 고정한 Lua+API 비용 측정이라 pty/드레인 없이도 위 문서와 같은 값이 나옴(실제 GUI 비용 아님). 주의: 스크립트가 `img.collect_plantuml_images`를 스텁하므로 R3에서 `collect_diagram_images`로 개명하면 벤치 스크립트도 같이 고쳐야 함
- [ ] 기존 동작 캡처(수동): plantuml 블록이 있는 문서를 열어 (i) 비활성 블록이 이미지로 대체되는지 (ii) 커서 진입 시 미리보기 split이 뜨는지 (iii) `RENDERMARK_IMG_STUB=1`로 텍스트 박스가 보이는지 스크린샷/메모 — 회귀 비교용
  - 사용자 수동 확인 필요: 화면 캡처·neopp GUI는 헤드리스에서 불가해 건너뜀
- [x] mdloom 플러그인의 그리기 기능 중 사용자가 의존하던 것의 목록(5절 R6 체크리스트의 입력): 소스 숨김 후 커서 올리면 노출, 한 줄 여러 이미지 나란히, 참조형 이미지, 표 안 이미지, 이미지 크기 읽기(PNG/JPEG/GIF/WebP), neopp 우선, `MDLOOM_IMG_STUB`
  - 출처: mdloom 태그 `before-lsp-scope`의 `editors/nvim/lua/mdloom/{image,images,image_size}.lua`와 `tests/{images,images_unit}.lua`(스펙 제목 14개). 확인된 목록(R6 표 외 추가분에 `*`):
    1. 이미지 자리 예약(virt_lines)과 소스 불변(버퍼 내용·modified 안 바뀜)
    2. 이미지·다이어그램 소스 숨김, 커서가 올라오면 노출 (f660eb8)
    3. 한 줄 여러 이미지 나란히, 폭 초과 시 줄바꿈 (f8fca98)
    4. 참조형 이미지 `![a][r]` 사용 위치마다 표시, 정의 conceal (be74a94)
    5. 위키 이미지 `![[x.png]]`, HTML `<img src>` (documentLink 해석 경유)
    6. `~/` 경로 확장 (issue image_tilde_path), 다운로드 링크(비이미지)는 제외*
    7. 이미지 크기 읽기 PNG/JPEG/GIF/WebP, 잘린 헤더·미지원 형식(SVG)은 무시 (`image_size.lua`)
    8. neopp 우선: 늦게 붙는 neopp provider에 경로·원본 비율·창 클리핑(`clip_*`, `dest_y_px`) 전달, 기본 `vim.ui.img`는 PNG만(그 외 형식은 provider 실패로 간주)
    9. 스크롤로 일부만 보일 때 클리핑 유지, 창 분할 시 창별 독립 placement, 창 닫기/스크롤 시 stale 제거*
    10. 편집·버퍼 삭제·비활성화 시 소유한 이미지 id와 예약만 정리*
    11. provider 오류 시 빈 예약 제거, 같은 파일 리비전으로 무한 재시도하지 않음*
    12. provider 미구비/불완전해도 SafeState에서 오류 없음*
    13. 오래된 응답 거부(서버 응답 경합)* — 서버 의존이라 rendermark에는 해당 없음
    14. 이미지가 있는 창의 `conceallevel < 1`이면 2로 올림*
    15. `MDLOOM_IMG_STUB=1`: provider 없이 이미지·다이어그램 텍스트 박스(`+---+`, `img:`) 표시, 해제 시 정상 렌더 복원
    16. 다이어그램: 렌더 캐시 hover 기반 인라인 표시, 렌더 알림이 해당 클라이언트·문서만 갱신 (coderunner/R3로 이관, 그리기 부분만 rendermark 대상)
    17. 확대 미리보기 `MdloomOpenImage` (`image.lua` open/close)
  - R6 표에서 아직 없는 행: 9(스크롤 중 일부만 보임), 11(재시도 억제), 12, 14는 rendermark에 이미 같은 동작이 있는지 R6에서 대조해야 함
- 완료 조건: 기준 수치가 이 문서 8절에 기록됨.

### R1 — 임시 우회 제거와 연결 정리

- [ ] `init.lua`: `images = false` 줄과 그 주석 제거 (`rendermark.setup{ max_width = 120, plantuml = {...} }` 형태로 복원, `plantuml` 키는 R4에서 개명)
- [ ] `lua/nvim_config/rendermark/init.lua`: `image.enabled = ...` 줄 제거, `if image.enabled then image.setup(opts) end` → `image.setup(opts)` (HEAD 상태)
- [ ] `lua/nvim_config/rendermark/image/init.lua`: `is_active()`를 `return backend.is_active()`로 복원
- [ ] `lua/nvim_config/rendermark/image/place.lua`: `_send_images_impl`의 `M.enabled == false` 조건 제거 (`if not backend.img_available() then return end`)
- [ ] 위 4곳은 `git checkout HEAD -- <파일>`로 되돌릴 수 있는지 확인(다른 변경과 섞이지 않았는지 `git diff`로 먼저 확인). 이 작업에서 이 4개 파일은 임시 우회 외 변경이 없다
- [ ] `lua/nvim_config/lsp/servers/markdown.lua` (Q7): 하드코딩 `~/workspace/markdown_lsp` 제거 → 설정 `setting` 모듈 또는 `vim.g.mdloom_dir`에서 읽기. 기본값은 PATH의 `mdloom`. rtp 추가(`editors/nvim`)는 플러그인을 설치 경로에서 가져올 수 없는 개발 환경에서만 수행. `target/debug/mdloom` 경로도 같은 설정으로
- [ ] Q5 결정에 따라 `complete/image.lua`, `complete/link.lua`, `actions.lua`, `rename.lua`와 스펙(`complete/image_spec`, `actions_spec`, `rename_spec`) 삭제. 삭제 전 `grep -rn "rendermark.complete\|rendermark.actions\|rendermark.rename" lua tests`로 참조 확인
- [ ] `plugins/complete.lua`의 cmp 소스 제거를 확정(이미 작업 트리에 있음)
- [ ] 스펙: 기존 이미지 스펙(`image/init_spec`, `table_image_spec`)이 `images` 기본값 상태에서 통과 — `image.enabled` 분기가 사라졌는지 확인
- 완료 조건: `grep -rn "image.enabled\|images = false\|M.enabled" lua init.lua` 결과 없음. mdloom 연결 상태에서 Markdown 이미지가 한 번만 그려진다(mdloom 플러그인의 그리기는 mdloom 작업 L1에서 이미 제거됨). (mdloom 작업이 먼저 끝나므로 mdloom 쪽 이미지 표시는 이미 없다.)

### R2 — 이미지 스캔 범위 (Q1: (c)로 확대 결정됨)

- [ ] 사용 현황 조사: 사용자의 노트 폴더에서 위키 이미지·HTML `<img>`·참조형 이미지 사용 빈도를 `grep`으로 센다 (`rg '!\[\[' ~/notes`, `rg '<img ' ~/notes`, `rg '^\[[^]]+\]: .*\.(png|jpg)' ~/notes`)
- [ ] 조사 결과로 지원 우선순위를 정한다(전부 구현하되 빈도가 높은 문법부터): 위키 이미지, 참조형, HTML `<img>`
- [ ] 구현 상세는 R6의 "스캔 확대"에서 한다. 이 단계는 조사와 우선순위 기록이다
- 완료 조건: 조사 수치와 구현 순서가 이 문서에 기록됨.

### R3 — 공급자 API와 다이어그램 항목 처리 (image/init.lua, place.lua, diagram.lua)

구현:
- [ ] `image/init.lua`: `set_diagram_source(source)`, `refresh(buf)`, `clear_diagram_source()` 추가. `refresh`는 해당 버퍼의 캐시(`block_cache`)를 무효화하고 `M.send_images()`를 예약
- [ ] `image/plantuml.lua` → `image/diagram.lua` 개명(`git mv`) 후 정리:
  - [ ] 제거: `plantuml_resolve_command`, `plantuml_jar`, `plantuml_run`, 임시 디렉터리·잡 관리·`plantuml_ensure_render`·`plantuml_sanitize_error`, 환경변수 `RENDERMARK_PLANTUML_JAR`/`PLANTUML_JAR`/`vim.g.rendermark_plantuml_jar`, "PlantUML disabled" 알림
  - [ ] 유지·재작성: `collect_plantuml_images(buf, result, errors)` → `collect_diagram_images(buf, result, errors)`:
    - 공급자 `items(buf)`를 호출. 항목마다 활성 블록 여부 판정(`plantuml_active_block`와 동일 로직)
    - 비활성 + `status == 'ready'`(또는 stale이지만 path 존재) → 기존과 같은 이미지 항목을 `result`에 추가(`row`, `col`, `end_col`, `path`, `source_width/height`는 `read_image_size`, `source_span_height = end_row - start_row + 1`, `plantuml = true`→`diagram = true`, `plantuml_end_row`→`diagram_end_row`, `virtual = false`)
    - 비활성 + `status == 'failed'` → `errors`에 `{buf, row = end_row, msg = error}`
    - 비활성 + `none`/`pending` → 아무것도 그리지 않음(소스 그대로)
    - 활성 블록: 미리보기 흐름은 기존 `plantuml_debounce_active` 구조를 유지하되 렌더 호출만 `source.request_live(buf, row)`(400ms 디바운스)로 바꾼다. 항목이 `ready`면 `plantuml_open_split/float`(→ `diagram_open_split/float`)로 표시
    - `conceallevel < 2`이면 창 옵션을 올리는 기존 동작 유지
  - [ ] 버퍼 정리(`plantuml_cleanup_buf`)에서 임시 폴더·잡 정리를 제거하고 타이머·float 정리만 남긴다
  - [ ] 상태 이름 `plantuml_states` → `diagram_states`, 창 변수 `rendermark_plantuml_preview_*` → `rendermark_diagram_preview_*` (preview.lua 281~304행, place.lua 15행의 `rendermark_plantuml_preview_source` 포함)
- [ ] `image/blocks.lua`: `plantuml_find_blocks`/`markdown_plantuml_block_height`를 사용하는 곳을 공급자 항목으로 교체
  - `preview.lua` 107행(`block_h`), 152~153행(코드블록 회피), `scan.lua`의 `deps.markdown_plantuml_block_height`(init.lua 60행) → 공급자 항목의 `end_row - start_row + 1`을 조회하는 함수 `diagram_block_span(buf, row)`로 교체
  - `blocks.lua` 삭제. `block_cache`는 공급자 항목 캐시로 개명(편집 틱 기준 무효화는 `refresh`로 대체)
- [ ] `place.lua`:
  - [ ] 73~81행: `CollectImages`가 `collect_markdown_images`와 `collect_diagram_images`를 병합하도록 이름 변경(`plantuml_errors` → `diagram_errors`)
  - [ ] 231행 `img.plantuml` → `img.diagram`, 360~363행 `plantuml_end_row` → `diagram_end_row`
  - [ ] 604~607행 오류 virt_lines `[plantuml: ...]` → `[diagram: ...]`
  - [ ] 640행 `ctx.plantuml_errors` 이름 변경
- [ ] `deco.lua` 31행: 코드블록 장식 비활성 언어 목록(`plantuml`, `puml`, `uml`)을 하드코딩에서 **공급자가 아는 언어**로 바꿀지 결정. 기본: 장식은 활성 블록이 아닌 이미지 대체 블록에서 conceal로 가려지므로 그대로 두되 목록을 설정화(`opts.diagram.disable_deco_langs`, 기본 `{plantuml, puml, uml}` + glue가 렌더러 `match`로 확장)
- [ ] 설정 키(Q4): `opts.diagram.preview`를 읽고 `opts.plantuml.preview`는 별칭으로 한 번 경고 후 수용(`vim.notify_once`)
- [ ] 스펙 추가 `tests/spec/rendermark/image/diagram_spec.lua` (가짜 공급자 사용):
  - 항목 `ready` → 이미지 항목이 `result`에 들어가고 `source_span_height`가 블록 높이와 같다
  - 항목 `failed` → 오류 virt_line, `none` → 아무것도 없음, `pending` → 없음
  - 활성 블록(커서가 블록 안) → 해당 항목은 `result`에서 빠지고 미리보기만 열림. `request_live`가 400ms 디바운스로 한 번만 호출
  - 공급자 없음 → 다이어그램 항목 없음, Markdown 이미지는 정상
  - `refresh(buf)` → 다음 `send_images`에서 새 항목 반영, 변경 없는 버퍼는 `vim.ui.img.set` 재호출 없음
  - 블록 위치가 편집으로 이동 → 공급자가 바뀐 위치를 돌려주면 새 위치로 그림
  - 공급자가 예외를 던져도 렌더링이 중단되지 않음(`pcall`)
- [ ] 기존 스펙 갱신: plantuml 실행에 의존하던 스펙(`image/init_spec`의 plantuml 관련)은 가짜 공급자로 재작성, 삭제된 기능(`plantuml_resolve_command` 등)의 스펙 삭제
- [ ] 성능: `benchmark_image_reapply.lua`가 기준선(R0)과 같은 호출 수를 유지하는지, `docs/plantuml_scan_performance.md`의 시나리오를 공급자 기반으로 다시 측정
- 완료 조건: 위 스펙 통과, 벤치 호출 수 회귀 없음, `grep -rn "plantuml_run\|plantuml_resolve\|plantuml_find_blocks\|PLANTUML_JAR" lua` 결과 없음.

### R4 — glue (nvim_config/markdown.lua)와 사용자 설정

- [ ] `lua/nvim_config/markdown.lua` 신규: 4.2절의 연결. coderunner가 없으면(`pcall(require, ...)` 실패) 공급자를 등록하지 않는다
- [ ] 렌더러 `match` 언어와 rendermark의 `disable_deco_langs` 동기화: glue가 coderunner 설정에서 렌더러 언어 목록을 읽어 `diagram.disable_deco_langs`에 합친다 (coderunner API 필요: `runner.renderer_langs()` — coderunner 작업에서 제공. 없으면 이 항목은 보류하고 기본 목록만 사용)
- [ ] `init.lua`에 `require'nvim_config.markdown'.setup()` 추가 (rendermark, coderunner 설정 이후 순서)
- [ ] `init.lua`의 `rendermark.setup{ plantuml = { preview = ... } }`를 `diagram = { preview = ... }`로 변경 (Q4)
- [ ] coderunner `renderers.plantuml` 설정을 사용자 `init.lua`에 추가하고 `render_on_open = true`(coderunner_plan Q8)로 기존 "열면 보이는 plantuml 블록이 자동 렌더되는" 경험을 유지
- [ ] 스펙 `tests/spec/markdown_glue_spec.lua`: 가짜 coderunner 모듈로 (a) 이벤트 `CodeRunnerDiagrams` → `image.refresh` 호출 (b) coderunner 부재 시 오류 없음 (c) 이벤트의 `buf`가 로드되지 않은 버퍼여도 오류 없음
- 완료 조건: 스펙 통과. 실제 coderunner가 있으면 plantuml 블록이 렌더된 이미지로 표시되고 저장 시 갱신된다 (coderunner 작업 C8 이후 통합 확인).

### R5 — 인접 내보낸 이미지 정책 (Q3)

- [ ] 규칙: 다이어그램 블록의 `end_row` 아래로 **빈 줄 0~1개** 뒤에 오는 문단이 이미지 링크를 가지면(표준 `![]()`; 위키·HTML은 rendermark가 스캔하지 못하므로 해당 없음) 그 블록의 다이어그램 항목은 그리지 않는다(소스 그대로 표시, 이미지 링크는 평소처럼 그려짐)
- [ ] 판정은 `diagram.lua`가 `scan.lua`의 `find_image_links`를 이용해 블록 다음 행들만 검사한다. 편집 비용을 줄이기 위해 해당 행만 읽는다
- [ ] 옵션 `diagram.hide_when_exported`(기본 true)로 끌 수 있게 한다
- [ ] 스펙: 인접 링크 있음(빈 줄 0·1) → 블록 이미지 없음, 빈 줄 2 → 블록 이미지 있음, 인접 문단에 이미지가 없음 → 블록 이미지 있음, 옵션 off → 항상 블록 이미지
- 완료 조건: 스펙 통과, 중복 표시 없음(수동).

### R6 — mdloom 표시 기능 대비 동등성 점검과 선택 확장

mdloom 플러그인이 제공하던 표시 기능과 rendermark의 현재 지원을 대조한다. "없음"이면 이 단계에서 구현하거나 의도적으로 포기한다고 기록한다.

| 기능 | mdloom 플러그인 | rendermark 현재 | 조치 |
| --- | --- | --- | --- |
| 이미지 자리 예약(virtual lines) | 예 | 예 (`place.lua` 예약) | 없음 |
| 이미지가 그려지는 동안 소스 숨김, 커서가 올라오면 노출 (커밋 f660eb8) | 예 | 확인 필요 (`deco.lua`/conceal) | 대조 후 보완 |
| 한 줄 여러 이미지 나란히, 폭 초과 시 줄바꿈 (f8fca98) | 예 | 예 (`layout.lua` `layout_image_line`) | 동작 대조 (테스트 케이스 이식) |
| 참조형 이미지 `![a][r]` 사용 위치마다 표시, 정의 conceal (be74a94) | 예 | 아니오 | R6 스캔 확대로 구현 (Q1 (c)) |
| 위키 이미지 `![[x.png]]` | 예 | 아니오 | R6 스캔 확대로 구현 |
| HTML `<img src>` | 예 | 아니오 | R6 스캔 확대로 구현 |
| 틸드 `~` 경로(`~/img.png`) (이슈 image_tilde_path) | 예 | 예 (`vim.fn.expand` 사용) | 스펙으로 확인 |
| 경로의 `%20`·공백 | 서버가 해석 | `%20` 치환 예 | 스펙 확인 |
| 표 안 이미지 | 아니오 | 예 (`table_image_spec`) | 없음 |
| neopp 임시 id/path API 지원, 기본 bytes API(PNG만) | 예 | 확인 필요 (`backend.lua`) | 대조 |
| 이미지 일부만 보일 때 숨김(기본 API는 자르기 불가) | 예 | 확인 필요 | 대조 |
| 스크롤·창 크기·분할·접기·편집에 따른 갱신, 닫힌 창 ID 제거 | 예 | 예 | 없음 |
| 스텁(텍스트 박스) 표시 | `MDLOOM_IMG_STUB` | `RENDERMARK_IMG_STUB`/`vim.g.rendermark_img_stub` | 환경변수 이름이 다름 — 문서화 |
| 이미지 크기 읽기 형식 | PNG/JPEG/GIF/WebP | `size.lua` | 대조 |
| 확대 미리보기 창(`MdloomOpenImage`) | 예 | `RendermarkPreviewShow/Hide/Toggle`(다이어그램 미리보기) | 일반 이미지 미리보기가 필요한지 결정. 필요하면 기능 추가(작은 작업) |

- [ ] 위 "확인 필요" 항목을 코드와 실행으로 확인하고 표를 갱신
- [ ] 필요한 보완을 별도 서브 이슈로 분리해 진행(이 문서에서는 목록만 유지)
- [ ] 스캔 확대 (Q1 (c)): `scan.lua`와 `table_state` 연동에 다음을 추가한다. 스펙은 mdloom 원본 `images_unit.lua`·`images.lua`(`git show before-lsp-scope:editors/nvim/tests/images_unit.lua`) 케이스를 이식한다
  - [ ] HTML `<img src="…" width=…>`: `src` 해석(로컬만), `width`/`height` 속성이 있으면 표시 크기에 반영 여부 결정, 코드 안·주석 안은 제외, 같은 줄 여러 개
  - [ ] 참조형 `![alt][ref]`, `![ref][]`, `![ref]`: 같은 문서의 정의 줄 `[ref]: path "title"`만 해석(대소문자 무시, 공백 정규화), 사용 위치마다 표시, 정의 줄은 conceal(neovim 번들 `markdown_inline` 쿼리 conceal, 커밋 be74a94 참고), 정의가 없으면 표시하지 않음
  - [ ] 위키 `![[name.png]]`, `![[dir/name.png]]`, `![[name.png|300]]`(너비), `![[name.png#...]]`는 무시: 경로형은 문서 폴더 기준, 이름형은 위 Q1 규칙의 이름 검색. 검색은 비동기·캐시(파일 감시 없이 `BufEnter`/저장 시 무효화), 결과 없음/모호는 오류 박스(`not_found`)
  - [ ] 경로 규칙은 기존 `resolve_image_path`를 공유: `%20`, `~`, `<…>` 감싸기, 쿼리·앵커 제거
  - [ ] 코드 스팬·펜스 코드블록 안의 이미지 문법은 제외(기존 규칙 유지)
  - [ ] 성능: 문서 스캔 비용이 늘지 않도록 줄 단위 프리필터(`![`, `<img`, `[…]:`)를 유지하고 `docs/image_reapply_performance.md` 벤치를 다시 측정
- 완료 조건: 표의 모든 행에 "동등" 또는 "의도적 미지원(사유)"이 기록됨.

### R7 — 정리

- [ ] `docs/` 문서 갱신: rendermark 이미지·다이어그램 설명(있다면)과 `docs/coderunner.md`와의 경계 설명. `README.md`의 기능 목록 갱신
- [ ] 이슈 `issue-rendermark_all_drawing.md`의 "확인 필요" 항목 닫기
- [ ] `tests/manual/`의 plantuml 관련 수동 스크립트·벤치 정리 (`benchmark_plantuml_scan.lua` 등 사용 여부 확인)
- [ ] 죽은 코드 점검: `grep -rn "plantuml" lua tests docs init.lua` 결과가 의도된 것(호환 별칭, 문서의 과거 설명)만 남는지
- [ ] `docs/plantuml_scan_performance.md`는 과거 측정 기록으로 보존하고 머리말에 "plantuml 실행은 coderunner로 이동" 메모 추가

### R8 — 통합 검증

- [ ] `bash run_tests.sh` 전체 통과
- [ ] 성능 벤치(`benchmark_image_reapply.lua`) 호출 수가 R0 기준선과 같음(변경 없음 → `vim.ui.img.set` 0)
- [ ] 수동 (neopp GUI 또는 `RENDERMARK_IMG_STUB=1`):
  - [ ] Markdown 이미지가 한 번만 그려진다 (mdloom 플러그인 그리기 제거 후 중복 없음)
  - [ ] 표 안 이미지, 한 줄 여러 이미지, 스크롤·분할·접기·창 크기 변경 후 위치
  - [ ] plantuml 블록: 렌더된 이미지로 대체, 커서 진입 시 소스 노출과 미리보기, 블록 수정 후 저장 시 갱신
  - [ ] 렌더 실패 시 `[diagram: ...]` 경고 표시와 coderunner `render-failed` 진단
  - [ ] 내보낸 이미지가 있는 블록: 블록 이미지가 숨겨지고 링크 이미지만 보임 (Q3)
  - [ ] coderunner 없이(glue만 제거) Markdown 이미지가 정상
  - [ ] mdloom 연결 상태에서 mdloom 서버가 이미지 표시에 관여하지 않음(`:lua vim.print(vim.lsp.get_clients()[1].server_capabilities.codeLensProvider)` 가 nil)
  - [ ] 읽기 모드(`read_mode`)와의 상호작용 (활성 블록 미리보기는 읽기 모드에서 열리지 않음 — 기존 동작 유지)
- [ ] Windows GUI 환경: 이미지 경로(드라이브 문자, 역슬래시), 스크롤, 미리보기. 결과를 `docs/`에 기록
- [ ] 진행 기록 갱신, 이슈 종료

## 6. 위험과 대응

| 위험 | 영향 | 대응 |
| --- | --- | --- |
| 공급자 호출이 `send_images`의 핫 패스에서 비용을 만든다 | 높음: 스크롤 지연 | 공급자는 메모리 조회만 하도록 계약(coderunner_plan 6절). rendermark는 편집 틱/`refresh` 기준으로 결과를 캐시하고 `pcall`로 보호. 벤치로 확인 |
| 블록 위치 추적 불일치 (편집 직후 공급자 항목이 이전 위치) | 중간: 이미지가 잘못된 행에 그려짐 | `items(buf)`를 호출 시점의 파싱으로 계산하도록 coderunner에 요구(6절). rendermark는 `refresh`가 오기 전에는 이전 항목을 쓰되 `changedtick`이 바뀌면 항목을 숨기고 다음 `refresh`를 기다리는 옵션을 둔다 |
| 확대한 스캔(위키 이름 검색 등)의 성능·정확도 | 중간: 느린 스크롤, 잘못된 파일 표시 | 이름 검색은 비동기·캐시·상한(후보 수, 깊이), 동명이면 가까운 것 우선, 벤치 재측정. 모호한 경우 표시하지 않고 오류 박스 |
| 활성 블록 미리보기에서 live 렌더 요청이 과도 | 중간 | 400ms 디바운스 유지, coderunner가 같은 키를 캐시로 재사용 |
| 이름 변경(plantuml → diagram)으로 사용자 설정·창 변수 호환 깨짐 | 낮음 | 별칭 수용과 경고 한 번, 창 변수는 내부용이라 영향 없음 |
| 이 작업 전에 임시 우회(`images = false`)가 남아 있는 기간의 중복/누락 | 낮음 | 우회는 R1에서 제거. 그때까지 rendermark 이미지는 꺼져 있고 mdloom 플러그인 표시가 대신한다 |
| 기존 스펙이 plantuml 실행에 강하게 결합 | 중간 | R3에서 가짜 공급자로 재작성. 삭제하는 스펙 목록을 이 문서 진행 기록에 남김 |

## 7. 이슈와의 매핑

`issue-rendermark_all_drawing.md`의 작업 항목 → 이 문서: 1(임시 우회 제거)=R1, 2(외부 입력 인터페이스)=R3·R4, 3(plantuml 실행 제거)=R3, 4(이미지 소스 종류)=R2·R6, 5(MDLOOM_IMG_STUB 의존)=R6 표, 6(conceal·배치·표·미리보기)=R6, 7(불필요 모듈 정리)=R1·R7.

## 8. 진행 기록

| 단계 | 상태 | 날짜 | 비고 |
| --- | --- | --- | --- |
| 선행: coderunner, mdloom 작업 | 부분 완료 | 2026-10-30 | coderunner: C0~C8 완료, C9는 Linux 자동 검증만 완료(Windows/GUI/mdloom 실환경·수동 시나리오 미검증, 이슈 유지). mdloom(`lsp-scope` 브랜치, master 미병합): L0~L5 완료, L6 부분 완료(구현 후 문서 대조 필요), L7 검증·L8 마무리 대기 |
| R0 기준선 | 부분 완료 | 2026-10-30 | 기준 수치: 전체 스펙 696 통과/0 실패/0 오류(69 파일), rendermark 259 통과/0/0(13 파일). 벤치(5회 중앙값, 1,000회): 변경 없음 680.0 ms·호출 전부 0, 이미지 하나 변경 690.8 ms·set 1000/mark 2000/clear 1000/redraw 1000. 미완: 수동 동작 캡처(사용자 확인 필요), 무관 변경 분리 커밋(사용자 판단) |
| R1 임시 우회 제거 | 대기 | | |
| R2 스캔 범위 결정 | 대기 | | |
| R3 공급자 API·diagram.lua | 대기 | | |
| R4 glue·사용자 설정 | 대기 | | |
| R5 인접 내보낸 이미지 정책 | 대기 | | |
| R6 동등성 점검 | 대기 | | |
| R7 정리 | 대기 | | |
| R8 통합 검증 | 대기 | | |
