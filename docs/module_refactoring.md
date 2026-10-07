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

## Stage 0a namespace migration (2026-10-07)

All 55 own modules moved under `lua/nvim_config` without splitting functions.
Internal require paths, Vim expression/RPC strings, module-cache mocks, manual
scripts and README paths now use the prefix. A comparison against stage 0
confirmed that removing `nvim_config.` from every migrated runtime file restores
its exact previous contents. Public APIs, state and setup order are preserved.

Only `env` and `msbuild` retain temporary forwarding shims: the external
`/home/ilmoek/workspace/image/.prjroot` still uses those names. Each shim returns
the same module table and performs no setup. Remove them after that external
configuration migrates. All 25 audited saved sessions contained no old require
strings. Restart running instances together before using instance-transfer RPC.

Verification: unit suite 518 successes, integration suite 11 successes, six
real-init lazy-load assertions passed (Telescope key/command, Config, Git, GV,
coverage), and both shim identities passed. The InsertEnter case reports
`vsnip source not registered` and pckr `Invalid group: cmp_nvim_lsp`; the exact
failure also occurs in the untouched stage 0 checkout with the installed plugins.
Git assertions pass but the installed Fugitive exit callback reports missing
`stdout`. Headless Neovim exits 0 despite Lua assertions, so logs were inspected. Existing dirty test-runner
and spec changes, and untracked integration/spec files, are preserved and remain
outside the stage commit; their namespace references were updated in the working
tree so the complete suite tests the migrated implementation. T01–T10 remain.

The require graph now has 57 nodes and 136 edges because of the two compatibility
shims. The same 7 layer violations and 4 cyclic groups remain for later stages.

All eight existing benchmark workloads completed. Launcher 1k/2k/4k chunks
measured 51.5/101.9/225.5 ms. Image reapply with unchanged images retained zero
emits, redraws, clears and extmarks; PlantUML unchanged paths retained zero full
reads. Status/spinner component counts and HTML full reads/parser requests match
stage 0. Grep timer cleanup retained zero active timers and idle ticks; a repeat
returned 35.7/38.1/30.0 ms for exit/signal/close, within baseline run variation.
Other timings vary with terminal scheduling; no timing improvement is claimed.
Full local logs: `/tmp/namespace-benchmark-*.log`.

Real-init startup, using three separate processes per case and isolated caches,
measured a cold-cache median of 94.539 ms (90.290/94.539/95.862) and warm-cache
median of 64.926 ms (64.926/65.150/63.127). Cold here means an empty Neovim loader
cache, not a cleared OS disk cache. Startup logs exclude exit cleanup. Stage 0
did not measure this workload, so these are post-migration references only.

Real-init lazy-case command (installed plugin data is retained, with temporary
XDG config/state/cache and NVIM_LOG_FILE; run with local RPC socket permissions):

```sh
NVIM_LAZY_TEST=insert nvim --headless -i NONE \
  --cmd 'set rtp^=/home/ilmoek/workspace/nvim_config' \
  -u init.lua -c 'luafile tests/test_lazy_plugins.lua' -c 'qa!'
```

The same command against a stage 0 archive in `/tmp/namespace-pre-migration`,
using its runtimepath/init/script, reproduces the InsertEnter error. Other cases
are `telescope-key`, `telescope-command`, `config`, `git`, `gv`, `coverage`.
Startup timing uses the same real init/runtimepath, replacing the Lua test with
`--startuptime /tmp/<sample>.log -c 'qa!'`; cold processes use a fresh cache,
warm processes share one cache after one unrecorded warmup. The temporary harness
is `/tmp/namespace_startup.py`; lazy harness `/tmp/namespace_lazy.sh`.

## Stage 2 utility decomposition (2026-10-07)

`nvim_config.util` is now an `init.lua` facade over buffer, text, map, hl, job,
cache, and serialize modules. Internal runtime modules import the specific
helpers they use; public utility functions remain available through the facade.
`OpenProjectRootTerminal` moved to `nvim_config.prjroot`, and terminal keymaps
call it there. No utility module requires a feature or infrastructure module.
The facade exports the same function references rather than copying state;
process/scratch-buffer mocks and manual benchmarks now patch job/buffer modules.

Validation: full unit suite exit 0 (515 successes, 0 failures, 0 errors across
47 batches), full integration suite 11/11 passed. The unit log still contains
the baseline's fake launcher-handle cleanup error and temporary-file E211
message; neither is a new stage 2 failure. The graph now has 62 modules and
153 edges, 5 layer violations, and 4 cyclic groups. The launcher cycle is
reduced to launcher/process_list; util/prjroot are no longer in a cyclic group.

