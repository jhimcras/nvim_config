-- :RendermarkImageOpen - an image enlarged in its own tab. A fake vim.ui.img
-- records set/del; nothing here draws or measures a screen (no redraw).
local H = require('tests.spec.rendermark.image.helpers')

local function png(w, h)
  local function u32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
  end
  return '\137PNG\r\n\026\n' .. u32(13) .. 'IHDR' .. u32(w) .. u32(h)
end

local function write(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
  return path
end

local function fresh_image()
  package.loaded['nvim_config.rendermark.image'] = nil
  return require('nvim_config.rendermark.image')
end

describe('rendermark image zoom', function()
  local img, dir, buf, win, store, sets, dels, notes
  local old_ui, old_backend, old_notify, old_g

  -- 1-based byte column of the first `needle` in the line, as a 0-based cursor column.
  local function col_of(line, needle) return (line:find(needle, 1, true)) - 1 end

  local function set_doc(lines, name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    if name then vim.api.nvim_buf_set_name(buf, dir .. '/' .. name) end
  end

  local function cursor(row, col) vim.api.nvim_win_set_cursor(win, { row, col }) end

  local function zoom_entry()
    local z = img.zoom_list()[1]
    return z, z and store[z.id]
  end

  before_each(function()
    old_ui = vim.ui
    old_backend = rawget(_G, '__rendermark_image_backend')
    old_notify = vim.notify
    old_g = { w = vim.g.neopp_cell_width_px, h = vim.g.neopp_cell_height_px, en = vim.g.neopp_images_enabled }
    rawset(_G, '__rendermark_image_backend', nil)
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px, vim.g.neopp_images_enabled = 10, 20, nil
    store, sets, dels, notes = {}, {}, {}, {}
    vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    vim.ui = {
      img = {
        set = function(id, path, opts) sets[#sets + 1] = id; store[id] = { path = path, opts = opts } end,
        del = function(id) dels[#dels + 1] = id; store[id] = nil end,
        get = function(id) return store[id] end,
      },
    }
    img = fresh_image()
    dir = vim.fn.tempname()
    write(dir .. '/a.png', png(200, 100))   -- landscape
    write(dir .. '/b.png', png(100, 400))   -- portrait
    write(dir .. '/c.png', png(20, 10))     -- smaller than any window
    write(dir .. '/broken.svg', '<svg/>')
    vim.cmd('new')
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = 'markdown'
  end)

  after_each(function()
    vim.wait(20, function() return false end)
    -- Back to the first tab, then drop every other (zoom) tab.
    vim.cmd('tabfirst')
    if #vim.api.nvim_list_tabpages() > 1 then vim.cmd('tabonly') end
    assert.same({}, img.zoom_list())
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.notify = old_notify
    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_backend)
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px, vim.g.neopp_images_enabled = old_g.w, old_g.h, old_g.en
    vim.fn.delete(dir, 'rf')
  end)

  describe('zoom_fit', function()
    it('fills the width of a landscape image and the height of a portrait one', function()
      assert.same({ 800, 400 }, { img.zoom_fit(200, 100, 800, 600) })
      assert.same({ 150, 600 }, { img.zoom_fit(100, 400, 800, 600) })
    end)

    it('enlarges an image smaller than the area', function()
      assert.same({ 800, 400 }, { img.zoom_fit(20, 10, 800, 600) })
    end)

    it('keeps the aspect and never exceeds the area', function()
      for _, area in ipairs({ { 800, 600 }, { 333, 777 }, { 2, 2 }, { 5000, 40 } }) do
        local w, h = img.zoom_fit(123, 77, area[1], area[2])
        assert.is_true(w <= area[1] and h <= area[2])
        assert.is_true(w == area[1] or h == area[2])
        -- One side is rounded to a whole pixel: at most half a pixel off the true ratio.
        assert.is_true(math.abs(w * 77 - h * 123) <= 123 * 0.5 + 77 * 0.5)
      end
    end)

    it('is nil without a usable size', function()
      assert.is_nil(img.zoom_fit(0, 10, 100, 100))
      assert.is_nil(img.zoom_fit(10, 10, 0, 100))
    end)
  end)

  describe('choosing the image', function()
    local LINE = 'x ![a](a.png) mid ![b](b.png) end <img src="c.png" width="40"> z'

    before_each(function()
      set_doc({ LINE, 'plain text' }, 'doc.md')
    end)

    local function target_at(col)
      cursor(1, col)
      return img.zoom_target(buf, win)
    end

    it('takes the link that holds the cursor column', function()
      assert.equals(dir .. '/a.png', target_at(col_of(LINE, '![a]')).path)
      assert.equals(dir .. '/a.png', target_at(col_of(LINE, 'a.png') + 2).path)
      assert.equals(dir .. '/b.png', target_at(col_of(LINE, '![b]')).path)
      assert.equals(dir .. '/b.png', target_at(col_of(LINE, 'b.png)')).path)
      assert.equals(dir .. '/c.png', target_at(col_of(LINE, '<img')).path)
    end)

    it('takes the nearest link when the cursor is between or outside them', function()
      assert.equals(dir .. '/a.png', target_at(0).path)                      -- before the first
      assert.equals(dir .. '/a.png', target_at(col_of(LINE, ' mid ') + 1).path) -- closer to a
      assert.equals(dir .. '/b.png', target_at(col_of(LINE, ' end ') + 1).path) -- closer to b
      assert.equals(dir .. '/c.png', target_at(#LINE - 1).path)              -- after the last
    end)

    it('reports the image size read from the file', function()
      local target = target_at(col_of(LINE, '![a]'))
      assert.same({ 200, 100 }, { target.width, target.height })
    end)

    it('has no target on a line without an image', function()
      cursor(2, 0)
      local target, msg = img.zoom_target(buf, win)
      assert.is_nil(target)
      assert.matches('no image under the cursor', msg)
    end)

    it('finds reference, wiki path and html images', function()
      write(dir .. '/sub/e.png', png(30, 30))
      set_doc({ '![alt][r]', '[r]: b.png', '![[a.png|50]]', '![[sub/e.png]]' })
      cursor(1, 0)
      assert.equals(dir .. '/b.png', img.zoom_target(buf, win).path)
      cursor(3, 0)
      assert.equals(dir .. '/a.png', img.zoom_target(buf, win).path)
      cursor(4, 0)
      assert.equals(dir .. '/sub/e.png', img.zoom_target(buf, win).path)
    end)

    it('finds a wiki image by name next to the document', function()
      set_doc({ '![[b.png]]' })
      cursor(1, 0)
      assert.equals(dir .. '/b.png', img.zoom_target(buf, win).path)
    end)

    it('ignores image syntax inside a code fence', function()
      set_doc({ '```md', '![a](a.png)', '```' })
      cursor(2, 0)
      local target = img.zoom_target(buf, win)
      assert.is_nil(target)
    end)

    it('explains missing, unreadable and remote images', function()
      set_doc({ '![x](nope.png)', '![s](broken.svg)', '![r](http://example.com/a.png)' })
      cursor(1, 0)
      local t1, m1 = img.zoom_target(buf, win)
      assert.is_nil(t1); assert.matches('image not found: nope.png', m1)
      cursor(2, 0)
      local t2, m2 = img.zoom_target(buf, win)
      assert.is_nil(t2); assert.matches('unsupported', m2)
      cursor(3, 0)
      local t3, m3 = img.zoom_target(buf, win)
      assert.is_nil(t3); assert.matches('no local image', m3)
    end)

    it('reports an ambiguous wiki name', function()
      -- The project-wide name search is its own spec; here only its verdict matters.
      local wikisearch = require('nvim_config.rendermark.image.wikisearch')
      local old_lookup = wikisearch.lookup
      wikisearch.lookup = function() return { error = 'ambiguous' } end
      set_doc({ '![[d.png]]' })
      cursor(1, 0)
      local target, msg = img.zoom_target(buf, win)
      wikisearch.lookup = old_lookup
      assert.is_nil(target)
      assert.matches('ambiguous', msg)
    end)
  end)

  describe('diagram blocks', function()
    local LINES = { 'intro', '```plantuml', 'a -> b', '```', 'outro' }
    local src

    before_each(function()
      set_doc(LINES, 'doc.md')
      src = H.fence_source({ status = 'ready', path = dir .. '/a.png' })
      img.set_diagram_source(src)
    end)

    it('takes the rendered image of a ready block from any row inside it', function()
      for row = 2, 4 do
        cursor(row, 0)
        local target = img.zoom_target(buf, win)
        assert.equals(dir .. '/a.png', target.path)
        assert.same({ 200, 100 }, { target.width, target.height })
      end
    end)

    it('does not take anything outside the block', function()
      cursor(1, 0)
      assert.is_nil((img.zoom_target(buf, win)))
    end)

    it('explains a block that is pending, failed or without a render', function()
      cursor(3, 0)
      src.status, src.path = 'pending', nil
      img.refresh(buf)
      assert.matches('not rendered yet %(pending%)', select(2, img.zoom_target(buf, win)))
      src.status, src.error = 'failed', 'boom'
      img.refresh(buf)
      assert.matches('render failed: boom', select(2, img.zoom_target(buf, win)))
      src.status, src.error = 'none', nil
      img.refresh(buf)
      assert.matches('not rendered yet %(none%)', select(2, img.zoom_target(buf, win)))
    end)

    it('does not open an SVG render', function()
      cursor(3, 0)
      src.path = dir .. '/broken.svg'
      img.refresh(buf)
      assert.matches('unsupported', select(2, img.zoom_target(buf, win)))
    end)
  end)

  describe('opening', function()
    before_each(function()
      set_doc({ '![a](a.png)', '![b](b.png)', '![c](c.png)' }, 'doc.md')
    end)

    local function open(row)
      cursor(row or 1, 0)
      return img.zoom_open(win)
    end

    it('opens a new tab with a read-only scratch buffer without chrome', function()
      local tabs = #vim.api.nvim_list_tabpages()
      local zbuf = open()
      assert.is_not_nil(zbuf)
      assert.equals(tabs + 1, #vim.api.nvim_list_tabpages())
      assert.equals(zbuf, vim.api.nvim_get_current_buf())
      local zwin = vim.api.nvim_get_current_win()
      assert.equals('nofile', vim.bo[zbuf].buftype)
      assert.equals('wipe', vim.bo[zbuf].bufhidden)
      assert.is_false(vim.bo[zbuf].modifiable)
      assert.is_false(vim.bo[zbuf].swapfile)
      assert.equals('rendermark_zoom', vim.bo[zbuf].filetype)
      for _, name in ipairs({ 'number', 'relativenumber', 'cursorline', 'list', 'wrap' }) do
        assert.is_false(vim.wo[zwin][name], name)
      end
      assert.equals('no', vim.wo[zwin].signcolumn)
      assert.equals('0', vim.wo[zwin].foldcolumn)
    end)

    it('maps q and <Esc> in the scratch buffer', function()
      local zbuf = open()
      local lhs = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(zbuf, 'n')) do lhs[map.lhs] = true end
      assert.is_true(lhs['q'])
      assert.is_true(lhs['<Esc>'])
    end)

    it('fits a landscape image to the window width and centers it', function()
      open(1)
      local z, entry = zoom_entry()
      local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
      local area_w, area_h = info.width * 10, info.height * 20
      local o = entry.opts
      assert.equals(dir .. '/a.png', entry.path)
      assert.equals('rendermark:zoom:' .. z.buf, z.id)
      assert.equals(area_w, o.display_width_px)
      assert.equals(math.floor(area_w * 100 / 200 + 0.5), o.display_height_px)
      assert.equals((info.wincol - 1) * 10, o.dest_x_px)
      assert.equals((info.winrow - 1) * 20 + math.floor((area_h - o.display_height_px) / 2), o.dest_y_px)
      assert.same({ 200, 100 }, { o.source_width, o.source_height })
      assert.same({ (info.wincol - 1) * 10, (info.winrow - 1) * 20, area_w, area_h },
        { o.clip_x_px, o.clip_y_px, o.clip_width_px, o.clip_height_px })
      assert.equals(math.floor(o.dest_x_px / 10), o.grid_col)
      assert.equals(math.floor(o.dest_y_px / 20), o.grid_row)
      assert.equals(z.buf, o.buf)
    end)

    it('fits a portrait image to the window height', function()
      open(2)
      local _, entry = zoom_entry()
      local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
      local o = entry.opts
      assert.equals(info.height * 20, o.display_height_px)
      assert.equals(math.floor(info.height * 20 * 100 / 400 + 0.5), o.display_width_px)
      assert.is_true(o.display_width_px < info.width * 10)
      -- centered horizontally
      assert.equals(math.floor((info.width * 10 - o.display_width_px) / 2), o.dest_x_px - (info.wincol - 1) * 10)
      assert.equals((info.winrow - 1) * 20, o.dest_y_px)
    end)

    it('enlarges an image smaller than the window', function()
      open(3)
      local _, entry = zoom_entry()
      local o = entry.opts
      assert.is_true(o.display_width_px > o.source_width * 5)
      assert.is_true(o.display_width_px == vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].width * 10
        or o.display_height_px == vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].height * 20)
    end)

    it('uses the neopp contract fields of the body pipeline', function()
      open(1)
      local _, entry = zoom_entry()
      for _, key in ipairs({ 'buf', 'row', 'col', 'grid_row', 'grid_col', 'win_left', 'win_width', 'win_top',
        'win_height', 'text_offset', 'source_width', 'source_height', 'dest_x_px', 'dest_y_px',
        'display_width_px', 'display_height_px', 'clip_x_px', 'clip_y_px', 'clip_width_px', 'clip_height_px',
        'virt_height', 'zindex' }) do
        assert.is_not_nil(entry.opts[key], key)
      end
    end)

    it('adds nothing to the document buffer or its reservations', function()
      local ns = img.ensure_image_namespace()
      local before = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      open(1)
      assert.same(before, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
      assert.equals(tick, vim.api.nvim_buf_get_changedtick(buf))
    end)

    it('survives a body sync in the zoom tab', function()
      open(1)
      local z = zoom_entry()
      img.send_images()
      vim.wait(20, function() return false end)
      assert.is_not_nil(store[z.id])
      assert.same({}, vim.tbl_filter(function(id) return id == z.id end, dels))
    end)

    it('is not sent again while the placement is unchanged', function()
      open(1)
      local count = #sets
      vim.api.nvim_exec_autocmds('BufEnter', {})
      vim.api.nvim_exec_autocmds('WinResized', {})
      assert.equals(count, #sets)
    end)

    it('keeps several zoom tabs apart: only the current tab shows its image', function()
      local first = open(1)
      vim.cmd('tabprevious')
      local second = open(2)
      assert.are_not.equal(first, second)
      assert.equals(2, #img.zoom_list())
      assert.is_nil(store['rendermark:zoom:' .. first])
      assert.is_not_nil(store['rendermark:zoom:' .. second])
      vim.cmd('tabprevious')
      vim.cmd('tabnext')
      vim.cmd('tabnext')
      assert.is_nil(store['rendermark:zoom:' .. second])
      assert.is_not_nil(store['rendermark:zoom:' .. first])
    end)
  end)

  describe('closing', function()
    local origin_tab, zbuf, id

    before_each(function()
      set_doc({ '![a](a.png)' }, 'doc.md')
      origin_tab = vim.api.nvim_get_current_tabpage()
      cursor(1, 0)
      zbuf = img.zoom_open(win)
      id = 'rendermark:zoom:' .. zbuf
    end)

    local function assert_closed()
      assert.same({ id }, dels)
      assert.is_nil(store[id])
      assert.same({}, img.zoom_list())
      assert.is_false(vim.api.nvim_buf_is_valid(zbuf))
      assert.equals(1, #vim.api.nvim_list_tabpages())
      assert.equals(origin_tab, vim.api.nvim_get_current_tabpage())
    end

    it('closes the tab and deletes the image on q', function()
      assert.is_not_nil(store[id])
      vim.api.nvim_feedkeys('q', 'x', false)
      assert_closed()
    end)

    it('does the same on <Esc>', function()
      vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
      assert_closed()
    end)

    it('deletes the image when the tab is closed by other means', function()
      vim.cmd('tabclose')
      assert_closed()
    end)

    it('deletes the image when the buffer is wiped', function()
      vim.cmd('tabclose')
      assert.same({ id }, dels)
    end)

    it('hides the image on leaving the tab and shows it again on return', function()
      vim.cmd('tabprevious')
      assert.same({ id }, dels)
      assert.is_nil(store[id])
      vim.cmd('tabnext')
      assert.is_not_nil(store[id])
      assert.equals(2, #sets)
    end)

    it('closing twice is harmless', function()
      img.zoom_close(zbuf)
      img.zoom_close(zbuf)
      assert_closed()
    end)
  end)

  describe('resizing', function()
    local function open_a()
      set_doc({ '![a](a.png)' }, 'doc.md')
      cursor(1, 0)
      img.zoom_open(win)
      return zoom_entry()
    end

    it('recomputes when the editor is resized', function()
      -- A headless nvim has no UI to resize, so the zoom window is narrowed by hand.
      local z, first = open_a()
      local w1 = first.opts.display_width_px
      local zwin = vim.api.nvim_get_current_win()
      vim.cmd('vsplit')
      vim.api.nvim_set_current_win(zwin)
      vim.api.nvim_win_set_width(zwin, vim.api.nvim_win_get_width(zwin) - 20)
      local count = #sets -- no autocmd runs for an API resize: only VimResized refits
      vim.api.nvim_exec_autocmds('VimResized', {})
      local _, second = zoom_entry()
      assert.equals(count + 1, #sets)
      assert.equals(z.id, sets[#sets])
      assert.equals(vim.api.nvim_win_get_width(zwin) * 10, second.opts.display_width_px)
      assert.is_true(second.opts.display_width_px < w1)
    end)

    it('recomputes when a window is resized', function()
      local _, first = open_a()
      local h1 = first.opts.display_height_px
      vim.cmd('botright split')
      vim.api.nvim_exec_autocmds('WinResized', {})
      vim.cmd('wincmd p')
      local _, second = zoom_entry()
      assert.is_true(second.opts.display_height_px <= h1)
      assert.is_true(second.opts.clip_height_px < first.opts.clip_height_px)
    end)

    it('recomputes when the cell size changes', function()
      local _, first = open_a()
      vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = 20, 40
      vim.api.nvim_exec_autocmds('User', { pattern = 'NeoppMetrics' })
      local _, second = zoom_entry()
      assert.equals(first.opts.display_width_px * 2, second.opts.display_width_px)
    end)
  end)

  describe('notifications', function()
    local function last_note() return notes[#notes] and notes[#notes].msg end

    it('says so when the cursor is not on an image', function()
      set_doc({ 'just text' }, 'doc.md')
      assert.is_nil(img.zoom_open(win))
      assert.matches('rendermark: no image under the cursor', last_note())
      assert.equals(vim.log.levels.WARN, notes[#notes].level)
      assert.same({}, img.zoom_list())
      assert.equals(1, #vim.api.nvim_list_tabpages())
    end)

    it('says so for a missing file without opening a tab', function()
      set_doc({ '![x](nope.png)' }, 'doc.md')
      assert.is_nil(img.zoom_open(win))
      assert.matches('image not found: nope.png', last_note())
      assert.equals(1, #vim.api.nvim_list_tabpages())
      assert.same({}, sets)
    end)

    it('says so without an image backend', function()
      vim.ui = {}
      set_doc({ '![a](a.png)' }, 'doc.md')
      assert.is_nil(img.zoom_open(win))
      assert.matches('no image backend', last_note())
      assert.equals(1, #vim.api.nvim_list_tabpages())
    end)

    it('says so when images are disabled', function()
      vim.g.neopp_images_enabled = false
      set_doc({ '![a](a.png)' }, 'doc.md')
      assert.is_nil(img.zoom_open(win))
      assert.matches('disabled', last_note())
    end)

    it('does not fail when the provider rejects the image', function()
      vim.ui.img.set = function() error('no terminal support') end
      set_doc({ '![a](a.png)' }, 'doc.md')
      assert.has_no.errors(function() img.zoom_open(win) end)
      assert.equals(2, #vim.api.nvim_list_tabpages())
    end)
  end)

  describe('command and keymap', function()
    after_each(function()
      pcall(vim.api.nvim_del_augroup_by_name, 'rendermark_image')
      pcall(vim.api.nvim_del_augroup_by_name, 'rendermark_image_zoom')
      pcall(vim.api.nvim_clear_autocmds, { event = 'User', pattern = 'NeoppReady' })
    end)

    it('registers the command and a markdown buffer map on setup', function()
      img.setup({})
      assert.equals(2, vim.fn.exists(':RendermarkImageOpen'))
      local other = vim.api.nvim_create_buf(false, true)
      vim.bo[other].filetype = 'markdown'
      vim.api.nvim_exec_autocmds('FileType', { buffer = other })
      local found
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(other, 'n')) do
        if map.desc == 'RendermarkImageOpen' then found = map end
      end
      assert.is_not_nil(found)
      assert.equals('i', found.lhs:sub(-1))
      vim.api.nvim_buf_delete(other, { force = true })
    end)

    it('runs through the command', function()
      img.setup({})
      set_doc({ '![a](a.png)' }, 'doc.md')
      cursor(1, 0)
      vim.cmd('RendermarkImageOpen')
      assert.equals(1, #img.zoom_list())
    end)

    it('exists without a backend and explains itself', function()
      vim.ui = {}
      img.setup({})
      assert.equals(2, vim.fn.exists(':RendermarkImageOpen'))
      vim.cmd('RendermarkImageOpen')
      assert.matches('no image backend', notes[#notes].msg)
    end)
  end)

  describe('stub backend', function()
    it('draws a text box into the scratch buffer and still sets the image', function()
      img._stub_active = true
      set_doc({ '![a](a.png)' }, 'doc.md')
      cursor(1, 0)
      local zbuf = img.zoom_open(win)
      img._stub_active = nil
      local lines = vim.api.nvim_buf_get_lines(zbuf, 0, -1, false)
      local text = table.concat(lines, '\n')
      assert.matches('img: a.png', text)
      assert.is_not_nil(store['rendermark:zoom:' .. zbuf])
      assert.is_false(vim.bo[zbuf].modifiable)
    end)
  end)
end)
