# rendermark 작업 인계

기준일: 2026-10-30. 기존 계획서와 이미지·Markdown 성능 기록을 통합했다.
사용법과 공개 API는 [이미지 매뉴얼](../docs/rendermark_image.md)을 따른다.

## 현재 상태

- R1~R7, R9, S3 구현은 완료했다. R8의 Linux 자동 검증도 통과했다.
- Linux의 실제 TUI stub·neopp 확인을 완료했다. M15의 비동기 디코더 실패 전달 한계는 아래 결과와 구분한다. Windows 확인 전에는 작업 전체를 완료로 처리하지 않는다.
- coderunner도 Linux 자동·실도구·GUI·실제 신뢰 UI·mdloom 연결을 확인했고 Windows 검증이 남았다. 자세한 내용은 [coderunner 인계](coderunner.md)를 본다.
- mdloom은 `lsp-scope` / `802b9a5`로 다시 확인했다. Linux 빌드·자동 검사와 nvim_config 실통합은 통과했으며 Windows·MSRV·병합은 남았다.
- 기존 `.issues/open/issue-rendermark_all_drawing.md`의 요구와 결정은 이 문서에 통합했다. 다음 세션에서는 아래 수동 확인 결과와 이 문서의 완료 상태를 갱신한다.

## 유지할 결정

| 영역 | 결정 |
| --- | --- |
| 역할 | rendermark가 모든 이미지 표시를 맡고 coderunner가 렌더 실행·캐시·내보내기·진단을 맡는다. mdloom은 LSP만 담당한다. |
| 연결 | 두 모듈은 서로를 require하지 않는다. `lua/nvim_config/markdown.lua`만 연결한다. 공급자가 없으면 일반 이미지만 표시한다. |
| 다이어그램 | 비활성 블록은 이미지로 대체한다. 커서 진입 시 소스를 드러내고 float/split 미리보기를 연다. 읽기 모드에서는 소스를 드러내거나 미리보기를 열지 않는다. |
| 내보낸 이미지 | 블록 다음 빈 줄 0~1개 뒤 문단에 로컬 이미지 링크가 있으면 블록 이미지는 숨기고 소스를 둔다. `diagram.hide_when_exported=false`로 해제할 수 있다. |
| 이미지 문법 | 표준·참조형·HTML `<img>`·위키 이미지를 지원한다. 참조형 정의 줄은 conceal하지 않고 사용 위치만 숨긴다. |
| 크기 | HTML `width`/`height`와 위키 `\|숫자`를 반영한다. 한 줄 이미지의 합계 폭이 넘으면 같은 band 안에서 축소한다. 줄바꿈으로 바꾸지 않는다(S1). |
| 확대 보기 | `:RendermarkImageOpen`과 Markdown 버퍼의 `<leader>i`가 새 탭에서 종횡비를 유지하며 창에 맞춰 확대한다(S2). |
| 표시 실패 | 예약 높이와 소스 conceal을 유지하고 예약 첫 줄에 오류 문구를 표시한다(S3). 같은 리비전은 재시도하지 않는다. |

### 공급자 계약

`image.set_diagram_source({ items, request_live? })`로 등록한다.
항목은 `{ start_row, end_row, key, lang, path?, format?, stale, status, error? }`이며 행은 0 기반이다.
`status`는 `ready`, `pending`, `failed`, `none` 중 하나다.

- `items(buf)`는 현재 위치의 항목을 메모리에서 반환한다. rendermark는 `changedtick`과 `refresh(buf)`로 결과를 무효화하고 공급자 오류를 `pcall`로 격리한다.
- glue는 `coderunner.diagrams`와 `coderunner.request_live`를 등록한다. `User CodeRunnerDiagrams`의 `data.buf`로 `image.refresh(buf)`를 호출한다.
- 활성 블록의 `none` 또는 오래된 `ready`는 400ms 디바운스 후 live 렌더를 요청한다. 수락된 같은 틱·블록은 다시 요청하지 않는다. `pending`·`failed`는 자동 재요청하지 않는다.
- 비활성 블록의 `ready` 또는 `pending`+`stale`+`path`는 이미지를 표시한다. `failed`는 `[diagram: …]` 오류 줄을 표시한다. 크기를 읽을 수 없는 SVG 결과는 소스를 유지한다.
- `clear_diagram_source()`는 공급자를 해제한다. `refresh()`의 버퍼 생략은 전체 무효화다.

