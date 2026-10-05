-- nvim --headless -u NONE -l tests/manual/benchmark_plantuml_scan.lua
-- Set IMAGE_BENCH_BASELINE to a snapshot root to compare the same workload.
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.IMAGE_BENCH_BASELINE then vim.opt.rtp:prepend(vim.env.IMAGE_BENCH_BASELINE) end
vim.g.is_testing = true
vim.o.lines = 100
vim.o.columns = 160
vim.ui.img = { set = function() end, del = function() end }
vim.g.neopp_channel = 1
vim.rpcnotify = function() end
local image = require('rendermark.image')
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'markdown'
local lines = {}
for i = 1, 3000 do lines[i] = 'plain markdown line ' .. i end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local ns = vim.api.nvim_create_namespace('plantuml-scan-benchmark')
for row = 0, 59 do
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { '•', 'Comment' } } })
end
local full_reads = 0
local get_lines = vim.api.nvim_buf_get_lines
vim.api.nvim_buf_get_lines = function(b, first, last, ...)
  if b == buf and first == 0 and last == -1 then full_reads = full_reads + 1 end
  return get_lines(b, first, last, ...)
end
local function run(label, action, iterations)
  full_reads = 0
  collectgarbage('collect')
  local start = vim.uv.hrtime()
  for _ = 1, iterations do action() end
  print(vim.json.encode({ scenario = label, iterations = iterations,
    ms_per_call = (vim.uv.hrtime() - start) / 1e6 / iterations, full_reads = full_reads }))
end
run('send_images-cold', image.send_images, 1)
run('send_images-unchanged', image.send_images, 200)
run('cursor-unchanged', image.cursor_active_block_sig, 500)
run('send_images-edited', function()
  vim.api.nvim_buf_set_lines(buf, 2999, 3000, false, { 'edited' })
  image.send_images()
end, 100)
vim.cmd('qa!')
