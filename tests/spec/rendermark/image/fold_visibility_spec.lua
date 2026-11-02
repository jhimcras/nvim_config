local H = require('tests.spec.rendermark.image.helpers')

describe('image visibility in closed folds', function()
  local old_ui, old_state, old_cells, img, buf, win, dir, store

  before_each(function()
    old_ui, old_state = vim.ui, rawget(_G, '__rendermark_image_backend')
    old_cells = { vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px }
    rawset(_G, '__rendermark_image_backend', nil)
    package.loaded['nvim_config.rendermark.image'] = nil
    store = {}
    vim.ui = { img = {
      set = function(id, path, opts) store[id] = { path = path, opts = opts } end,
      del = function(id) store[id] = nil end,
    } }
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = 10, 20
    img = require('nvim_config.rendermark.image')
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local f = assert(io.open(dir .. '/image.png', 'wb'))
    f:write('\137PNG\r\n\026\n' .. string.char(0, 0, 0, 13) .. 'IHDR'
      .. string.char(0, 0, 0, 160, 0, 0, 0, 80))
    f:close()
    vim.cmd('new')
    win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, dir .. '/doc.md')
    vim.bo[buf].filetype = 'markdown'
    vim.wo[win].foldmethod = 'manual'
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_state)
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = unpack(old_cells)
    package.loaded['nvim_config.rendermark.image'] = nil
    vim.fn.delete(dir, 'rf')
  end)

  local function sync()
    img.refresh(buf)
    img.send_images()
    vim.wait(30)
    img.send_images()
  end

  for _, row in ipairs({ 1, 2 }) do
    it('hides a normal image at fold row ' .. row .. ' and restores it on opening', function()
      local lines = { 'heading', 'body', 'tail' }
      lines[row] = '![image](image.png)'
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      sync()
      assert.equals(1, vim.tbl_count(store))
      vim.cmd('1,2fold')
      sync()
      assert.same({}, store)
      vim.cmd('normal! zR')
      sync()
      assert.equals(1, vim.tbl_count(store))
    end)
  end

  it('keeps a diagram replacing its own fold but hides it inside a larger fold', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false,
      { 'heading', '```plantuml', 'a -> b', '```', 'tail' })
    img.set_diagram_source(H.fence_source({ status = 'ready', path = dir .. '/image.png' }))
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    vim.cmd('2,4fold')
    sync()
    assert.equals(1, vim.tbl_count(store))
    vim.cmd('normal! zE')
    vim.cmd('1,4fold')
    sync()
    assert.same({}, store)
    vim.cmd('normal! zR')
    sync()
    assert.equals(1, vim.tbl_count(store))
  end)
end)
