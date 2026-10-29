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

After R5 (exported-image check, `diagram.hide_when_exported`), same workload,
3 runs each against the HEAD snapshot: send_images after each edit
0.277-0.288 -> 0.393-0.401 ms/call (one 31-row read and link scan per block,
10 blocks, once per changedtick). Cold 0.52-0.67 -> 0.70-0.94 ms. Unchanged
send_images (0.28-0.30) and cursor signature (0.003) are unchanged: the
verdict is cached with the items of the tick. Full buffer reads and provider
calls stay at 0 / 0 / 0 / 100 as above.

## After R6-A: document index for image scanning (2026-10-30)

The image scan now skips fenced code blocks and resolves reference images
(`![alt][ref]`, `![ref][]`, `![ref]`), which both need facts about the whole
document: fence rows and `[label]: path` definitions. `image/docindex.lua`
builds them in one line pass (`nvim_buf_get_lines(0, -1)` plus two plain
`find`s per line), cached per buffer by changedtick, and only when a scanned
line contains `![` (a buffer without images never builds it). Scrolling,
cursor moves and unchanged `send_images` reuse the cached index.

Same script, 3 runs each against the HEAD snapshot (`IMAGE_BENCH_BASELINE`),
ms per call. `BENCH_IMAGES=1` puts 5 image links (one a reference image) in the
viewport, a fenced block every 50 lines and a definition on the last line;
`BENCH_LINES` sets the size.

| Workload | Scenario | Before | After |
| --- | --- | ---: | ---: |
| 3000 lines, no images | cold / unchanged / edited | 0.25-0.30 / 0.09-0.10 / 0.09 | 0.28-0.31 / 0.08 / 0.07-0.08 |
| 3000 lines, images | cold | 0.66-0.83 | 1.48-1.52 |
| 3000 lines, images | unchanged send_images | 0.30-0.32 | 0.30-0.31 |
| 3000 lines, images | send_images after each edit | 0.28-0.31 | 0.59-0.60 |
| 8000 lines, images | cold | 0.67-0.81 | 2.11-2.14 |
| 8000 lines, images | unchanged send_images | 0.31-0.32 | 0.30-0.34 |
| 8000 lines, images | send_images after each edit | 0.29-0.30 | 1.10-1.23 |

The cost is one index build per edit of a document that has an image in view
(about 0.1 ms per 1000 lines, after the 30 ms TextChanged debounce), none per
scroll or cursor move, and none for documents without images. The "full
reads" column of the script is 1 (cold) / 100 (edited) for the image
workloads, which is exactly this index. `benchmark_image_reapply.lua` stubs the
scan, so it only guards the call counts: 5 runs, median unchanged 681.3 ms
(664.3-695.9), one-image-size-changed 686.8 ms (678.2-702.3), call counts
identical to R0 (unchanged 0/0/0/0/0; changed set 1000, mark 2000, clear 1000,
redraw 1000, del 0).

```sh
BENCH_IMAGES=1 BENCH_LINES=8000 nvim --headless -u NONE -l tests/manual/benchmark_plantuml_scan.lua
```

## After R6-B: `<img` and wiki embeds in the line prefilter (2026-10-30)

The prefilter is now `scan.has_image_candidate` (`![`, or `<` followed by a
case-insensitive `<img` tag start), used by the scan, `line_has_image_link`
(wrap, anchor signature) and the exported-image check. `![[` needs no test of its
own because it contains `![`. Wiki name lookups only start for a bare name that
is not in the document folder, and then walk the project root once,
asynchronously (see `docs/rendermark_plan.md`, R6-B rules); the script below only
uses absolute-path embeds, so it measures the scan, not the walk.

Same script, 3 runs each against the HEAD snapshot of the commit before R6-B
(`IMAGE_BENCH_BASELINE`), ms per call. `BENCH_IMAGES=1` now also puts 2 HTML
`<img>` and 2 `![[path]]` lines in the viewport (9 images instead of 5; before
R6-B those 4 lines are plain text). `BENCH_NOISE=1` makes every 5th line HTML
text without an image (`<div>`, `<b>`, `<image>`, plus a lone `![`).

| Workload | Scenario | Before | After |
| --- | --- | ---: | ---: |
| 3000 lines, no images | cold / unchanged / edited | 0.26-0.32 / 0.08-0.09 / 0.07 | 0.29-0.35 / 0.08 / 0.07 |
| 3000 lines, HTML text, no image | cold / unchanged / edited | 0.59-0.62 / 0.09-0.10 / 0.36-0.39 | 0.64-0.72 / 0.09-0.10 / 0.37-0.39 |
| 3000 lines, images | cold | 1.19-1.23 | 1.77-1.84 |
| 3000 lines, images | unchanged send_images | 0.29-0.30 | 0.56-0.58 |
| 3000 lines, images | send_images after each edit | 0.58-0.59 | 0.85 |
| 8000 lines, images | cold | 2.05-2.28 | 2.12-2.47 |
| 8000 lines, images | unchanged send_images | 0.30 | 0.57-0.59 |
| 8000 lines, images | send_images after each edit | 1.11-1.20 | 1.35 |

Documents without images cost the same (the extra `<` plain find per line is
below the noise, also with HTML text on every 5th line). The image workloads
now draw 9 images instead of 5, so the rise is the per-image cost
(about 0.06 ms in both: 0.29 / 5 before, 0.56 / 9 after), not the syntaxes or
the prefilter. `benchmark_image_reapply.lua` stubs the scan, so it only guards
the call counts: 5 runs, median unchanged 673.6 ms (666.9-704.0),
one-image-size-changed 682.2 ms (675.5-710.5), call counts identical to R0
(unchanged 0/0/0/0/0; changed set 1000, mark 2000, clear 1000, redraw 1000,
del 0).

```sh
BENCH_NOISE=1 nvim --headless -u NONE -l tests/manual/benchmark_plantuml_scan.lua
BENCH_IMAGES=1 BENCH_LINES=8000 nvim --headless -u NONE -l tests/manual/benchmark_plantuml_scan.lua
```