The launcher benchmark retains all output/match assertions: 1k/2k/4k chunks
have medians 51.252/102.092/222.935 ms. The grep timer benchmark still asserts
one timer per search and reports zero active timers and zero idle ticks after
exit, signal, and close. Its CPU readings vary materially between runs, so a
separate sequential pre-stage/post-stage comparison was also performed using
the original grep and benchmark files from the stage 1 commit in isolated
Neovim processes; no code from both versions is loaded into one process.

| grep scenario (20 rounds) | Pre-stage CPU ms | Post-stage CPU ms |
| --- | ---: | ---: |
| exit | 77.629 | 76.661 |
| signal | 73.323 | 82.549 |
| close | 51.768 | 66.150 |

The original stage 0 readings were 36.311/37.223/31.985 ms, while this run's
pre-stage readings are also substantially higher. The isolated pair gives
mixed timing results; it does not establish a sustained performance regression.
CPU timing remains a noisy diagnostic for this wait-heavy workload; deterministic
timer cleanup assertions passed in both versions. Additional repeated timing
comparisons are needed before interpreting the signal/close deltas as a change.

## Stage 3 settings and assembly (2026-10-07)

`init.lua` now shows the independent setup calls: tabline setup follows status
setup directly. Status no longer initializes tabline. Unit minimal init retains
its previous headless skip; integration uses the real assembly. Plugin lazy
callbacks and rendermark internal setup remain at their existing initialization
points.

Fold text, terminal options, external-file reload and header detection now live
in setting. Fold text evaluates `nvim_config.setting.fold_text` rather than the
removed global `FoldText`. Grep/GrepWord and SaveSession commands register in
their owning setup functions; options, completion and keymaps retain their
behavior. Completion keeps an explicit module expression.

Verification: full unit suite exits 0; integration 11 cases pass, including real
header detection, external reload, terminal behavior, commands, statusline and
tabline. New tests evaluate fold text without the global helper and exercise
actual SaveSession command completion. Real-init fold-text/command expressions
pass with Telescope and cmp still unloaded (`/tmp/stage3_startup.lua`), using
test-owned XDG config/state/cache/log paths. The require graph retains 5 layer
violations and 4 cyclic groups; session notifications remain for stage 5.

## Stage 5 qflist and session decomposition (2026-10-07)

Grep now owns rg process stages and prompts: previous-job confirmation,
stream callbacks, list creation, window lifecycle, argument construction, and
process registration/cancellation. Search state, including the project root,
travels in one context; timer/callback scheduling and registry ownership remain
unchanged. Generic list tags/highlights, filter chains/commands, and edit/sort
operators live in `qflist/tag.lua`, `filter.lua`, and `edit.lua`. Their setup
calls are explicit beside grep in init; status and session list persistence use
the qflist modules directly. Operator strings now target `qflist.edit`.

Session uses `session/init.lua` for public commands, `lists.lua` for existing
quickfix/loclist/launcher sidecar formats and restore order, and `exit_guard.lua`
for process/modified-buffer inspection and quit handling. Process inspection
reads the shared registry directly. The command wrapper is still installed by
setup, forwards indexed native commands through the original metatable, and
preserves forced quit, write-before-quit, cancellation, and QuitPre behavior.
The guard receives a dynamic process getter, preserving public process getter
mocking without a require back to the session parent.

### Session event contract

Both notifications are synchronous `User` autocmds; no new schedule/debounce
boundary is introduced. Payload is `{ action, path, session }`: `path` is the
affected session file, and `session` is `vim.v.this_session` after the operation.

| Event | action | Emission point |
| --- | --- | --- |
| SessionChanged | save | After sidecars, mksession, and success notification |
| SessionChanged | remove | After deleting the target and clearing current session when appropriate |
| SessionChanged | close | After process termination, buffer wipeout, cwd reset, current-session clearing, and quickfix clearing |
| SessionLoaded | open | After sourcing the session, setting every list before opening windows, restoring matches/cursors, and resetting cmdheight |

Cancelled operations and missing-session removals emit nothing. Tabline handles
both events with a synchronous full refresh, preserving immediately visible
SaveSession updates and showing fully restored state on OpenSession. Native
`nvim -S` keeps its existing `SessionLoadPost` handler.

### Validation

Full unit suite and all 11 integration cases exit 0. Added four tests for
event payload/order, synchronous tabline updates, restored lists/cmdheight,
and cancelled/missing operations; two process tests cover split read chunks,
project roots differing from cwd, and queued reads after cancellation. An
initial complete run reported 526 successful assertions in 50 batches. The
final full run reported 503 successes in 49 summaries; the launcher worker
printed 22 successes then exited without its summary. Its targeted rerun
completed all 23 launcher tests with no failures/errors. The baseline fake
launcher-handle cleanup and temporary-file E211 messages remain unchanged.

