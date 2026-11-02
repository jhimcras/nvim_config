# mdloom Windows 이동 버퍼 수정

대상: mdloom `lsp-scope`의 `editors/nvim`. 이 환경의 mdloom checkout에는 remote가 없어 패치로 전달한다. Rust 바이너리 변경은 없다.

Windows cmd.exe에서 적용:

```bat
cd /d D:\workspace\nvim_config
git pull --ff-only origin mdloom_integration
cd /d D:\workspace\mdloom
git apply --check D:/workspace/nvim_config/patches/mdloom-windows-move-buffer.patch
git apply D:/workspace/nvim_config/patches/mdloom-windows-move-buffer.patch
```

이미 적용됐거나 대상 파일이 달라 check가 실패하면 중복 적용하지 않는다. 실행 중인 Neovim은 종료하고 새로 실행한다. 실제 로드하는 플러그인 경로가 `D:/workspace/mdloom/editors/nvim`인지 확인하고 W4 smoke 및 별도 이동 검증을 처음부터 실행한다.

수정은 이동 전 열린 버퍼의 정규화 경로를 기록하고, 파일 이동 후에도 옛 이름에 남은 버퍼를 Neovim rename과 같은 saveas 방식으로 갱신한다. 회귀 테스트는 디스크만 이동하는 rename을 주입해 버퍼 경로 갱신과 편집 후 저장을 확인한다.

Linux 확인: `cargo test -p mdloom --test nvim move_in_neovim -- --nocapture` 통과. Windows 재검증은 미실행이다.
