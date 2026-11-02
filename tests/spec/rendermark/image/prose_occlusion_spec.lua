local image
local globals = { 'neopp_images_enabled', 'neopp_cell_width_px', 'neopp_cell_height_px' }

describe('image prose slots do not request GUI link occlusion', function()
  local old_img, old_backend, old_module, old_globals, path, payload

  before_each(function()
    old_img = vim.ui.img
    old_backend = rawget(_G, '__rendermark_image_backend')
    old_module = package.loaded['nvim_config.rendermark.image']
    old_globals = {}
    for _, key in ipairs(globals) do old_globals[key] = vim.g[key] end
    rawset(_G, '__rendermark_image_backend', nil)
    package.loaded['nvim_config.rendermark.image'] = nil
    image = require('nvim_config.rendermark.image')
    payload = {}
    vim.ui.img = {
      set = function(id, p, opts) payload[id] = { path = p, opts = opts } end,
      del = function(id) payload[id] = nil end,
    }
    vim.g.neopp_images_enabled = true
    vim.g.neopp_cell_width_px = 10
    vim.g.neopp_cell_height_px = 18
    image.safe_screenpos = function(_, lnum, col) return { row = lnum, col = col } end
    path = vim.fn.tempname() .. '.png'
    local file = assert(io.open(path, 'wb'))
    file:write(string.char(137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,
      0,0,0,100,0,0,0,50))
    file:close()
    vim.cmd('tabnew')
    vim.bo.filetype = 'markdown'
    vim.wo.foldmethod = 'manual'
    vim.wo.wrap = false
  end)

  after_each(function()
    vim.cmd('tabclose!')
    vim.fn.delete(path)
    vim.ui.img = old_img
    rawset(_G, '__rendermark_image_backend', old_backend)
    package.loaded['nvim_config.rendermark.image'] = old_module
    for _, key in ipairs(globals) do vim.g[key] = old_globals[key] end
  end)

  local function check(line, count)
    local source = { 'prose', line, 'after' }
    vim.api.nvim_buf_set_lines(0, 0, -1, false, source)
    vim.bo.modified = false
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    image.send_images(); image.send_images()
    local sent = 0
    for _, entry in pairs(payload) do
      sent = sent + 1
      -- The raw row is concealed by Neovim; the GUI must not hide the
      -- rebuilt prose using the (much wider) original link-text span.
      assert.equals(-1, entry.opts.text_col)
      assert.equals(-1, entry.opts.text_end_col)
    end
    assert.equals(count, sent)
    assert.same(source, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_false(vim.bo.modified)
  end

  it('preserves the slot after an inline image', function()
    check('lead ![blue](' .. path .. ') tail', 1)
  end)

  it('preserves the slots between and after multiple images', function()
    check('lead ![a](' .. path .. ') between ![b](' .. path .. ') tail', 2)
  end)
end)
