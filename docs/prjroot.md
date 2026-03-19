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

### Launcher objects — named build/run tasks

Any key that is **not** `options` or `lsp_env` is treated as a launcher object. Each object defines a command that can be run asynchronously in a scratch buffer.

```lua
return {
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
}
```
