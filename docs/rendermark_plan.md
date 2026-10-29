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
- 성능 기준: `docs/image_reapply_performance.md`, `tests/manual/benchmark_image_reapply.lua`, `docs/image_scan_performance.md`

## 3. 결정이 필요한 항목

| ID | 질문 | 선택지 | 권장 |
| --- | --- | --- | --- |
| Q1 | 이미지 소스 범위. 기존 mdloom은 위키(`![[x]]`)·HTML `<img>`·참조형(`![a][r]`) 이미지도 표시했다. rendermark 스캔은 `![alt](path)`(표 행 포함)만 찾는다 | (a) 기능 축소를 감수 (b) HTML `<img src>`와 참조형(로컬 경로)을 `scan.lua`에 추가 (c) 위키까지 추가 | **(c)로 확대 적용 (2026-10-30 사용자 결정: rendermark에 확대 적용)**. HTML `<img src>`, 참조형 이미지, 위키 이미지를 모두 rendermark 스캔이 지원한다. 위키 이름형(`![[img.png]]`)은 mdloom 인덱스 없이 풀어야 하므로 R6에서 규칙을 정한다: 문서 폴더 → 워크스페이스 루트 아래 이름 검색(`vim.fs.find`, 숨김·`node_modules`·`.git` 제외, 결과 캐시, 동명이면 문서와 가까운 것 우선, 없으면 오류 박스). **사양 변경 (2026-10-30 사용자 결정)**: 참조형 이미지의 **정의 줄(`[ref]: path`)은 conceal 하지 않고 그대로 둔다**(be74a94의 결론 + 공간 예약 계약: 텍스트 conceal은 빈 행을 남기고 `conceal_lines`는 행 배치를 바꾼다). 이전 서술의 "정의 conceal" 요구는 폐기. 사용 위치 `![a][r]` 전체의 conceal은 유지 |
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
    4. 참조형 이미지 `![a][r]` 사용 위치마다 표시, ~~정의 conceal~~ (be74a94; 정의 줄은 conceal 하지 않음으로 사양 변경, 사용자 결정 2026-10-30)
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

- [x] `init.lua`: `images = false` 줄과 그 주석 제거 (`rendermark.setup{ max_width = 120, plantuml = {...} }` 형태로 복원, `plantuml` 키는 R4에서 개명)
  - 완료(2026-10-30): `images = false` 줄과 주석 제거(`git diff HEAD -- init.lua`에는 아래 `vim.g.mdloom_dir` 한 줄만 남음)
- [x] `lua/nvim_config/rendermark/init.lua`: `image.enabled = ...` 줄 제거, `if image.enabled then image.setup(opts) end` → `image.setup(opts)` (HEAD 상태)
- [ ] `lua/nvim_config/rendermark/image/init.lua`: `is_active()`를 `return backend.is_active()`로 복원
- [ ] `lua/nvim_config/rendermark/image/place.lua`: `_send_images_impl`의 `M.enabled == false` 조건 제거 (`if not backend.img_available() then return end`)
- [x] 위 4곳은 `git checkout HEAD -- <파일>`로 되돌릴 수 있는지 확인(다른 변경과 섞이지 않았는지 `git diff`로 먼저 확인). 이 작업에서 이 4개 파일은 임시 우회 외 변경이 없다
  - 완료: `git diff`로 임시 우회 외 변경이 없음을 확인하고 `git checkout HEAD -- <3개 파일>`로 복원(`init.lua`는 우회 줄만 제거)
- [x] `lua/nvim_config/lsp/servers/markdown.lua` (Q7): 하드코딩 `~/workspace/markdown_lsp` 제거 → 설정 `setting` 모듈 또는 `vim.g.mdloom_dir`에서 읽기. 기본값은 PATH의 `mdloom`. rtp 추가(`editors/nvim`)는 플러그인을 설치 경로에서 가져올 수 없는 개발 환경에서만 수행. `target/debug/mdloom` 경로도 같은 설정으로
  - 완료: 설정 방식은 `vim.g.mdloom_dir`(기존 `vim.g.*` 관례, `init.lua`에서 `~/workspace/markdown_lsp`로 설정). 바이너리는 PATH의 `mdloom` → `<mdloom_dir>/target/{debug,release}/mdloom` 순. `editors/nvim` rtp 추가는 `mdloom_dir`가 있고 그 디렉터리가 존재할 때만. 플러그인(`require('mdloom')`)이 없거나 바이너리가 없으면 조용히 건너뜀. 경로 결정은 `M.cmd(dir)`로 노출하고 `tests/spec/lsp_spec.lua`에 스펙 3개 추가
  - 참고: 현재 PATH의 `mdloom`은 `~/workspace/markdown_lsp/target/debug/mdloom`으로의 심볼릭 링크라 개발 빌드와 같은 바이너리를 가리킴
- [x] Q5 결정에 따라 `complete/image.lua`, `complete/link.lua`, `actions.lua`, `rename.lua`와 스펙(`complete/image_spec`, `actions_spec`, `rename_spec`) 삭제. 삭제 전 `grep -rn "rendermark.complete\|rendermark.actions\|rendermark.rename" lua tests`로 참조 확인
  - 완료: 참조는 `actions.lua`→`rename.lua` 상호 참조, `plugins/complete.lua`, `tests/spec/plugins/complete_spec.lua`의 모의 등록, `tests/test_lazy_plugins.lua`(수동 스크립트의 `markdown_image` 소스 기대)뿐이었고 모두 함께 정리. `rendermark/complete/` 디렉터리 삭제. 삭제 스펙은 `complete/image_spec`, `actions_spec`, `rename_spec`
- [x] `plugins/complete.lua`의 cmp 소스 제거를 확정(이미 작업 트리에 있음)
- [x] 스펙: 기존 이미지 스펙(`image/init_spec`, `table_image_spec`)이 `images` 기본값 상태에서 통과 — `image.enabled` 분기가 사라졌는지 확인
  - 확인: `M.enabled`/`image.enabled` 분기 제거 후 전체 스펙 통과(66개 파일, 통과 681 / 실패 0 / 오류 0)
- 완료 조건: `grep -rn "image.enabled\|images = false\|M.enabled" lua init.lua` 결과 없음. mdloom 연결 상태에서 Markdown 이미지가 한 번만 그려진다(mdloom 플러그인의 그리기는 mdloom 작업 L1에서 이미 제거됨). (mdloom 작업이 먼저 끝나므로 mdloom 쪽 이미지 표시는 이미 없다.)

### R2 — 이미지 스캔 범위 (Q1: (c)로 확대 결정됨)

- [x] 사용 현황 조사: 사용자의 노트 폴더에서 위키 이미지·HTML `<img>`·참조형 이미지 사용 빈도를 `rg`로 센다
  - 노트 폴더는 `~/notes`(git 저장소, 커밋 427개)로 확인. `pickers.lua`의 `M.Notes()`가 `cwd = '~/notes/'`로 쓰는 실제 경로이며 `vim.g`에 별도 노트 경로 설정은 없다. 보조로 `~/workspace/keep`(Keep 내보내기 노트)과 `~/workspace/markdown_lsp`(mdloom 문서·테스트)도 센다. `~/workspace` 전체는 llvm-project 등 대용량 저장소가 있어 `rg`가 끝나지 않아 개별 폴더(깊이 6, `target`·`node_modules`·`.git` 제외)로 한정했다
  - 주의: 코드 스팬·펜스 안의 문법 예시도 한 번 센 원시 수치다(코드 안 제외 필터 없음). 수치는 2026-10-30 기준
- [x] 조사 결과로 지원 우선순위를 정한다(전부 구현하되 빈도가 높은 문법부터): 아래 "구현 순서" 참고
- [x] 현재 `scan.lua`·`size.lua` 지원 범위 정리: 아래 "현재 지원 범위" 참고
- [x] 구현 상세는 R6의 "스캔 확대"에서 한다. 이 단계는 조사와 우선순위 기록이다 (코드 변경 없음)
- 완료 조건: 조사 수치와 구현 순서가 이 문서에 기록됨.

#### 조사 수치

`~/notes` (전체 파일 251개, 디렉터리 26개, `*.md` 207개; 이미지 파일 3개 = png 2 + svg 1; `rg ... --glob='*.md'` 원시 수치):

| 문법 | 패턴 | 파일 수 | 사용 수 |
| --- | --- | --- | --- |
| 표준 `![alt](path)` | `!\[[^]]*\]\([^)]*\)` | 4 | 4 (확장자: png 3, svg 1; http(s) 0) |
| 위키 `![[...]]` 전체 | `!\[\[[^]]*\]\]` | 0 | 0 (이름형 0 / 경로형 0 / `\|width` 0 / `#anchor` 0) |
| HTML `<img` | `<img\b` | 0 | 0 (`src` 0, `width`/`height` 0) |
| 참조형 `![a][r]`·`![r][]`·`![r]` 사용 | `!\[[^]]*\]\[[^]]*\]` | 0 | 0 |
| 참조 정의줄(이미지 확장자) | `^\[[^]]+\]: .*\.(png\|jpe?g\|gif\|webp\|svg)` | 0 | 0 (이미지가 아닌 정의줄은 1개: `study/vim/Vim.md`의 URL 링크) |

표준 이미지 4개의 내역: 상대 경로 3개(`functor_performance.png`, `Git_Data_Transport_Commands.png`, `tools_overview.svg`, 모두 문서와 같은 폴더에 존재), 절대 경로 예시 1개(`study/Markdown.md`의 `![image](/image.png)`, 파일 없음 = `not_found` 박스가 됨). svg가 1개 있다: rendermark의 `size.lua`는 PNG/JPEG/WebP만 읽으므로(아래 참고) 이 이미지는 `unsupported` 오류 박스가 된다.

보조 범위 (이미지 사용 수는 `*.md` 원시 수치):

| 범위 | md 파일 | 표준 | 위키 | `<img` | 참조형 | 이미지 파일 |
| --- | --- | --- | --- | --- | --- | --- |
| `~/notes` | 207 | 4 | 0 | 0 | 0 | 3 (png 2, svg 1) |
| `~/workspace/keep` | 449 | 27 (모두 `../assets/…` 상대 경로, 확장자 png 13 / jpg 13) | 0 | 0 | 0 | 29 (png 16, jpg 13) |
| `~/workspace/markdown_lsp` | 41 | 35 | 22 | 14 | 7 | 1 |
| `~/workspace/nvim_config` | 14 | 7 | 12 | 11 | 5 | 0 |
| `~/workspace/img_manager` | 27 | 0 | 0 | 11 | 0 | - |

`markdown_lsp`·`nvim_config`·`img_manager`의 위키/`<img`/참조형 수치는 문법을 설명하는 문서, 테스트 픽스처, 이슈 본문의 예시 텍스트이지 노트 사용이 아니다(예: `markdown_lsp/fixtures/{contracts,facts,parser}`, `doc/issues/closed/issue-ref_image_conceal.md`, `issue-image_tilde_path.md`). `image`, `ImageViewer`, `imgtagger`, `myvim`, `reading_manager`는 이미지 문법 사용 0, `neovim_md`·`mindmap`·`bookmarks`는 md 0개.

결론: 사용자의 실제 노트(`~/notes`, `keep`)에는 표준 `![alt](path)`만 있고 위키·HTML·참조형 이미지는 한 번도 쓰이지 않는다. 확대(Q1 (c))는 기존 mdloom 기능 동등성을 위한 것이며 현재 데이터로는 회귀 위험이 없다.

#### 위키 이름형 검색의 규모 위험

| 폴더 | 파일 수 | 디렉터리 수 | 이미지 파일 | 동명 이미지(basename 중복) |
| --- | --- | --- | --- | --- |
| `~/notes` | 251 | 26 | 3 | 0 |
| `~/workspace/keep` | 1075 | 291 | 29 | 0 |
| `~/workspace/markdown_lsp` | 167 | 42 | 1 | 0 |

노트 폴더는 `.git`·`node_modules`·`target`을 제외해도 파일이 251~1075개, 이미지 3~29개, 동명 이미지 0건이다. `~/notes`에서 이름으로 전체 탐색(`find -name`)은 5 ms 미만이다. 즉 노트 폴더 단위의 이름 검색은 규모 위험이 낮고 모호(동명) 사례도 현재 없다. 위험은 노트 폴더가 아닌 곳(`~/workspace` 같은 상위 폴더나 llvm-project 같은 대형 저장소)을 "워크스페이스 루트"로 잡을 때만 생긴다: 이번 조사에서도 `~/workspace` 전체에 대한 `rg`는 시간 안에 끝나지 않았다. 따라서 이름 검색의 상한(탐색 파일 수 또는 깊이)과 루트 결정(`prjroot` 또는 `.git` 상위 중 노트 쪽)은 R6에서 필수로 정한다.

#### 현재 지원 범위 (`image/scan.lua`, `image/size.lua`, 읽기만 하고 변경 없음)

