# 이미지 변경분 적용 성능 비교

`issue-image_send_images_full_reapply.md` 수정 전 HEAD와 수정 후 코드를 동일한 headless Neovim에서 비교했다. 각 시나리오에서 `send_images()`를 1,000회 호출하고, 별도 프로세스로 5회 실행한 시간의 중앙값을 사용했다.

벤치마크는 20개 이미지의 스캔 결과를 고정하며, 화면에 배치된 이미지는 10개다. 실제 파일 읽기와 GUI RPC는 스텁으로 대체했다. 측정 시간은 Lua 및 Neovim API 처리 시간이며 실제 GUI 렌더링 시간은 포함하지 않는다.

| 시나리오 | 수정 전 | 수정 후 | 차이 |
| --- | ---: | ---: | ---: |
| 변경 없음 | 693.90 ms | 683.90 ms | 1.4% 감소 |
| 이미지 하나의 너비 변경 | 691.91 ms | 700.20 ms | 1.2% 증가 |

시간 차이는 작으며 Lua 실행 성능 개선으로 판단하기 어렵다. 주요 효과는 불필요한 GUI 전송과 extmark 갱신 제거다.

| 1,000회 누적 호출 | 변경 없음: 전 → 후 | 이미지 하나 변경: 전 → 후 |
| --- | ---: | ---: |
| `vim.ui.img.set` | 10,000 → 0 | 10,000 → 1,000 |
| extmark 생성 | 20,000 → 0 | 20,000 → 2,000 |
| namespace clear | 1,000 → 0 | 1,000 → 1,000 |
| `force_redraw` | 1,000 → 0 | 1,000 → 1,000 |

부분 변경의 clear는 기존 버퍼 전체 삭제에서 변경된 행 삭제로 바뀌었다. 버퍼 텍스트가 편집되면 extmark가 이동할 수 있으므로 해당 버퍼의 캐시를 무효화하고 재생성한다. 예약 높이가 바뀌는 경우 기존의 레이아웃 안정화 후 재동기화 동작을 유지한다.

재현:

```sh
nvim --headless -u NONE -l tests/manual/benchmark_image_reapply.lua
```

수정 전 비교는 `/tmp` 아래에 수정 전 `lua/rendermark/image.lua`와 `lua/rendermark/image/backend.lua`를 같은 디렉터리 구조로 저장하고 `IMAGE_BENCH_BASELINE`을 그 루트로 지정한다. 나머지 모듈은 현재 저장소에서 읽는다.

검증: `bash run_tests.sh` 전체 통과. 추가 회귀 테스트는 동일 행의 extmark ID 유지, 변경 행 갱신, 편집에 따른 이동, 제거된 행 정리, 이미지 변경·삭제·재등록 및 redraw 생략을 확인한다.
