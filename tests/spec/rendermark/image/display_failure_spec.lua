-- rendermark.image: a provider that refuses an image (vim.ui.img.set raises or
-- returns false) keeps the reserved rows and shows the display-failure text there.
-- Rendering is verified through extmarks only (no redraw under --headless).

local H = require('tests.spec.rendermark.image.helpers')

local function bytes(arr) return string.char(unpack(arr)) end

-- Header-only PNG of w x h pixels (enough for the size reader).
local function png(w, h)
  local function be32(n) return string.char(0, 0, math.floor(n / 256), n % 256) end
  return bytes({ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82 }) .. be32(w) .. be32(h)
end

local function write(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
  return path
end

-- 200x120 at 10x20 px cells: six rows.
local function png_200x120() return png(200, 120) end

local function touch(path, seconds)
  local st = assert(vim.uv.fs_stat(path))
  assert(vim.uv.fs_utime(path, st.atime.sec, st.mtime.sec + seconds))
end

describe('an image the provider refuses', function()
  local old_ui, old_store, old_notify_once, img, buf, win, dir
  local calls, dels, mode, store, warnings

  -- mode: 'ok' | 'throw' | 'false' | function(id, path, opts) -> 'ok' | 'throw' | 'false'
  local function behave(id, path, opts)
    local m = type(mode) == 'function' and mode(id, path, opts) or mode
    if m == 'throw' then error('no image support') end
    if m == 'false' then return false end
    store[id] = { path = path, opts = opts }
  end

  before_each(function()
    old_ui = vim.ui
    old_store = rawget(_G, '__rendermark_image_backend')
    old_notify_once = vim.notify_once
    rawset(_G, '__rendermark_image_backend', nil)
    package.loaded['nvim_config.rendermark.image'] = nil
    img = require('nvim_config.rendermark.image')
    calls, dels, store, warnings, mode = {}, {}, {}, {}, 'ok'
    local seen = {}
    vim.notify_once = function(msg, level)
      if seen[msg] then return end
      seen[msg] = true
      warnings[#warnings + 1] = { msg, level }
    end
    vim.ui = { img = {
      set = function(id, path, opts)
        calls[#calls + 1] = path
        return behave(id, path, opts)
      end,
      del = function(id) dels[#dels + 1] = id; store[id] = nil end,
    } }
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    write(dir .. '/pic.png', png_200x120())
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = 10, 20
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.ui = old_ui
    vim.notify_once = old_notify_once
    rawset(_G, '__rendermark_image_backend', old_store)
    package.loaded['nvim_config.rendermark.image'] = nil
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = nil, nil
    vim.fn.delete(dir, 'rf')
  end)

  local function sync()
    img.send_images()
    vim.wait(30)
    img.send_images()
  end

  local function open(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. '/doc.md')
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.cmd('new')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd('resize 20')
    sync()
  end

  -- Reserved geometry: virt_lines count per anchor row, source conceals, and the
  -- plain text of every virt_lines/overlay chunk.
  local function summary()
    local out = { virt = {}, conceal = {}, failed = {}, overlay_failed = {}, total = 0 }
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, img.ensure_image_namespace(), 0, -1, { details = true })) do
      local d = m[4]
      if d.virt_lines then
        out.virt[m[2]] = (out.virt[m[2]] or 0) + #d.virt_lines
        out.total = out.total + #d.virt_lines
        for i, line in ipairs(d.virt_lines) do
          local text = img.virt_text_to_plain(line)
          if text:find('display failed', 1, true) then
            out.failed[#out.failed + 1] = { row = m[2], line = i, text = text, hl = line[1][2] }
          end
        end
      end
      if d.virt_text then
        local text = img.virt_text_to_plain(d.virt_text)
        if text:find('display failed', 1, true) then
          out.overlay_failed[#out.overlay_failed + 1] = { row = m[2], text = text }
        end
      end
      if d.conceal then out.conceal[#out.conceal + 1] = { m[2], m[3], d.end_col } end
    end
    return out
  end

    describe('when set raises', function()
    it('keeps the reserved rows and draws the error text in the first of them', function()
      open({ 'before', '![a](pic.png)', 'after' })
      local shown = summary()
      assert.equals(5, shown.virt[1])   -- 6 rows: the source row plus 5 virt_lines
      assert.equals(0, #shown.failed)
      assert.same({ { 1, 0, #'![a](pic.png)' } }, shown.conceal)
      assert.equals(1, #calls)

      -- Same revision, entry changes (window height): asked again, now it fails.
      mode = 'throw'
      vim.cmd('resize 15')
      sync()
      local failed = summary()
      assert.equals(2, #calls)
      assert.same(shown.virt, failed.virt)
      assert.equals(shown.total, failed.total)
      assert.same(shown.conceal, failed.conceal)
      assert.equals(1, #failed.failed)
      assert.equals(1, failed.failed[1].row)
      assert.equals(1, failed.failed[1].line)        -- first reserved row
      assert.equals('WarningMsg', failed.failed[1].hl)
      assert.truthy(failed.failed[1].text:find('[neopp: image display failed: pic.png]', 1, true))
      assert.equals(1, #warnings)
      assert.truthy(warnings[1][1]:find(dir .. '/pic.png', 1, true))
      -- The image that was on screen is taken down.
      assert.equals(1, #dels)
      assert.is_nil(next(store))
    end)

    it('shows the same rows as a working provider, from the first draw on', function()
      open({ 'before', '![a](pic.png)', 'after' })
      local working = summary()
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(buf, { force = true })
      rawset(_G, '__rendermark_image_backend', nil)
      package.loaded['nvim_config.rendermark.image'] = nil
      img = require('nvim_config.rendermark.image')
      mode = 'throw'
      open({ 'before', '![a](pic.png)', 'after' })
      local failed = summary()
      assert.same(working.virt, failed.virt)
      assert.same(working.conceal, failed.conceal)
      assert.equals(1, #failed.failed)
    end)

    it('does not ask again for the same revision, however often it syncs or scrolls', function()
      mode = 'throw'
      open({ 'before', '![a](pic.png)', 'after' })
      assert.equals(1, #calls)
      for _ = 1, 4 do sync() end
      vim.cmd('resize 12')
      sync()
      vim.cmd('resize 22')
      sync()
      assert.equals(1, #calls)
      assert.equals(1, #warnings)
      assert.equals(1, #summary().failed)
    end)

    it('asks again when the file changes, and fails again with the same rows', function()
      mode = 'throw'
      open({ 'before', '![a](pic.png)', 'after' })
      local before = summary()
      touch(dir .. '/pic.png', 5)
      sync()
      assert.equals(2, #calls)
      local after = summary()
      assert.same(before.virt, after.virt)
      assert.equals(1, #after.failed)
      sync()
      assert.equals(2, #calls)
    end)

    it('asks again when the displayed size changes (zoom), with the new height reserved', function()
      mode = 'throw'
      open({ 'before', '![a](pic.png)', 'after' })
      assert.equals(5, summary().virt[1])
      vim.g.neopp_font_zoom_scale = 0.5
      sync()
      vim.g.neopp_font_zoom_scale = nil
      assert.equals(2, #calls)
      local small = summary()
      assert.equals(2, small.virt[1])   -- 100x60: three rows
      assert.equals(1, #small.failed)
    end)

    it('recovers when a retry succeeds: box gone, image shown, same rows', function()
      mode = 'throw'
      open({ 'before', '![a](pic.png)', 'after' })
      local failed = summary()
      assert.equals(1, #failed.failed)
      mode = 'ok'
      sync()
      assert.equals(1, #calls)            -- same revision: still not retried
      assert.equals(1, #summary().failed)
      touch(dir .. '/pic.png', 5)
      sync()
      assert.equals(2, #calls)
      local ok = summary()
      assert.equals(0, #ok.failed)
      assert.same(failed.virt, ok.virt)
      assert.equals(failed.total, ok.total)
      assert.same(failed.conceal, ok.conceal)
      assert.equals(1, vim.tbl_count(store))
    end)

    it('keeps the failure while the image is away, for the same revision', function()
      mode = 'throw'
      open({ 'before', '![a](pic.png)', 'after' })
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'no image' })
      sync()
      assert.equals(0, #summary().failed)
      assert.equals(0, summary().total)
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '![a](pic.png)' })
      mode = 'ok'
      sync()
      -- Back again with the same revision: still refused, not asked again.
      assert.equals(1, #calls)
      assert.equals(1, #summary().failed)
    end)
  end)

  it('is tried again after images are switched off and on', function()
    mode = 'throw'
    open({ 'before', '![a](pic.png)', 'after' })
    assert.equals(1, #calls)
    vim.g.neopp_images_enabled = false
    sync()
    assert.equals(0, summary().total)
    vim.g.neopp_images_enabled = nil
    mode = 'ok'
    sync()
    assert.equals(2, #calls)
    assert.equals(0, #summary().failed)
    assert.equals(5, summary().virt[1])
  end)

  describe('when set returns false', function()
    it('is handled like an exception', function()
      mode = 'false'
      open({ 'before', '![a](pic.png)', 'after' })
      for _ = 1, 3 do sync() end
      assert.equals(1, #calls)
      local shown = summary()
      assert.equals(5, shown.virt[1])
      assert.equals(1, #shown.failed)
      assert.equals(1, #warnings)
      assert.truthy(warnings[1][1]:find('returned false', 1, true))
    end)

    it('does not count nil as a failure', function()
      mode = function() return nil end
      open({ 'before', '![a](pic.png)', 'after' })
      assert.equals(0, #summary().failed)
      assert.equals(0, #warnings)
    end)
  end)

  describe('with several images on one line', function()
    it('boxes only the refused one and still sends the others', function()
      write(dir .. '/bad.png', png_200x120())
      write(dir .. '/other.png', png_200x120())
      mode = function(_, path) return path:find('bad.png', 1, true) and 'throw' or 'ok' end
      open({ 'before', '![a](other.png) ![b](bad.png) ![c](pic.png)', 'after' })
      local shown = summary()
      assert.equals(3, #calls)
      assert.equals(5, shown.virt[1])
      assert.equals(1, #shown.failed)
      assert.truthy(shown.failed[1].text:find('bad.png', 1, true))
      local sent = {}
      for _, e in pairs(store) do sent[#sent + 1] = vim.fn.fnamemodify(e.path, ':t') end
      table.sort(sent)
      assert.same({ 'other.png', 'pic.png' }, sent)
    end)

    it('keeps the failure of one image when another one changes', function()
      write(dir .. '/bad.png', png_200x120())
      mode = function(_, path) return path:find('bad.png', 1, true) and 'throw' or 'ok' end
      open({ 'before', '![a](pic.png) ![b](bad.png)', 'after' })
      assert.equals(2, #calls)
      write(dir .. '/pic.png', png(100, 60))
      touch(dir .. '/pic.png', 7)
      sync()
      -- pic.png was sent again (new size), bad.png was not.
      local per_file = {}
      for _, path in ipairs(calls) do
        local name = vim.fn.fnamemodify(path, ':t')
        per_file[name] = (per_file[name] or 0) + 1
      end
      assert.same({ ['bad.png'] = 1, ['pic.png'] = 2 }, per_file)
      assert.equals(1, #summary().failed)
      assert.equals(1, #warnings)
    end)
  end)

  describe('for a diagram block', function()
    it('boxes the rendered image in the rows of the block and leaves the source hidden', function()
      write(dir .. '/d.png', png_200x120())
      local src = H.fence_source({ status = 'ready', path = dir .. '/d.png' })
      img.set_diagram_source(src)
      mode = 'throw'
      open({ 'before', '```plantuml', 'a -> b', '```', 'after' })
      local shown = summary()
      assert.equals(1, #calls)
      assert.equals(1, #shown.failed)
      -- Three source rows are hidden under six image rows.
      assert.equals(3, shown.total)
      assert.truthy(shown.failed[1].text:find('d.png', 1, true))
      assert.equals(0, #vim.tbl_filter(function(m) return m[4].virt_lines
        and img.virt_text_to_plain(m[4].virt_lines[1]):find('[diagram:', 1, true) end,
        vim.api.nvim_buf_get_extmarks(buf, img.ensure_image_namespace(), 0, -1, { details = true })))
    end)
  end)

  describe('with the terminal stub', function()
    it('replaces the stub box by the error text without changing the rows', function()
      -- A provider-less terminal: the stub is installed and then made to fail.
      vim.ui = {}
      rawset(_G, '__rendermark_image_backend', nil)
      package.loaded['nvim_config.rendermark.image'] = nil
      vim.g.rendermark_img_stub = true
      img = require('nvim_config.rendermark.image')
      img.setup({})
      vim.g.rendermark_img_stub = nil
      assert.is_true(img._stub_active)
      local stub_set = vim.ui.img.set
      local fail = false
      vim.ui.img.set = function(...)
        calls[#calls + 1] = select(2, ...)
        if fail then error('refused') end
        return stub_set(...)
      end
      open({ 'before', '![a](pic.png)', 'after' })
      local boxed = summary()
      assert.equals(5, boxed.virt[1])
      assert.equals(0, #boxed.failed)
      fail = true
      vim.cmd('resize 15')
      sync()
      local failed = summary()
      assert.same(boxed.virt, failed.virt)
      assert.equals(boxed.total, failed.total)
      assert.same(boxed.conceal, failed.conceal)
      assert.equals(1, #failed.failed)
      assert.equals(1, #warnings)
    end)
  end)

  describe('rows that are not virt_lines', function()
    it('puts the text on the source row when the image is one row high', function()
      write(dir .. '/tiny.png', png(40, 10))
      mode = 'throw'
      open({ 'before', '![a](tiny.png)', 'after' })
      local shown = summary()
      assert.equals(0, shown.total)
      assert.equals(1, #shown.overlay_failed)
      assert.equals(1, shown.overlay_failed[1].row)
    end)

    it('draw_stub_footprint_box emits a carried reservation larger than the image', function()
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a', 'b' })
      local ns = img.ensure_image_namespace()
      img.draw_stub_footprint_box(buf, ns, {
        row = 0, reserve_h = 5,
        label = { source_span = 1, virt_h = 3, boxes = { { name = 'x.png', w_px = 100, h_px = 60, start_cell = 0 } } },
      }, 10, nil)
      local virt = 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        virt = virt + #(m[4].virt_lines or {})
      end
      assert.equals(4, virt)
    end)
  end)

  describe('inside a table cell', function()
    local wrap = require('nvim_config.rendermark.wrap')

    after_each(function() pcall(wrap.disable, 0) end)

    it('does not touch the other image, and keeps the cell blank', function()
      write(dir .. '/bad.png', png_200x120())
      mode = function(_, path) return path:find('bad.png', 1, true) and 'throw' or 'ok' end
      local safe_screenpos = img.safe_screenpos
      img.safe_screenpos = function(_, lnum) return { row = lnum, col = 1 } end
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, dir .. '/doc.md')
      vim.cmd('new')
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      wrap.setup({ left_pad = 0, right_pad = 0, max_width = 70 })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'prose', '| a | b |', '|--|--|',
        '| ![](pic.png) | ![](bad.png) |' })
      vim.bo[buf].filetype = 'markdown'
      wrap.apply(0)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      wrap.refresh(0)
      img.send_images()
      vim.wait(30)
      img.send_images()
      img.safe_screenpos = safe_screenpos
      local function bad_calls()
        local n = 0
        for _, path in ipairs(calls) do
          if path:find('bad.png', 1, true) then n = n + 1 end
        end
        return n
      end
      local settled = bad_calls()
      local sent = {}
      for _, e in pairs(store) do sent[#sent + 1] = vim.fn.fnamemodify(e.path, ':t') end
      assert.same({ 'pic.png' }, sent)
      -- The table owns the cell rows; the image namespace stays empty.
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(buf, img.ensure_image_namespace(), 0, -1, {}))
      for _ = 1, 3 do img.send_images() end
      -- The refused image is not asked again (the other one is the table's own business).
      assert.equals(settled, bad_calls())
      assert.equals(1, #warnings)
    end)
  end)
end)