- 지원 문법: 표준 `![alt](path)`만. 패턴은 `!%[[^%]]*%]%(([^%)%s]+)%)`, 즉 경로에 공백·`)`가 있을 수 없고 `"title"`이 붙은 형태와 `<…>` 감싸기는 인식하지 못한다. 한 줄 여러 개 지원(순서대로 `col0`는 표시 폭 기준, 항목에 `byte_col`/`byte_end_col`)
- 표 행: `table_state.table_row`/`table_source_rows`로 표 셀의 이미지를 별도 수집(wrap이 그린 행의 항목을 복사), 그리지 않은 표 행은 일반 스캔에서 건너뜀. 표 셀 텍스트는 `wrap/table.lua`가 `scan_markdown_image_text`를 호출
- 가상 텍스트: 다른 네임스페이스의 extmark `virt_text`/`virt_lines`에 있는 이미지 문법도 스캔(`virtual = true` 항목; 이미지 자신의 `image_ns`는 제외). plantuml 블록 높이를 `source_span_height`로 반영
- 제외 규칙: 인라인 코드 스팬(`code_spans`, 같은 길이의 백틱 짝)만 제외. **펜스 코드블록(` ``` `) 안의 이미지 문법은 제외하지 않는다**: `scan.lua`·`place.lua`에 펜스 판정이 없다(펜스 판정은 `blocks.lua`의 plantuml 용뿐). R6 체크리스트의 "펜스 코드블록 안은 제외(기존 규칙 유지)"는 사실과 달라서, 펜스 제외는 "유지"가 아니라 신규 구현이 된다
- 버퍼 조건: filetype `markdown` 또는 확장자 `md`/`markdown`일 때만
- 경로 해석 `resolve_image_path(buf, raw)`: 빈 문자열이나 `scheme://`는 무시(nil), `%20`을 공백으로, `vim.fn.expand`(`~` 확장), 절대 경로 판정(`is_absolute_path`, Windows 드라이브·`\`·`/` 시작 처리) 후 아니면 문서 폴더 기준(이름 없는 버퍼는 cwd), `:p`로 정규화. 쿼리(`?`)·앵커(`#`) 제거, `<…>` 벗기기, 다른 `%xx` 디코딩은 하지 않는다
- 항목 오류: 파일이 없으면 `error = 'not_found'`, 크기를 못 읽으면 `error = 'unsupported'`. `source_span_height`는 최소 1
- 이미지 크기(`size.lua`): 파일 앞 512 KiB만 읽어 PNG(IHDR), JPEG(SOF 마커), WebP(VP8X/VP8/VP8L) 헤더 파싱. GIF·SVG·BMP 등은 `nil`이라 `unsupported`가 된다(GIF는 mdloom 목록의 "PNG/JPEG/GIF/WebP"와 달리 현재 미지원). mtime·크기 기준 캐시. 따라서 `~/notes`의 svg 1개와 위키·HTML 이미지가 gif/svg일 경우 박스로 표시된다
- 프리필터: `line_has_image_link`가 `text:find('![', 1, true)` 후에야 패턴을 적용

#### 구현 순서 (R6 "스캔 확대"에 적용)

실사용 빈도는 위키·HTML·참조형 모두 0이므로 빈도가 아니라 mdloom 동등성, 기존 코드 재사용도, 위험도 순으로 정한다. 데이터가 생기면 순서를 재검토한다.

1. 공통 기반(표준 문법에도 이득): `resolve_image_path`에 쿼리·앵커 제거와 `<…>` 벗기기 추가, 펜스 코드블록 제외 구현, 라인 프리필터 확장(`![`, `<img`, `[…]:`), GIF 등 지원 형식 결정(svg는 의도적 미지원 후보)
2. 참조형 `![alt][ref]`·`![ref][]`·`![ref]`: mdloom에서 전용 커밋(be74a94)과 이슈(`issue-ref_image_conceal`)가 있어 사용 이력이 가장 확실하고, 같은 문서 내 정의 줄 해석만 필요해 비용·위험이 작다. ~~정의 줄 conceal 포함~~ (정의 줄은 conceal 하지 않음, Q1 사양 변경 2026-10-30)
3. HTML `<img src>`: 한 줄 속성 파싱으로 끝나고 `width`/`height` 반영 여부만 정하면 된다
4. 위키 경로형 `![[dir/name.png]]`·`![[name.png|300]]`·`![[name.png#…]]`: 문서 폴더 기준 해석이라 `resolve_image_path` 재사용, 폭 옵션 파싱만 추가
5. 위키 이름형 `![[name.png]]`: 파일 시스템 검색, 캐시, 모호성 처리가 필요해 가장 복잡하고 가장 위험하므로 마지막. 위 수치상 노트 폴더 규모에서는 문제가 없지만 루트 결정과 상한을 먼저 확정한다

R3 후속 메모 (R2 기록 정정): R2의 "펜스 판정은 `blocks.lua`의 plantuml 용뿐"이던 코드는 R3에서 `blocks.lua`와 함께 삭제됐다. 이제 `image/` 안에는 펜스 판정이 전혀 없으므로 위 1번의 "펜스 코드블록 제외"는 재사용 없이 `scan.lua`에 새로 구현해야 한다(공급자 항목의 `start_row/end_row`는 다이어그램 블록만 알려주므로 일반 코드블록 판정에는 쓸 수 없다). `scan.lua`의 `source_span_height`는 R3부터 `deps.diagram_block_span`(공급자 항목)으로 얻는다.

### R3 — 공급자 API와 다이어그램 항목 처리 (image/init.lua, place.lua, diagram.lua)

구현:
- [x] `image/init.lua`: `set_diagram_source(source)`, `refresh(buf)`, `clear_diagram_source()` 추가. `refresh`는 해당 버퍼의 캐시(`block_cache`)를 무효화하고 `M.send_images()`를 예약
  - 완료(2026-10-30): `set_diagram_source(source)`는 `items`(필수)·`request_live`(선택) 타입을 `vim.validate`로 검사하고 저장한 뒤 전체 `refresh()`, `clear_diagram_source()`도 같다. `refresh(buf)`는 버퍼(생략하면 전체)의 항목 캐시를 지우고 `schedule_image_sync()`(기존 WinScrolled 등과 같은 합쳐지는 예약 경로)로 `send_images`를 예약한다. 로드되지 않았거나 잘못된 버퍼여도 오류 없음
- [x] `image/plantuml.lua` → `image/diagram.lua` 개명(`git mv`) 후 정리:
  - [x] 제거: `plantuml_resolve_command`, `plantuml_jar`, `plantuml_run`, 임시 디렉터리·잡 관리·`plantuml_ensure_render`·`plantuml_sanitize_error`, 환경변수 `RENDERMARK_PLANTUML_JAR`/`PLANTUML_JAR`/`vim.g.rendermark_plantuml_jar`, "PlantUML disabled" 알림
  - [x] 유지·재작성: `collect_plantuml_images(buf, result, errors)` → `collect_diagram_images(buf, result, errors)`:
    - 공급자 `items(buf)`를 호출. 항목마다 활성 블록 여부 판정(`plantuml_active_block`와 동일 로직)
    - 비활성 + `status == 'ready'`(또는 stale이지만 path 존재) → 기존과 같은 이미지 항목을 `result`에 추가(`row`, `col`, `end_col`, `path`, `source_width/height`는 `read_image_size`, `source_span_height = end_row - start_row + 1`, `plantuml = true`→`diagram = true`, `plantuml_end_row`→`diagram_end_row`, `virtual = false`)
    - 비활성 + `status == 'failed'` → `errors`에 `{buf, row = end_row, msg = error}`
    - 비활성 + `none`/`pending` → 아무것도 그리지 않음(소스 그대로)
    - 활성 블록: 미리보기 흐름은 기존 `plantuml_debounce_active` 구조를 유지하되 렌더 호출만 `source.request_live(buf, row)`(400ms 디바운스)로 바꾼다. 항목이 `ready`면 `plantuml_open_split/float`(→ `diagram_open_split/float`)로 표시
    - `conceallevel < 2`이면 창 옵션을 올리는 기존 동작 유지
  - [x] 버퍼 정리(`plantuml_cleanup_buf`)에서 임시 폴더·잡 정리를 제거하고 타이머·float 정리만 남긴다
  - [x] 상태 이름 `plantuml_states` → `diagram_states`, 창 변수 `rendermark_plantuml_preview_*` → `rendermark_diagram_preview_*` (preview.lua 281~304행, place.lua 15행의 `rendermark_plantuml_preview_source` 포함)
    - 완료. 설계 선택: (1) 활성 블록 판정은 `diagram.lua`의 `diagram_active_block`에 그대로 두고(`plantuml_active_block`과 같은 로직, 포커스가 미리보기 창이면 그 블록 유지, 읽기 모드면 없음) 공급자 항목 목록을 입력으로 받는다. (2) 활성 블록에서 `ready`는 `stale`이어도 미리보기를 연다(코드를 고치는 동안 미리보기가 닫혔다 열리는 깜박임이 없다). `status == 'none'` 또는 `ready`+`stale`이면 `request_live`를 400ms 디바운스로 요청하고(편집마다 타이머를 다시 건다), 같은 `changedtick`·블록은 요청이 수락된 뒤 다시 요청하지 않는다(공급자 반환이 false면 다음에 다시 시도). `pending`은 공급자가 이미 렌더 중이라 요청하지 않고 `failed`는 같은 텍스트로 재시도하지 않는다. (3) 비활성 블록은 `status == 'ready'` 또는 `pending`+`stale`(+path)일 때 이미지를 그린다(`failed`는 path가 있어도 오류 줄만). 크기를 못 읽는 형식(SVG)은 소스를 그대로 둔다. (4) 항목 형식 점검: `coderunner.provider.diagrams`의 필드(`start_row/end_row/key/lang/path/format/stale/status/error`)와 `request_live(buf, row) -> boolean`을 코드로 확인했고 rendermark는 coderunner를 require하지 않는다(D3). `key`는 블록 식별자(렌더 키 아님)라 디바운스 중복 판정에는 `changedtick`+`start_row`를 쓴다
- [x] `image/blocks.lua`: `plantuml_find_blocks`/`markdown_plantuml_block_height`를 사용하는 곳을 공급자 항목으로 교체
  - `preview.lua` 107행(`block_h`), 152~153행(코드블록 회피), `scan.lua`의 `deps.markdown_plantuml_block_height`(init.lua 60행) → 공급자 항목의 `end_row - start_row + 1`을 조회하는 함수 `diagram_block_span(buf, row)`로 교체
  - `blocks.lua` 삭제. `block_cache`는 공급자 항목 캐시로 개명(편집 틱 기준 무효화는 `refresh`로 대체)
  - 완료: `blocks.lua` 삭제, `scan.lua`의 dep 이름은 `diagram_block_span`, `preview.lua` 107행·코드블록 회피는 `diagram_block_span`/`diagram_items`, `cursor_active_block_sig`도 `diagram_items` 사용. `stable_hash`는 `blocks.lua`에 같이 있던 함수라 `image/hash.lua`로 옮김(`place.lua`·`preview.lua` 사용). 캐시 `block_cache` → `item_cache`: 문서는 "편집 틱 기준 무효화는 `refresh`로 대체"라고 했지만 위험 6절(편집 직후 항목이 이전 위치)을 막기 위해 **`changedtick` 키와 `refresh`를 둘 다 유지**했다. 편집 뒤 첫 조회는 항상 공급자를 다시 호출하므로 잘못된 행에 그릴 일이 없고, 틱이 같을 때(커서·스크롤·변경 없는 `send_images`)는 공급자를 부르지 않는다. 비용: 편집당 공급자 호출 1회. `refresh`는 틱이 같은 상태에서 상태(pending→ready)가 바뀐 경우를 위해 필요
- [x] `place.lua`:
  - [x] 73~81행: `CollectImages`가 `collect_markdown_images`와 `collect_diagram_images`를 병합하도록 이름 변경(`plantuml_errors` → `diagram_errors`)
  - [x] 231행 `img.plantuml` → `img.diagram`, 360~363행 `plantuml_end_row` → `diagram_end_row`
  - [x] 604~607행 오류 virt_lines `[plantuml: ...]` → `[diagram: ...]`
  - [x] 640행 `ctx.plantuml_errors` 이름 변경
  - `CollectImages`는 이미 두 수집을 병합하고 있어 이름(`collect_diagram_images`, `diagram_errors`)만 바꿨다. 오류 줄은 `[diagram: <msg>]`
- [x] `deco.lua` 31행: 코드블록 장식 비활성 언어 목록(`plantuml`, `puml`, `uml`)을 하드코딩에서 **공급자가 아는 언어**로 바꿀지 결정. 기본: 장식은 활성 블록이 아닌 이미지 대체 블록에서 conceal로 가려지므로 그대로 두되 목록을 설정화(`opts.diagram.disable_deco_langs`, 기본 `{plantuml, puml, uml}` + glue가 렌더러 `match`로 확장)
  - 완료: `deco.lua` 기본값에 `diagram.disable_deco_langs = { plantuml, puml, uml }`를 두고 `code.disable`은 제거했다(참조는 `deco.lua` 한 곳뿐이었음). 사용자 목록은 기본 목록을 대체한다(`tbl_deep_extend`가 리스트를 통째로 바꿈) — 렌더러 언어와의 합치기는 R4 glue 몫. 스펙: `deco_spec`에 설정 반영 케이스 추가
- [x] 설정 키(Q4): `opts.diagram.preview`를 읽고 `opts.plantuml.preview`는 별칭으로 한 번 경고 후 수용(`vim.notify_once`)
  - 완료: `diagram.preview`가 우선, `plantuml.preview`가 있으면 `vim.notify_once` 경고 후 값이 없을 때 대신 사용. 주의: `init.lua`의 사용자 설정은 R4에서 바꾸므로(지시) 그때까지 시작할 때 경고가 한 번 뜬다
- [x] 스펙 추가 `tests/spec/rendermark/image/diagram_spec.lua` (가짜 공급자 사용):
  - 항목 `ready` → 이미지 항목이 `result`에 들어가고 `source_span_height`가 블록 높이와 같다
  - 항목 `failed` → 오류 virt_line, `none` → 아무것도 없음, `pending` → 없음
  - 활성 블록(커서가 블록 안) → 해당 항목은 `result`에서 빠지고 미리보기만 열림. `request_live`가 400ms 디바운스로 한 번만 호출
  - 공급자 없음 → 다이어그램 항목 없음, Markdown 이미지는 정상
  - `refresh(buf)` → 다음 `send_images`에서 새 항목 반영, 변경 없는 버퍼는 `vim.ui.img.set` 재호출 없음
  - 블록 위치가 편집으로 이동 → 공급자가 바뀐 위치를 돌려주면 새 위치로 그림
  - 공급자가 예외를 던져도 렌더링이 중단되지 않음(`pcall`)
  - 완료: `tests/spec/rendermark/image/diagram_spec.lua` 19개(위 7개 시나리오 + stale/SVG/유효하지 않은 항목/`request_live` 예외/preview 숨김/타 버퍼 캐시/잘못된 버퍼 refresh/설정 별칭). 가짜 공급자는 `tests/spec/rendermark/image/helpers.lua`(`fence_source`). 테스트 사이에 이전 인스턴스의 예약된 동기화가 다음 테스트의 창에 미리보기를 여는 오염이 있어 `after_each`에서 이벤트 루프를 한 번 비운다
- [x] 기존 스펙 갱신: plantuml 실행에 의존하던 스펙(`image/init_spec`의 plantuml 관련)은 가짜 공급자로 재작성, 삭제된 기능(`plantuml_resolve_command` 등)의 스펙 삭제
  - 실행·`plantuml_resolve_command` 등에 의존한 스펙은 애초에 없었다(`init_spec`은 `collect_plantuml_images`를 스텁하거나 블록 스캔 함수를 직접 호출). 변경: `cursor_active_block_sig`(3)와 `compute_preview_placement`(3)는 가짜 공급자를 등록하고 `diagram_block_span`을 스텁하도록 재작성, e2e 스텁은 `collect_diagram_images`/`diagram` 필드로 개명, 설정 스펙은 `diagram.preview`로 변경. **삭제한 스펙**(`init_spec`의 `PlantUML scan cache`, 3개 중 2개): `shares one full read across block and height queries until editing or cleanup`(공급자 호출 횟수를 세는 `asks the provider once per changedtick and once per refresh`로 대체), `keeps unfinished fence heights without rendering unfinished blocks`(펜스 스캔이 공급자 몫이 되어 삭제; 닫히지 않은 펜스 처리는 coderunner `blocks_spec`가 맡음). 나머지 1개(`does not query block heights for decoration text...`)는 `diagram_block_span` 기준으로 이름만 바꿔 유지. 신규: `gives no block span outside the provider items`
- [x] 성능: `benchmark_image_reapply.lua`가 기준선(R0)과 같은 호출 수를 유지하는지, `docs/image_scan_performance.md`의 시나리오를 공급자 기반으로 다시 측정
  - 벤치(`benchmark_image_reapply.lua`, 스텁 이름 `collect_diagram_images`로 수정, 5회): 변경 없음 중앙값 671.3 ms(667.2~680.1), 너비 변경 680.1 ms(675.4~685.1). R0(680.0 / 690.8 ms) 대비 회귀 없음. 호출 수는 R0와 동일(변경 없음 set/mark/clear/redraw/del 0, 너비 변경 set 1000/mark 2000/clear 1000/redraw 1000/del 0)
  - `docs/image_scan_performance.md`에 "After R3" 절을 추가해 공급자 기반으로 다시 측정(`benchmark_image_scan.lua`는 `BENCH_PROVIDER=1`로 가짜 공급자 등록, 공급자 호출 수 보고): 변경 없는 `send_images`·커서 서명 때 공급자 호출 0, 편집당 1회, 전체 버퍼 읽기 0
- 완료 조건(충족, 2026-10-30): 위 스펙 통과, 벤치 호출 수 회귀 없음, `grep -rn "plantuml_run\|plantuml_resolve\|plantuml_find_blocks\|PLANTUML_JAR" lua` 결과 없음.

### R4 — glue (nvim_config/markdown.lua)와 사용자 설정

- [x] `lua/nvim_config/markdown.lua` 신규: 4.2절의 연결. coderunner가 없으면(`pcall(require, ...)` 실패) 공급자를 등록하지 않는다
  - 완료(2026-10-30): `setup()`은 augroup `nvim_config_markdown`을 `clear`로 만든 뒤(중복 호출 안전) coderunner를 `pcall(require)`하고, 있으면 `image.set_diagram_source{ items = runner.diagrams, request_live = runner.request_live }`와 `User CodeRunnerDiagrams` → `image.refresh(args.data.buf)`를 등록한다. 이벤트 `data.buf`가 숫자가 아니면 무시하고, 로드되지 않았거나 없는 버퍼는 `image.refresh`가 이미 안전하다(스펙으로 확인). 실제 이름은 의사코드와 같다: `coderunner.diagrams(buf)`, `coderunner.request_live(buf, row)`(`init.lua`가 `provider.lua`로 위임), 이벤트 `CodeRunnerDiagrams`의 `data = { buf = buf }`(`render.lua` `event`)
- [x] 렌더러 `match` 언어와 rendermark의 `disable_deco_langs` 동기화
  - 완료(2026-10-30): 문서가 가정한 `runner.renderer_langs()`는 coderunner에 **없다**. 대신 공개 API `coderunner.resolve(workspace, false)`(전역 + 이미 로드된 워크스페이스 설정을 병합, 신뢰 프롬프트 없음)의 `renderers[*].match`를 읽는다. glue는 `M.deco_langs()`(기본 `plantuml, puml, uml` + 렌더러 `match`를 소문자·중복 제거·정렬해 합침)를 제공하고 `init.lua`가 `rendermark.setup{ diagram = { disable_deco_langs = ... } }`에 넘긴다. 시점: `deco.setup`이 목록을 한 번만 읽고(`tbl_deep_extend`가 리스트를 통째로 대체) glue의 `setup()`은 rendermark 설정 뒤에 오므로, 목록은 `rendermark.setup` **인자를 만들 때**(coderunner 설정 뒤, rendermark 설정 앞) 계산한다. 한계: 이후에 로드되는 워크스페이스 렌더러의 언어는 따라가지 않는다(이미지가 대체하는 블록의 코드 배경 장식만 남는 외관 문제). rendermark의 기본 목록이 glue에 한 벌 더 있다(`default_deco_langs`)
- [x] `init.lua`에 `require'nvim_config.markdown'.setup()` 추가 (rendermark, coderunner 설정 이후 순서)
- [x] `init.lua`의 `rendermark.setup{ plantuml = { preview = ... } }`를 `diagram = { preview = ... }`로 변경 (Q4)
  - 완료: 헤드리스 기동에서 별칭 경고가 사라졌고 출력이 없다
- [x] coderunner `renderers.plantuml` 설정을 사용자 `init.lua`에 추가하고 `render_on_open = true`(coderunner_plan Q8)로 기존 "열면 보이는 plantuml 블록이 자동 렌더되는" 경험을 유지
  - `renderers.plantuml`(`match = { plantuml, puml }`, `formats = { png, svg }`, stdin/stdout)과 `render_on_open = true`는 coderunner 작업에서 이미 `init.lua`에 있었다. R4에서 `cmd`만 `plantuml_cmd()`로 바꿨다: 이전 rendermark와 같은 규칙으로 `vim.g.rendermark_plantuml_jar` → `RENDERMARK_PLANTUML_JAR` → `PLANTUML_JAR`의 jar가 읽히고 `java`가 PATH에 있으면 `java -jar <jar> -t{format} -pipe`, 아니면 PATH의 `plantuml` 래퍼(`plantuml -t{format} -pipe`). 값은 시작할 때 한 번 정해진다(이전 rendermark는 실행마다 조회). 이 개발 환경에서는 `/usr/bin/plantuml` 래퍼가 없는 `/usr/bin/java`(깨진 링크)를 쓰므로 `PATH=~/.local/jdk-21/bin:$PATH PLANTUML_JAR=/usr/share/java/plantuml/plantuml.jar`가 있어야 동작한다
  - **coderunner 결함 수정(별도 커밋)**: 실제 plantuml로 확인하다가 `output = 'stdout'` 렌더러의 stdout이 UTF-8 정리(`clean_utf8`)를 거쳐 PNG가 깨지는 것(1499 → 1795 바이트)을 발견했다(SVG만 우연히 멀쩡). `formats[1]`이 png인 위 설정과 rendermark(PNG/JPEG/WebP만 크기 읽기)에는 치명적이라 렌더러 stdout은 원시 바이트로 두도록 `exec.run_step`/`command.run`을 고쳤다(`raw_stdout`; 러너 stdout·stderr는 그대로 정리). 스펙: `command_spec`에 1개
- [x] 스펙 `tests/spec/markdown_glue_spec.lua`: 가짜 coderunner 모듈로 (a) 이벤트 `CodeRunnerDiagrams` → `image.refresh` 호출 (b) coderunner 부재 시 오류 없음 (c) 이벤트의 `buf`가 로드되지 않은 버퍼여도 오류 없음
  - 완료: 9개(가짜 모듈 주입 7 — 등록·전달, 이벤트 → refresh, 부재, 잘못된 버퍼(실제 `image.refresh`), 숫자 아닌 buf, 중복 `setup`, `deco_langs` 2 — + 실제 coderunner·rendermark 통합 1: 가짜 렌더러(원시 PNG를 echo)로 `request_live` → 렌더 완료 이벤트 → glue의 `refresh`가 항목 캐시를 비워 `collect_diagram_images`가 `ready` 이미지 항목을 돌려줌)
- [ ] neopp GUI(또는 `RENDERMARK_IMG_STUB=1`)에서 plantuml 블록이 이미지로 대체되고 저장 시 갱신되는지 통합 확인 (헤드리스 불가, R8 수동 항목)
- 완료 조건: 스펙 통과. 실제 coderunner가 있으면 plantuml 블록이 렌더된 이미지로 표시되고 저장 시 갱신된다 (coderunner 작업 C8 이후 통합 확인).
  - 확인한 것(2026-10-30): 스펙 통과, 실제 `init.lua`로 헤드리스 기동이 출력 없이 끝남, 같은 `init.lua`에서 실제 plantuml로 `request_live` → 유효한 PNG(1499 바이트) `ready`. 확인하지 못한 것(`[ ]`로 R8에 남김): neopp GUI/`RENDERMARK_IMG_STUB`에서 블록이 이미지로 대체되는 모습, 저장 시 갱신(`auto_render`)과 화면 반영, 활성 블록 미리보기 split, 그리기 쪽 이벤트 연쇄의 실사용 지연

### R5 — 인접 내보낸 이미지 정책 (Q3)

- [x] 규칙: 다이어그램 블록의 `end_row` 아래로 **빈 줄 0~1개** 뒤에 오는 문단이 이미지 링크를 가지면(표준 `![]()`. R6-B부터 HTML `<img src>`와 위키 `![[x.png]]`·참조형도 같은 `find_image_links`로 세므로 포함. 위키의 이름형은 검색 중에도 로컬 링크로 센다) 그 블록의 다이어그램 항목은 그리지 않는다(소스 그대로 표시, 이미지 링크는 평소처럼 그려짐)
  - 완료(2026-10-30): "문단" = 빈 줄(공백뿐인 줄)을 만나면 끝, 코드 펜스 줄(` ``` `/`~~~`)을 만나도 끝(첫 줄이 펜스면 문단 없음). 근거: 펜스 안의 링크는 글자 그대로의 코드이고, 블록 바로 뒤에 다른 다이어그램 블록이 붙어 있을 때 그 안쪽을 보면 안 됨. 링크는 줄 단위로 `find_image_links`(인라인 코드 스팬 안은 제외)로 찾고, `resolve_image_path`가 nil인 원격(`scheme://`) 링크는 세지 않는다(rendermark가 그리지 않으므로 블록 이미지 대신이 될 수 없음). 파일이 없는 로컬 링크는 센다(링크 쪽에 `not_found` 박스가 보임). 줄 단위 판정은 실제로 그려지는 스캔(`collect_markdown_images`)과 같은 단위다. 읽는 범위는 빈 줄 1 + 문단 30줄 상한. 실패(`failed`) 블록의 `[diagram: ...]` 오류 줄은 내보낸 이미지가 있어도 그대로 표시(정보이지 중복이 아님)
- [x] 판정은 `diagram.lua`가 `scan.lua`의 `find_image_links`를 이용해 블록 다음 행들만 검사한다. 편집 비용을 줄이기 위해 해당 행만 읽는다
  - 완료: `diagram_exported_below(buf, item)`가 `nvim_buf_get_lines(end_row+1, end_row+32)` 한 번만 읽는다(스펙이 읽기 범위를 단언). 판정은 `item_cache[buf].exported[end_row]`에 그 `changedtick`의 항목과 함께 저장돼 편집·`refresh` 때 항목과 같이 버려진다 — 링크 줄·빈 줄·블록 편집 직후 첫 조회가 새 판정을 반영. `find_image_links`는 `scan.lua`에서 `M.find_image_links`로 노출. 활성 블록은 판정 경로를 타지 않아 미리보기가 그대로 열리고, 숨긴 블록은 결과 항목이 없으므로 예약·conceal(`source_span_height`)도 생기지 않는다(링크 이미지 예약만 남음). 단 `diagram_block_span`/`cursor_active_block_sig`는 그대로 블록을 알고 있어 미리보기 배치(블록 회피)가 소스 높이를 쓴다 — 소스가 그대로 보이므로 맞는 동작
- [x] 옵션 `diagram.hide_when_exported`(기본 true)로 끌 수 있게 한다
  - 완료: `image.setup(opts)`가 `opts.diagram.hide_when_exported == false`일 때만 끈다(`diagram.preview`와 같은 `opts.diagram` 아래). `init.lua`의 사용자 설정은 기본값을 쓰므로 변경 없음
- [x] 스펙: 인접 링크 있음(빈 줄 0·1) → 블록 이미지 없음, 빈 줄 2 → 블록 이미지 있음, 인접 문단에 이미지가 없음 → 블록 이미지 있음, 옵션 off → 항상 블록 이미지
  - 완료: `tests/spec/rendermark/image/diagram_spec.lua`에 15개 추가(빈 줄 0·1, 2·3, 이미지 없는 문단, 문단 전체·문단 끝, 코드 스팬·원격·펜스, 문단 중간 링크, 옵션 off/기본값, 편집으로 링크 추가·삭제·간격 변화, `refresh`, 버퍼 끝, 읽기 범위 단언(전체 읽기 0, 같은 틱 재조회 시 읽기 0), `send_images`로 링크 이미지만 set되고 블록 행에 extmark 없음/옵션 off면 둘 다, 링크 추가·삭제 전이, 활성 블록 미리보기 유지, 실패 오류 줄 유지)
- 완료 조건: 스펙 통과, 중복 표시 없음(수동).
  - 확인(2026-10-30): 스펙 통과. 중복 없음은 `send_images` 결과(링크 이미지만 `vim.ui.img.set`, 블록 행 예약·conceal 없음)로 헤드리스 확인했고 GUI/스텁 화면 확인은 R8 수동 항목(`[ ]` 유지)

### R6 — mdloom 표시 기능 대비 동등성 점검과 선택 확장

mdloom 플러그인이 제공하던 표시 기능과 rendermark의 현재 지원을 대조한다. "없음"이면 이 단계에서 구현하거나 의도적으로 포기한다고 기록한다.

판정(R6-A, 2026-10-30): 각 행은 "동등" / "보완 완료" / "의도적 미지원(사유)" / "서브 이슈(사유)" 중 하나다. 위키·HTML 행은 R6-B(2026-10-30)에서 닫았다.

| 기능 | mdloom 플러그인 | rendermark 현재 | 판정 |
| --- | --- | --- | --- |
| 이미지 자리 예약(virtual lines)과 소스 불변 | 예 | `place.lua` `remember_image_reservation`. 그리기는 extmark뿐이라 버퍼 내용·modified 불변 | **동등** |
| 이미지가 그려지는 동안 소스 숨김, 커서가 올라오면 노출 (f660eb8) | 커서 행의 conceal extmark를 빼서 노출 | 소스 범위에 `conceal=''` extmark(우선순위 250), 다이어그램은 `conceal_lines`+`conceal`. 커서 행 노출은 nvim의 `concealcursor`(기본 빈 값)가 맡고, 스텁은 커서 행에 박스를 안 그림(`cursor_rows_for`). 읽기 모드는 `concealcursor='nvic'`라 항상 숨김. 스펙 추가: `scan_spec`(conceal 범위, `concealcursor` 빈 값) | **동등** (구현 방식이 다름: 플러그인이 extmark를 빼는 대신 nvim 옵션에 위임) |
| 한 줄 여러 이미지 나란히 (f8fca98) | 나란히, 폭 초과 시 다음 band로 줄바꿈 | 나란히 배치는 같음(`layout_image_line`, 스펙 이식: 4개 한 줄 → `dest_x_px` 증가·`dest_y_px` 동일). 폭을 넘으면 **줄바꿈 대신 한 band 안에서 모두 축소**(기존 `layout_image_line fit` 스펙이 이 동작을 고정) | 나란히: **동등** / 폭 초과: **의도적 유지**(서브 이슈 S1 닫힘, 사용자 결정 2026-10-30: "기존 rendermark 방식으로" = 한 band 안에서 모두 축소) |
| 참조형 이미지 `![a][r]`·`![r][]`·`![r]` 사용 위치마다 표시 (be74a94) | 예 | **구현 완료**(R6-A): `docindex.lua`(정의 수집, 변경 틱 캐시) + `scan.lua`. 사용 위치마다 표시, 대소문자·공백 무시, 첫 정의 우선, 정의 없으면 표시 안 함, 단축형 `![r]`은 정의가 있을 때만, 펜스 안 정의 무시 | **보완 완료** |
| 참조형의 정의 줄 conceal | 플러그인은 안 함 | be74a94의 결론: `[ref]` 라벨 conceal은 nvim 번들 `markdown_inline` 쿼리 몫이고 플러그인이 conceal을 덧씌우면 사용자 treesitter 설정과 충돌. 정의 줄은 그대로 둔다(텍스트 conceal은 빈 행을 남기고 `conceal_lines`는 행 배치를 바꿔 공간 예약 계약을 건드림). 사용 위치 `![a][r]` 전체는 일반 이미지처럼 conceal | **conceal 하지 않음** (사양 정정, 사용자 결정 2026-10-30; be74a94 결론 + 공간 예약 계약). 코드 변경 없음 |
| 위키 이미지 `![[x.png]]` | 예(서버가 `documentLink`로 해석, 이름형은 mdloom 인덱스) | **구현 완료**(R6-B): `![[name.png]]`·`![[dir/name.png]]`·`![[name.png\|300]]`·`![[name.png#h]]`. 이미지 확장자만(`png jpg jpeg gif webp svg bmp avif`), `![[note]]`·`![[x.pdf]]`는 이미지가 아님. 경로형은 문서 폴더 기준, 이름형은 문서 폴더 → 프로젝트 루트 아래 이름 검색(비동기·캐시, 아래 규칙). 너비 옵션은 표시 너비에 반영(mdloom 원본은 미반영, 아래 결정) | **보완 완료** |
| HTML `<img src>` | 예 | **구현 완료**(R6-B): 한 줄 안의 `<img …>`(따옴표 `"`·`'`·없음, 대소문자 무시), `src`의 `%xx`·`?#`·`~` 처리는 `resolve_image_path` 공유, 원격·`data:` 제외, 코드 스팬·펜스·같은 줄 `<!-- -->` 안 제외, 같은 줄 여러 개. conceal 범위는 태그 전체. `width`/`height`(px)는 표시 너비에 반영(mdloom 원본은 미반영, 아래 결정). 여러 줄에 걸친 태그는 줄 단위 스캔의 한계로 **인식하지 않음** | **보완 완료** (여러 줄 태그: 의도적 미지원, 사유: 스캔이 줄 단위이고 여러 줄 상태는 펜스처럼 문서 인덱스가 필요해 빈도(사용 0) 대비 비용이 큼) |
| 틸드 `~` 경로 (이슈 image_tilde_path) | 예 | `resolve_image_path`가 `~`/`~/…`를 `os_homedir()`로 확장(`$VAR`만 `expand`). `vim.fn.expand`는 `?`·`#`를 glob/버퍼 이름으로 풀어 쿼리·앵커와 충돌해 교체 | **보완 완료** (스펙 추가) |
| 경로의 `%20`·공백·쿼리·앵커·`<…>` | 서버(URI)가 해석 | `%20`만 치환하던 것을 `%xx` 전체 디코딩, `?query`/`#anchor` 제거, `<…>` 벗기기로 확대. 실제 파일이 그 문자를 포함하면 있는 그대로의 이름이 우선(`C#.png`, `100%25.png`). 표준 `![alt](path "title")`, `<path with spaces>`, 괄호가 균형 잡힌 경로 인식. Windows 드라이브 `C:`는 영향 없음(`://`만 원격으로 판정) | **보완 완료** (스펙 추가) |
| 표 안 이미지 | 아니오 | 예 (`table_image_spec`) | **동등** (rendermark 우위) |
| neopp 임시 id/path API | 예 | `backend.lua` `vim.ui.img.set(id, path, opts)`에 경로·원본 크기·`clip_*`·`dest_*_px`·`zindex` 전달, neopp가 늦게 붙어도 `NeoppReady`에서 초기화 | **동등** |
| 기본 bytes API(PNG만) | 예 | 없음. nvim 0.11에는 `vim.ui.img`가 없고 rendermark는 neopp 계약(경로+클리핑)만 쓴다 | **의도적 미지원**(사유: neopp 전용 계약) |
| 이미지 일부만 보일 때 | 기본 API는 자르기 불가라 숨김, neopp는 클리핑 | neopp 클리핑만 존재(자르기 가능하므로 숨길 필요 없음). 스크롤로 앵커가 화면 위로 나가도 footprint 규칙으로 예약·클리핑 유지(`partially visible …` 스펙) | **동등** |
| 스크롤·창 크기·분할·접기·편집 갱신, 닫힌 창 ID 제거, 버퍼 삭제 정리 | 예 | 예 (`same buffer in multiple windows`, `BufUnload`의 `clear_images_for_buf`/`diagram_cleanup_buf`/`docindex.forget`) | **동등** |
| provider 오류 후 재시도 억제 | 오류 시 빈 예약 제거, 같은 리비전은 재시도 안 함 | 이전: `set` 예외가 `send_images`까지 전파돼 동기화마다 반복. **보완**: `backend.lua`가 `set`/`del`을 `pcall`로 감싸 경고 한 번(`notify_once`), 같은 항목은 바뀔 때까지 재시도 안 함. 빈 예약은 남음(예약은 공간 계약이라 건드리지 않음) | 재시도 억제: **보완 완료** (스펙 추가) / 빈 예약 제거: **서브 이슈 S3** |
| provider 미구비/불완전 시 SafeState 오류 없음 | 예 | 이전: `del`이 없는 provider에서 오류. **보완**: `del` 부재 허용, `vim.ui.img = {}`는 `img_available`이 막아 무동작 | **보완 완료** (스펙 추가) |
| `conceallevel < 1`이면 2로 | 이미지 창에서 올림 | `wrap.apply`가 마크다운 창의 `conceallevel < 2`를 2로 올리고 `disable`에서 복원, 다이어그램 창은 `diagram.lua`도 올림. wrap을 끈 창은 올리지 않음(wrap이 마크다운 창의 소유자) | **동등** |
| 스텁(텍스트 박스) 표시 | `MDLOOM_IMG_STUB=1` | `RENDERMARK_IMG_STUB=1` 또는 `vim.g.rendermark_img_stub`, `vim.ui.img`가 없을 때만 설치. 이전엔 `RENDERMARK_IMG_STUB=0`도 켜졌음 → `''`/`0`/`'0'`은 끔으로 **보완**. `backend.lua` 주석에 이름·의미를 적음(사용자 문서는 R7 README). 스텁은 공간 할당을 바꾸지 않음(메모리 `project_stub_allocation_render_separation`) | **보완 완료** (스펙 추가), 환경변수 이름은 다름(`MDLOOM_` → `RENDERMARK_`) |
| 이미지 크기 읽기 형식 | PNG/JPEG/GIF/WebP | `size.lua`: PNG/JPEG/WebP에 **GIF(87a/89a) 추가**. SVG·BMP는 `unsupported` 박스(rendermark가 래스터만 그림, `~/notes`의 svg 1개가 해당) | GIF: **보완 완료** (스펙 추가) / SVG 등: **의도적 미지원**(사유: neopp가 그릴 수 없음) |
| 서버 응답 경합(오래된 응답 거부) | 예 | 서버 응답을 쓰지 않음 | **의도적 미지원**(사유: 해당 없음) |
| 이미지 소스 범위 밖: 펜스 코드블록 안 이미지 문법 제외 | 서버가 제외 | 이전엔 제외 없음 | **보완 완료**(R6-A, 아래 규칙) |
| 확대 미리보기 창 `MdloomOpenImage` | 예 | 다이어그램 활성 블록 미리보기(`RendermarkPreviewShow/Hide/Toggle`) + **`:RendermarkImageOpen`**(R9): 새 탭에 이미지를 창에 꽉 차게 표시 | **구현 완료**(서브 이슈 S2, R9). float/split 재사용 대신 새 탭 + 별도 모듈 `image/zoom.lua`(사용자 결정) |

서브 이슈 목록:
- S1 한 줄 이미지가 폭을 넘을 때의 동작 — **의도적 유지(사용자 결정 2026-10-30, 닫힘)**: 현재처럼 한 band에서 모두 축소한다(이미지가 매우 작아질 수 있음). mdloom처럼 다음 band로 줄바꿈하려면 `layout_image_line`의 반환 높이와 예약 행 수(`ReserveRow`)가 바뀌어 neopp와의 공간 할당 계약과 `layout_image_line fit` 스펙을 함께 바꿔야 하므로 "기존 rendermark 방식으로" 두기로 했다. 코드 변경 없음. 폭이 모자라 작게 보이는 이미지는 S2의 `:RendermarkImageOpen`으로 크게 볼 수 있다
- S2 일반 이미지 확대 미리보기(`MdloomOpenImage` 동등) — **구현 완료(R9)**: `:RendermarkImageOpen`, 새 탭에 창에 꽉 차게 표시
- S3 provider 오류 시 빈 예약 제거: `set` 실패를 `send_images`에 되돌려 해당 이미지의 예약·conceal을 빼고 같은 리비전은 다시 안 그림. 현재는 경고 한 번 + 예약 유지(소스는 숨겨진 채 빈 공간)

R6-A에서 정한 공통 기반 규칙:
- 링크 문법(`scan.lua` `find_image_links`): `![alt](dest)` 의 dest는 `path`, `<path with spaces>`, 균형 잡힌 괄호를 가진 경로, 뒤에 `"t"`/`'t'`/`(t)` title. 빈 경로·닫히지 않은 `<`·공백 포함 맨 경로는 이미지가 아님. 프리필터는 줄에 `![`가 있는지 평문 `find`(함수 맨 앞)
- 경로(`resolve_image_path`): `<…>` 벗기기 → 후보 `[그대로, ?#제거, %xx 디코딩, 둘 다]` 중 실제 있는 파일을 첫 번째로 채택, 하나도 없으면 마지막(제거+디코딩)을 돌려줌(파일 확인은 후보가 둘 이상일 때만). `scheme://`는 nil, `~`는 `os_homedir()`
- 펜스 제외(`image/docindex.lua`): treesitter 없이 줄 단위 상태. 여는 줄은 앞에 공백·`>` 뒤 ``` 3개 이상 또는 `~~~` 3개 이상(백틱 펜스의 info string에 백틱이 있으면 펜스 아님), 닫는 줄은 같은 문자·같거나 더 긴 길이·뒤에 공백만, 닫히지 않으면 문서 끝까지. 목록 마커와 같은 줄의 펜스(`- ```lua`)는 인식하지 않음. 버퍼 전체를 한 번 읽어 {펜스 구간, 정의}를 `changedtick`별로 캐시하고 줄 조회는 이진 탐색. **스캔한 줄에 `![`가 있을 때만** 만들므로 이미지가 없는 문서는 비용 0. 적용 대상은 버퍼 줄 스캔뿐: 다른 네임스페이스의 virt_text/virt_lines는 제외하지 않음(다이어그램 블록 행에 붙은 `source_span_height` 경로가 의존). 비용은 `docs/image_scan_performance.md`의 "After R6-A": 이미지가 보이는 문서의 편집당 +0.3 ms(3000줄)·+0.8 ms(8000줄), 스크롤·커서·변경 없는 `send_images`는 증가 없음
- 참조형: 정의는 `^ {0,3}[label]: dest [title]` 한 줄(라벨 `^`로 시작하는 각주 제외, 이후 쓰레기 문자가 있으면 정의 아님), 라벨은 공백 정규화+소문자(비ASCII는 `vim.fn.tolower`). `line_has_image_link(text, buf)`는 `buf`가 있을 때만 참조형을 셈(wrap이 이미지 줄을 감싸지 않게 하기 위함). 항목에 `ref_label`, `raw_path`는 정의의 목적지
- R6-B 연결점: 새 문법의 줄 프리필터는 `find_image_links` 맨 앞의 `![` 조기 종료와 `collect_markdown_images`의 `line:find('![', 1, true)` 조건 두 곳에 `<img`를 더하면 된다. 펜스 제외는 같은 조건 안에서 이미 적용됨

R6-B에서 정한 규칙 (HTML `<img>`·위키 이미지, 2026-10-30):
- 반환 형식: `find_image_links`는 `{ s, e, raw, ref, meta }`, `meta`는 위키·HTML 링크에만 `{ wiki|html = true, want_width?, want_height? }`. 링크는 본문 순서로 정렬하고 앞 링크 안에 들어가거나 코드 스팬 안인 링크는 버린다(`![<img src=c.png>](d.png)`는 `d.png` 하나). `scan_markdown_image_text`의 `byte_col`/`byte_end_col`(conceal 범위)은 그대로이고 태그/`![[…]]` 전체를 덮는다. `[<img src=b.png>](url)`처럼 링크 텍스트 안의 `<img>`는 센다
- 프리필터: `scan.has_image_candidate(text)` 한 곳(`![` 평문 `find`, 없으면 `<` 평문 `find` 뒤에 `<[iI][mM][gG][%s/>]`). `![[`는 `![`에 이미 포함되므로 별도 검사가 없다. 사용처 4곳이 같은 함수를 쓴다: `find_image_links` 맨 앞, `collect_markdown_images`(문서 인덱스 생성 조건 포함), `line_has_image_link`(wrap과 `get_image_anchor_sig`), `diagram_exported_below`. 따라서 wrap은 새 문법의 줄도 감싸지 않고(`rendermark.image`가 배치), 내보낸 이미지 판정(R5)도 새 문법을 센다
- HTML: 태그가 한 줄 안에서 닫혀야 한다. 속성은 `name`, `name=값`(`"…"`·`'…'`·무따옴표; 무따옴표 값 끝의 `/>`의 `/`는 태그 몫), 첫 번째 속성이 이긴다. `src`의 엔티티(`&amp; &lt; &gt; &quot; &apos;`)를 푼다. `src`가 비었거나 없으면 이미지가 아니다. 이 뒤 경로는 `resolve_image_path`(원격 `scheme://`와 `data:`는 nil)
- 크기 속성 결정: **반영한다 — 유지 결정(사용자 확인 2026-10-30, 추가 작업 없음)**(mdloom 원본은 서버가 준 링크만 그려 `width`/`height`를 쓰지 않았으므로 동등성이 아니라 추가 기능). 이유: 모든 크기 계산이 `compute_image_display_size` 한 곳을 지나므로(`layout_image_line`, 표 셀 `wrap/table.lua`) 항목에 `native_width`(CSS px)를 두고 그 함수에서 `source_width` 대신 쓰는 5줄 변경으로 끝나고, 공간 예약은 기존과 같은 경로(`layout_image_line` → `ReserveRow`)에서 계산되어 스텁/neopp 할당 계약(메모리 `project_stub_allocation_render_separation`)을 건드리지 않는다. 규칙: `width`가 있으면 그 값, 없고 `height`만 있으면 그 높이가 되는 너비(`h × 원본너비/원본높이`), 둘 다 있어도 원본 비율은 유지(찌그러뜨리지 않음)해 `width`만 쓴다. 단위는 `300`·`300px`만, `%`·`em` 등은 무시. 결과는 여전히 창 너비·`max_rows`로 제한되고 한 줄 여러 이미지는 기존대로 공통 높이를 쓴다. `native_width`가 없는 항목의 계산은 변경 전과 부동소수점까지 같다
- 위키 문법: `![[target|옵션…]]`, `|` 앞의 `\`(표 셀 이스케이프)를 허용, `target`에서 `#…`(헤딩·`^블록`)를 제거, 옵션 중 `^\d+(x\d+)?$`인 첫 항목이 너비(와 높이), 그 밖의 `|텍스트`는 별칭이라 무시. `target`에 `[`/`]`가 있거나 이미지 확장자가 아니면 이미지가 아니다. `/`나 `\`가 있으면 경로형(`resolve_image_path`, 문서 폴더 기준·`~`·절대 경로·원격 제외), 없으면 이름형
- 위키 이름 검색 (`image/wikisearch.lua`): ① 문서 폴더에 `name`이 있으면 `fs_stat` 한 번으로 끝(검색 없음) ② 없으면 프로젝트 루트(`nvim_config.prjroot` `GetProjectRoot`: `.git`·`.prjroot` 등, 없으면 문서 폴더) 아래의 **이미지 파일 색인**에서 이름으로 찾는다. 색인은 루트당 하나이고 `vim.uv.fs_scandir` 콜백으로 폴더를 하나씩 도는 **비동기** 너비 우선 탐색으로 만든다(메인 루프를 막지 않음; `vim.system`/외부 `fd`는 쓰지 않음 — Windows에서도 같은 코드). 숨김 폴더(`.git`, `.obsidian` …)·`node_modules`·`target`·심볼릭 링크 폴더는 건너뜀. 후보는 이름이 정확히(대소문자 구분, mdloom 규칙 1과 같음) 같은 파일. ③ 후보가 여럿이면 문서 폴더에서의 폴더 거리(올라간 칸 + 내려간 칸)가 가장 작은 것, 거리까지 같으면 `error = 'ambiguous'` 박스(`[neopp: image name is ambiguous: name]`), 후보가 없으면 `not_found` 박스(경로는 문서 폴더 기준 후보)
- 상한과 근거: 탐색 항목(파일+폴더) 20000개, 깊이 8 (`wikisearch.limits`). R2 조사(노트 폴더 파일 251~1075개, 폴더 26~291개, 이미지 3~29개, 동명 0)의 약 20배라 정상 노트 폴더는 상한에 닿지 않고, `~/workspace` 같은 상위 폴더나 대형 저장소가 루트가 돼도 탐색은 한정된 시간(워커 스레드의 readdir 수십 ms 이내)에 끝난다. 상한을 넘으면 거기까지 모은 결과로 답한다(못 찾으면 `not_found`)
- 비동기 방식 선택: **찾는 중에는 아무것도 그리지 않는다**(예약·conceal·오류 박스 모두 없음 = 소스 그대로). 이유: 박스를 먼저 그리면 곧 이미지로 바뀌며 예약 행 수가 두 번 바뀌어 스크롤 안정성(메모리 `project_reservation_scroll_stability`)에 해롭고, 소스 그대로 두면 예약 계약에 영향이 없다. 색인이 완료되면 `vim.schedule` 안에서 기다리던 버퍼마다 `image.refresh(buf)`를 불러 다시 그린다(`wikisearch.on_ready`). `send_images`가 새 색인 요청을 만드는 일은 없다: 루트당 진행 중인 탐색이 있으면 요청을 합치고(스크롤 중 반복 호출 포함 `stats.started` 1회), 완료 후엔 캐시에서 답한다
- 캐시 무효화(파일 감시 없음): `image/init.lua`의 `BufWritePost`와 `BufEnter`(markdown 버퍼)가 그 루트의 색인에 `stale`을 표시한다. 다음 조회가 **오래된 색인으로 답하면서** 백그라운드 재탐색을 시작하고(이미지가 깜박이지 않음), 끝난 뒤 결과가 달라졌을 때만 `on_ready`로 다시 그린다. `BufEnter`는 색인 나이가 2초 미만이면 무시(창 전환마다 재탐색하지 않기 위함; 저장은 항상 무효화). 위키 이름 조회가 없는 문서는 색인도 탐색도 만들지 않는다
- 한계: 여러 줄에 걸친 `<img>`와 여러 줄 `<!-- -->` 안의 `<img>`(같은 줄 주석만 제외)는 줄 단위 스캔이라 다루지 못한다. 표 셀의 `![[a.png\|100]]`은 파서가 이스케이프를 허용하지만 표 셀 분할과의 상호작용은 스펙으로 고정하지 않았다. 원격 `<img>`가 있는 줄도 `line_has_image_link`는 참이라(표준 원격 이미지와 같음) wrap이 그 줄을 감싸지 않는다. GUI(neopp)·`RENDERMARK_IMG_STUB` 화면 확인은 R8 수동 항목

- [x] 위 "확인 필요" 항목을 코드와 실행으로 확인하고 표를 갱신 (R6-A: 위키·HTML 행은 R6-B)
- [x] 필요한 보완을 별도 서브 이슈로 분리해 진행(이 문서에서는 목록만 유지): 작은 보완(GIF 크기, 틸드·`%xx`·쿼리·앵커·`<…>`, provider 오류 내성, 스텁 환경변수 값)은 R6-A에서 구현, 큰 것은 S1~S3
- [ ] 스캔 확대 (Q1 (c)): `scan.lua`와 `table_state` 연동에 다음을 추가한다. 스펙은 mdloom 원본 `images_unit.lua`·`images.lua`(`git show before-lsp-scope:editors/nvim/tests/images_unit.lua`) 케이스를 이식한다
  - [x] HTML `<img src="…" width=…>`: `src` 해석(로컬만), `width`/`height` 속성이 있으면 표시 크기에 반영 여부 결정, 코드 안·주석 안은 제외, 같은 줄 여러 개 (R6-B: 크기는 반영, 여러 줄 태그는 줄 단위 한계로 미지원 — 위 규칙)
  - [x] 참조형 `![alt][ref]`, `![ref][]`, `![ref]`: 같은 문서의 정의 줄 `[ref]: path "title"`만 해석(대소문자 무시, 공백 정규화), 사용 위치마다 표시, 정의가 없으면 표시하지 않음 (R6-A). 정의 줄은 **conceal 하지 않음**(사용자 결정 2026-10-30; be74a94 결론 + 공간 예약 계약. 이전의 "정의 줄 conceal" 요구를 정정, 코드 변경 없음)
  - [x] 위키 `![[name.png]]`, `![[dir/name.png]]`, `![[name.png|300]]`(너비), `![[name.png#...]]`는 무시: 경로형은 문서 폴더 기준, 이름형은 위 Q1 규칙의 이름 검색. 검색은 비동기·캐시(파일 감시 없이 `BufEnter`/저장 시 무효화), 결과 없음/모호는 오류 박스(`not_found`/`ambiguous`) (R6-B)
  - [x] 경로 규칙은 기존 `resolve_image_path`를 공유: `%20`(및 `%xx`), `~`, `<…>` 감싸기, 쿼리·앵커 제거 (R6-A)
  - [x] 코드 스팬·펜스 코드블록 안의 이미지 문법은 제외 (R6-A: 코드 스팬은 기존, 펜스는 신규 `docindex.lua`)
  - [x] 성능: 문서 스캔 비용이 늘지 않도록 줄 단위 프리필터(`![`, `<img`, `[…]:`)를 유지하고 `docs/image_reapply_performance.md` 벤치를 다시 측정 — R6-A(`![`와 참조형)와 R6-B(`<img`·위키)의 측정은 `docs/image_scan_performance.md` "After R6-A"·"After R6-B". 이미지 없는 문서(HTML 텍스트 줄 포함)는 불변, `benchmark_image_reapply`(5회) 호출 수 불변
- 완료 조건: 표의 모든 행에 "동등", "의도적 미지원(사유)" 또는 사용자 결정(의도적 유지·conceal 하지 않음)이 기록됨. 열린 항목은 S3 하나(사용자가 설명을 요청한 상태라 손대지 않음).

### R7 — 정리

- [x] `docs/` 문서 갱신: rendermark 이미지·다이어그램 설명(있다면)과 `docs/coderunner.md`와의 경계 설명. `README.md`의 기능 목록 갱신
  - 신규 `docs/rendermark_image.md`(비슷한 문서 없었음): 공급자 계약, glue, 설정 키 3개, 지원 문법·경로 규칙·위키 이름 검색, 크기 형식(PNG/JPEG/WebP/GIF, SVG 미지원), 스텁 환경변수. `docs/coderunner.md`: rendermark와의 경계 문장 2곳 갱신, 낡은 "병행 기간" 서술 정정, `raw_stdout` 설명 추가. `README.md`: rendermark 행에서 없어진 링크 이동·이미지 완성 기능 제거, 새 문법·스텁·문서 링크 추가, coderunner·glue 행 추가, 하단 설명의 actions/rename/completion 서술 정정
- [x] 이슈 `issue-rendermark_all_drawing.md`의 "확인 필요" 항목 닫기
  - 3개 항목 `[x]`로 닫고 "3. 작업 노트" 추가(R0~R7 요약, R8 수동 확인 대기). R8 수동 확인이 남아 있어 `closed/`로는 옮기지 않음(`.issues/`는 git 제외)
- [x] `tests/manual/`의 plantuml 관련 수동 스크립트·벤치 정리 (`benchmark_image_scan.lua` 등 사용 여부 확인)
  - `benchmark_plantuml_scan.lua` -> `benchmark_image_scan.lua`(`git mv`), `plantuml_scan_performance.md` -> `image_scan_performance.md`. 스크립트는 공급자·Markdown/HTML/위키 이미지 스캔을 재므로 plantuml 이름이 맞지 않았다. 참조(docs, 스크립트 머리말·네임스페이스, 닫힌 이슈 2개, 이 문서)를 모두 갱신하고 `BENCH_PROVIDER=1 BENCH_IMAGES=1`로 실행 확인. `module_refactoring.md`의 `#### plantuml_scan` 소제목은 당시 출력 기록의 라벨이라 그대로 둠. `coderunner_smoke.lua`는 coderunner용 수동 스크립트라 변경 없음
- [x] 죽은 코드 점검: `grep -rn "plantuml" lua tests docs init.lua` 결과가 의도된 것(호환 별칭, 문서의 과거 설명)만 남는지
  - 남은 것: 호환 별칭 `plantuml.preview`(`image/init.lua`, `diagram_spec`), 펜스 언어 기본값 `plantuml/puml/uml`(`deco.lua`, `markdown.lua`, 관련 스펙), 스펙의 ```plantuml 펜스 픽스처, 사용자 `init.lua`의 coderunner `renderers.plantuml`·`plantuml_cmd()`, 과거 기록 문서, 외부 플러그인 `plantuml-previewer.vim`(`plugins.lua`, 별개 기능). 정리한 것: `rendermark/init.lua`의 낡은 "markdown-oxide go-to-definition" 주석(`link.setup` 호출 주석 포함; 모듈은 이미 없음), `backend.lua` 주석의 옛 플러그인 환경변수 이름(`grep -ri mdloom lua/nvim_config/rendermark` 비움 — 이슈 완료 기준), `module_refactoring.md`의 삭제된 코드 서술에 "later removed" 주석. `grep -rn "markdown-oxide\|markdown_oxide" lua tests init.lua` 결과 없음. 고아 점검(`image/` 모듈 14개의 `require` 호출처, rendermark 함수 정의의 참조 수)에서 R1~R6이 만든 고아 없음
- [x] `docs/image_scan_performance.md`는 과거 측정 기록으로 보존하고 머리말에 "plantuml 실행은 coderunner로 이동" 메모 추가
  - 개명 경위와 함께 머리말에 메모 추가, 본문 측정은 그대로
- 완료 조건: grep 결과가 의도된 것만 남음 (충족). 전체 `bash run_tests.sh` 종료 0, 실패·오류 0(스펙 줄 801·803, 두 번 실행)

### R8 — 통합 검증

#### 자동 검증 (2026-10-30, 헤드리스 Linux, nvim 0.12.4) — 완료

- [x] `bash run_tests.sh` 전체 통과: 종료 0, 실패 0, 오류 0, `Success` 줄 802(스펙 파일 70개; `session/events_spec`는 출력 줄이 실행마다 빠지는 기존 현상으로 요약이 누락돼 단독 재실행에서 4개 통과 확인). 읽기 모드 스펙 1개(아래)를 더한 뒤 전체를 다시 실행해 종료 0, `Success` 803, 실패·오류 0. `tests/spec/rendermark`는 13개 파일 352/0/0, `tests/spec/coderunner`·`markdown_glue_spec`은 단독 종료 0
- [x] 성능 벤치 `benchmark_image_reapply.lua` 5회: 호출 수가 R0 기준선과 같음(변경 없음 `set`/`mark`/`clear`/`redraw`/`del` 전부 0, 너비 변경 set 1000/mark 2000/clear 1000/redraw 1000/del 0). 중앙값은 아래 표
- [x] `benchmark_image_scan.lua` 대표 시나리오: R6-B 문서(`docs/image_scan_performance.md` "After R6-B")의 수치 범위와 일치(아래 표)
- [x] 실제 `init.lua` 헤드리스 기동(XDG 격리): 경고·오류 없이 종료. 임시 문서(표준·표 안·참조형·HTML·위키 경로형/이름형 이미지, plantuml 블록 2개 중 하나는 아래에 내보낸 이미지 링크, 펜스 안 이미지 문법)를 열고 `RENDERMARK_IMG_STUB=1`로 확인: coderunner `diagrams`가 `pending`(`render_on_open`이 자동 시작) → 렌더 후 `ready`, `collect_markdown_images` 7개(중복 0, 펜스 안 문법 제외), `collect_diagram_images`는 내보낸 이미지가 붙은 블록을 빼고 1개만, `send_images` 후 스텁 저장소 항목 8개(= 7 + 블록 1). 본 저장소의 `tests/manual/rendermark_manual.md`로도 확인: Markdown 이미지 18개(중복 0, `not_found`·`unsupported` 오류 박스 각 1), 다이어그램 4개 `ready` 3 / `failed` 1, 그려진 블록 2개 + `[diagram: ERROR]` 오류 줄 1개(내보낸 이미지가 붙은 블록은 숨김). 실패 블록과 저장 시 갱신: 문법 오류 블록은 `failed`(plantuml 종료 코드 200) + `[diagram: ERROR]`, 블록을 고치고 `:write`하면 `auto_render`가 새 이미지로 `ready`·`stale` 해제
- [x] coderunner 없이(`package.preload`로 `require` 실패를 흉내): glue `setup()` 오류 없음, 자동명령 0개, Markdown 이미지 7개 수집·`vim.ui.img.set` 7회, 다이어그램 항목 0. 스펙 근거: `tests/spec/markdown_glue_spec.lua`의 `registers nothing and stays quiet without coderunner`
- [x] mdloom 연결(가능한 범위): `vim.g.mdloom_dir = '~/workspace/markdown_lsp'`, `M.cmd` = `{ ~/.local/bin/mdloom, 'lsp' }`(PATH 바이너리 우선; 심볼릭 링크로 `markdown_lsp/target/debug/mdloom`과 같은 빌드), `~/workspace/markdown_lsp`는 `lsp-scope` 브랜치(작업 트리 깨끗). 실제 서버를 헤드리스에서 기동해(10초 제한) `initialize` 완료 후 `server_capabilities.codeLensProvider == nil`, 능력 목록에 codeLens·inlayHint 등 그리기 관련 항목 없음. 기동 때 `mdloom: problems in the config: ~/.config/mdloom/config.toml (0 error(s), 2 warning(s))` 알림이 한 번 나온다(아래 "발견한 점")
- [x] 읽기 모드: `diagram.lua`의 `diagram_active_block`이 읽기 모드 창(`vim.w.read_mode_active`)에서 항상 활성 블록 없음으로 답한다. 기존 스펙에는 이 분기를 고정하는 것이 없어(`table_image_spec`의 읽기 모드 스펙은 표 행 전용) 스펙 1개 추가(`diagram_spec`: 읽기 모드 창에서 커서가 블록 안이어도 블록 이미지가 그려진 채 유지, 미리보기 창 0, `request_live` 0, 읽기 모드를 끄면 다시 활성). 분기를 지우면 이 스펙이 실패함을 확인. 읽기 모드 자체(`concealcursor='nvic'`)는 `read_mode_spec`·`wrap/init_spec`·`events_spec`
- [x] 코드 위생: `git status` 깨끗(이 단계의 변경은 아래 커밋 목록뿐), push 안 함

R0 대비 최종 수치:

| 항목 | R0 | R7 | R8 |
| --- | ---: | ---: | ---: |
| 전체 스펙 통과 (`Success` 줄) | 696 (69 파일) | 801~803 | 802 (70 파일) → 읽기 모드 스펙 추가 후 803 |
| 실패 / 오류 | 0 / 0 | 0 / 0 | 0 / 0 |
| `tests/spec/rendermark` | 259 (13 파일) | - | 352 (13 파일; R0 대비 +93, 아래 `diagram_spec` 35개 포함) |
| `benchmark_image_reapply` 변경 없음 중앙값 | 680.0 ms (672.0~696.7) | 673.6 ms (R6-B) | 672.0 ms (658.9~683.3) |
| `benchmark_image_reapply` 너비 변경 중앙값 | 690.8 ms (681.4~705.9) | 682.2 ms (R6-B) | 679.6 ms (668.7~692.2) |
| 호출 수 (변경 없음) | set/mark/clear/redraw/del 0 | 0 | 0 |
| 호출 수 (너비 변경) | set 1000, mark 2000, clear 1000, redraw 1000, del 0 | 같음 | 같음 |

스캔 벤치(`benchmark_image_scan.lua`, ms/호출, 1회 실행) — "After R6-B" 표와 비교:

| 시나리오 | R6-B 기록 | R8 |
| --- | ---: | ---: |
| 3000줄, 이미지 없음 (cold / unchanged / edited) | 0.29-0.35 / 0.08 / 0.07 | 0.29 / 0.08 / 0.08 |
| 3000줄, HTML 텍스트(`BENCH_NOISE=1`) edited | 0.37-0.39 | 0.39 (cold 0.84, unchanged 0.11) |
| 3000줄, 이미지(`BENCH_PROVIDER=1 BENCH_IMAGES=1`) cold / unchanged / edited | 1.77-1.84 / 0.56-0.58 / 0.85 (공급자 없이) | 1.77 / 0.55 / 0.99 (공급자 10블록 포함: 편집당 공급자 호출 1회, 전체 읽기 1회) |
| 8000줄, 이미지 cold / unchanged / edited | 2.12-2.47 / 0.57-0.59 / 1.35 | 2.40 / 0.58 / 1.35 |
| 커서 이동(변경 없음) | - | 0.002~0.003, 공급자 호출 0 |

발견한 점 (코드 수정 없음):
- 사용자 환경: 실행 중인 mdloom daemon(`/home/ilmoek/workspace/nvim_config` 루트, 00:35 시작)이 프로토콜 1이고 현재 빌드는 프로토콜 2라, 다른 세션이 붙어 있는 동안 새 nvim에서 mdloom이 `protocol version conflict`로 연결되지 못한다(헤드리스에서 확인). 열린 nvim 세션을 모두 닫은 뒤 `mdloom daemon stop`으로 daemon을 내리고 새로 연다. 이 확인 중 만든 임시 daemon은 정리했고 사용자의 daemon은 건드리지 않았다
- `~/.config/mdloom/config.toml`의 `[runners.*]`·`[renderers.plantuml]`이 mdloom L4(실행·렌더링 제거) 이후 경고 2건의 원인으로 보인다(확인하지 않음). `init.lua`의 `coderunner.setup`로 옮겨졌으므로 TOML에서 지워도 된다 — 사용자 판단
- `init.lua`의 `coderunner.setup{ diagnostics = false }`라서 `render-failed`·`stale-export` 진단은 화면에 나오지 않는다. (d)를 확인하려면 임시로 `true`로 바꾼다
- 헤드리스 `send_images`는 보이는 줄만 스캔하고 위키 이름 검색은 비동기라 첫 호출에서는 소스 그대로이다(설계대로). 확인 스크립트는 직접 `collect_markdown_images`를 호출하고 완료를 기다려야 한다

#### 수동 확인 체크리스트 (사용자) — 대기

샘플: `tests/manual/rendermark_manual.md`(이미지는 `tests/manual/rendermark_manual_assets/`의 작은 PNG 3개와 SVG 1개). 절 제목의 (a)~(h)가 아래 항목과 대응한다. 한 항목씩 열어 보고 `[x]`와 메모를 남긴다. 문서를 `:w`로 고쳤다면 끝에 `git restore tests/manual/rendermark_manual.md`.

준비 (한 번만):

```sh
cd ~/workspace/nvim_config
# 1) 이전 mdloom daemon 정리: 열린 nvim 을 모두 닫은 뒤
mdloom daemon stop
# 2) 그림 없이도 텍스트 박스로 보는 모드 (터미널 nvim)
RENDERMARK_IMG_STUB=1 nvim tests/manual/rendermark_manual.md
# 3) 실제 그림: neopp GUI 로 같은 파일을 연다 (neopp 는 PATH 에 없으므로 평소 쓰는 방법으로)
# plantuml 이 PATH 에서 안 돌면(이 개발 환경처럼 java 링크가 깨진 경우):
PATH=~/.local/jdk-21/bin:$PATH PLANTUML_JAR=/usr/share/java/plantuml/plantuml.jar \
  RENDERMARK_IMG_STUB=1 nvim tests/manual/rendermark_manual.md
```

스텁 모드에서는 이미지 자리에 `+---+`와 `img: <파일>` 텍스트 박스가 보이고, 소스(`![..](..)`)가 숨는다. neopp 에서는 실제 이미지다. 아래는 어느 모드에서든 같은 판정이다.

- [ ] M1 (a) Markdown 이미지가 한 번만 그려진다: "(a)" 절의 빨강 이미지가 한 개만 보이고(같은 자리에 겹치거나 두 번 나오지 않음), 문장 중간의 파랑 이미지도 한 개. 소스 `![red](...)`는 숨는다. 같은 문서를 mdloom 이 붙은 상태로 열어 mdloom 쪽 그림(옛 플러그인)이 따로 나오지 않는지 확인. 이어서 `:lua vim.print(vim.lsp.get_clients()[1].server_capabilities.codeLensProvider)` 가 `nil`
- [ ] M2 (b) 표·한 줄 여러 이미지: "(b)" 절의 표 셀 이미지 2개가 셀 안에 보이고 표가 깨지지 않는다. "한 줄에 세 개" 줄은 세 이미지가 나란히 한 줄 높이로 보인다(너비가 모자라면 함께 축소되는 것이 의도적 유지 설계, 서브 이슈 S1 닫힘). 없는 파일은 `not_found`, SVG 는 `unsupported` 오류 박스. 인라인 코드와 ```md 펜스 안의 이미지 문법은 그려지지 않는다
- [ ] M3 (b) 스크롤: "(b)"의 `scroll target` 이미지가 있는 곳까지 `<C-e>`/`<C-y>`로 한 줄씩, `<C-d>`/`<C-u>`로 반 화면씩 오르내린다. 이미지가 위/아래 경계에 걸쳐 일부만 보여도 잘려 보이고(neopp) 위치가 어긋나지 않으며, 왔다 갔다 해도 진동하지 않는다
- [ ] M4 (b) 분할·접기·창 크기: `:vsplit`으로 같은 문서를 두 창에 열면 각 창에 이미지가 독립으로 그려지고, 한 창을 닫으면 그 창의 이미지만 사라진다. "(b)" 절 전체를 `zfap`(또는 `:set foldmethod=indent`/`zc`)로 접으면 이미지가 접힌 줄에 남지 않고 펴면 돌아온다. GUI 창 크기를 줄였다 늘리면 이미지 크기와 위치가 새 너비를 따른다. 줄바꿈 토글 `:MarkdownWrapToggle` 후 전후에 어긋남이 없다
- [ ] M5 (c) plantuml 블록: 열고 잠시 뒤 "(c)" 블록이 소스 대신 렌더된 이미지로 바뀐다(`render_on_open`). `j`로 블록 안에 들어가면 소스가 드러나고 미리보기 split(오른쪽이나 아래, 창 비율에 따라)이 뜬다. 블록 밖으로 나가면 미리보기가 닫히고 다시 이미지가 보인다. 블록 안에서 `Alice -> Bob: hello` 를 `hello again` 으로 바꾸고 `:w` 하면 잠시 뒤(저장 렌더 디바운스 200ms + 렌더 시간) 이미지가 새 내용으로 갱신된다. `:RendermarkPreviewToggle`로 미리보기를 끄면 블록에 들어가도 열리지 않는다
- [ ] M6 (d) 렌더 실패: "(d)" 블록은 이미지가 되지 않고 소스가 그대로이며 블록 끝에 `[diagram: ERROR]` 경고 줄이 보인다. 코더러너 진단: `init.lua`의 `diagnostics = false` 를 임시로 `true` 로 바꾸고 다시 열어 `:lua vim.print(vim.diagnostic.get(0))` 에 `render-failed` warning(블록 첫 줄)이 있는지 확인한 뒤 되돌린다. 블록을 고치면 경고와 진단이 사라진다. `:CodeRender!` 로 강제 재렌더도 시험
- [ ] M7 (e) 내보낸 이미지 인접 블록: "(e)"의 첫 블록(바로 아래에 초록 이미지 링크)은 소스가 그대로이고 초록 이미지만 그려진다(블록 이미지 없음). 둘째 블록(빈 줄 2개 아래 링크)은 블록 이미지와 파랑 링크 이미지가 둘 다 보인다. 첫 블록 아래 링크 앞에 빈 줄을 2개 넣으면 블록 이미지가 나타나고, 줄을 지우면 다시 숨는다. 실제 내보내기: 임시 문서(`tests/manual/` 밖, 예 `/tmp/exp.md`)에 plantuml 블록을 쓰고 `:CodeExport` 후 블록 이미지 대신 링크 이미지만 남는지
- [ ] M8 (f) coderunner 없이: 임시로 `init.lua`의 `require'nvim_config.markdown'.setup()` 줄만 주석 처리하고(glue 제거: 공급자 등록 없음) 같은 문서를 연다. 시작 오류 없음, (a)~(b)·(h)의 Markdown 이미지는 그대로이고 plantuml 블록은 소스 그대로(이미지·경고 없음). 확인 뒤 `git checkout init.lua`로 되돌린다
- [ ] M9 (g) 읽기 모드: `<Space>r` 로 읽기 모드를 켠다. 커서가 "(c)" 블록 안에 있어도 블록은 이미지로 유지되고 소스가 드러나지 않으며 미리보기 split 이 열리지 않는다. 읽기 모드에서 이미지와 표가 정상이고, 다시 `<Space>r` 로 끄면 블록 안 커서에서 평소처럼 소스와 미리보기가 나온다
- [ ] M10 (h) 위키·HTML·참조형: "(h)" 절의 참조형 이미지 2개(`![ref alt][redref]`, 단축형 `![redref]`)가 빨강으로 보이고 정의 줄 `[redref]: ...`은 그대로 남는다. HTML `<img ... width="120">`은 폭 120px 정도로(원본 240px보다 작게) 보인다. 위키 경로형 2개 중 `|60`이 붙은 것은 더 작게. 위키 이름형 `![[rm_green.png]]`은 처음에는 소스 그대로이다가 잠시 뒤(프로젝트 루트 색인 후) 초록 이미지로 바뀐다. 이름을 `rm_nothing.png`로 바꿔 저장하면 `not_found` 오류 박스
- [ ] M11 (i) Windows GUI: 같은 저장소를 Windows 에 두고 neopp 로 `tests\manual\rendermark_manual.md` 를 연다. M1·M3·M5 를 반복하고, 별도 임시 문서에 경로 변형을 넣어 확인한다(`C:\...`는 실제 경로로 바꿔서): `![d](C:\Users\me\...\rm_red.png)`, `![b](rendermark_manual_assets\rm_red.png)`, `![f](C:/Users/me/.../rm_red.png)`, `![u](<rendermark_manual_assets/rm_red.png>)`. 모두 한 번씩만 그려지고 스크롤·미리보기 split 이 동작해야 한다. plantuml 렌더(`render_on_open`)는 Windows 의 `plantuml`/`java` 경로 설정에 달렸다. 결과(되는 것/안 되는 것)를 아래 "수동 확인 결과"에 적는다
- [ ] M12 R0 에 남은 "기존 동작 캡처": (i) 비활성 plantuml 블록이 이미지로 대체되는지 (M5), (ii) 커서 진입 시 미리보기 split (M5), (iii) `RENDERMARK_IMG_STUB=1`로 텍스트 박스 (준비 2). 회귀 비교가 필요하면 R0 기준 코드를 별도 작업 트리로 연다: `git worktree add ../nvim_before 07ab9fa`, `mkdir -p /tmp/xdg_before && ln -sfn $PWD/../nvim_before /tmp/xdg_before/nvim && XDG_CONFIG_HOME=/tmp/xdg_before RENDERMARK_IMG_STUB=1 nvim tests/manual/rendermark_manual.md` (그 시점 코드는 rendermark 가 plantuml 을 직접 실행하고 `RENDERMARK_PLANTUML_JAR`/`PLANTUML_JAR`를 읽는다). 비교 후 `git worktree remove ../nvim_before`
- [ ] M13 R4 의 neopp GUI 통합 확인: M5 가 곧 그 확인이다(plantuml 블록 대체, 저장 시 갱신, 미리보기 split, 이벤트 연쇄의 지연 체감). 저장 후 이미지가 바뀌기까지 체감 지연이 있으면 시간을 적는다
- [ ] M14 (j, R9) 이미지 확대 보기 `:RendermarkImageOpen`(Markdown 버퍼의 `<leader>i`): 샘플 "(j)" 절 "세 개" 줄에서 커서를 빨강/파랑/초록 링크 위에 두고 실행하면 새 탭이 열리고 그 이미지가 창에 꽉 차게(종횡비 유지, 가운데; 240x120·120x120·160x80 모두 확대) 보인다. 링크 사이 공백에서는 가까운 이미지가 열린다. 참조형·HTML·위키 줄에서도 열리고, 없는 파일·SVG·이미지 없는 줄에서는 탭 없이 알림만 뜬다. (c) 의 렌더된 plantuml 블록 안에서는 렌더 이미지가 열린다. 창 크기를 바꾸면(GUI 창 크기, `<C-w>v` 등) 이미지가 다시 맞춰지고, 다른 탭으로 갔다 오면 이미지가 사라졌다 돌아오며 문서 탭의 이미지는 영향이 없다. `q`/`<Esc>` 로 탭이 닫히고 원래 탭으로 돌아오며 이미지가 남지 않는다. 스텁(`RENDERMARK_IMG_STUB=1`)에서는 같은 자리에 `img: <파일>` 박스가 보인다

수동 확인 결과 (사용자가 채움):

| 항목 | 환경(neopp/스텁/Windows) | 결과 | 메모 |
| --- | --- | --- | --- |
| M1~M14 | | | |

#### 남은 일

- [ ] 수동 확인(M1~M14) 완료 후 진행 기록 갱신
- [ ] 수동 확인 후 이슈 `issue-rendermark_all_drawing.md`를 `closed/`로 이동 (사용자 결정)
- 완료 조건: 자동 검증 항목이 모두 `[x]`이고(충족), 수동 체크리스트가 사용자 확인으로 모두 `[x]`가 된다.

### R9 — R8 보고 후속 결정 반영 (2026-10-30)

사용자가 R8 보고를 보고 정한 것을 반영한다.

| 번호 | 결정 | 처리 |
| --- | --- | --- |
| (1) | HTML `width`/`height`·위키 `\|300` 크기 속성 반영은 유지 | 추가 작업 없음. R6-B의 "크기 속성 결정"에 유지 결정을 기록 |
| (2) | 참조 정의 줄은 가리지 않고 그대로 둔다 | **계획서 사양 변경**: Q1·R0 목록 4·R2 구현 순서 2·R6 표·R6 체크박스의 "정의 줄 conceal" 요구를 "conceal 하지 않음"으로 정정. 코드 변경 없음(현재 동작이 이미 그렇다) |
| (3) | S1(한 줄 이미지가 폭을 넘을 때)은 기존 rendermark 방식 유지 | S1을 "의도적 유지"로 닫고 동등성 표 행을 갱신. 코드 변경 없음 |
| (4) | S2 구현: 일반 이미지 확대 보기 | 아래 |
| (5) | S3(provider 오류 시 빈 예약 제거)는 사용자가 설명을 요청한 상태 | 건드리지 않음. **열린 상태 유지** |
| (6) | `plantuml-previewer.vim` 미사용 | `plugins.lua`에서 제거(아래) |

**S2 구현 — `:RendermarkImageOpen`** (`image/zoom.lua`, 사용 방법은 [rendermark_image.md](rendermark_image.md))

- 명령 이름: 기존 `RendermarkPreviewShow/Hide/Toggle`의 `Rendermark<대상><동작>` 관례를 따라 `RendermarkImageOpen`. 키맵: Markdown 버퍼 로컬 `<leader>i`. 조사: 전역 키맵(`keymap.lua`)과 플러그인 키맵에 `<leader>i*`가 없고 coderunner가 같은 방식(`FileType markdown` 버퍼 로컬 `<leader>c*`)을 쓴다. `gp*`(`gpp`는 다이어그램 미리보기 재열기)는 내장 `gp`(붙여넣기 후 이동)에 `timeoutlen` 지연을 만들 수 있어 피했다
- 대상 선택: 다이어그램 블록 안이면 항목이 `ready`일 때 렌더 이미지(공급자 `items` 사용, 읽기 모드·활성 여부와 무관), 아니면 커서 줄을 `scan_markdown_image_text`(표준·참조형·HTML·위키, 본문과 같은 해석·오류)로 스캔해 커서 열을 포함한 링크, 없으면 가장 가까운 링크. 코드 펜스 안은 제외. 오류(`not_found`/`unsupported`/`ambiguous`)·대상 없음·백엔드 없음(`vim.ui.img` 없음)·`neopp_images_enabled = false`는 탭을 열지 않고 `vim.notify`
- 표시: `tabnew`로 만든 `nofile`/`bufhidden=wipe`/`modifiable=false` 스크래치 버퍼(`rendermark_zoom`), 창 옵션(줄 번호·sign·fold 열·`wrap`·`cursorline` 등) 끔, `q`·`<Esc>`가 탭을 닫고 원래 탭으로 돌아감
- 크기 계산: 창 텍스트 영역(`getwininfo`의 `width - textoff`, `height`) × 셀 크기(`vim.g.neopp_cell_width_px/height_px`, 기본 10x18 — 본문 경로와 같은 기본값·클리핑 규약)를 픽셀로 바꾸고 `min(영역 너비/원본 너비, 영역 높이/원본 높이)` 배율로 맞춘 뒤 가운데 정렬. 원본 크기는 `size.lua`(`read_image_size`). **확대 한도 없음**: 요구가 "창에 꽉 차게"이고 래스터 확대는 GUI가 샘플링하기 때문(필요해지면 `zoom_fit`에 상한만 더하면 된다)
- 생명주기: 창 크기 변경(`VimResized`/`WinResized`, 탭·창 진입, `NeoppMetrics`)에 다시 맞추고 같은 배치는 다시 보내지 않음. 탭을 떠나면 `del`, 돌아오면 `set`. 탭·버퍼·창이 닫히면 이미지 id 정리(`BufWipeout`/`WinClosed`). 스텁이면 `draw_stub_preview_box`로 같은 사각형에 텍스트 박스
- **본문 경로와 섞지 않음**: `image/zoom.lua`는 `send_images`/payload/예약 extmark를 쓰지 않고 `vim.ui.img.set/del`을 자기 id(`rendermark:zoom:<버퍼>`)로 직접 부른다. 이 id는 `backend`의 live 집합에 없으므로 본문 동기화가 지우거나 다시 올리지 못한다(스펙 `survives a body sync in the zoom tab`). 문서 버퍼에 extmark·`changedtick` 변화가 없다(스펙). 따라서 공간 할당 불변(메모리 `project_stub_allocation_render_separation`)
- 검증: 신규 `tests/spec/rendermark/image/zoom_spec.lua` 45개(대상 선택·열/가까운 링크, 참조형·HTML·위키·다이어그램, 탭·버퍼 옵션·키맵, 가로·세로·작은 이미지 크기, 닫기·`del`, 탭 이동, 리사이즈, 알림, 명령·키맵 등록, 스텁). 전체 `bash run_tests.sh` 종료 0, 실패·오류 0, `Success` 줄 848(기준 803 + 45). `benchmark_image_reapply` 호출 수 R0와 같음(변경 없음 전부 0, 너비 변경 set 1000/mark 2000/clear 1000/redraw 1000). 실제 `init.lua`+스텁 헤드리스: 명령·`<leader>i` 등록, 스텁 저장소에 756x378 배치, `q`로 정리 확인
- 한계: 헤드리스라 화면에 그려진 모습(neopp)은 확인하지 못했다(M14). 위키 이름 검색 중이면(첫 스캔) 대상 없음 알림이 나가므로 잠시 뒤 다시 실행한다. 이미지 안에서 확대·이동은 없다(창에 맞춘 고정 배치)

**플러그인 정리 (6)**

- `lua/nvim_config/plugins.lua`: `weirongxu/plantuml-previewer.vim` 항목 제거. 그 `requires`였던 `tyru/open-browser.vim`은 저장소 어디에서도 쓰이지 않아(`grep` 결과 `plugins.lua` 한 줄뿐; 명령 `OpenBrowser*`·`PlantumlOpen` 사용 없음) 함께 제거
- `aklt/plantuml-syntax`는 단독 항목으로 유지, `cond = event({'FileType'}, {'plantuml'})` 그대로. 근거: 하이라이트·들여쓰기 전용이라 previewer(브라우저 미리보기)와 무관하고, 다이어그램 그림은 coderunner+rendermark가 맡으므로 소스 편집용 문법만 남는다
- 락/컴파일 파일: 플러그인 관리자는 pckr이고 저장소에 추적되는 락파일·`packer_compiled.lua`는 없다(`.gitignore`가 `packer_compiled.lua`를 제외). 갱신할 것 없음. 이미 설치된 디렉터리(`~/.local/share/nvim/site/pack/pckr/opt/{plantuml-previewer.vim,open-browser.vim}`)는 저장소 밖이라 건드리지 않았다. 필요하면 `:Pckr clean`으로 지운다
- README의 플러그인 목록 갱신. 헤드리스 기동 smoke(XDG 격리)와 `tests/spec/plugins*` 통과
- 발견(기존 문제, 이번 변경과 무관): nvim 0.12.4는 `.puml`/`.plantuml`/`.pu`/`.wsd`/`.iuml`을 `plantuml` 파일타입으로 감지하지 못하고, 감지(`ftdetect/plantuml.vim`)는 `opt/`에 있는 `plantuml-syntax`가 로드돼야 생긴다. 그런데 이 플러그인은 `FileType plantuml`에서 로드되므로 파일타입을 직접 지정(`:set ft=plantuml`)하기 전에는 문법 하이라이트가 켜지지 않는다. previewer를 지워도 상태는 같다(이전에도 같은 조건). 필요하면 `ft`/`BufRead` 조건이나 `vim.filetype.add`로 바꾼다 — 사용자 판단

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
| R1 임시 우회 제거 | 완료(GUI 중복 확인은 R8) | 2026-10-30 | 임시 우회 4곳 제거, mdloom 경로를 `vim.g.mdloom_dir`로 설정화, `complete/{image,link}`·`actions`·`rename`과 스펙 3개 삭제, cmp 소스 제거 확정. 전체 스펙 66개 파일 통과 681/0/0(696 − 삭제 스펙 18 + 신규 3). 완료 조건 grep 결과 없음. mdloom 확인: 체크아웃 `lsp-scope`에 그리기 코드 없음(`editors/nvim`은 `init.lua`뿐), 단 master에는 아직 `image.lua`·`images.lua` 등이 남아 있어 병합 전 master 사용 시 중복 그리기 |
| R2 스캔 범위 결정 | 완료 | 2026-10-30 | 노트 폴더 `~/notes`(md 207개) 조사: 표준 `![]()` 4개(png 3, svg 1)뿐이고 위키·HTML `<img>`·참조형 사용은 0(`keep`도 표준 27개뿐, 이미지 확장자 png/jpg). 구현 순서: 공통 기반(경로 쿼리·앵커/`<>`, 펜스 제외, 프리필터) → 참조형 → HTML → 위키 경로형 → 위키 이름형. 이름 검색 규모 위험은 노트 폴더에선 낮음(파일 251~1075, 이미지 3~29, 동명 0). 이상 징후: `scan.lua`에 펜스 코드블록 제외가 없어 R6의 "기존 규칙 유지"는 신규 구현이고, `size.lua`는 GIF·SVG 미지원 |
| R3 공급자 API·diagram.lua | 완료 | 2026-10-30 | `set_diagram_source`/`clear_diagram_source`/`refresh` 추가, `plantuml.lua`→`diagram.lua`(실행·캐시·임시 폴더·잡·jar·환경변수·"PlantUML disabled" 제거, `collect_diagram_images`), `blocks.lua` 삭제(`diagram_items`/`diagram_block_span`, `stable_hash`→`hash.lua`), place/preview/창 변수/오류 줄 개명, `deco`의 `diagram.disable_deco_langs`, `diagram.preview` 우선·`plantuml.preview` 경고 별칭. 신규 `diagram_spec` 19개 + `deco_spec` 1개, `init_spec` 재작성(스펙 2개 삭제). 전체 701 통과/0/0(67 파일, 종료 코드 0; R1 681 + 20), `tests/spec/rendermark` 260/0/0(11 파일). 벤치(5회 중앙값): 변경 없음 671.3 ms·호출 전부 0, 너비 변경 680.1 ms·set 1000/mark 2000/clear 1000/redraw 1000(R0 680.0/690.8 ms, 같은 호출 수). `grep plantuml_run\|plantuml_resolve\|plantuml_find_blocks\|PLANTUML_JAR lua` 결과 없음. 한계: `init.lua`의 `plantuml.preview` 사용자 설정은 R4까지 경고 한 번 발생, 닫히지 않은 펜스의 높이 예약은 이제 공급자(coderunner 파서)가 정한다 |
| R4 glue·사용자 설정 | 완료(GUI 확인은 R8) | 2026-10-30 | `nvim_config/markdown.lua`(`setup`, `deco_langs`), `init.lua`(`diagram.preview`, `disable_deco_langs`, `plantuml_cmd()`, `markdown.setup()`), `tests/spec/markdown_glue_spec.lua` 9개. `renderer_langs()`는 coderunner에 없어 `coderunner.resolve` 사용. 실제 plantuml로 PNG 렌더 확인 중 coderunner가 stdout 렌더러 출력을 UTF-8 정리해 PNG를 깨뜨리는 결함 발견·수정(`raw_stdout`, 스펙 1개). 전체 `bash run_tests.sh` 종료 코드 0, 실패·오류 0(스펙 줄 기준 R3 697 → 708). 한계: 워크스페이스 전용 렌더러 언어는 `disable_deco_langs`에 반영되지 않음, plantuml 명령은 시작 시 한 번 결정 |
| R5 인접 내보낸 이미지 정책 | 완료(GUI 확인은 R8) | 2026-10-30 | `diagram.lua`의 `diagram_exported_below`(블록 다음 빈 줄 0~1개 + 문단, 펜스·빈 줄에서 끝, 코드 스팬·원격 링크 제외), 옵션 `diagram.hide_when_exported`(기본 true), 판정은 `changedtick` 항목 캐시에 저장. 스펙 +15(전체 `bash run_tests.sh` 종료 0, 실패·오류 0, 스펙 줄 725). 벤치: `benchmark_image_reapply`(5회, `collect_diagram_images` 스텁이라 호출 수 불변) 변경 없음 670.0~693.5 ms·호출 전부 0, 너비 변경 677.6~701.9 ms·set 1000/mark 2000/clear 1000/redraw 1000; `benchmark_image_scan` 편집당 `send_images` 0.28 → 0.40 ms(블록 10개, 읽기는 블록당 31줄), 나머지 시나리오 불변·전체 읽기 0. 한계: 내보낸 이미지가 오래된 경우의 표시는 진단 몫(Q3) |
| R6 동등성 점검 | 완료(GUI 확인은 R8) | 2026-10-30 | R6-A: 동등성 표 확정(서브 이슈 S1~S3), 공통 기반(`%xx`·쿼리·앵커·`<…>`·title·tilde, 펜스 제외 `docindex.lua`), 참조형 이미지, GIF 크기, provider 오류 내성, 스텁 환경변수 값. 전체 `bash run_tests.sh` 종료 0, 실패·오류 0(스펙 줄 R5 725 → 759~762, 3회 실행에서 일부 기존 spec 출력 줄이 빠져 실행마다 ±3 변동하나 실패·오류는 0; 신규 `scan_spec` 39). 벤치: `benchmark_image_reapply`(5회) 변경 없음 중앙값 681.3 ms·호출 전부 0, 너비 변경 686.8 ms·set 1000/mark 2000/clear 1000/redraw 1000(R0와 같음); 스캔은 이미지가 보이는 문서의 편집당 +0.3 ms(3000줄)·+0.8 ms(8000줄), 이미지 없는 문서·스크롤·커서·변경 없는 `send_images`는 불변. R6-B: HTML `<img src>`(크기 속성 반영, 여러 줄 태그 미지원), 위키 이미지(경로형·이름형, `wikisearch.lua` 비동기 색인·캐시·`ambiguous` 박스), 프리필터 `has_image_candidate`. 신규 `html_wiki_spec` 38개, 전체 `bash run_tests.sh` 종료 0, 실패·오류 0(스펙 줄 802). 벤치: `benchmark_image_reapply`(5회) 변경 없음 중앙값 673.6 ms·호출 전부 0, 너비 변경 682.2 ms·set 1000/mark 2000/clear 1000/redraw 1000(R0와 같음); 이미지 없는 문서(HTML 텍스트 줄 포함) 불변, 이미지당 `send_images` 비용은 문법과 무관(약 0.06 ms) |
| R7 정리 | 완료 | 2026-10-30 | `docs/rendermark_image.md` 신설(공급자 계약·glue·설정 키·이미지 문법·경로·위키 검색·크기 형식·스텁), README·`coderunner.md`(`raw_stdout` 포함) 갱신, 낡은 주석 정정, 벤치·성능 문서를 `*_image_scan*`로 개명하고 머리말 메모, 이슈 "확인 필요" 닫기와 작업 노트 추가(closed 이동은 R8 후). grep 점검 결과는 호환 별칭·언어 기본값·픽스처·coderunner 렌더러 설정·과거 기록만 남음. 전체 `bash run_tests.sh` 종료 0, 실패·오류 0(스펙 줄 801~803) |
| R8 통합 검증 | 자동 검증 완료, 수동 확인 대기 | 2026-10-30 | 전체 `bash run_tests.sh` 종료 0, 실패·오류 0(`Success` 802 → 읽기 모드 스펙 추가 후 803; R0 696), `tests/spec/rendermark` 352/0/0(R0 259). 벤치 5회 중앙값: 변경 없음 672.0 ms·호출 전부 0, 너비 변경 679.6 ms·set 1000/mark 2000/clear 1000/redraw 1000(R0 680.0/690.8 ms, 호출 수 같음). 스캔 벤치는 R6-B 수치 범위. 실제 `init.lua` 헤드리스 스모크(XDG 격리, 스텁): 경고·오류 없음, plantuml `ready`/`failed`, Markdown 이미지 중복 0, 내보낸 이미지 인접 블록 숨김, 저장 시 갱신, coderunner 없이 Markdown 이미지 정상, mdloom `codeLensProvider` nil. 스펙 추가: 읽기 모드 창은 활성 블록 없음(`diagram_spec`). 발견: mdloom daemon 프로토콜 1 잔존(사용자 세션 종료 후 `mdloom daemon stop`), `mdloom` config.toml 경고 2건, `diagnostics=false`라 진단은 확인 시 임시 활성화 필요. 수동 체크리스트 M1~M13은 R8 절, 샘플은 `tests/manual/rendermark_manual.md`. 이슈는 수동 확인 뒤 사용자가 닫는다 |
| R9 후속 결정 반영 | 완료(GUI 확인 M14 대기) | 2026-10-30 | 사용자 결정 6건 반영. (1) 크기 속성 유지 기록, (2) 참조 정의 줄 conceal 요구를 "conceal 하지 않음"으로 사양 정정(코드 변경 없음), (3) S1 의도적 유지로 닫음, (4) S2 구현: `:RendermarkImageOpen`(Markdown 버퍼 `<leader>i`), `image/zoom.lua`(본문 경로와 분리, 새 탭에 창 가득 맞춤, 확대 한도 없음), 신규 `zoom_spec` 45개, (5) S3 열린 상태 유지, (6) `plantuml-previewer.vim`·`open-browser.vim` 제거, `plantuml-syntax` 단독 유지. 전체 `bash run_tests.sh` 종료 0, 실패·오류 0, `Success` 848(803 + 45). `benchmark_image_reapply` 호출 수 R0와 같음. 수동 체크리스트에 M14 추가 |
