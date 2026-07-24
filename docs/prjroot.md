# `.prjroot` Manual

## What is `.prjroot`?

A `.prjroot` file is a **Lua file** placed at a project root directory. Neovim detects it as a root marker and loads it on `BufRead` to apply per-project configuration.

The file must return a Lua table:

```lua
return {
  -- keys go here
}
```

---

## Root detection

The project root is the nearest ancestor directory containing any of:
- `.git`
- `.prjroot`
- `compile_command.json`
- `compile_flags.txt`
- `README.md`

---

## Top-level keys

### `options` — Buffer-local vim options

Applied to every buffer opened inside the project.

```lua
return {
  options = {
    shiftwidth = 2,
    tabstop = 2,
    expandtab = true,
    -- any vim.bo option
  }
}
```

Any `vim.bo` (buffer-local) option key is valid.

---

### `lsp_env` — LSP server environment variables

Sets `cmd_env` for LSP servers (`clangd`, `lua_ls`, `ty`) when opening files in this project.

```lua
return {
  lsp_env = {
    VIRTUAL_ENV = '/path/to/.venv',
    PATH = '/path/to/.venv/bin:/usr/bin',
  }
}
```

Applied on `BufReadPre`, before the LSP server starts.

---

### `clangd_args` — extra clangd command-line flags

Appended to the default clangd command line for this project. Use it to throttle a
project whose background index is too heavy — see [clangd.md](clangd.md).

```lua
return {
  clangd_args = { '-j=2' },
}
```

clangd takes the **last** occurrence of a repeated flag, so an entry here overrides the
matching default.

Applied on `BufReadPre`, before the LSP server starts — so it only affects servers
started afterwards. If clangd is already attached to this project, run `:LspRestart`.

---

### Launcher objects — named build/run tasks

Any launcher definition should be placed inside a `launchers` table. Each object defines a command that can be run asynchronously in a scratch buffer.

```lua
return {
  launchers = {
    build = {
      cmd      = 'cmake',
      args     = { '--build', 'build' },
      cwd      = './build',       -- relative (.) is expanded to project root
      key      = '<f5>',          -- optional buffer-local keymap to trigger this
      env      = { CC = 'clang' },-- optional environment variables
      position = { orientation = 'vertical' },  -- or 'horizontal', 'tab', 'external'
      highlight = {
        ['error']   = 'ErrorMsg',
        ['warning'] = 'WarningMsg',
      },
    },
    run = {
      cmd  = './my_app',
      args = {},
      key  = '<f6>',
    },
  },
}
```

#### Launcher object fields

| Field | Type | Required | Description |
|---|---|---|---|
| `cmd` | string | yes | Executable to run |
| `args` | string[] | yes | Command arguments |
| `cwd` | string | no | Working directory. A leading `.` is replaced by the project root. Defaults to project root. |
| `key` | string | no | Buffer-local normal keymap that triggers this launcher |
| `env` | table | no | Extra environment variables as `{ KEY = 'value' }` |
| `position` | table or `'external'` | no | Where to open the output buffer. `{ orientation = 'vertical' }` (default), `'horizontal'`, `'tab'`, or `'external'` (no window, background only) |
| `highlight` | table | no | `{ pattern = 'HlGroup' }` pairs — matched with `matchadd` in the output buffer |
| `patterns` | table | no | Named output-line matchers used to extract jump targets (`<CR>` in the output buffer). See below. |

#### `patterns` — extracting jump targets from output lines

Each entry in `patterns` matches a line of output and extracts fields (typically `filename`, `row`, `column`) used by `<CR>` to open the file:

```lua
patterns = {
  error = {
    pattern   = '%d+>(%S+)%((%d+)%): (error) (C%d+)',  -- Lua pattern, one capture per extract field
    extract   = { 'filename', 'row', 'tag', 'errorcode' },
    highlight = { [1] = '#BB0000', [3] = '#DD0000' },    -- capture index -> hl color/group

    -- Optional: compute the base directory for resolving a *relative* filename.
    -- Called with the extracted fields and the raw line; return an absolute
    -- directory, or nil to fall through to the project root / an on-disk search.
    -- Useful when relative paths in the output are relative to something other
    -- than the project root (e.g. an MSVC project file's directory, which may
    -- itself appear elsewhere on the same line).
    base_dir = function(match, line)
      local proj = line:match('%[([^%[%]]+%.vcxproj)%]%s*$')
      if proj then
        return vim.fn.fnamemodify(proj:gsub('\\', '/'), ':h')
      end
    end,
  },
}
```

Resolution order for a matched `filename` on `<CR>`: as-is, then under `base_dir` (if the pattern defines one), then under the project root, then (if still not found) an on-disk search under the project root — opening the file directly if exactly one candidate is found, or a quickfix list to pick from if there are several.

---

## Commands

| Command | Description |
|---|---|
| `:PrjRootConfig` | Opens `.prjroot` in a vertical split for editing |

---

## Example — full file

```lua
return {
  options = {
    shiftwidth = 4,
    tabstop = 4,
    expandtab = false,
  },

  lsp_env = {
    VIRTUAL_ENV = '/home/user/projects/myapp/.venv',
  },

  clangd_args = { '-j=2' },

  launchers = {
    build = {
      cmd      = 'make',
      args     = { '-j8' },
      key      = '<f5>',
      highlight = {
        ['error:']   = 'ErrorMsg',
        ['warning:'] = 'WarningMsg',
      },
    },

    test = {
      cmd      = 'pytest',
      args     = { '-v' },
      cwd      = './tests',
      key      = '<f6>',
      position = { orientation = 'horizontal' },
    },
  },
}
```
