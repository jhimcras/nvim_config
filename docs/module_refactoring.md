# Module refactoring verification

## Stage 0 baseline (2026-10-07)

Environment: Linux, NVIM v0.12.4 (RelWithDebInfo), LuaJIT 2.1.1784580905.
Measurements use the working tree before namespace migration, including the
existing uncommitted test-runner/spec improvements. Those changes are not part
of the stage 0 commit. Existing installed plugin data was preserved; every
process had temporary XDG config/state/cache directories and disabled shada.
The benchmarks ran in separate Neovim processes, with up to four independent
benchmarks at once. Timings therefore describe this run, not a guaranteed
performance budget; compare repeated runs with the same workloads before
attributing a small timing difference to refactoring.

`bash run_tests.sh`: exit 0, 518 successes, 0 failures, 0 errors across 48 spec
batches. Full local log: `/tmp/module-refactoring-unit-baseline.log`.

### Require graph

Run `python3 scripts/check_require_graph.py`; optional `--root PATH` inspects
another checkout. Exit 1 reports architectural problems, exit 0 reports none.
The baseline has 55 modules, 134 local edges, 7 layer violations, 4 cyclic groups.

| Source | Target |
| --- | --- |
| file_info | status |
| grep | status.spinner |
| launcher | status.spinner |
| instance_move | plugins.tele |
| session | tabline |
| util | launcher |
| util | prjroot |

Cyclic groups:

- launcher, prjroot, process_list, util
- lsp_setting, lsp_setting.clangd, lsp_setting.lua_ls, lsp_setting.python
- rendermark.deco, rendermark.html, rendermark.image, rendermark.image.scan, rendermark.wrap
- instance_move, plugins, plugins.tele

The scanner includes delayed literal requires, `pcall(require, 'name')`, and
literal paths embedded in statusline/operator/RPC strings. It excludes external
modules and self references: a module's own command string is not an intermodule
cycle. It supports both the old tree and `nvim_config` prefix automatically.
It is a text scan, not a full Lua parser; dynamically constructed names cannot
be resolved, and inline comment/string text can produce conservative edges.
The layer map treats `launcher.registry` and the future shared `spinner` as L1,
util modules as L0, status/tabline as L3, assembly/plugin modules as L4, and other
features as L2. L0 may use env/internal util modules; L1 may require only L0.

Additional requirements beyond the issue's explicit stage list: remove
`file_info -> status`, move the shared spinner below features, and break the
`plugins -> plugins.tele -> plugins` dependency as well as the instance picker
cycle. The original graph is expected to fail until the relevant stages finish.

### Benchmark invocation

