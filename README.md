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
| `lua/nvim_config/launcher.lua` | Asynchronous program launcher (`lua/nvim_config/launcher/registry.lua`: job registry) |
| `lua/nvim_config/process_list.lua` | List/inspect/kill running launcher jobs |
| `lua/nvim_config/prjroot.lua` | Project root detection (`.git`, `.prjroot`, etc.) — see [docs/prjroot.md](docs/prjroot.md) |
| `lua/nvim_config/session.lua` | Session management per project root |
| `lua/nvim_config/status.lua` | Custom statusline with LSP, git branch/commit, diagnostics (`lua/nvim_config/status/mode.lua`: mode indicator) |
| `lua/nvim_config/tabline.lua` | Custom tabline |
| `lua/nvim_config/instance.lua` | Spawn a new instance of the host — the GUI parent (via `--embed`) or a TUI (`:NewInstance [file]`, `:NewInstance!` to diagnose host detection) |
| `lua/nvim_config/instance_move.lua` | Move a file/Oil buffer or tab to a new or running Nvim instance (`:MoveBufferToInstance`, `:MoveTabToInstance`) |
| `lua/nvim_config/reopen.lua` | Reopen the last closed window or tab with its layout (`<leader>u`, `:Reopen`) |
| `lua/nvim_config/highlight.lua` | Statusline/UI highlight group definitions |
| `lua/nvim_config/git.lua` | Git branch and commit info with TTL caching |
| `lua/nvim_config/grep.lua` | RipGrep integration |
| `lua/nvim_config/msbuild.lua` | MSBuild integration |
| `lua/nvim_config/lsp_setting.lua` | LSP client configuration (`lua/nvim_config/lsp_setting/`: per-server tweaks — clangd, lua_ls, python, markdown; Markdown code action to create missing link targets) — see [docs/clangd.md](docs/clangd.md) for clangd indexing load |
| `lua/nvim_config/read_mode.lua` | Distraction-free READ mode, per window, any filetype |
| `lua/nvim_config/smart_cursorline.lua` | Cursorline shown only where useful (active window, normal mode) |
| `lua/nvim_config/file_info.lua` | File size/info display (`<C-g>`, `:FileInfo`) |
| `lua/nvim_config/ansi_parser.lua` | ANSI SGR color codes → Neovim highlight groups |
| `lua/nvim_config/json.lua` | jq-backed JSON pretty-print/minify (`:JsonPretty`, `:JsonOneline`) |
| `lua/nvim_config/util.lua` | Shared utilities (memoize, keymaps, … `lua/nvim_config/util/cache.lua`, `lua/nvim_config/util/serialize.lua`) |
| `lua/nvim_config/rendermark/` | Markdown rendering: browser-like soft-wrap, boxed tables (images allowed in cells), HTML subset (e.g. `<details>`), inline image and PlantUML previews (neopp GUI), link navigation/completion (`<C-]>`/`<C-}>`, creates missing link/wikilink targets), image file completion for `![`, Obsidian-style checkbox toggle (`<C-Space>`) |

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

Specs live in `tests/spec/` (one file per module, e.g. `util_spec.lua`, `prjroot_spec.lua`, `git_spec.lua`, `rendermark_wrap_spec.lua`, `rendermark_image_spec.lua`).
