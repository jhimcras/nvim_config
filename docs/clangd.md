# clangd — reducing indexing load

Background indexing a large C/C++ project can saturate the machine. This is worst on
Windows, where the index writes thousands of small files and real-time AV scanning
amplifies the I/O cost.

Three levers, roughly in increasing order of effect:

---

## 1. Default flags (already applied)

`lua/lsp_setting/clangd.lua` builds the clangd command line in `M.cmd()`:

| Flag | Why |
|---|---|
| `-j=<cores/2>` | clangd defaults to one async worker per CPU core, and the background index draws from that same pool. Halving it leaves cores free for interactive work. Floor of 2. |
| `--background-index-priority=background` | The default is `low`, not `background`. `background` is the lowest tier — on Windows it maps to background thread mode, which lowers **disk I/O** priority as well as CPU. |

Background indexing stays on, so workspace symbols, project-wide references and call
hierarchy keep working — they just warm up more slowly.

Check what a running server actually got:

```vim
:lua =vim.lsp.get_clients({name='clangd'})[1].config.cmd
```

---

## 2. Per-project override — `.prjroot`

To throttle one heavy project without slowing down everything else, add `clangd_args`
to its `.prjroot` (see [prjroot.md](prjroot.md)):

```lua
return {
  clangd_args = { '-j=2' },
}
```

Entries are appended after the defaults, and clangd takes the last occurrence of a
repeated flag — so `-j=2` wins over the computed `-j=`.

This is applied on `BufReadPre`, which only affects servers started afterwards. If
clangd is already attached to the project, run `:LspRestart`.

---

## 3. Shrink what gets indexed — `.clangd`

Usually the biggest win. This is **not** a Neovim setting: it is a `.clangd` YAML file
placed at the root of the C++ project itself. It tells clangd to skip building
background index shards for paths you never navigate into:

```yaml
If:
  PathMatch: [third_party/.*, build/.*, generated/.*]
Index:
  Background: Skip
```

`PathMatch` entries are regexes matched against the file path. Cutting vendored and
generated trees out of the index removes translation units from the work queue
entirely, rather than just doing the same work more slowly.

---

## Windows

clangd stores its index as thousands of small shard files under
`<project>/.cache/clangd/index/`. Windows Defender's real-time protection scans every
one of them as it is written, which inflates both indexing time and disk load far
beyond what the same project costs on Linux.

Adding `.cache/clangd` and the build tree to Defender's exclusion list is typically the
single most effective change on Windows — more than any flag above. It is an OS-level
setting, not something this config can do.
