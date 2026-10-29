# PlantUML block scan comparison

The block list and PlantUML height spans share a buffer/changedtick cache.
A cache miss reads the buffer once and scans its fences; subsequent cursor,
collection, and preview queries reuse it. Buffer cleanup clears the cache,
including buffers that never created a preview state. External virt_text
queries block heights only when it contains an image link. Unclosed PlantUML
fences still provide height spans without being rendered.

Measured with headless Neovim, stubbed image transport, 3000 markdown lines,
and 60 external decoration extmarks. The headless viewport collected 23 of
those marks. No actual PlantUML process or image decoding was involved.
Baseline used the original image.lua and image/scan.lua copied before editing.
Times are means for the indicated number of calls; cold is a single sample.

| Scenario | Calls | Before ms/call | After ms/call | Full buffer reads before → after |
| --- | ---: | ---: | ---: | ---: |
| Cold send_images | 1 | 23.349 | 5.254 | 24 → 1 |
| Unchanged send_images | 200 | 15.491 | 0.138 | 4800 → 0 |
| Unchanged cursor signature | 500 | 0.659 | 0.004 | 500 → 0 |
| send_images after each edit | 100 | 15.570 | 0.800 | 2400 → 100 |

Unchanged send_images improved about 112× (99.1% less time). Editing still
requires a full scan, once per changedtick. These measurements isolate scan
cost and do not represent real GUI rendering or PlantUML generation latency.

Reproduce:

```sh
nvim --headless -u NONE -l tests/manual/benchmark_plantuml_scan.lua
IMAGE_BENCH_BASELINE=/path/to/original/snapshot nvim --headless -u NONE -l tests/manual/benchmark_plantuml_scan.lua
```

The full test suite passed, including regression checks for shared reads,
edit invalidation, explicit cleanup, unfinished fences, and decoration filtering.

## After R3: provider-based diagram items (2026-10-30)

The scan above no longer exists. `image/blocks.lua` (fence scan) was removed
and rendermark now asks a diagram provider for DiagramItems
(`set_diagram_source`). The provider answer is cached per buffer by
changedtick and dropped by `refresh(buf)`, so the cost left in the hot path is
one provider call per edit (a memory lookup in coderunner) and none for
cursor, scroll and unchanged `send_images`.

Same workload as above (headless Neopp stub, 3000 lines, 60 decoration
extmarks, `vim.ui.img` stubbed), 3 runs each, range of the means. "Before" is
the HEAD commit before R3 run through the updated script
(`IMAGE_BENCH_BASELINE`), "after, no provider" is the same buffer with no
provider registered, "after, provider" registers a fake provider with 10 ready
PNG blocks (5 inside the viewport, `BENCH_PROVIDER=1`), where the extra
`send_images` cost is the five visible images being collected and laid out.

| Scenario | Calls | Before ms/call | After, no provider | After, provider (10 blocks) | Provider calls (after) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold send_images | 1 | 1.01-1.28 | 0.27-0.33 | 0.57-0.70 | 1 |
| Unchanged send_images | 200 | 0.091-0.101 | 0.089-0.103 | 0.268-0.285 | 0 |
| Unchanged cursor signature | 500 | 0.003 | 0.002-0.003 | 0.003 | 0 |
| send_images after each edit | 100 | 0.732-0.754 | 0.087-0.089 | 0.280-0.289 | 100 |

Full buffer reads are 0 in every "after" row (before: 1 cold, 100 for the
edited scenario). The old edit cost was the fence scan; it is now a provider
call, whose real cost is the provider's (coderunner reports 0.0012 ms for a
repeated lookup in `coderunner_performance.md`). Absolute numbers differ
from the table above because this machine and its load differ; compare only
within this table. The reapply benchmark (`benchmark_image_reapply.lua`,
which stubs `collect_diagram_images`) keeps the R0 call counts: unchanged
set/mark/clear/redraw/del all 0, one-image-size-changed
set 1000, mark 2000, clear 1000, redraw 1000, del 0.

```sh
BENCH_PROVIDER=1 nvim --headless -u NONE -l tests/manual/benchmark_plantuml_scan.lua
```