## 구현 위치와 주의점

| 위치 (`lua/nvim_config/` 기준) | 역할 |
| --- | --- |
| `markdown.lua`, 저장소 루트 `init.lua` | 공급자·이벤트 연결, 초기 렌더러 언어와 설정 조립 |
| `rendermark/image/diagram.lua` | 공급자 캐시, 활성 블록·인접 이미지 판정, live 요청·미리보기 |
| `rendermark/image/scan.lua`, `docindex.lua` | 이미지 문법·경로 해석, 펜스·참조 정의의 문서 색인 |
| `rendermark/image/wikisearch.lua` | 위키 이름의 비동기 검색·루트별 캐시 |
| `rendermark/image/place.lua`, `backend.lua`, `stub.lua` | 예약·배치·변경분 전송·표시 실패 박스 |
| `rendermark/image/zoom.lua` | 본문 예약과 분리된 새 탭 이미지 보기 |
| `lsp/servers/markdown.lua` | PATH의 mdloom 우선, `vim.g.mdloom_dir`의 개발 빌드 대체 경로 |

- `images=false`·`image.enabled` 임시 우회와 rendermark의 PlantUML 실행·임시 폴더·잡 관리는 제거했다. `plantuml.lua`는 `diagram.lua`로 바뀌었고 `blocks.lua`는 삭제했다.
- markdown-oxide 전용 `complete/`, `actions.lua`, `rename.lua`와 cmp 등록은 제거했다. `plantuml-previewer.vim`·`open-browser.vim`도 제거하고 문법용 `plantuml-syntax`만 남겼다.
- `diagram.preview`가 정식 설정이다. `plantuml.preview`는 한 번 경고하는 호환 별칭이다. 사용자 설정은 이미 새 키를 쓴다.
- `init.lua`는 `diagnostics=true`, `render_on_open=true`, split 미리보기·`size=0.20`·`lifecycle='cursor'`를 사용한다. mdloom의 LSP 전용 버전 연결 후 coderunner 진단을 활성화했다.
- `markdown.deco_langs()`는 setup 당시 렌더러 언어만 합친다. 나중에 로드한 워크스페이스 렌더러 언어는 코드 장식 제외 목록에 자동 반영되지 않는다.
- 위키 이름은 문서 폴더를 먼저 찾고 프로젝트 루트에서 검색한다. 동일 거리의 동명 파일은 모호성 오류다. 숨김·`node_modules`·`target`·심볼릭 링크 폴더를 건너뛰며 항목 20,000개·깊이 8이 상한이다. 저장·`BufEnter`가 캐시를 무효화하며 파일 감시는 없다.
- 실패 리비전은 이미지 경로·mtime·파일 크기·표시 크기다. 스크롤은 재시도 사유가 아니다. 파일·표시 크기 변경 또는 이미지 표시를 껐다 켜면 재시도한다. 새 실패가 있으면 같은 동기화에서 한 패스를 더 돌려 오류 박스를 그린다.

## 수동 수용 기준과 결과

샘플은 [rendermark_manual.md](../tests/manual/rendermark_manual.md)와 같은 폴더의 이미지 자산을 쓴다.
터미널에서는 `RENDERMARK_IMG_STUB=1 nvim tests/manual/rendermark_manual.md`로 시작한다.
실제 이미지는 neopp로 같은 파일을 연다. PlantUML이 실패하면 먼저 `java`·`plantuml` 실행 경로와 `PLANTUML_JAR`를 확인한다.

