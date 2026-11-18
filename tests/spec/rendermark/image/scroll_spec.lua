describe('tall body image scrolling', function()
  local img, buf, win, path, store, old_ui, old_backend, group

  local function sync()
    img.send_images()
    img.send_images()
  end

  local function entry(target)
    for _, e in pairs(store) do
      if e.buf == buf and (not target or e.win_height == vim.api.nvim_win_get_height(target)) then return e end
    end
  end

  local function offset()
    local e = assert(entry())
    return e.text_grid_row * 20 - e.dest_y_px
  end

  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
    vim.wait(10)
    sync()
  end

  before_each(function()
    old_ui, old_backend = vim.ui, rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)
    package.loaded['nvim_config.rendermark.image'] = nil
    img = require('nvim_config.rendermark.image')
    store = {}
    vim.ui = { img = {
      set = function(id, _, opts) store[id] = opts end,
      del = function(id) store[id] = nil end,
    } }
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = 10, 20
    path = vim.fn.tempname() .. '.png'
    local f = assert(io.open(path, 'wb'))
    f:write('\137PNG\r\n\026\n' .. string.rep('\0', 8) .. string.char(0, 0, 1, 44, 0, 0, 7, 208)) -- 300x2000
    f:close()
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'before', '![image](' .. path .. ')', 'after', 'end' })
    vim.cmd('new')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd('resize 10')
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    for _, key in ipairs({ 'j', 'k' }) do
      vim.keymap.set('n', key, 'v:count == 0 ? "g' .. key .. '" : "' .. key .. '"', { expr = true, buffer = buf })
    end
    group = vim.api.nvim_create_augroup('image_scroll_test', { clear = true })
    img.image_scroll_setup(group)
    sync()
    img.image_scroll_cursor_moved()
  end)

  after_each(function()
    vim.wait(30)
    vim.api.nvim_del_augroup_by_id(group)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.wait(30)
    vim.fn.delete(path)
    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_backend)
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = nil, nil
    package.loaded['nvim_config.rendermark.image'] = nil
  end)

  it('keeps the native width and height but reserves only window height minus one filler rows', function()
    local e = entry()
    assert.equals(300, e.display_width_px)
    assert.equals(2000, e.display_height_px)
    assert.equals(10, e.virt_height)
    local count = 0
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, img.ensure_image_namespace(), 0, -1, { details = true })) do
      count = count + #(mark[4].virt_lines or {})
    end
    assert.equals(9, count)
  end)

  it('scrolls with j and counts without moving or editing the real cursor line', function()
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    press('j')
    assert.equals(20, offset())
    assert.equals(2, vim.api.nvim_win_get_cursor(win)[1])
    press('10j')
    assert.equals(220, offset())
    press('k')
    assert.equals(200, offset())
    assert.equals(tick, vim.api.nvim_buf_get_changedtick(buf))
  end)

  it('keeps the offset across edits on other lines and rows shifted above', function()
    press('10j')
    assert.equals(200, offset())
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, { 'end edited' })
    sync()
    assert.equals(200, offset())
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted' })
    sync()
    assert.equals(200, offset())
    assert.equals(3, vim.api.nvim_win_get_cursor(win)[1])
    press('j')
    assert.equals(220, offset())
  end)

  it('shows the last slice before the next j leaves for the next real line', function()
    press('90j')
    assert.equals(1800, offset())
    assert.equals(2, vim.api.nvim_win_get_cursor(win)[1])
    press('j')
    assert.equals(3, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it('uses leftover count to leave the image after reaching its bottom', function()
    press('91j')
    assert.equals(3, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it('enters from below at the bottom and from above at the top', function()
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    img.image_scroll_cursor_moved()
    press('k')
    img.image_scroll_cursor_moved()
    sync()
    assert.equals(1800, offset())
    press('k')
    assert.equals(1780, offset())
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    img.image_scroll_cursor_moved()
    press('j')
    img.image_scroll_cursor_moved()
    sync()
    assert.equals(0, offset())
  end)

  it('handles arrows, half pages and wheel input inside the image', function()
    press('<Down>')
    assert.equals(20, offset())
    press('<C-d>')
    assert.equals(120, offset())
    press('<ScrollWheelDown>')
    assert.equals(180, offset())
    press('<C-u>')
    assert.equals(80, offset())
  end)

  it('clamps the offset when the window grows and the whole image fits', function()
    press('90j')
    vim.g.neopp_cell_height_px = 250
    sync()
    assert.is_false(img.scroll_image(1, 1))
    local e = entry()
    assert.equals(e.text_grid_row * 250, e.dest_y_px)
  end)

  it('keeps offsets independent in two windows showing the same buffer', function()
    press('10j')
    vim.cmd('vsplit')
    local other = vim.api.nvim_get_current_win()
    sync()
    assert.is_true(img.scroll_image(1, 1))
    local found = {}
    for id, e in pairs(store) do
      found[tonumber(id:match(':win:(%d+):'))] = e.text_grid_row * 20 - e.dest_y_px
    end
    assert.equals(200, found[win])
    assert.equals(20, found[other])
    vim.api.nvim_win_close(other, true)
  end)

  it('falls through when images are disabled or the source changes', function()
    vim.g.neopp_images_enabled = false
    assert.is_false(img.scroll_image(1, 1))
    vim.g.neopp_images_enabled = nil
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'plain text' })
    assert.is_false(img.scroll_image(1, 1))
  end)

  it('shows the offset in the terminal stub', function()
    img._stub_active = true
    press('10j')
    local text = ''
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, img.ensure_image_namespace(), 0, -1, { details = true })) do
      for _, row in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(row) do text = text .. chunk[1] end
      end
    end
    assert.is_truthy(text:find('y=200/1800', 1, true))
  end)

  it('scrolls through read mode maps and still works after leaving read mode', function()
    local read = require('nvim_config.read_mode')
    read.enter(win)
    press('j')
    assert.equals(20, offset())
    read.exit(win)
    press('j')
    assert.equals(40, offset())
  end)

  it('sends integer geometry and exposes the last pixels with fractional cell metrics', function()
    vim.g.neopp_cell_height_px = 18.5
    sync()
    assert.is_true(img.scroll_image(1, 99))
    sync()
    local e = entry()
    assert.equals(math.floor(e.dest_y_px), e.dest_y_px)
    assert.equals(math.floor(e.clip_height_px), e.clip_height_px)
    assert.is_true(e.dest_y_px + e.display_height_px <= e.clip_y_px + e.clip_height_px)
  end)
end)
