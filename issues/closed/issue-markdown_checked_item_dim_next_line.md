# 마크다운 체크된 항목 아래 줄의 dimming 오류

1. 현황
체크된 체크박스 항목의 dimming 구현(569d6d8) 이후, 같은 깊이의 다음 항목이
잘못 dim 처리됨.

재현 예시
- [ ] Test
    - [x] sub1
    - [ ] sub2

2. 목표
체크된 항목 자체(wrap 된 행과 실제 하위 목록 포함)만 dim 되고 다음 형제 항목은
영향받지 않도록 수정.

3. 원인
Tree-sitter markdown parser가 4칸 들여쓴 다음 목록 항목을 앞의 `list_item` 노드
범위에 포함하는 경우가 있으며, dimming 코드가 그 노드의 전체 행 범위를 그대로
사용해 다음 형제 항목에도 `Comment` highlight를 적용했음.

4. 해결
체크된 항목 이후 같은 깊이 또는 바깥 깊이의 목록 marker를 만나면 dimming을
중단하도록 수정. 실제로 더 깊게 중첩된 하위 목록은 기존처럼 dim 처리됨.
`tests/spec/rendermark_deco_spec.lua`에 재현 예시 회귀 테스트를 추가했으며 전체
테스트 스위트 통과.