| 항목 | 샘플 | 통과 기준 |
| --- | --- | --- |
| M1 | (a) | mdloom 연결 유무와 무관하게 일반 이미지는 한 번만 표시되고 소스는 숨는다. mdloom의 `codeLensProvider`는 nil이다. |
| M2 | (b) | 표 셀·한 줄 여러 이미지가 정상이다. 폭 초과 시 함께 축소한다. 없는 파일·SVG는 오류 박스이고 코드 안 문법은 표시하지 않는다. |
| M3 | (b) | 한 줄·반 화면 스크롤과 화면 경계 클리핑에서 위치가 맞고 진동하지 않는다. |
| M4 | (b) | 분할 창은 독립적으로 표시·정리한다. 접기·펼치기·창 크기 변경·wrap 토글 후 위치가 맞는다. |
| M5 | (c) | 열 때 렌더되고 커서 진입 시 소스·미리보기가 나온다. 저장 후 갱신되고 블록을 벗어나면 닫힌다. preview 토글도 동작한다. |
| M6 | (d) | 실패 블록은 소스와 오류 줄을 유지하고 `render-failed`가 보인다. 코드 수정·저장과 `:CodeRender!`로 회복한다. |
| M7 | (e) | 인접 링크는 블록 이미지를 숨긴다. 빈 줄 2개면 둘 다 표시한다. 임시 문서에서 `:CodeExport` 후에도 중복되지 않는다. |
| M8 | (f) | glue setup을 임시 해제해도 시작 오류 없이 일반 이미지가 표시된다. 다이어그램 이미지는 없다. |
| M9 | (g) | `<Space>r` 읽기 모드에서는 블록 안 커서도 이미지 상태를 유지하고 미리보기를 열지 않는다. 해제하면 복구된다. |
| M10 | (h) | 참조·HTML·위키 이미지와 크기가 맞는다. 정의 줄은 남고 이름 검색 완료 후 이미지가 나타난다. 없는 이름은 오류 박스다. |
| M11 | (i) | Windows neopp에서 M1·M3·M5와 드라이브 절대 경로·역슬래시·슬래시·공백 경로를 확인한다. |
| M12 | (c), 스텁 | 비활성 이미지 대체·활성 미리보기·텍스트 박스를 기록한다. 회귀 비교가 필요하면 기준 커밋 `07ab9fa`를 별도 worktree로 사용한다. |
| M13 | (c) | 실제 neopp에서 저장→렌더→이벤트→이미지 갱신을 확인하고 체감 지연을 적는다. |
| M14 | (j) | `<leader>i`로 선택한 일반·다이어그램 이미지가 새 탭을 채운다. 크기 변경·탭 이동·q/Esc 정리가 맞고 오류 대상은 탭 없이 알림만 낸다. |
| M15 | (k) | 손상 PNG가 표시 거부되면 같은 예약 높이에 오류가 뜨고 뒤 글이 움직이지 않는다. 정상 파일로 교체하면 회복하고 다른 이미지는 영향이 없다. |

M15에서 GUI가 손상 파일을 받아들이면 스텁에서 `vim.ui.img.set = function() error('boom') end`로 실패를 만들고 분할해 확인한다.
샘플이나 설정을 임시 수정했다면 자신의 변경만 되돌린다. 현재 작업 전체를 checkout/restore하지 않는다.

