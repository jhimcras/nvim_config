# Neovim Config TODO

---

## Core / General Settings

- [x] window 사이의 회색 선이 거슬림. 라인으로 변경하고 Font 변경 함
- [x] window에서도 neovim 사용할 수 있도록 하기
- [x] relative row number가 좋은지 한번 확인해 보자. 이게 어떨땐 필요하기도 하더라..
- [x] F2키로 rename binding 하기. Input을 받을 있도록 Interative interface 구성 해야 함.
- [x] Neovim packages 기능 확인해 보고 가능한 vim-plug 사용안하는 방법 찾아보기, plugin manager도
      만들어 보는게 좋겠다. plugin reload를 할 수 있는 방법을 못 찾았기 때문이다. 아직까지는 vim-plug
      가 좋다.
- [x] 설정 파일 Reload 방법 고민. `so%`로는 한계가 있다.
  - 기본 설정은 `so $MYVIMRC`로 가능하며, 중복 실행은 잘 막아 두어야 한다.
  - lua plugin들은 이미 require되었기 때문에 package를 전부 nil로 만들면 되나?
    - `package.loaded`안에는 `_G`등과 같이 global 데이터가 같이 들어 있어서 일괄 삭제가 어렵다.
    - 지전한 파일을 리셋 할 수 있도록 했다.
- [x] config 파일들 정리
- [x] `init.lua`등 설정 파일 읽어오는 방법 고민. 하나의 파일만 읽어오던 예전 방식에 비해 lua를 활용
      하게 되면 여러개의 파일을 열어볼 필요하 있다.
  - 각종 Plugin들은 정해진 폴더에 넣어 두고 `require`를 해서 읽어 온다.
  - `init.lua`는 처음 `init.vim`읽을때 마지막에 `luafile`로 읽도록 하면 된다.
- [x] `set clipbaord=unnamedplus` 사용해 보고 지속 사용 여부 결정해 보자. 쓸만 한것 같다.
- [x] `<leader><leader>` mapping은 Dealy가 있다. `visual-multi-cursor` plugin과 충돌이 있었다.
      `visual-multi-cursor`를 사용하지 않기로 했다.
- [x] `w`로 저장 하는것 보다는 `update`로 저장하는게 좋은데 버릇이 잘못 들었다.
- [x] tabline 우측의 X 버튼 없애기
- [x] netrw 사용방법을 숙지 해 보자. Vinegar Plugin도 좋은것 같다. 일단 Dirvish를 설치해서 사용해
      보기로 했다. 파일 생성 삭제가 살짝 불편하다.
- [x] `GuiPopupmenu 0`으로 할때 더 깔끔한것 같다.
- [x] `<leader>`로 mapping 된것들 좀더 효과적으로 정리 필요함.
- [x] Visual Mode에서 lua로 `vim.api.nvim_eval([[getpos("'>")]])`하면 현재 선택한 위치를 가져와야
      하는데 지금은 정상적인 위치를 가져오지 못한다. `<esc>`로 visual 모드를 빠져나오기 전에는 `'>`
      마크가 갱신 되지 않는다. 이를 해결하기 위해서 `line('v')`, `col('v')`함수를 활용 했다.
- [x] Tabline에 들어가는 이름을 임의로 지정할 수 있도록 하기
- [x] Command Line에서 `lua ...`로 lua 함수를 호출 할때 `<Tab>`키로 자동 완성 되면 좋을것 같다.
  - `help :command-completion-customlist`해서 알아보자
  - built-in 명령어를 변경 할 수 없으므로, neovim을 다시 컴파일 하거나, `Lua`같은 명령어를 만들어야 함.
- [x] `fillchars`의 `diff`를 `-`말고 다른걸로 바꾸고 싶은데 뭐가 적당할까?
- [x] lua Plugin을 자동으로 Reset 되도록 하는 방법 필요 (`autocmd BufWritePost *.lua ...`)
- [x] `gq` operator
- [x] `Config`, `ConfigLua` commands doesn't make inactive window defocus. That was the other problem.
- [x] `Config` 명령을 사용하지 않은 버퍼에서 실행한 경우에는 그 버퍼에 뒤집어 씌우자
- [x] `Config` 명령어에 Argument를 입력하여 설정 파일들 검색 결과를 telescope 로 보여주면 좋을듯
- [x] `init.lua`파일 내용 정리
- [x] `init.lua`를 다시 로딩 하면 발생하는 에러들이 있다.
  - lsp-status의 `CursorHold`시 발생하는 호출 오류가 대표적이다.
