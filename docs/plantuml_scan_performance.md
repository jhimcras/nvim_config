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
