# 마크다운 코드 블럭 폭 계산 오류

1. 현황
코드블럭에 tab(\t)가 포함되어 있는 경우 폭이 잘못 계산 됨.

2. 원인
lua/rendermark/deco.lua 의 dw() 가 vim.fn.strdisplaywidth(s) 를 시작 컬럼 없이 호출함.
탭 폭은 그 탭이 놓이는 화면 컬럼에 따라 달라지는데, 코드 본문은 화면 컬럼 0 이 아니라
indent_w + pad (블럭 들여쓰기 + 왼쪽 inline 패딩) 에서 시작함.
그래서 탭이 포함된 줄은 폭이 잘못 계산되어 블럭이 필요보다 넓어지고 오른쪽 fill 도
어긋나 배경 사각형이 닫히지 않음.

3. 해결
dw(s, col) 로 시작 컬럼을 받게 하고, row_geom() 이 본문 폭을
dw(line:sub(start + 1), indent_w + pad) 로 계산하도록 수정.
tests/spec/rendermark_deco_spec.lua:
- code_row_width() 헬퍼도 실제 그려지는 컬럼 기준으로 폭을 재도록 수정
  (extmark 순서에 의존하지 않게 lead/text/fill 분리)
- 'measures a tab in a code line from the column it is drawn at' 테스트 추가
전체 스위트 통과. 실제 화면(pty)에서도 탭 포함 코드블럭의 오른쪽 경계가 일치함을 확인.