- [ ] Lua 코드를 바로 실행해 보고 에러 확인 할 수 있도록 하는 기능이 있으면 좋겠다.
  - Checkout `rafcamlet/nvim-luapad`
- [ ] Plugin 써봤던 것들 리뷰 정리 해 놓으면 좋을것 같다.
- [x] Plugin의 Unit test 프로그램 만들어야 겠다
- [x] 가끔 `colorcolumn`이 안나오는 경우가 있다.
- [x] diff할때는 `colorcolumn`은 꺼지고, Inactive, Active 구분해서 포커스 주는것도 꺼지는게 좋겠다.
- [ ] UTF, Bomb 모드를 켜 놓았을때(Window 환경에서) 파일 저장 할때 자동으로 변경해서 저장해주기
- [x] cpp 대형 파일인 경우 matchparen 속도 느려짐
- [x] `init.vim` 설정 파일에서 Folded된것만 밝게 Highlighting 하고 싶은데 방법을 모르겠다.
  - `winhighlight`를 이용하여 윈도우 들어갈때 해당 윈도우 highlight를 바꿔주도록 했다.
  위의 query는 동작하지 않고, 밑에것만 동작 한다. `(paragraph)`가 없는것도 아닌데 안된다.
- [ ] tab이 close될 때 해당 tab의 다음 tab으로 이동 하는데 이전에 있던 tab으로 이동하도록 함.
- [ ] 방금전에 닫은 윈도우를 동일한 위치에 다시 열어주는 기능 (실수로 닫았을때 다시 열기 용)
- [x] 파일 정보를 확인 할 수 있는 Floating 윈도우
    - Status line에 표시되는 모든 Components를 디스플레이
    - 여러가지 정보들을 추가적으로 포함 시킬 수 있음
    - 윈도우 폭이 짧아진 경우 특정 keymap이나 command를 통해 해당 윈도우의 상세 정보를 확인할 수 있도록 함
- [ ] 새로운 neovim을 열어 주는 기능 (사용중인 GUI로), command, telescope 모두 사용 할 수 있음
    - [ ] 선택한 session을 열어주는 기능
    - [ ] 선택한 파일, 버퍼를 새로운neovim 프로세스에서 열어주는 기능
