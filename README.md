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
| `lua/launcher.lua` | Asynchronous program launcher |
| `lua/prjroot.lua` | Project root detection (`.git`, `.prjroot`, etc.) |
| `lua/session.lua` | Session management per project root |
| `lua/status.lua` | Custom statusline with LSP, git branch/commit, diagnostics |
| `lua/git.lua` | Git branch and commit info with TTL caching |
| `lua/grep.lua` | RipGrep integration |
| `lua/msbuild.lua` | MSBuild integration |
| `lua/util.lua` | Shared utilities (memoize, serialize, keymaps, …) |

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
- `nvim-lua/lsp-status.nvim` — LSP status in statusline

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
- `MeanderingProgrammer/render-markdown.nvim` — rendered markdown in buffer

**Misc**
- `weirongxu/plantuml-previewer.vim` — PlantUML preview

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim).

```sh
bash run_tests.sh
```

Specs in `tests/spec/`: `util_spec.lua`, `prjroot_spec.lua`, `git_spec.lua`.