| 확인일 | 항목 | 환경 | 결과·메모 |
| --- | --- | --- | --- |
| 2026-10-30 | M1~M10·M12·M14 | Linux 실제 init + TUI stub | source/modified 불변, 문법·크기·공동 축소·표·스크롤/클리핑·split/fold/resize/wrap/버퍼 전환, 실제 PNG 자동 렌더·활성 미리보기·저장 갱신·실패 복구·인접 export 억제·빈 줄 2개·읽기 모드·공급자 해제·확대 탭/q/Esc/resize/탭 전환 통과 |
| 2026-10-30 | M15 | Linux TUI stub, 제공자 거부 주입 | 오류 박스·예약 높이·뒤 문장 화면 행 유지, 같은 리비전 재시도 0, 파일 변경 후 회복 통과 |
| 2026-10-30 | M1~M10·M13·M14 | Linux Xvfb + 실제 neopp | 실이미지와 키 입력·스크린샷 확인. 반 화면 스크롤·공급자 해제·확대 resize/Esc도 추가 확인. 저장→렌더→이벤트 2회→화면 갱신 약 1.187초는 단일 관찰값 |
| 2026-10-30 | M15 | Linux 실제 neopp | 손상 PNG의 비동기 디코더 실패는 Lua에 전달되지 않아 빈 예약 공간. 정상 파일 교체 후 표시 회복. 실제 GUI 오류 박스·동일 높이 회복 통과가 아님 |
| 미실행 | M11 및 Windows 전체 | Windows stub / neopp | 사용자가 [W5·W6](../../markdown_lsp/doc/manual-test.md#현행-windows-검증-순서-w1w8)에서 확인 예정 |

실제 TUI stub은 `RENDERMARK_IMG_STUB=1`이고, neopp는 이 변수를 해제한 실제 `vim.ui.img`였다. 일반/표 이미지의 배치 안정화 후 10회 동기화에서 `set=0`, 스크롤 후 20회 동기화에서 viewport/payload가 안정적이었다. 기존 표 중복 전송 관찰은 이번 조건에서 재현되지 않았으며 수정 완료라는 뜻은 아니다.

실도구는 JDK21 PATH·`RENDERMARK_PLANTUML_JAR=/usr/share/java/plantuml/plantuml.jar`·`JAVA_TOOL_OPTIONS=-Djava.awt.headless=true`를 명시했다. 현재 기본 wrapper는 Java 경로 문제로 동작하지 않으므로, 환경 지정 없이 통과한 결과로 읽지 않는다. neopp의 비동기 PNG 거부는 `vim.ui.img.set`의 동기 오류가 아니어서 S3 오류 박스로 바뀌지 않았다. 교체 이미지 크기가 달라 예약 높이도 5→7로 바뀌었으므로 M15의 높이 보장은 stub 주입 결과로만 기록한다.

미리보기 생성 후 `vim.v.errmsg`에 조용한 `E31: No such mapping`이 남았지만 화면/messages와 기능 실패는 없었다. ftplugin의 `sil! unmap` 경로가 후보이며 원인은 확정하지 않았다. Windows 결과와 남은 한계를 기록한 뒤 이 문서와 [coderunner 인계](coderunner.md)의 전체 완료 여부를 판단한다.

## 자동 검증 기록과 재실행

2026-10-30 통합 작업에서는 전체 unit 866개·TUI 통합 11개가 실패·오류 0으로 통과했다. 아래 성능 및 S2/S3 수치는 그 이전 작업 기록이다.
Linux·Neovim 0.12.4에서 S3까지 전체 테스트는 종료 0, 실패·오류 0이었다.
마지막 `Success` 출력은 863줄이며 일부 기존 워커의 요약 누락으로 실행마다 약 3줄 차이가 있었다.
S2의 `zoom_spec` 45개와 S3의 `display_failure_spec` 17개가 추가됐다.
실제 init+스텁 smoke는 일반 이미지 중복 없음, ready/failed·저장 갱신·인접 이미지 억제·coderunner 없는 동작을 확인했다.
실제 mdloom initialize에서 `codeLensProvider=nil`도 확인했다. GUI 그림은 확인하지 않았다.

```sh
bash run_tests.sh
bash run_tests.sh tests/spec/rendermark
bash run_tests.sh tests/spec/markdown_glue_spec.lua
nvim --headless -u NONE -l tests/manual/benchmark_image_reapply.lua
BENCH_PROVIDER=1 nvim --headless -u NONE -l tests/manual/benchmark_image_scan.lua
BENCH_IMAGES=1 BENCH_LINES=8000 nvim --headless -u NONE -l tests/manual/benchmark_image_scan.lua
BENCH_NOISE=1 nvim --headless -u NONE -l tests/manual/benchmark_image_scan.lua
nvim --headless --clean -c "set lines=50 columns=140" -c "luafile tests/manual/benchmark_markdown_cursor.lua"
nvim --headless -u tests/minimal_init.lua -l tests/manual/benchmark_markdown_html.lua
```

### 성능 기준

측정 시간은 환경과 부하에 따라 변한다. 같은 조건의 반복 측정과 호출 수로 회귀를 판단한다.
기존 측정은 Linux·Neovim 0.12.4/LuaJIT에서 수행했다. 커서·HTML은 2026-10-05, 공급자 전환 이후 이미지 기준은 2026-10-30 기록이다.

| 대상 | 보존할 기준·결론 |
| --- | --- |
| 이미지 변경분 전송 | 1,000회 호출에서 변경 없음은 set/mark/clear/redraw/del 모두 0. 이미지 하나 너비 변경은 1000/2000/1000/1000/0. S3 이후도 같으며 중앙값은 약 678/683ms였다. GUI RPC·파일 읽기는 스텁이므로 실제 표시 시간은 아니다. |
| 이미지 문서 색인 | 이미지가 보이는 문서는 편집 틱마다 펜스·참조 정의용 전체 읽기 1회. 스크롤·커서·변경 없는 호출은 색인을 재사용한다. R6-A에서 편집 비용 증가는 3000행 약 0.3ms, 8000행 약 0.8ms였다. |
| 스캔 확대 | R6-B의 이미지 9개 조건에서 변경 없는 호출 약 0.56~0.59ms, 편집당 3000행 0.85ms·8000행 1.35ms. 이미지 없는 문서는 약 0.08~0.10ms로 유지됐다. 위키 디렉터리 탐색 비용은 이 벤치에 포함되지 않는다. |
| 공급자 조회 | 편집·refresh 뒤 한 번 호출하고 변경 없는 send_images·커서·스크롤은 재사용한다. 과거 PlantUML 자체 스캔의 개선 배수는 현재 구조에 적용하지 않는다. |
| 커서 refresh | 2026-10-05의 5016행 headless 기준 j/k 중앙값 8.76→1.70ms, l/h 7.94→0.24ms, 입력 1키 10.56→0.79ms. 전체 refresh는 약 9.6ms로 같았다. 실제 pty 입력 지연은 Tree-sitter 재파싱 비중이 커서 개선이 작았다. |
| HTML refresh | 편집당 전체 읽기 2→1회. `<`가 없으면 parser 요청 1→0회. 50000행 중앙값 plain 483→2.9ms, sparse 461→394ms, dense 2186→1143ms였다(2026-10-05). HTML 단독 비용이며 실제 입력 지연은 아니다. |

커서 증분 경로는 view key·외부 extmark 서명이 같을 때만 이전/현재 행을 다시 그린다.
표는 표 전체로 확장하고 같은 행 이동은 그리지 않는다. 같은 행 입력은 100ms 디바운스, 줄바꿈은 즉시 전체 refresh한다.
HTML은 표시 범위만 장식하되 접힌 details의 숨김 마크는 화면 밖에도 유지한다.
HTML이 있는 문서의 전역 파싱·스캔과 입력 시 Tree-sitter 재파싱 비용은 남아 있다.

## 확인된 한계와 다음 세션 주의사항

- 여러 줄 `<img>`와 여러 줄 HTML 주석 내부의 이미지 제외는 지원하지 않는다. 위키 너비 표기와 표 셀 분할의 상호작용도 아직 별도 회귀 스펙이 없다.
- PNG/JPEG/WebP/GIF만 크기를 읽는다. SVG·BMP 등은 unsupported다. 표 셀·미리보기 float의 표시 실패는 경고와 재시도 억제만 하고 박스를 만들지 않는다.
- 같은 크기 파일의 mtime만 바뀌면 실패 항목은 재시도하지만 이미 성공한 같은 payload는 다시 보내지 않는다. 확대 탭의 실패 처리도 본문 경로와 분리돼 있다.
- 위키 이름을 찾는 첫 비동기 검색 중 확대 명령을 실행하면 대상 없음 알림이 날 수 있다. 검색 후 다시 실행한다. 확대 탭에는 추가 확대·이동 조작이 없다.
- `.puml` 등 파일타입을 모르는 상태에서는 `plantuml-syntax`의 `FileType plantuml` 지연 로드가 시작되지 않는 기존 문제가 있다. 별도 작업 결정 전에는 변경하지 않는다.
- 이전 확인에서 mdloom 프로토콜 1 daemon이 남아 있었다. 같은 문제가 재현되면 열린 사용자 세션 종료 후 `mdloom daemon stop`을 고려한다. 실행 중 세션을 임의 종료하지 않는다.
- mdloom 전역 config의 옛 runners/renderers를 실제로 확인하고 제거했다. `[links] scope="filesystem"`은 유지했다. 별도 legacy workspace에서는 경고만 나오고 CLI/LSP가 정상인 것도 확인했다.