- [ ] Outline 기능 구현
- [ ] python debuger 추가
- [ ] diff 창 열릴때 기본으로 전체 unfold 되어 있도록
- [x] util의 GetBufferName, GetBufferDir, GetCurrentBufferDir 함수 리팩토링
    - 해당 함수들은 버퍼 타입 관계 없이 이름을 리턴 하도록 함. 즉, protocol (ex. fugitive://)은 때고 리턴.
    - GetBufferProtocol 함수를 구현. 프로토콜이 뭔지 str로 리턴 (ex. fugitive:// → 'fugitive')
    - 현재 GetBufferName에서 'oil'타입으로 분기된 코드는 해당 되는 곳으로 추출하고 GetBufferProtocol 함수를 사용하도록 함.


## UI: Statusline / Tabline

- [x] Status line에 LSP 정보(diagnostic, function, ...), Treesitter 내용 넣기
- [x] QuickFix도 status line 만들면 좋을것 같다.
- [x] `tabmove`를 했을때 tabline이 갱신되지 않는다.
- [x] Git branch head 가 아닌 경우 status line에 branch명이 표시되지 않음 (commit ID 라도 표시 되어야 할 듯)
- [x] normal 모드 `<ESC>` 눌렀을 때 Diagnostic float window 제거
- [x] normal 모드 `<ESC>` 눌렀을 때 statusline redraw
    - 구현 했는데 ECS를 한번 무시하는 것처럼 보임 → feedkey와 redraw의 실행 순서가 바뀜
    - feedkey는 키를 scheduling 하기 때문에 redraw도 scheduling 해서 지연 시켜 줘야 실행 순서가 바뀌지 않음
- [x] seperator 없이 padding 1을 하면 각 component 간 간격이 2가 됨 → 1이 될 수 있도록 하는게 좋을듯
- [ ] Search 번호 Display 때문에 파일크기가 큰 경우 전체적인 속도가 느려짐 (꼭 search display가 아니더라도 대형 파일은 속도가 느림)
- [ ] status의 파일 이름 옆에 형식을 아이콘으로 표시하면 좋을 듯
- [x] Column이 짧아졌을 때 display되는 우선 순위로 글자를 잘라 주도록 해야 함
- [x] 비정상 checkhealth buffer의 상태창. checkhealth 뿐 아니라 여러 종류의 버퍼 타입이 아직 커버 되지 않음.
- [ ] 버퍼 타입, 파일 타입에 따른 status line Customization.
    - [x] checkhealth : 그냥 CHECK HEALTH 라고만 나와도 될듯
    - [x] man pager : 어떤 MAN page인지, search count, 현재 커서 위치 표시
- [ ] 라인에 `<tab>`이 들어 있는 경우에 실제로 보이는 것과 다른 column이 statusline에 표시 된다.
- [x] Tabline 에 floating window 정보가 나오지 않도록 수정
- [x] tabline이 꽉 찾을 때 좌측에 "<" 나오면서 앞부분의 tab들이 안보임
    - tabline 텍스트 길이가 윈도우 길이보다 길어지면 보이는 만큼만 탭을 보여줌
    - 우로 한번 스크롤 하면 우측에 안보이던 탭이 하나 보이면 되고
    - 좌로 한번 스크롤 하면 좌측에 안보이던 탭이 하나 보이면 됨
    - 예를 들어 우측 한번 스크롤 했을때 기본적으로 가장 완쪽에 보이단 탭은 안보이고 가장 오른쪽 땝의 다음 탭이 보이면 되는데 이때 택스트 길이가 넘어 간다면 왼쪽의 탭을 몇개 더 안보이게 해도 됨
    - keymap을 통해 좌우로 스크롤 할수 있도록 함. 숫자키 누른후(혹은 그냥) `<leader>t` 누르면 우측으로 스크롤 `<leader>T` 누르면 좌측으로 스크롤
    - tabkine 우측의 session 이름은 항상 나오도록 함
- [x] tabline 이 스크롤 되어 있어 현재 탭이 tabline에 보이지 않는 경우 좌 또는 우의 맞는 위치에 현재탭의 인덱스만 표시(현재탭 highlight) 동일하게
- [x] `gt`, `gT`로 탭 이동 할때 현재 탭이 보이도록 스크롤
- [x] telescope를 사용해서 전체 tabline을 리스트업 하고 이중 타이핑 한 word의 파일이 있는 tab으로 이동 하는 기능
- [x] Status line 텍스트 길이를 윈도우 폭에 의해 동적으로 변경
    - Main Concept
        - 각 component는 축소 버전의 텍스트를 함께 생성 함
        - 사용자 지정에 의해 각 component는 축소(제거) 우선 순위를 갖음
        - 1차 생성 후 실제로 Display되는 텍스트의 길이(hilight 등 제외)가 실제 윈도우 폭보다 큰 경우는 축소를 시도함
        - 우선 순위가 높은 순으로 하나의 component씩 축소(제거) 하면서 윈도우 폭과 길이를 비교
        - component의 축소 버전이 없는 경우는 해당 component는 제거
        - 모든 component를 축소 했으면 더이상 할 것은 없음. vim의 기본 사양 대로 `>`가 나오는것을 유지. (이정도 짧아지면 축소는 무의미)
    - Detailed Implementation Idea
        - `width_thresholds`는 더이상 사용하지 않음
        - `make_statusline_test`에서 hl를 붙이기 전 길이를 체크 하는 것이 적합한 구현 방법인 것으로 보임 (더 최적화된 방법이 있다면 변경 가능)
        - component의 우선 순위는 1부터 10 사이의 값을 사용 하고 동일한 값은 로직적으로 먼저 나오는 것을 우선함.
        - component는 `make_statusline_test`의 `components`인자가 되는 모든 함수
- [x] GdiffSplit을 해서 나뉘는 윈도우의 bufffer 이름이 'fugitive'로 시작하며 길이가 길어 축소 되는데 축소 되면 fugitive인지 알수 없음. 
- [x] Linux에서 Oil의 폴더 이름이 잘못 표시 됨.
- [ ] tabline의각 tab이 잘 구분되지 않음


## Search: Loupe / Grep

- [x] `loupe`에 부족한 기능들이 있다.
  - `*`로 같은 단어 찾는 것과 유사하게 동일한 단어를 highlighting 해주는 기능이 있으면 좋겠다. 화면 이동 안하고,
    커서 이동 안하고 되는게 좋을것 같다.
  - `n`, `N`이 항상 같은 방향으로 검색하도록 하면 좋겠다.
- [x] `*`로 검색할때 처음에는 이동하지 않았으면 좋겠다. 그리고 현재 문서에 몇개나 매칭 되는지 나오면
      좋을것 같다.
  - Loupe 플러그인의 `#`이 이런 기능으로 매핑 되어 있으니 사용해 보자. 그런데 `#`은 뒤로 검색하는
    기능이라 사용하기 어려울듯.
  - `#`를 `nmap # *N`으로 매핑했다. 이렇게 사용해 보자.
- [x] Got `No range allowed` error when accidentaly press numbers and `<esc>` to escape.
    - `<esc>`를 loupe plugin 함수로 mapping 해 놓았기 때문으로 보임
- [x] `*`이후 바로 `N`을 사용하여 원래 위치로 돌아오도록 했는데 화면안에 같은 단어가 없는 경우에 화면이 움직인다.
- [x] rg등 Async 명령이 시작되면 정지할 수가 없다. 다른 Async 명령이랑 겹치면 부하 걸리는듯.
- [x] Search 할때 현재 위치 Hightlight가 비 정상적이라 커서 위치를 알 수가 없다. `IncSearch`를 바꿔 해결.


## Quickfix / Location List

- [x] `Grep`으로 생성된 QuickFix 윈도우는 찾을때의 project root가 달라 QuickFix 윈도우가 포커스 된
      상태에서 다시 검색하면 다른 폴더에서 찾기 명령이 들어간다. QuickFix도 폴더를 바꿔 줘야 할것 같다.
- [x] `Grep` 결과 QuickFix에 검색 글자 highlighting 되면 좋을것 같다.
- [x] `Grep` 결과 QuickFix는 `relativenumber`는 꺼져 있고, `number`는 켜져 있는게 어떨까?
- [x] 결과를 onread 함수에서 바로 quickfix로 넣다 보니 결과 데이터 라인이 잘리는 경우가 있음
- [x] Grep 중간에 `<c-c>`로 취소하는 기능
- [x] 전체 개수 status line에 표시
- [x] quickfix stack 정상적으로 남지 않는 현상
    - `setloclist` 함수 사용시 `nr`값을 세팅하고 `line`대신 `items`로 바꾸니까 됨
- [x] Grep을 하고 있는 중에 끝났는지를 알 수 있는 방법이 필요함. 
  - 현재의 상태를 status에 보여주면 좋을 듯. (searching, done, terminated, ...)
  - 현재는 전체 라인수가 실시간으로 업데이트 됨. 하지만 Grep이 끝났는지 여부를 알 수 있는것은 아님
- [x] status line 색이 현재는 normal 과 같은데 바꾸면 좋을듯
- [x] Location List로 변경
    - [x] Location List로 리스트업
    - [x] wndid가 하나만 있기 때문에 동시에 여러개 search 하는 경우 오류 발생
    - [x] lopen으로 열린 리스트가 어떤 윈도우의 리스트 인지 알 수 있는 방법 필요 (status line 색상?)
    - [x] 열었던 윈도우가 quit 되었을때 같이 제거 되어야 함 (실효성 검증, side effect 필요)
    - [x] 다른 여러개의 윈도우에서 동시 Grep 하면 동시에 시작 하지 않고 이전 Grep을 대기 함.
- [x] 지정한 라인을 삭제하는 기능 (dd, d<motion>, v_d 등)
- [x] `lolder`, `lnewer`로 리스트가 변경 되었을때 highlight 가 없어짐
- [x] `Lfilter`, `Cfilter`로 변경된 내용 statusline에 표시?
- [x] 두 개의 loclist 윈도우가 열려 있을 때 statusline의 검색 제목이 뒤바뀌는 버그
    - Neovim이 qf/loclist 윈도우의 window-local `%!expr` statusline을 무시하고 global `%!statusline_entry()`로 fallback 함
    - 수정: `%!expr` 대신 pre-rendered 포맷 문자열(`%#HlGroup#`, `%l/%L` 등을 직접 포함)을 window-local statusline에 설정
    - `grep.update_loclist_sl(winid)` 로 관리하며 timer, onexit, filter 변경 시 갱신
- [x] loclist가 close되면 origin 윈도우의 color tag는 보이지 않아야 함. lopen으로 다시 열면 그때 다시 표시


## Project Root

- [x] New `.prjroot` file template. I decided to use vsnip.
- [x] 폴더 이름에 스페이스가 포함되어 있는 경우에 에러가 발생함
- [x] Repeatedly executed current folder checking function for every status updating.
- [x] project마다 `tabstop`, `expandtab` 옵션을 자동 될수 있도록 하는 기능 (prjroot 사용)
- [ ] prjroot on launcher filetype buffer is not collect.
- [ ] prjroot finding rules are needed to improve. Think when empty folder has just been created.


## Launcher / Build

- [x] Launcher library cannot be interupted.
- [x] Launcher needs not to run when other process running
- [x] Launcher window need to position smarter
- [x] Termination process
- [x] Launcher buffer 생성 시에도 버퍼에 생성된 폴더 prjroot를 저장하여 단축키가 그대로 동작 할 수 있도록 해주어야 한다.
- [x] 파일 이름을 build.lua가 아닌 launcher.lua 로 바꿔야 할것 같다.
- [x] build plugin 이름을 launcher로 변경하고 build는 폴더로 만들어서 msbuild, lua 등 빌더를 관리 할 수 있도록 한다.
- [ ] Run (using launcher) program on background (on unix use `&`)
- [ ] It's very annoying when create a new window from the cursor on most left side of buffer.
      The old window has been shifted to right side.
- [ ] 결과 Parsing 해서 에러, 경고 위치 이동 해주는 기능
- [ ] 윈도우가 만들어지는 위치, 크기를 지정할 수 있는 옵션 (상하좌우, prjroot상에 이미 같은 윈도우가 있으면 해당 윈도우 지우고)
- [x] 실행하려고 하는 커맨드에 문제가 있어서 실행 못했을때 아무런 메시지가 나오지 않는다. `q`로 창을 없앨수도 없다.
- [x] 동일한 prjroot에서 생성된 동일한 이름의 Launcher 버퍼 있으면 버퍼 내용만 삭제하고 그대로 사용 (윈도우 유지)
- [x] 기존 버퍼에 실행 결과를 다시 Display 할때 버퍼가 Hidden 상태면 현재 tab에 다시 vsplit 하여 나타나도록 함.
- [ ] 동일 prjroot의 다른 버퍼에서도 launcher 버퍼를 제거 할 수 있는 단축키
- [x] `vim.loop.kill(pid, 15)`를 사용 하는 것은 `read_stop`등을 할 수 없기 떄문에 handle을 사용하는게 좋다고 함. 리팩토링 필요.
- [x] terminal color를 파싱해서 highlight
- [ ] session 저장할때 내용 저장 하고 session 열때 같이 열림
    - 다음 저장시 기존에 저장했으나 버퍼가 닫힌것은 삭제
- [x] output의 encoding을 지정 할 수 있어야 함
- [ ] Lua function 실행 호출도 할 수 있음
- [x] 실행 중인 경우 statusline에 spin animation, 끝나면 끝났다고 statusline에 표시.
- [x] launcher 실행 과 프로젝트 옵션이 함께 사용 되어 문제가 되고 있음. launcher 는 최상위의 launcher키에서 읽어오도록 수정.
- [ ] 비동기로 동작중인 프로그램 리스트를 볼 수 있는 기능


## Language Server (LSP)

- [x] lua LSP중 성능이 괜찮으면서 window 지원되는것 찾아 보기
- [x] completion-nvim 좀더 잘 활용할 수 있는 방안 마련해 보기. C++ 프로젝트를 이걸로 진행해보면서
      이것저것 불편한것 찾아봐야 겠다.
- [x] cmake LSP 사용해보기
- [x] LSP formatting keymap binding 하기
- [x] completion할때 나오는 정보에서 hightlighting이 잘못 되는것 같다. Markdown syntax를 사용하는것
      같은데 디버깅을 어떻게 하면 좋을지 모르겠다.
- [x] Completion할때 나오는 작은 설명창의 Highlighting이 이상하게 된다. `_`만 분홍색이다. 위치도
      이상해서 내용을 읽어 볼 수가 없다. Markdown syntax를 floating window에서 잘 보이게 만들어 줘야 한다.
  1. plasticboy의 vim-markdown 플러그인의 syntax highlighting에서 이상하게 highlighting된다.
  2. active 윈도우 포커스를 위해 `autocmd`로 highlighting을 바꾸도록 해 놨는데 이상하게 꼬이면서
     가독성이 없게 되었다.
  3. clangd에서 markdown 형식으로 나오도록 세팅 해야 정상적으로 나온다.
  4. clangd에서 나오는 markdown을 escaping 하면서 이상하게 꼬이는것 같다.
  5. clangd에서 signatureHelp와 completion은 markdown으로 나오지 않는다. plaintext만 나옴.
- [x] LSP를 이용한 CodeAction 도 가능하도록 해보자.
- [x] LSP Diagnostic 이동 mapping을 만들자. 예를 들어 Normal 모드에서 `]d`를 누르면 다음 Warning
      이나 Error로 이동 시켜 주는 것이다.
- [x] LSP의 Preview에서 `_`들어간 경우 이상하게 Highlighting 됨.
- [x] `Gdiffsplit`해서 생성된 윈도우는 LSP 하지 않아도 됨. 그외 fugitive로 생성된 임시 파일도 마찬가지.
- [x] clangd가 특정 header에서 적용 되지 않음 - header가 objcpp로 열려서 발생함
- [x] 전체 프로젝트에서 특정 함수를 telescope로 이동 할 수 있는 기능 → lsp_dynamic_workspace_symbols
- [x] log 파일이 항상 크게 남음
- [x] Indexing 끝났을때 redrawstatus 해줘야 함
- [x] language server를 환경 변수 세팅 후 실핼 하도록 수정


## Diagnostics

- [x] Diagnostic List 표시 (Quickfix List 사용)
- [x] clang-tidy LSP(clangd)로 사용해보기, .clang-tidy 파일 만들면 바로 동작할듯.
- [x] lsp-status plugin의 statusline.lua 파일의 statusline_lsp 함수에 버그가 있다.
```lua
  -- if #vim.lsp.buf_get_clients(bufnr) == 0 then
  if next(vim.lsp.buf_get_clients()) == nil then
```


## Completion / Snippet

- [x] Snippet을 사용해 보자. UltiSnips를 사용해 보았는데 snippet을 어떤 방식으로 사용하는가에 대한
      좋은 인상을 받았다. 지금 vim을 사용하는 방식이 built-in LSP를 사용하고 있어서 UltiSnips를 사용
      하지는 못할것 같고, [vim-vsnip](https://github.com/hrsh7th/vim-vsnip)가 호환된다고 하니 사용해 보는것이 좋을것 같다.
- [x] Snippet completion중 다른 completion을 하고 싶을 때 `<Tab>`키를 눌렀을때 다음 입력 항목으로 넘어
      가 버림. 다른 단축키를 사용하도록 설정함.

### Snippet을 이용한 Completion
Snippet을 이용한 completion은 statement, 함수 등을 편리하게 입력하게 해준다. 하지만 함수에 snippet을
이용하는 것은 signature preview와 크게 다를것이 없으며 편리한것은 괄호가 자동입력 된다는것 말고는 큰
편의 점이 없는것 같다. Statement는 타이핑을 줄여주어 편리 했다. 단점으로는 snippet입력 중 `<Tab>`키를
누르게 되었을때 다른 completion이 나오길 원하지만 snippet의 다음 입력란으로 넘어가게 되어 불편했다.


## Treesitter / Syntax Highlighting

- [x] `Util.PrintTreesitter` 함수를 scratch buffer로 읽어 오는 방법 연구해 보자. Plugin을 설치 했다.
- [x] markdown syntax highlighting이 좀 이상한것 같다. treesitter highlighting 사용하니까 해결 됨.
- [x] treesitter 기능 확인
  - [x] 현재 Scope Highlighting 하는것 좋은것 같은데 실제로 얼마나 효용 가치가 있는지 확인 필요하다.
        생각보다 많이 거슬려서 일단 껏다.
  - [x] 다양한 Query가 있는것 같은데 하나씩 확인해서 내가 사용하기 좋을것들로 세팅 해봐야 겠다.
- [x] treesitter에서 syntax를 갱신하지 않는 경우가 있음. Undo했을 경우인것 같음. 뭔가 안정화 되어
      가고 있다는 느낌이 있음.
- [x] lua의 treesitter를 이용한 highlighting이 이상하게 되서 확인 해 보니 parser에는 문제가 없었다.
      nvim-treesitter plugin의 `get_node_at_cursor`을 특정 위치에서 호출 해봤을때 function이 아닌데
      function이라고 나오는 경우가 있다.
- [x] treesitter 트리구조 확인하는 명령어 만들어 놔야 겠다. TSPlayground plugin을 사용하면 된다.
- [x] argument, function object 가 정상적으로 동작하지 않고 있다. nvim-treesitter-textobjects 설치 후 정상화.
- [x] treesitter highlight error when substituting.
- [x] 파일이 큰 경우 `syntax on`상태에서 느려진다. 좀 느려지긴 하지만 사용할 만 한것 같다.
- [x] treesitter를 이용한 markdown 파일 타입의 `highlights.scm`을 `nvim-treesitter/queries/markdown`
      폴더에 저장해 놨더니 그 파일의 룰에 맞춰 동작 했다. 이걸 활용하면 좋을것 같다.
- [x] markdown 에서 list item 다음 줄로 넘겨 놓고 indent를 2 이상을 하면 codeblock으로 highlighting
      된다. Treesitter로 파싱된 값은 `soft_line_break`라고 정상적으로 나온다. Treesitter로
      highlighting을 했더니 모든게 정상화 되었다. 아직 공식적으로 지원하고 있지는 않다.


## Markdown

- [x] vimwiki 사용 방안 생각해 보기. Markdown plugin을 직접 만들어 사용하기로 함. `index.md`는
      note폴더에 넣고 keymap 하여 사용 함.
- [x] Treesitter 이용하여 만들던 markdown plugin을 지워 버렸다. 일단 `plasticboy/vim-markdown`을
      활용해 봐야 겠다.
- [x] plasticboy의 vim-markdown은 일단 쓰고 있는데 mkdx도 써 봤다. vim-markdow이 조금더 나은거 같긴
      한데 내 입맛에 맞진 않는다. 역시 만들어서 써야 겠다. 내가 주로 사용하는 기능은 링크 이동과,
      자동 Indent, 자동 List Item, 자동 checkbox 이며, Checkbox Toggling 기능이다.
- [ ] markdown에서 `---`를 연결된 선으로 표시할 수 있으면 좋을것 같다. virtual text를 확인해 보자.
- [ ] Markdown task list 매핑해서 체크 해주는 기능이 nested tasklist에서 중복으로 실행 되어, 상위
      task list가 체크 되거나 해제 되는 버그가 있다.
- [ ] Auto indentation
- [ ] Auto new line list mark
- [ ] checkbox toggle 기능 구현

### `render-markdown`
- [ ] plugin의 color가 정상적으로 나오고 있지 않음
- [x] header에 숫자 나오는거 없는게 나을듯. virtual indent 되면 좋을것 같음.
- [ ] check된 라인의 strike 보다는 dimming 하는게 좋을 듯
- [x] LSP의 설명 창이 이상하게 렌더링 됨 (override-buftype-nofile로 해결)


## Session

- [x] session 생성하는법 확인. `mksession`으로 저장하고, `source`로 읽어 온다.
- [x] Session 저장 해뒀다가 읽어온 파일이 Diagnostic이 안되는 경우가 있음. Language Server가 바로
      실행되지 않는것 같다. `:e`로 다시 열면 동작 했다. 언젠가부터 해결되어 있었다.
- [x] session을 이용해서 이전에 작업하던 상태를 그대로 기억해 놓도록 하면 좋은것 같다. 이걸 리스트
      업 해서 관리하는건 어떨까? telescope로 간편하게 검색 할 수 있도록 연결 하면 좋을것 같다.
      `stdpath('data')`의 하위에 `session` 폴더를 만들어 두고 session들을 저장해 놓도록 했다.
- [x] 현재 session은 `v:this_session`에 저장 되어 있다. 이를 tabline 우측에 표시해 주면 편리 할것
      같다. Remove, Save 같은 동작을 했을때 변경 되도록 해줘야 한다.
- [x] Session이 telescope에서 fuzzy finding이 안됨
- [x] RemoveSession이 정상 동작하지 않음
- [x] Telescope에서 없는 session 입력 했을때 에러 발생
- [x] command line에서 RemoveSession, SaveSession 의 자동 완성이 미리 입력한 문자열로 시작되지 않음
- [x] session에 quickfix(location) list 저장, 로딩 하는 기능
    - [x] 현재 index도 함께 저장, 파일 변경 시 같이 변경되는 line number도 바뀌어 저장 되는 지 확인 필요
    - [x] location list가 여러개 저장되는 경우가 있는것으로 보임. 이런 경우 session 로딩 할때 에러 발생.
- [x] Session 저장 할때 sessions 폴더가 없는 경우 그냥 저장 실패함
- [x] 자동 Session 저장 기능
- [ ] 저장할 quickfix가 큰경우, 혹은 똑같은 경우에 대한 대처
- [x] session 변경, close 할때 저장 안된 버퍼가 있는 경우 알려주고 동작 중지
- [ ] session 변경, close 할때 버퍼 중 terminal이 있는 경우 뭔가 실행 중인지 확인해 주면 좋음. 구현이 어렵다면 터미널 버퍼가 있다고 알려주고 사용자가 확인 했을때만 진행 되도록 함.
- [ ] `cmdheight`가 1이 아닌 값으로 저장 되는 경우가 있음
- [ ] `:qa`로 neovim 종료할때 자동 저장 안되는것 같음


## File Manager

- [x] `gx` command to execute in dirvish on unix systems.
- [x] oil 버퍼에서는 prjroot가 동작하지 않는 것으로 보임 (터미널, telescope를 통한 파일 열기가 안됨)
- [x] oil버퍼 편집 후 저장 하면 나오는 확인창에 border line 넣기


## Buffer Management

- [x] 현재 보이는 버퍼 외의 모든 버퍼 wipeout


## Telescope

- [x] 빈칸을 search 하게 되면 부하 걸려서 뻣는다


## IME / Korean Input

- [x] 현재 키보드 상태가 한글인지 영문인지 Status Line에 나오게 할 수는 없을까?
  - linux에서는 `fcitx-remote` shell 명령으로 알 수 있으나 status에 찍으려고 계속 호출 하니까 과부하
    걸리는것 같다. Background로 과부하 없이 모니터링 하게 할 수 있을까? 아니면 바뀔때만 Call back
    함수 호출 되도록 할 수는 있을까?
  - Normal 모드로 바뀌었을때는 `barbaric` 플러그인을 사용하여 자동으로 영문으로 바뀌도록 했다.
  - Status Line에 나오게 하면 계속 마우스 커서가 깜박 거려서 거슬린다. 다른 방법 없을까???
  - lua의 `io.popen` 함수를 사용하여 깜박거리는것은 해결 가능 했다.
- [ ] 키보드 상태가 한글인지 영문인지 여부를 tabline 우측에 표시. 영문이 아닐때만 표시하면 될듯.
- [ ] Buffer가 Markdown일때만 Insert mode에서 한영키를 누르자 마자 Status가 Refresh 되지 않았다.
- [ ] Command mode (and Searching) 일때는 Status에 한영 표시가 되지 않는다.


## Git / Fugitive

- [x] `Gclog`를 통해 전환된 과거 코드에서 원래 코드로 한번에 돌아 올 수 있는 기능
- [ ] `Gclog`후 원래 코드로 돌아오는 기능 동작 안됨
