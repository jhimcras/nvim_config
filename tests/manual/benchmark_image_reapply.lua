vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.IMAGE_BENCH_BASELINE then vim.opt.rtp:prepend(vim.env.IMAGE_BENCH_BASELINE) end
vim.g.is_testing = true
vim.o.lines = 100
vim.o.columns = 160
local counts = { set = 0, del = 0, mark = 0, clear = 0, redraw = 0 }
vim.ui.img = { set = function() counts.set = counts.set + 1 end, del = function() counts.del = counts.del + 1 end }
vim.g.neopp_channel = 1
vim.rpcnotify = function(_, event) if event == 'force_redraw' then counts.redraw = counts.redraw + 1 end end
for key, name in pairs({ mark = 'nvim_buf_set_extmark', clear = 'nvim_buf_clear_namespace' }) do
  local original = vim.api[name]
  vim.api[name] = function(...) counts[key] = counts[key] + 1; return original(...) end
end
local img = require('nvim_config.rendermark.image')
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].filetype = 'markdown'
local lines = {}
for i = 1, 80 do lines[i] = 'image ' .. i end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local width = 100
img.collect_markdown_images = function()
  local images = {}
  for i = 1, 20 do images[i] = { row = i * 2, col = 0, end_col = 6, byte_col = 0, byte_end_col = 6,
    path = '/tmp/benchmark-' .. i .. '.png', source_width = i == 1 and width or 100, source_height = 18 } end
  return images
end
img.collect_plantuml_images = function() end
for _ = 1, 5 do img.send_images(); vim.wait(1) end
local function run(label, change)
  for k in pairs(counts) do counts[k] = 0 end
  collectgarbage('collect')
  local start = vim.uv.hrtime()
  for i = 1, 1000 do if change then width = 100 + i % 2 end; img.send_images() end
  print(vim.json.encode({ scenario = label, ms = (vim.uv.hrtime() - start) / 1e6, calls = counts }))
end
run('unchanged')
run('one-image-size-changed', true)
vim.cmd('qa!')
