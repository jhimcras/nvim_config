# Markdown HTML refresh 성능 비교

측정일: 2026-10-05. Neovim 0.12.4 / LuaJIT, Linux headless 환경.

## 변경

- 버퍼 전체 줄 읽기를 편집당 2회에서 1회로 통합하고 표의 줄도 같은 스냅샷을 사용한다.
- `<`가 없는 문서는 Tree-sitter 파싱, 코드/표 쿼리, details 스캔을 생략한다.
- wrap의 visible segments 안에서만 HTML 제목, 스타일, summary, br 장식을 만든다.
- 변경 없는 스크롤에서도 표시 범위를 비교하여 이전 장식을 제거하고 새 범위를 그린다.
- 화면 밖 표 행의 br 정보는 요청 시 장식 생성 없이 계산한다.
- 접힌 details의 conceal_lines는 화면 밖에도 유지한다. 실제로 본문이 숨겨져야 화면 범위와 커서 이동이 올바르게 계산된다. 범위/커서만 바뀌면 이 숨김 마크는 다시 만들지 않는다.

## 측정 조건

`tests/manual/benchmark_markdown_html.lua`로 수정 전 HEAD의 html.lua와 수정 후 모듈을 각각 실행했다. 각 문서를 한 번 렌더링한 다음 첫 행을 25회 편집했다. 각 편집 직후 `html.refresh()`만 측정했고 편집 API와 사전 GC 시간은 제외했다. 수정 후 표시 범위는 20행이며 수정 전은 전달된 범위 인자를 무시하고 전체를 페인트한다. 중앙값은 정렬된 13번째, p95는 24번째 샘플이다.

- plain: 모든 행이 일반 텍스트.
- sparse: 1,000행마다 한 행에 `<mark>`와 `<br>`.
- dense: 첫 편집 행을 제외한 모든 행에 `<mark>`와 `<br>`.

실제 Markdown Tree-sitter 파서를 사용하며 파서를 모킹하지 않는다. 수치는 전체 wrap refresh나 실제 키 입력 지연이 아니라 HTML refresh 단독 비용이다.

## 결과

| 문서 | 행 수 | 수정 전 중앙값 (ms) | 수정 후 중앙값 (ms) | 감소율 | 수정 전 p95 (ms) | 수정 후 p95 (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| plain | 1,000 | 7.017 | 0.089 | 98.7% | 13.418 | 0.139 |
| plain | 10,000 | 89.620 | 0.571 | 99.4% | 94.990 | 0.613 |
| plain | 50,000 | 483.293 | 2.896 | 99.4% | 500.827 | 3.219 |
| sparse | 1,000 | 6.907 | 5.670 | 17.9% | 7.831 | 6.437 |
| sparse | 10,000 | 89.946 | 72.337 | 19.6% | 92.557 | 79.092 |
| sparse | 50,000 | 461.041 | 393.656 | 14.6% | 476.208 | 415.652 |
| dense | 1,000 | 34.907 | 18.919 | 45.8% | 35.293 | 21.024 |
| dense | 10,000 | 401.501 | 208.370 | 48.1% | 404.434 | 216.421 |
| dense | 50,000 | 2186.167 | 1143.202 | 47.7% | 2236.037 | 1168.718 |

전체 읽기는 모든 사례에서 편집당 2회 → 1회, parser 요청은 plain에서 1회 → 0회였다. sparse/dense에서는 parser 요청이 1회로 유지됐다.

`<`가 있는 문서는 details와 코드 블록의 전역 문맥을 위해 전체 파싱/스캔을 유지하므로 편집 비용이 여전히 문서 크기에 비례한다. 이번 변경은 증분 파싱 구현이 아닌, HTML 없는 문서의 빠른 경로와 표시 범위 페인트 방식이다. 큰 접힌 details는 편집 후 숨김 마크 재생성 비용도 남는다.

## 검증

전체 35개 테스트 파일, 436개 테스트 통과(실패/테스트 오류 0). HTML 테스트 14개에는 표시 범위 변경, br 커서 행 전환, 읽기 횟수와 parser 생략, 화면 밖 표의 br, details 숨김 유지와 태그 삭제 회귀 검증이 포함된다.

## 재실행

```sh
# 비교 대상 수정 전 커밋의 파일을 /tmp에 저장한다.
git show <before-commit>:lua/rendermark/html.lua > /tmp/markdown_html_original.lua

NVIM_LOG_FILE=/tmp/markdown_benchmark.log nvim --headless -u tests/minimal_init.lua -l tests/manual/benchmark_markdown_html.lua /tmp/markdown_html_original.lua
NVIM_LOG_FILE=/tmp/markdown_benchmark.log nvim --headless -u tests/minimal_init.lua -l tests/manual/benchmark_markdown_html.lua
```
