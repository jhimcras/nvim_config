-- nvim --headless -u NONE -l tests/manual/benchmark_plantuml_scan.lua
-- Set IMAGE_BENCH_BASELINE to a snapshot root to compare the same workload.
-- Set BENCH_PROVIDER=1 to register a fake diagram provider with 10 ready blocks
-- (5 inside the headless viewport); without it no provider is registered.
-- Set BENCH_IMAGES=1 to add 5 image links inside the viewport (one a reference
-- image), a fenced block every 50 lines and a definition at the end, so each
-- edit pays for the document index. It also adds 2 HTML <img> and 2 wiki
-- ![[path]] embeds in the viewport (R6-B syntaxes; plain text before R6-B).
-- Set BENCH_NOISE=1 to make every 5th line HTML text with no image, which the
-- `<img` prefilter must reject cheaply. BENCH_LINES=<n> changes the 3000-line size.
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.IMAGE_BENCH_BASELINE then vim.opt.rtp:prepend(vim.env.IMAGE_BENCH_BASELINE) end
vim.g.is_testing = true
vim.o.lines = 100
vim.o.columns = 160
vim.ui.img = { set = function() end, del = function() end }
vim.g.neopp_channel = 1
vim.rpcnotify = function() end
local image = require('nvim_config.rendermark.image')
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'markdown'
local lines = {}
local line_count = tonumber(vim.env.BENCH_LINES) or 3000
for i = 1, line_count do lines[i] = 'plain markdown line ' .. i end
if vim.env.BENCH_NOISE then
  for i = 5, line_count, 5 do lines[i] = '<div class="x">text <b>bold</b> <image> ' .. i .. '</div> ![ not an image' end
end
local blocks = { 10, 30, 50, 70, 90, 400, 800, 1200, 1600, 2000 }
if vim.env.BENCH_PROVIDER then
  for _, row in ipairs(blocks) do
    lines[row + 1] = '```plantuml'
    lines[row + 5] = '```'
  end
end
if vim.env.BENCH_IMAGES then
  local png = vim.fn.tempname() .. '.png'
  local f = assert(io.open(png, 'wb'))
  f:write(string.char(137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 100, 0, 0, 0, 50))
  f:close()
  for _, row in ipairs({ 3, 12, 21, 30, 39 }) do lines[row + 1] = '![img](' .. png .. ')' end
  lines[49] = '![ref][pic]'
  lines[7] = '<img src="' .. png .. '" width="100">'
  lines[16] = 'text <IMG alt=x src=\'' .. png .. '\'> text'
  lines[25] = '![[' .. png .. '|80]]'
  lines[34] = '![[' .. png .. '#top]] end'
  for row = 100, line_count - 10, 50 do
    lines[row + 1] = '```lua'
    lines[row + 3] = '```'
  end
  lines[line_count] = '[pic]: ' .. png
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local ns = vim.api.nvim_create_namespace('plantuml-scan-benchmark')
for row = 0, 59 do
  vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { '•', 'Comment' } } })
end
local provider_calls = 0
if vim.env.BENCH_PROVIDER then
  -- 100x50 PNG header: enough for the size reader.
  local png = vim.fn.tempname() .. '.png'
  local f = assert(io.open(png, 'wb'))
  f:write(string.char(137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 100, 0, 0, 0, 50))
  f:close()
  image.set_diagram_source({
    items = function()
      provider_calls = provider_calls + 1
      local items = {}
      for _, row in ipairs(blocks) do
        items[#items + 1] = { start_row = row, end_row = row + 4, key = 'k' .. row, lang = 'plantuml',
          path = png, format = 'png', stale = false, status = 'ready' }
      end
      return items
    end,
  })
end
local full_reads = 0
local get_lines = vim.api.nvim_buf_get_lines
vim.api.nvim_buf_get_lines = function(b, first, last, ...)
  if b == buf and first == 0 and last == -1 then full_reads = full_reads + 1 end
  return get_lines(b, first, last, ...)
end
local function run(label, action, iterations)
  full_reads, provider_calls = 0, 0
  collectgarbage('collect')
  local start = vim.uv.hrtime()
  for _ = 1, iterations do action() end
  print(vim.json.encode({ scenario = label, iterations = iterations,
    ms_per_call = (vim.uv.hrtime() - start) / 1e6 / iterations, full_reads = full_reads,
    provider_calls = provider_calls }))
end
run('send_images-cold', image.send_images, 1)
run('send_images-unchanged', image.send_images, 200)
run('cursor-unchanged', image.cursor_active_block_sig, 500)
run('send_images-edited', function()
  vim.api.nvim_buf_set_lines(buf, line_count - 2, line_count - 1, false, { 'edited' })
  image.send_images()
end, 100)
vim.cmd('qa!')
