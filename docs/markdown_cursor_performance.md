# Markdown 커서 이동 refresh 성능 비교

측정일: 2026-10-05. Neovim 0.12.4 / LuaJIT, Linux.

## 변경

- CursorMoved/CursorMovedI 는 `refresh_cursor()` 로 처리한다. 마지막 전체 렌더의 view key(버퍼, changedtick, 창 너비/높이, textoff, topline, leftcol, read mode, 이미지 활성, deco 폭)와 화면 안 외부 extmark 시그니처가 같을 때만 증분 경로를 탄다. 하나라도 다르면 전체 refresh 로 넘어간다.
- 같은 행 안의 이동은 아무것도 다시 그리지 않는다.
- 행이 바뀌면 이전/현재 커서 행만 다시 그린다. 그 행이 표 안이면 표 전체로 넓힌다. 직전 렌더로 줄 높이가 바뀌어 새로 보이게 된 행도 함께 그린다.
- deco 는 `render_range` 범위 밖에 mark 를 만들지 않는다. 그래서 부분 clear 후 다시 그려도 중복이 생기지 않는다.
- 코드 펜스를 지날 때의 즉시 repaint 는 화면 전체가 아니라 두 행만 다시 그린다.
- 커서 행에서 입력할 때(TextChangedI, 행 변화 없음)는 100 ms debounce 를 둔다. Enter 등으로 행이 바뀌면 바로 전체 refresh 한다.
- 증분 경로의 이미지 sync 는 다시 그린 행의 virt_lines 높이나 표 안 이미지 배치가 바뀐 경우에만 한다.

## 측정 1: Lua 처리 비용 (headless)

`tests/manual/benchmark_markdown_cursor.lua`. 5,016행 문서(제목, 긴 문단, 목록, 체크박스, 인용, 코드 블록, 표 반복), 140x48 창, 1201행부터 표시. autocmd 를 발생시킨 뒤 wrap 의 이중 지연 refresh 가 끝날 때까지 시간을 잰다. typing 은 highlighter 가 redraw 에서 하는 재파싱을 시계 밖에서 먼저 수행한다.

| 시나리오 | 수정 전 중앙값 | 수정 후 중앙값 | 수정 전 p95 | 수정 후 p95 | extmark 생성/단계 (전 → 후) |
| --- | ---: | ---: | ---: | ---: | ---: |
| j/k (60회) | 8.76 ms | 1.70 ms | 13.95 ms | 2.57 ms | 95.2 → 4.7 |
| l/h (60회) | 7.94 ms | 0.24 ms | 11.79 ms | 0.34 ms | 88.0 → 0 |
| 입력 1키 | 10.56 ms | 0.79 ms | 14.78 ms | 1.00 ms | 88.0 → 0 |
| 입력 20키 연속(30 ms 간격) wrap CPU | 230.0 ms | 15.8 ms | | | |
| 전체 refresh (참고) | 9.58 ms | 9.64 ms | 13.79 ms | 14.53 ms | 90 → 90 |

입력 1키의 0.79 ms 는 주로 `html.skip_hidden()` 비용이다. changedtick 이 바뀌면 HTML 스캔을 다시 하는데, 이 동작은 이번 변경 전부터 있었다.

## 측정 2: 실제 키 입력 (pty)

`script` pty 에서 `nvim --clean -u <rendermark만 로드하는 init>` 으로 같은 문서를 열고 키를 실제로 입력했다. 두 사용자 명령 사이의 `getrusage` CPU 를 쟀다. redraw 와 treesitter highlighter 비용도 포함된다. 3회 평균이다.

| 시나리오 | 수정 전 | 수정 후 | wrap 끔 (하한) |
| --- | ---: | ---: | ---: |
| j 30회 + k 30회 (80 ms 간격) | 1,751 ms | 721 ms | 53 ms |
| l 30회 + h 30회 | 1,831 ms | 100 ms | |
| insert 모드 40자 입력 (60 ms 간격) | 2,573 ms | 2,458 ms | 2,386 ms |

- j/k 에서 scheduled Lua 시간은 1,067 → 333 ms 였다. 나머지는 virt_lines 가 많은 화면의 redraw 와 highlighter 비용이다.
- 입력의 대부분은 편집마다 하는 markdown treesitter 재파싱(5,000행 기준 키당 약 60 ms)이다. wrap 을 꺼도 같으므로 wrap 이 줄일 수 있는 부분이 아니다.
- 남은 증분 경로 비용의 약 40% 는 `parser:parse({first, last})` 의 `LanguageTree:is_valid()` 다. 이 검사는 문서 전체의 injection region 수에 비례한다. 증분 경로에서 parse 를 생략해 보니 키당 약 1.7 ms 가 더 줄었다. 이번 변경에는 넣지 않았다.

## 검증

`tests/spec/rendermark_wrap_cursor_spec.lua` (9개). 커서 경로로 그린 결과를, 같은 내용과 같은 크기의 다른 창을 전체 refresh 한 결과와 extmark 단위로 비교한다.

- j/k 로 문서 전체를 왕복하며 매 단계 비교 (표, 코드 펜스, 체크박스, 인용, `<br>` 행 포함). 중간에 전체 refresh 없이 여러 단계를 이동한 뒤에도 비교.
- 같은 행 이동은 extmark 를 0개 만든다.
- 다른 행에 외부 hl extmark 가 생기면 전체 refresh 로 넘어간다.
- autocmd 없이 창 너비가 바뀐 경우(eventignore 상태의 vsplit)도 전체 refresh 로 넘어간다.
- 다른 창(float)이 같은 버퍼를 렌더한 뒤에도 전체 refresh 로 넘어간다.
- 이미지 sync 는 행 높이가 바뀐 이동에서만 한다.
- 커서 행 입력은 debounce 동안 렌더하지 않고 이후 전체 결과와 같다. 줄바꿈 입력은 바로 렌더한다.

mutation 확인: view key 에서 너비 제거, 이전 커서 행 생략, 외부 시그니처 무효화, 표 확장 생략, owner 검사 제거, deco clip 제거, debounce 제거를 각각 적용하면 해당 테스트가 실패한다.

전체 38개 테스트 파일, 459개 테스트 통과.

## 재실행

```sh
mkdir -p /tmp/md_base && git archive <before-commit> lua | tar -x -C /tmp/md_base
MD_BENCH_BASELINE=/tmp/md_base nvim --headless --clean -c "set lines=50 columns=140" -c "luafile tests/manual/benchmark_markdown_cursor.lua"
nvim --headless --clean -c "set lines=50 columns=140" -c "luafile tests/manual/benchmark_markdown_cursor.lua"
```