Graph: 72 modules, 187 local edges, 2 upward violations, 3 cyclic groups.
Session no longer requires tabline, and qflist/grep/session introduce no cycles.
The remaining violations are file_info -> status and instance_move -> plugins.tele;
remaining cyclic groups are LSP server/parent, rendermark, and plugin/picker.

Both targeted benchmarks exited 0. Grep timer cleanup still reports no active
timers and no idle ticks in all three scenarios. Statusline search/LSP/entry
counts exactly match the stage 0 workload; timings remain subject to the
run-to-run variation documented above. Raw outputs:

```text
{"rows":[{"cpu_ms":49.818,"scenario":"exit","rounds":20,"active_immediately":0,"idle_ticks":0},{"cpu_ms":71.98700000000001,"scenario":"signal","rounds":20,"active_immediately":0,"idle_ticks":0},{"cpu_ms":48.59099999999999,"scenario":"close","rounds":20,"active_immediately":0,"idle_ticks":0}],"nvim":"0.12.4+v0.12.4"}
```

```text
{"lines":5000,"iterations":50,"nvim":{"api_compatible":0,"build":"v0.12.4","minor":12,"patch":4,"major":0,"api_level":14,"api_prerelease":false},"rows":[{"redraw_ms":958.534639,"drained_ms":1013.242645,"width":24,"calls":{"search":51,"entry":204,"lsp":50},"active":"general"},{"redraw_ms":39.753378,"drained_ms":97.00398199999999,"width":23,"calls":{"search":52,"entry":208,"lsp":1},"active":"quickfix"},{"redraw_ms":904.646658,"drained_ms":960.845681,"width":119,"calls":{"search":51,"entry":204,"lsp":50},"active":"general"},{"redraw_ms":27.096964,"drained_ms":82.11129,"width":120,"calls":{"search":50,"entry":200,"lsp":0},"active":"quickfix"}]}
```

## Stage 6 status and LSP (2026-10-07)

Status is now an entry/setup facade, component/render helpers and layouts.
One render context/cache survives every shrink pass; the public API table travels
with that context so existing `status.lsp`/`current_function` overrides remain
visible without a component-to-parent dependency. Tree-sitter symbol lookup
lives in the L2 symbol module and the LSP summary in lsp/status. FileInfo now
reads those feature helpers directly, removing its upward status dependency.

LSP assembly now lives in lsp/init, common attachment in attach, float decoration
in float, progress state in progress and server settings under servers. Requiring
LSP leaves the global floating-preview handler unchanged. Explicit setup installs
one wrapper; repeated setup retains that wrapper. Diagnostic symbols and progress
state aliases remain public, with one progress-state table. Markdown actions and
rename helpers live in rendermark; completion sources under rendermark/complete.

Verification: full unit suite exits 0 (526 success lines), all 11 integrations
pass, including actual FileInfo and statusline rendering. Float load/setup regression
verifies no load-time replacement, idempotent setup, one underlying preview call,
and unchanged border options. The status benchmark retains exactly the baseline
entry/search/LSP counts in all four layouts; general redraw timings are 769/760 ms
versus baseline 816/820 ms, with no improvement claim. Local logs:
`/tmp/stage6-unit.log`, `/tmp/stage6-integration.log`, `/tmp/stage6-status-benchmark.log`.
The graph now has one upward dependency and two cyclic groups, scheduled for
stages 7 and 8. Independent setup order and plugin lazy callbacks are preserved.

## Stage 7 Markdown wrapping and image decomposition (2026-10-07)

Wrap now owns orchestration/setup in wrap/init, inline collection in inline,
and table parsing/layout/rendering in table. Shared table_state owns table
queries and placements; image scan reads it without requiring wrap. The public
wrap table helpers retain the same references. Read mode and HTML details publish
synchronous User events instead of requiring wrap. ReadModeChanged carries
`{ win, buf, active }` after mode options/state are applied; MarkdownDetailsChanged
carries `{ win, buf }` after HTML repaint. Wrap refreshes that window immediately
only if it still exists and displays that buffer. Duplicate mode transitions and
unsuccessful details toggles emit nothing.

Image is split into init, blocks, screen, stub, layout, preview, plantuml and
place, retaining backend/scan/size/extmarks. Init owns one public API and shared
state; helper factories receive those references without requiring their parent.
Placement orchestration delegates window collection, scanning, reservation,
layout, decoration and payload stages. Reservation changes still defer payloads
until resync; unchanged payloads/extmarks remain skipped.

