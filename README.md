# NeoVim Config

Personal Neovim configuration.

## Requirements

- Neovim >= 0.10
- [pckr.nvim](https://github.com/lewis6991/pckr.nvim) (plugin manager)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (for tests)
- ripgrep (for grep integration)

## Environment Variables

```sh
LUALS=/path/to/lua-language-server   # Lua LSP
VIMLS=/path/to/vim-language-server   # VimScript LSP
```

## Built-in Modules

| Module | Description |
|---|---|
| `lua/setting.lua` | Core options and autocmds (auto-reload, terminal, folding, …) |
| `lua/keymap.lua` | Global keymaps |
| `lua/env.lua` | OS/environment detection helpers |
| `lua/launcher.lua` | Asynchronous program launcher (`lua/launcher/registry.lua`: job registry) |
| `lua/process_list.lua` | List/inspect/kill running launcher jobs |
| `lua/prjroot.lua` | Project root detection (`.git`, `.prjroot`, etc.) — see [docs/prjroot.md](docs/prjroot.md) |
| `lua/session.lua` | Session management per project root |
| `lua/status.lua` | Custom statusline with LSP, git branch/commit, diagnostics (`lua/status/mode.lua`: mode indicator) |
| `lua/tabline.lua` | Custom tabline |
| `lua/highlight.lua` | Statusline/UI highlight group definitions |
| `lua/git.lua` | Git branch and commit info with TTL caching |
| `lua/grep.lua` | RipGrep integration |
| `lua/msbuild.lua` | MSBuild integration |
| `lua/lsp_setting.lua` | LSP client configuration (`lua/lsp_setting/`: per-server tweaks — clangd, lua_ls, python, markdown) |
| `lua/read_mode.lua` | Distraction-free READ mode, per window, any filetype |
| `lua/smart_cursorline.lua` | Cursorline shown only where useful (active window, normal mode) |
| `lua/file_info.lua` | File size/info display (`<C-g>`, `:FileInfo`) |
| `lua/ansi_parser.lua` | ANSI SGR color codes → Neovim highlight groups |
| `lua/json.lua` | jq-backed JSON pretty-print/minify (`:JsonPretty`, `:JsonOneline`) |
| `lua/util.lua` | Shared utilities (memoize, keymaps, … `lua/util/cache.lua`, `lua/util/serialize.lua`) |
| `lua/rendermark/` | Markdown rendering: browser-like soft-wrap, boxed tables, inline image previews, link navigation/completion (`<C-]>`/`<C-}>`, creates missing link/wikilink targets), Obsidian-style checkbox toggle (`<C-Space>`) |

## Plugins

**Editing**
- `tpope/vim-surround` — surround text objects
- `numToStr/Comment.nvim` — commenting
- `kana/vim-textobj-user` + `vim-textobj-entire`, `vim-indent-object` — extra text objects
- `nvim-treesitter/nvim-treesitter` + textobjects — syntax-aware motions and highlights
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
- `MeanderingProgrammer/render-markdown.nvim` — draws headings/checkboxes/links/code blocks; `lua/rendermark/` layers soft-wrap, image previews, link navigation/completion and checkbox toggling on top (only `lua/rendermark/rm_compat.lua` touches the plugin directly)

**Misc**
- `weirongxu/plantuml-previewer.vim` — PlantUML preview
- `andythigpen/nvim-coverage` — code coverage overlay (Unix only)

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

```sh
bash run_tests.sh
```

Specs live in `tests/spec/` (one file per module, e.g. `util_spec.lua`, `prjroot_spec.lua`, `git_spec.lua`, `rendermark_wrap_spec.lua`, `rendermark_image_spec.lua`).
