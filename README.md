# NeoVim Config

Personal Neovim configuration.

## Requirements

- Neovim >= 0.11 (uses `vim.lsp.config` / `vim.lsp.enable`)
- [pckr.nvim](https://github.com/lewis6991/pckr.nvim) (plugin manager)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (for tests)
- ripgrep (for grep integration)

## Environment Variables

```sh
LUALS=/path/to/lua-language-server   # Lua LSP
VIMLS=/path/to/vim-language-server   # VimScript LSP
```

## Built-in Modules

Own Lua modules use the `nvim_config` namespace, for example `require('nvim_config.status')`.
Restart all running Neovim instances after updating so instance-transfer RPC uses the same module paths.
Temporary `env` and `msbuild` forwarding modules support the external `workspace/image/.prjroot`;
remove them once that configuration uses the new paths.

| Module | Description |
|---|---|
| `lua/nvim_config/setting.lua` | Core options and autocmds (auto-reload, terminal, folding, …) |
| `lua/nvim_config/keymap.lua` | Global keymaps |
| `lua/nvim_config/env.lua` | OS/environment detection helpers |
| `lua/nvim_config/launcher/` | Asynchronous launcher: output, terminal, project objects, jump, buffer guards and shared job registry |
| `lua/nvim_config/launcher/process_list.lua` | List/inspect/kill running launcher jobs |
| `lua/nvim_config/prjroot.lua` | Project root detection (`.git`, `.prjroot`, etc.) — see [docs/prjroot.md](docs/prjroot.md) |
| `lua/nvim_config/session/` | Session commands, persisted lists and process/modified-buffer exit guard |
| `lua/nvim_config/status/` | Custom statusline with LSP, git branch/commit, diagnostics (`lua/nvim_config/status/mode.lua`: mode indicator) |
| `lua/nvim_config/tabline.lua` | Custom tabline |
| `lua/nvim_config/instance/init.lua` | Spawn a new instance of the host — the GUI parent (via `--embed`) or a TUI (`:NewInstance [file]`, `:NewInstance!` to diagnose host detection) |
| `lua/nvim_config/instance/move.lua` | Move a file/Oil buffer or tab to a new or running Nvim instance (`:MoveBufferToInstance`, `:MoveTabToInstance`) |
| `lua/nvim_config/reopen.lua` | Reopen the last closed window or tab with its layout (`<leader>u`, `:Reopen`) |
| `lua/nvim_config/highlight.lua` | Statusline/UI highlight group definitions |
| `lua/nvim_config/git.lua` | Git branch and commit info with TTL caching |
| `lua/nvim_config/grep.lua` | RipGrep process execution and prompts |
| `lua/nvim_config/qflist/` | Quickfix/loclist tags, filters and editing operators |
| `lua/nvim_config/msbuild.lua` | MSBuild integration |
| `lua/nvim_config/lsp/` | LSP client configuration (`lua/nvim_config/lsp/servers/`: per-server tweaks — clangd, lua_ls, python, markdown) — see [docs/clangd.md](docs/clangd.md) for clangd indexing load |
| `lua/nvim_config/read_mode.lua` | Distraction-free READ mode, per window, any filetype |
| `lua/nvim_config/smart_cursorline.lua` | Cursorline shown only where useful (active window, normal mode) |
| `lua/nvim_config/file_info.lua` | File size/info display (`<C-g>`, `:FileInfo`) |
| `lua/nvim_config/ansi_parser.lua` | ANSI SGR color codes → Neovim highlight groups |
| `lua/nvim_config/json.lua` | jq-backed JSON pretty-print/minify (`:JsonPretty`, `:JsonOneline`) |
| `lua/nvim_config/util/` | Buffer, text, keymap, highlight, job, cache and serialization helpers; init re-exports the public API |
| `lua/nvim_config/rendermark/` | Markdown rendering: browser-like soft-wrap, boxed tables (images allowed in cells), HTML subset (e.g. `<details>`), inline image and PlantUML previews (neopp GUI), link navigation/completion (`<C-]>`/`<C-}>`, creates missing link/wikilink targets), image file completion for `![`, Obsidian-style checkbox toggle (`<C-Space>`) |

Markdown wrap orchestration, inline styles and table rendering live in
`rendermark/wrap/`; `rendermark/table_state.lua` shares table placements with images.
`rendermark/image/` separates synchronization, placement, preview, PlantUML,
stub drawing, screen coordinates and layout. Markdown actions/rename and
completion sources live in `rendermark/`, alongside the renderer.
Telescope configuration lives in `plugins/tele/init.lua`; lazy feature pickers
live in `plugins/tele/pickers.lua`.

## Plugins

**Editing**
- `tpope/vim-surround` — surround text objects
- `numToStr/Comment.nvim` — commenting
- `kana/vim-textobj-user` + `vim-textobj-entire`, `vim-indent-object` — extra text objects
- `nvim-treesitter/nvim-treesitter` + textobjects (`master` branch) — syntax-aware motions and highlights
- `monkoose/matchparen.nvim` — faster bracket matching
- `wincent/loupe` — improved search highlighting

**Completion & Snippets**
- `hrsh7th/nvim-cmp` — completion engine
- `hrsh7th/vim-vsnip` + `cmp-vsnip` — snippet support
- `hrsh7th/cmp-nvim-lsp`, `cmp-nvim-lsp-signature-help` — LSP sources

**LSP**
- LSP status is shown by the custom statusline using Neovim's built-in `vim.lsp.status()`

**Navigation**
- `nvim-telescope/telescope.nvim` — fuzzy finder
- `stevearc/oil.nvim` — file explorer
- `johngrib/vim-f-hangul` — f/t motion for Hangul

**Git**
- `tpope/vim-fugitive` — Git integration
- `junegunn/gv.vim` — commit graph viewer

**UI**
- `sam4llis/nvim-tundra` — colorscheme
- `norcalli/nvim-colorizer.lua` — color preview

**Misc**
- `weirongxu/plantuml-previewer.vim` — PlantUML preview
- `andythigpen/nvim-coverage` — code coverage overlay (Unix only)

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

```sh
bash run_tests.sh
```

Specs live in `tests/spec/`, grouped by module (for example `lsp_spec.lua`,
`instance/move_spec.lua`, `rendermark/wrap/init_spec.lua` and
`rendermark/image/init_spec.lua`). Run one file or directory with
`bash run_tests.sh tests/spec/rendermark`.

Run `bash run_integration_tests.sh` for real-init terminal integration tests,
and `python3 scripts/check_require_graph.py` to check local dependency layers
and cycles. Refactoring validation and benchmark results are recorded in
[docs/module_refactoring.md](docs/module_refactoring.md).
