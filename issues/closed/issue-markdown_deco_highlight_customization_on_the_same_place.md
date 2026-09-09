# 마크다운 하이라이트 값 설정 모음

1. 현황
마크다운의 하이라이트 값을 설정 할 수 있는 특수 인터페이스는 없음

2. 목표
deco 코드 상단에 마크다운 하이라이트 값을 설정 코드를 모아 놓고 사용자가 설정 할 수 있도록 함.
3. 작업 노트
- `lua/rendermark/deco.lua` 상단 `defaults`에 `highlight` 테이블 신설. 이 모듈이 쓰는 모든 그룹
  (`RendermarkHeading/Rule/Quote/Bullet/Unchecked/Checked/Code/CodeInfo`, `@markup.heading.1..6.markdown`)을
  한 곳에 모음. 값은 `nvim_set_hl` 스펙, 또는 콜러스킴에서 파생해야 하는 경우 함수
  (`RendermarkCode`, `RendermarkCodeInfo` — `Normal` 음영은 상단 `code_bg()` 헬퍼로 분리).
- 하단 `define_highlights()`는 이제 `config.highlight`를 순회하며 적용만 함 (함수면 호출).
  `ColorScheme` 자동명령 재적용 동작은 그대로.
- `M.setup`에서 highlight 항목만은 deep merge가 아니라 그룹 단위 통째 교체.
  기본값이 `{ link = 'Comment' }`인 그룹에 `{ fg = ... }`만 주면 link가 남아 이기기 때문.
- 사용법:
      require('rendermark').setup {
        highlight = { RendermarkQuote = { fg = '#7aa2f7' } },
      }
