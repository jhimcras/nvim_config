# rendermark 이미지·다이어그램 그리기

`lua/nvim_config/rendermark/image/`가 Markdown 버퍼의 이미지와 다이어그램을 모두 그린다.
그리기는 extmark와 `vim.ui.img`(neopp GUI)뿐이라 버퍼 내용은 바뀌지 않는다.
설계 결정, 검증 현황과 성능 측정은 [작업 문서](../.refactoring_docs/rendermark.md)에 있다.

## coderunner와의 경계

| 담당 | 하는 일 |
| --- | --- |
| rendermark | 이미지 문법 스캔, 경로 해석, 크기 읽기, 자리 예약, 소스 숨김, 배치, 활성 블록 미리보기 |
| coderunner ([coderunner.md](coderunner.md)) | 다이어그램 블록 파싱, 렌더 실행(plantuml 등), 캐시, 내보내기, 진단 |
| glue `lua/nvim_config/markdown.lua` | 둘을 잇는 유일한 곳 |

rendermark와 coderunner는 서로를 `require`하지 않는다. 한쪽이 없거나 꺼져도 다른 쪽은 영향이 없다
(coderunner가 없으면 공급자가 없어 다이어그램 항목이 없고 Markdown 이미지만 그린다).
mdloom 플러그인도 이미지를 그리지 않는다.

### 공급자 계약

```lua
local image = require('nvim_config.rendermark.image')
image.set_diagram_source({
    items = function(buf) return {} end,      -- DiagramItem[] (필수)
    request_live = function(buf, row) end,    -- 선택. 활성 블록의 렌더 요청, 수락하면 true
})
image.refresh(buf)          -- 공급자 결과가 바뀌면 호출. buf 생략 시 전체
image.clear_diagram_source()
```

`DiagramItem` = `{ start_row, end_row, key, lang, path?, format?, stale, status, error? }`
(0 기반 행, `status`는 `ready`/`pending`/`failed`/`none`).
`items(buf)`는 메모리 조회만 해야 한다. rendermark는 `changedtick`과 `refresh`를 기준으로 결과를 캐시하고
`pcall`로 보호하므로, 편집이 없으면 공급자를 다시 부르지 않는다.

glue는 `coderunner.diagrams`/`coderunner.request_live`를 공급자로 등록하고
`User CodeRunnerDiagrams`(`data.buf`)에서 `image.refresh(buf)`를 부른다.
또 `M.deco_langs()`로 렌더러 `match` 언어를 `diagram.disable_deco_langs`에 합쳐 넘긴다
(`init.lua`의 `rendermark.setup` 인자). 워크스페이스 설정으로 나중에 로드되는 렌더러의 언어는 따라가지 않는다.

### 다이어그램 표시 규칙

- 비활성 블록: `ready`(또는 `pending`+stale+path)이면 소스를 이미지로 대체한다(블록 높이 예약, 소스 conceal).
  `failed`는 블록 끝에 `[diagram: <오류>]` 줄, `none`/`pending`은 소스 그대로.
- 활성 블록(커서가 블록 안): 소스를 보여 주고 미리보기를 float/split으로 연다. 미리보기가 필요한데 렌더가
  없거나 오래됐으면 400ms 디바운스 후 `request_live`를 부른다. 읽기 모드에서는 열지 않는다.
- 내보낸 이미지: 블록 끝 아래로 빈 줄 0~1개 뒤 문단에 이미지 링크가 있으면 그 블록의 이미지는 그리지 않고
  소스를 둔다(링크 이미지가 표시를 맡는다). 실패 오류 줄은 유지한다.
- SVG 결과는 크기를 읽을 수 없어 이미지로 그리지 않고 소스를 그대로 둔다.

### 설정 키 (`rendermark.setup{ diagram = ... }`)

| 키 | 기본 | 설명 |
| --- | --- | --- |
| `diagram.preview` | `mode='float'` 등 | 활성 블록 미리보기. `mode`(`float`/`split`), `auto`, `split.size`(비율 <1, 칸 수 >=1, `'half'`), `split.position`/`lifecycle`(`cursor`/`persistent`). 구 키 `plantuml.preview`는 경고 한 번 후 수용하는 호환 별칭 |
| `diagram.disable_deco_langs` | `plantuml`, `puml`, `uml` | 코드블록 장식을 끄는 펜스 언어. 사용자 목록은 기본 목록을 대체(glue가 렌더러 언어를 합쳐 줌) |
| `diagram.hide_when_exported` | `true` | 위 "내보낸 이미지" 규칙. `false`면 항상 블록 이미지를 그림 |