From the repository root, create a temporary directory and set
`XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, and `NVIM_LOG_FILE` beneath
it, while leaving `XDG_DATA_HOME` at the installed plugin location. Use:

```bash
nvim --headless -i NONE -u NONE -l tests/manual/benchmark_launcher.lua
nvim --headless -i NONE -u NONE --cmd 'set lines=50 columns=140' -l tests/manual/benchmark_markdown_cursor.lua
nvim --headless -i NONE -u tests/minimal_init.lua -l tests/manual/benchmark_markdown_html.lua
nvim --headless -i NONE -u NONE -l tests/manual/benchmark_image_reapply.lua
nvim --headless -i NONE -u NONE -l tests/manual/benchmark_plantuml_scan.lua
nvim --headless -i NONE -u NONE -l tests/manual/benchmark_grep_timer.lua
python3 tests/manual/benchmark_statusline_shrink.py
python3 tests/manual/benchmark_spinner.py
```

For the two PTY benchmarks, set `STATUSLINE_BENCH_OUTPUT` to separate result
files. Their helper scripts still use their own fixed `/tmp` PTY/log paths.
All eight commands exited 0. Raw output follows so counts and timings remain
available after temporary logs disappear. Spinner's `before`/`after` labels
refer to the benchmark's timer implementations, not this module refactor.

#### launcher

```text
{"launcher":[{"chunks":1000,"median_ms":56.431951},{"chunks":2000,"median_ms":126.687278},{"chunks":4000,"median_ms":263.728702}],"ansi":[{"mean_ms":0.0202119,"bytes":1024},{"mean_ms":0.13850725,"bytes":10240},{"mean_ms":0.5792347999999999,"bytes":55296}],"nvim":"0.12.4+v0.12.4"}
```

#### markdown_cursor

```text
lines=5016 window=80x22 visible=1201..1211
idle         median   0.006 ms  p95   0.009 ms  extmarks/step    0.0  clears/step   0.0
j/k          median   1.820 ms  p95   2.646 ms  extmarks/step    3.3  clears/step   2.0
l/h          median   0.140 ms  p95   0.207 ms  extmarks/step    0.0  clears/step   0.0
typing/key   median   0.599 ms  p95   0.746 ms  extmarks/step    0.0  clears/step   2.0
typing/burst median  18.010 ms of wrap CPU per 20-key burst
full         median   6.681 ms  p95   8.775 ms  extmarks/step   45.0  clears/step   3.0
```

#### markdown_html

```text
kind,lines,median_ms,p95_ms,full_reads_per_edit,parser_requests_per_edit
plain,1000,0.066,0.131,1.0,0.0
plain,10000,0.569,0.598,1.0,0.0
plain,50000,3.092,3.585,1.0,0.0
sparse,1000,6.945,7.575,1.0,1.0
sparse,10000,78.545,83.531,1.0,1.0
sparse,50000,400.851,431.387,1.0,1.0
dense,1000,19.940,20.831,1.0,1.0
dense,10000,217.396,224.041,1.0,1.0
dense,50000,1155.285,1196.070,1.0,1.0
```

#### image_reapply

```text
{"scenario":"unchanged","ms":787.692627,"calls":{"set":0,"del":0,"clear":0,"redraw":0,"mark":0}}
{"scenario":"one-image-size-changed","ms":823.2949589999999,"calls":{"set":1000,"del":0,"clear":1000,"redraw":1000,"mark":2000}}
```

#### plantuml_scan

```text
{"full_reads":1,"scenario":"send_images-cold","ms_per_call":3.983579,"iterations":1}
{"full_reads":0,"scenario":"send_images-unchanged","ms_per_call":0.09570387,"iterations":200}
{"full_reads":0,"scenario":"cursor-unchanged","ms_per_call":0.002697414,"iterations":500}
{"full_reads":100,"scenario":"send_images-edited","ms_per_call":0.80476842,"iterations":100}
```

#### grep_timer

```text
{"nvim":"0.12.4+v0.12.4","rows":[{"rounds":20,"active_immediately":0,"idle_ticks":0,"cpu_ms":36.31099999999999,"scenario":"exit"},{"rounds":20,"active_immediately":0,"idle_ticks":0,"cpu_ms":37.22299999999999,"scenario":"signal"},{"rounds":20,"active_immediately":0,"idle_ticks":0,"cpu_ms":31.985,"scenario":"close"}]}
```

#### statusline

```text
{"rows":[{"calls":{"search":51,"entry":204,"lsp":50},"width":24,"active":"general","redraw_ms":815.581128,"drained_ms":869.379447},{"calls":{"search":52,"entry":208,"lsp":1},"width":23,"active":"quickfix","redraw_ms":25.69445,"drained_ms":79.28010399999999},{"calls":{"search":51,"entry":204,"lsp":50},"width":119,"active":"general","redraw_ms":819.658968,"drained_ms":873.497738},{"calls":{"search":50,"entry":200,"lsp":0},"width":120,"active":"quickfix","redraw_ms":21.096955,"drained_ms":74.709763}],"iterations":50,"lines":5000,"nvim":{"build":"v0.12.4","api_level":14,"api_prerelease":false,"major":0,"minor":12,"patch":4,"api_compatible":0}}
```

#### spinner

```text
{"nvim":{"api_level":14,"api_prerelease":false,"major":0,"minor":12,"patch":4,"api_compatible":0,"build":"v0.12.4"},"rows":[{"drained_ms":2374.749504,"scenario":"visible","calls":{"entry":604,"search":151,"lsp":151},"implementation":"before","width":24,"redraw_ms":2320.939999},{"drained_ms":64.06031400000001,"scenario":"visible","calls":{"entry":104,"search":1,"lsp":1},"implementation":"after","width":24,"redraw_ms":10.487977},{"drained_ms":820.00266,"scenario":"hidden","calls":{"entry":204,"search":51,"lsp":51},"implementation":"before","width":24,"redraw_ms":766.256411},{"drained_ms":54.421838,"scenario":"hidden","calls":{"entry":0,"search":0,"lsp":0},"implementation":"after","width":24,"redraw_ms":0.614197}],"iterations":50,"lines":5000}
```

### Remaining verification

Real-init cold/warm startup and first-use plugin timing were not measured in
stage 0. The headless workloads above do not represent actual GUI image output,
real terminal redraw, external language servers, or real plugin startup. Run
real-init lazy-load cases and manual UI checks after migration; retain stored
session data formats and restart old instances for the new RPC module paths.