Six regression tests cover event timing/targets/duplicates/shared table cleanup,
reservation deferral/signature skip, and nested/failed image sync recovery.
Original/extracted function review found no unrelated behavior changes. Full
integration: 11/11 passed with test-owned local tmux/RPC sockets. The initial
sandbox-only invocation could not create those sockets; the permitted rerun passed.
Final full unit suite: exit 0, 531 success lines, 50 summaries, no reported
failures/errors (`/tmp/stage7-image-review-full-unit.log`). As seen in stage 5,
the launcher worker printed 22 success lines without a summary; its isolated
rerun completed all 23 tests with zero failures/errors
(`/tmp/stage7-launcher-final.log`). The added image fixture initially
counted unrelated Tree-sitter redraw callbacks; it now captures only image
resync callbacks. No production change was needed. Existing baseline fake
launcher-handle cleanup and temporary-file E211 messages remain.
Graph: 89 modules, 212 local edges, one upward violation and one cyclic group,
all involving instance_move/plugins/tele and reserved for stage 8.

Benchmarks used isolated XDG config/state/cache/log paths and existing plugin data.
The first cursor run overlapped HTML/other tests and measured typing/burst 43.153ms;
a separate sequential HEAD/current pair measured 31.418/22.111ms. Counters matched
in every run. These timings do not establish a performance improvement. Image
HEAD/current comparisons likewise retain counts; GUI image output and actual
external PlantUML rendering remain manual acceptance checks.

### Sequential cursor baseline (stage 6 HEAD)

```text
lines=5016 window=80x22 visible=1201..1211
idle         median   0.005 ms  p95   0.010 ms  extmarks/step    0.0  clears/step   0.0
j/k          median   1.544 ms  p95   2.209 ms  extmarks/step    3.3  clears/step   2.0
l/h          median   0.141 ms  p95   0.215 ms  extmarks/step    0.0  clears/step   0.0
typing/key   median   0.610 ms  p95   0.798 ms  extmarks/step    0.0  clears/step   2.0
typing/burst median  31.418 ms of wrap CPU per 20-key burst
full         median   6.763 ms  p95   9.229 ms  extmarks/step   45.0  clears/step   3.0
```

### Sequential cursor after stage 7

```text
lines=5016 window=80x22 visible=1201..1211
idle         median   0.004 ms  p95   0.008 ms  extmarks/step    0.0  clears/step   0.0
j/k          median   1.475 ms  p95   2.343 ms  extmarks/step    3.3  clears/step   2.0
l/h          median   0.092 ms  p95   0.196 ms  extmarks/step    0.0  clears/step   0.0
typing/key   median   0.599 ms  p95   0.779 ms  extmarks/step    0.0  clears/step   2.0
typing/burst median  22.111 ms of wrap CPU per 20-key burst
full         median   5.304 ms  p95   6.504 ms  extmarks/step   45.0  clears/step   3.0
```

### HTML after stage 7

```text
kind,lines,median_ms,p95_ms,full_reads_per_edit,parser_requests_per_edit
plain,1000,0.068,0.150,1.0,0.0
plain,10000,0.553,0.594,1.0,0.0
plain,50000,3.099,6.270,1.0,0.0
sparse,1000,6.357,7.715,1.0,1.0
sparse,10000,75.784,87.384,1.0,1.0
sparse,50000,411.340,452.416,1.0,1.0
dense,1000,20.124,20.600,1.0,1.0
dense,10000,225.833,249.586,1.0,1.0
dense,50000,1175.649,1268.446,1.0,1.0
```

### Image reapply before stage 7

```text
{"scenario":"unchanged","ms":810.495118,"calls":{"set":0,"del":0,"redraw":0,"mark":0,"clear":0}}
{"scenario":"one-image-size-changed","ms":793.62392,"calls":{"set":1000,"del":0,"redraw":1000,"mark":2000,"clear":1000}}
```

### Image reapply after stage 7

```text
{"calls":{"clear":0,"set":0,"redraw":0,"mark":0,"del":0},"scenario":"unchanged","ms":786.514982}
{"calls":{"clear":1000,"set":1000,"redraw":1000,"mark":2000,"del":0},"scenario":"one-image-size-changed","ms":778.1531670000001}
```

### PlantUML before stage 7

```text
{"full_reads":1,"scenario":"send_images-cold","ms_per_call":3.714582,"iterations":1}
{"full_reads":0,"scenario":"send_images-unchanged","ms_per_call":0.09689693000000001,"iterations":200}
{"full_reads":0,"scenario":"cursor-unchanged","ms_per_call":0.002554916,"iterations":500}
{"full_reads":100,"scenario":"send_images-edited","ms_per_call":0.7740575,"iterations":100}
```

### PlantUML after stage 7

```text
{"iterations":1,"full_reads":1,"scenario":"send_images-cold","ms_per_call":1.092425}
{"iterations":200,"full_reads":0,"scenario":"send_images-unchanged","ms_per_call":0.09524257999999999}
{"iterations":500,"full_reads":0,"scenario":"cursor-unchanged","ms_per_call":0.002559588}
{"iterations":100,"full_reads":100,"scenario":"send_images-edited","ms_per_call":0.8945039300000001}
```