명령: `:RendermarkPreviewShow`, `:RendermarkPreviewHide`, `:RendermarkPreviewToggle`.

## 이미지 확대 보기 (`:RendermarkImageOpen`)

본문 이미지는 줄 높이로 그려지므로 작게 보일 수 있다. `:RendermarkImageOpen`(Markdown 버퍼의 `<leader>i`)은
커서가 있는 이미지를 **새 탭**에 창이 꽉 차도록(종횡비 유지, 창에 맞는 최대 크기, 가운데 정렬) 보여 준다.
`q` 또는 `<Esc>` 로 탭을 닫으면 이미지도 지워지고 원래 탭으로 돌아온다.

| 커서 위치 | 여는 이미지 |
| --- | --- |
| 다이어그램 블록 안(활성 블록 포함) | 그 항목이 `ready` 이면 렌더된 이미지(공급자 항목의 `path`). `pending`/`failed`/`none`과 SVG는 알림 |
| 이미지 링크가 있는 줄 | 표준·참조형·HTML `<img>`·위키 모두. 한 줄에 여러 개이면 커서 열을 포함한 링크, 없으면 가장 가까운 링크 |
| 그 밖 | `rendermark: no image under the cursor` 알림 |

없는 파일(`not_found`), 크기를 못 읽는 형식(`unsupported`), 모호한 위키 이름(`ambiguous`), 원격 이미지, 이미지 백엔드
(`vim.ui.img`) 없음, `vim.g.neopp_images_enabled = false` 는 탭을 열지 않고 `vim.notify` 로 알린다.
코드 펜스 안의 이미지 문법은 본문과 같이 이미지로 보지 않는다.

- 크기: 창 텍스트 영역(셀 수 x `neopp_cell_width_px`/`neopp_cell_height_px`)을 픽셀로 바꾸고 원본 크기(`size.lua`)와
  비교해 `min(창 너비/원본 너비, 창 높이/원본 높이)` 배율로 맞춘다. 창보다 작은 이미지도 꽉 차게 **확대**한다
  (한도 없음: 요구가 "창에 꽉 차게"이고, 해상도는 GUI 가 다시 샘플링한다). 창 크기가 바뀌면
  (`VimResized`/`WinResized`, 탭·창 진입, `NeoppMetrics`) 다시 계산하고 배치가 같으면 다시 보내지 않는다.
- 탭 버퍼는 `nofile`/읽기 전용 스크래치(`rendermark_zoom`)이고 줄 번호·sign·fold 열·줄 바꿈을 끈다. 다른 탭으로 가면
  이미지를 내리고(`vim.ui.img.del`) 돌아오면 다시 올린다. 탭·버퍼가 닫히면 이미지 id를 지운다.
- 본문 그리기와 분리돼 있다(`image/zoom.lua`): 문서에 extmark·공간 예약을 만들지 않고 `send_images`/payload 경로를
  지나지 않으며, `vim.ui.img.set/del` 을 자기 id(`rendermark:zoom:<버퍼>`)로 직접 부른다. `RENDERMARK_IMG_STUB=1`
  이면 같은 사각형에 텍스트 박스를 그린다.

## 지원하는 이미지 문법

| 문법 | 비고 |
| --- | --- |
| `![alt](path)` | `"title"`, `<path with spaces>`, 균형 잡힌 괄호 경로 허용. 한 줄 여러 개, 표 셀 안 가능 |
| 참조형 `![alt][ref]`, `![ref][]`, `![ref]` | 같은 문서의 `[ref]: path` 정의만. 대소문자·공백 무시, 정의가 없으면 그리지 않음, 정의 줄은 그대로 둠 |
| HTML `<img src="…">` | 한 줄 안에서 닫힌 태그만. `width`/`height`(px)를 표시 너비에 반영. 여러 줄 태그는 미지원 |
| 위키 `![[name.png]]`, `![[dir/name.png]]`, `![[name.png\|300]]`, `![[name.png#h]]` | 이미지 확장자만(`png jpg jpeg gif webp svg bmp avif`). `\|숫자`는 너비 |

코드 스팬·펜스 코드블록 안, HTML 주석(같은 줄) 안의 문법은 제외한다. 원격(`scheme://`)과 `data:`는 그리지 않는다.
이미지가 있는 줄은 wrap이 감싸지 않는다.

### 경로 규칙

- 문서 폴더 기준 상대 경로, 절대 경로(Windows 드라이브·`\` 포함), `~`/`~/…` 확장.
- `%xx` 디코딩, `?query`·`#anchor` 제거, `<…>` 벗기기. 실제 파일이 그 문자를 포함하면 있는 그대로의 이름이 우선(`C#.png`).

### 위키 이름 검색 (`![[name.png]]`, 경로 없음)

1. 문서 폴더에 있으면 끝.
2. 없으면 프로젝트 루트(`prjroot`, 없으면 문서 폴더) 아래의 이미지 색인에서 이름이 정확히(대소문자 구분) 같은 파일을 찾는다.
   색인은 `vim.uv.fs_scandir`로 만드는 비동기 너비 우선 탐색이며 루트당 하나다. 숨김 폴더·`node_modules`·`target`·
   심볼릭 링크 폴더는 건너뛰고, 탐색 항목 20000개·깊이 8이 상한이다.
3. 후보가 여럿이면 문서 폴더에서 가장 가까운 것, 거리까지 같으면 `[neopp: image name is ambiguous: …]` 박스.
   없으면 `[neopp: image not found: …]` 박스.

찾는 중에는 아무것도 그리지 않고(소스 그대로) 끝나면 `refresh`로 다시 그린다. 파일 감시는 없고, 저장과 `BufEnter`가
색인을 stale로 표시해 다음 조회가 백그라운드로 다시 탐색한다.

### 이미지 크기와 형식

크기는 파일 앞 512 KiB의 헤더에서 읽는다: **PNG, JPEG, WebP, GIF**(87a/89a). **SVG·BMP 등은 지원하지 않는다**
(neopp가 래스터만 그린다). 이런 파일은 `[neopp: image unsupported: …]` 박스로 표시된다.

### 표시 실패 (`vim.ui.img.set`이 거부한 이미지)

`vim.ui.img.set`이 예외를 던지거나 `false`를 돌려주면(`nil`은 성공) 그 이미지는 **자리를 그대로 두고** 그 자리에
`[neopp: image display failed: <경로>]` 경고(`WarningMsg`, `not_found` 등과 같은 오류 문구)를 그린다. 문구는 예약된
첫 가상 줄(가상 줄이 없는 1행짜리 이미지는 소스 행)에 한 줄이고 나머지 예약 줄은 비어 있다. 예약 행 수와 소스 숨김은
실패 전후가 같아서 아래 글이 움직이지 않고 스크롤이 안정적이다. 경고 알림(`rendermark: vim.ui.img.set failed for <경로>: <원인>`)은
같은 메시지당 한 번만 뜬다.

- 같은 리비전(경로·파일 mtime·크기·표시 크기)은 다시 시도하지 않는다. 스크롤·창 높이 변화는 리비전이 아니다.
  파일이 바뀌거나 표시 크기가 바뀌면 다음 동기화가 다시 시도하고, 성공하면 경고가 사라지고 이미지가 같은 행 수로 그려진다.
  이미지 표시를 껐다 켜도(`vim.g.neopp_images_enabled`) 다시 시도한다.
- 한 줄 여러 이미지는 거부된 이미지 자리에만 경고가 뜨고 나머지는 정상으로 그려진다. 다이어그램 블록 이미지도 같다.
- 표 셀 안 이미지와 미리보기 float 이미지는 경고 알림과 재시도 억제만 있고 박스는 그리지 않는다(표가 셀 공간을 소유).
- 스텁(`RENDERMARK_IMG_STUB`)에서는 스텁 박스가 같은 자리에서 경고 문구로 바뀐다.

## 스텁 (이미지 provider가 없는 터미널)

`vim.ui.img`가 없을 때만 텍스트 박스 스텁을 설치한다. 환경변수 `RENDERMARK_IMG_STUB=1` 또는
`vim.g.rendermark_img_stub = true`(옛 `MDLOOM_IMG_STUB`)로 켠다. `''`, `'0'`, `0`은 끔.
스텁은 공간 할당을 바꾸지 않고 neopp GUI와 같은 자리를 예약한다(시각 테스트용). neopp가 늦게 붙으면
`User NeoppReady`에서 초기화한다.
