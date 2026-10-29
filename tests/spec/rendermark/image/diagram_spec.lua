-- rendermark.image diagram items: drawing, errors and previews driven by a
-- provider. A fake provider stands in for any real renderer.
local H = require('tests.spec.rendermark.image.helpers')

local function bytes(arr) return string.char(unpack(arr)) end

-- 100x50 PNG header (the size reader only needs the leading bytes).
local PNG = bytes({
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
  0, 0, 0, 100, 0, 0, 0, 50,
})

local function tmpfile(data, ext)
  local p = vim.fn.tempname() .. (ext or '.png')
  local f = assert(io.open(p, 'wb'))
  f:write(data)
  f:close()
  return p
end

local function fresh_image()
  package.loaded['nvim_config.rendermark.image'] = nil
  return require('nvim_config.rendermark.image')
end

local LINES = {
  'intro',          -- 0
  '```plantuml',    -- 1
  '@startuml',      -- 2
  'a -> b',         -- 3
  '@enduml',        -- 4
  '```',            -- 5
  'outro',          -- 6
}
local START, END = 1, 5

describe('rendermark diagram items', function()
  local img, src, buf, win, png, store, sets
  local old_ui, old_backend

  -- Fresh module, fake vim.ui.img that counts `set`, and one window on `buf`.
  before_each(function()
    old_ui = vim.ui
    old_backend = rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)
    store, sets = {}, 0
    vim.ui = {
      img = {
        set = function(id, path, opts) sets = sets + 1; store[id] = { path = path, opts = opts } end,
        del = function(id) store[id] = nil end,
        get = function(id) return store[id] end,
      },
    }
    img = fresh_image()
    png = tmpfile(PNG)
    src = H.fence_source({ status = 'ready', path = png })
    img.set_diagram_source(src)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
    vim.bo[buf].filetype = 'markdown'
    vim.cmd('new')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_cursor(win, { 1, 0 }) -- row 0, outside the block
  end)

  after_each(function()
    -- Let scheduled syncs (refresh) run while their buffer and window still exist.
    vim.wait(30, function() return false end)
    pcall(img.diagram_cleanup_buf, buf)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_backend)
  end)

  local function collect()
    local result, errors = {}, {}
    img.collect_diagram_images(buf, result, errors)
    return result, errors
  end

  local function error_lines()
    local texts = {}
    local ns = img.ensure_image_namespace()
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        texts[#texts + 1] = img.virt_text_to_plain(vl)
      end
    end
    return texts
  end

  local function buf_image()
    for id, entry in pairs(store) do
      if id:sub(1, 4) == 'buf:' then return entry end
    end
  end

  local function preview_windows()
    local found = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local ok, meta = pcall(function() return vim.w[w].rendermark_diagram_preview_source end)
      if ok and type(meta) == 'table' then found[#found + 1] = { win = w, meta = meta } end
    end
    return found
  end

  describe('ready item', function()
    it('becomes an image item spanning the whole block', function()
      local result, errors = collect()
      assert.equals(0, #errors)
      assert.equals(1, #result)
      local item = result[1]
      assert.equals(START, item.row)
      assert.equals(png, item.path)
      assert.equals(100, item.source_width)
      assert.equals(50, item.source_height)
      assert.equals(END - START + 1, item.source_span_height)
      assert.is_true(item.diagram)
      assert.equals(END, item.diagram_end_row)
      assert.is_false(item.virtual)
    end)

    it('keeps a stale image while its replacement is pending, but not a failed one', function()
      src.status, src.stale = 'pending', true
      img.refresh(buf)
      assert.equals(1, #(collect()))
      src.status = 'failed'
      src.error = 'boom'
      img.refresh(buf)
      assert.equals(0, #(collect()))
    end)

    it('leaves an unreadable image (for example SVG) as source', function()
      src.path = tmpfile('<svg/>', '.svg')
      img.refresh(buf)
      local result, errors = collect()
      assert.equals(0, #result)
      assert.equals(0, #errors)
    end)
  end)

  describe('other statuses', function()
    it('reports a failed item as an error on the closing fence row', function()
      src.status, src.path, src.error = 'failed', nil, 'syntax error line 3'
      img.refresh(buf)
      local result, errors = collect()
      assert.equals(0, #result)
      assert.same({ { buf = buf, row = END, msg = 'syntax error line 3' } }, errors)
    end)

    it('shows a failed item as a [diagram: ...] warning line', function()
      src.status, src.path, src.error = 'failed', nil, 'syntax error line 3'
      img.refresh(buf)
      img.send_images()
      assert.same({ ' [diagram: syntax error line 3]' }, error_lines())
    end)

    it('draws nothing for none and pending', function()
      for _, status in ipairs({ 'none', 'pending' }) do
        src.status, src.path = status, nil
        img.refresh(buf)
        local result, errors = collect()
        assert.equals(0, #result)
        assert.equals(0, #errors)
        img.send_images()
        assert.same({}, error_lines())
      end
    end)
  end)

  describe('active block', function()
    local function enter_block()
      vim.api.nvim_win_set_cursor(win, { START + 2, 0 }) -- inside the fence
    end

    it('is left out of the result and previewed instead', function()
      enter_block()
      local result = collect()
      assert.equals(0, #result)
      local previews = preview_windows()
      assert.equals(1, #previews)
      assert.equals(png, previews[1].meta.path)
      assert.equals(START, previews[1].meta.start_row)
      assert.equals(0, #src.live_calls) -- already rendered: no live request
    end)

    it('asks the provider for a live render once, after the 400 ms debounce', function()
      src.status, src.path = 'none', nil
      img.refresh(buf)
      enter_block()
      collect()
      collect()
      collect()
      assert.equals(0, #src.live_calls)
      vim.wait(250, function() return false end)
      collect() -- re-armed by the repeat
      assert.equals(0, #src.live_calls)
      assert.is_true(vim.wait(1500, function() return #src.live_calls > 0 end, 20))
      vim.wait(600, function() return false end)
      assert.equals(1, #src.live_calls)
      assert.equals(buf, src.live_calls[1].buf)
      assert.equals(START, src.live_calls[1].row)
      assert.equals(0, #preview_windows()) -- nothing to show before the render exists
      -- Same text: asked once, not again.
      collect()
      vim.wait(600, function() return false end)
      assert.equals(1, #src.live_calls)
    end)

    it('keeps a stale preview and survives a failing request_live', function()
      src.stale = true
      src.request_live = function() error('request failed') end
      enter_block()
      collect()
      assert.equals(1, #preview_windows()) -- the stale image stays up
      vim.wait(600, function() return false end)
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
    end)

    it('does not preview a block under the cursor while the preview is hidden', function()
      img._preview_user = false
      enter_block()
      assert.equals(0, #(collect()))
      assert.equals(0, #preview_windows())
      assert.equals(0, #src.live_calls)
    end)

    it('is never active in a read-mode window: the image stays drawn and no preview opens', function()
      src.status, src.path = 'none', nil
      img.refresh(buf)
      vim.w[win].read_mode_active = true
      enter_block()
      assert.equals(0, #(collect()))
      vim.wait(600, function() return false end)
      assert.equals(0, #preview_windows())
      assert.equals(0, #src.live_calls) -- no live render is requested either
      src.status, src.path = 'ready', png
      img.refresh(buf)
      local result = collect()
      assert.equals(1, #result) -- the cursor inside the block does not reveal the source
      assert.equals(START, result[1].row)
      assert.equals(0, #preview_windows())
      vim.w[win].read_mode_active = nil
      assert.equals(0, #(collect())) -- leaving read mode makes the block active again
      assert.equals(1, #preview_windows())
    end)
  end)

  describe('provider', function()
    it('absent: no diagram items, markdown images still collected', function()
      img.clear_diagram_source()
      local result, errors = collect()
      assert.equals(0, #result)
      assert.equals(0, #errors)
      local md = tmpfile(PNG)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '![alt](' .. md .. ')' })
      local images = img.collect_markdown_images(buf, 0, 1)
      assert.equals(1, #images)
      assert.equals(md, images[1].path)
      assert.is_nil(images[1].diagram)
    end)

    it('is required to have an items function', function()
      assert.has_error(function() img.set_diagram_source({}) end)
      assert.has_error(function() img.set_diagram_source({ items = function() end, request_live = 1 }) end)
    end)

    it('raising from items() neither throws nor stops markdown images', function()
      src.raise = 'items exploded'
      img.refresh(buf)
      local result, errors
      assert.has_no.errors(function() result, errors = collect() end)
      assert.equals(0, #result)
      assert.equals(0, #errors)
      assert.has_no.errors(function() img.send_images() end)
      assert.has_no.errors(function() img.cursor_active_block_sig() end)
      local md = tmpfile(PNG)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '![alt](' .. md .. ')' })
      assert.equals(1, #img.collect_markdown_images(buf, 0, 1))
    end)

    it('ignores malformed items', function()
      src.items = function() return { 'x', { start_row = 'a' }, { start_row = 3, end_row = 1 },
        { start_row = 1, end_row = END, status = 'ready', path = png } } end
      img.refresh(buf)
      assert.equals(1, #img.diagram_items(buf))
    end)
  end)

  describe('refresh', function()
    it('shows new items on the next send and does not re-set unchanged images', function()
      src.status, src.path = 'none', nil
      img.refresh(buf)
      img.send_images()
      img.send_images()
      assert.is_nil(buf_image())

      -- The provider changed but nobody said so: the cached answer is reused.
      src.status, src.path = 'ready', png
      img.send_images()
      assert.is_nil(buf_image())

      img.refresh(buf)
      img.send_images() -- first send reserves virt_lines
      img.send_images() -- second send applies the payload
      assert.is_not_nil(buf_image())
      assert.equals(png, buf_image().path)

      local before = sets
      img.send_images()
      img.send_images()
      img.send_images()
      assert.equals(before, sets)
    end)

    it('leaves other buffers cached', function()
      local other = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(other, 0, -1, false, LINES)
      img.diagram_items(buf)
      img.diagram_items(other)
      local calls = src.item_calls
      img.refresh(buf)
      img.diagram_items(other)
      assert.equals(calls, src.item_calls)
      img.diagram_items(buf)
      assert.equals(calls + 1, src.item_calls)
      pcall(img.diagram_cleanup_buf, other)
      pcall(vim.api.nvim_buf_delete, other, { force = true })
    end)

    it('accepts an unloaded or invalid buffer', function()
      assert.has_no.errors(function() img.refresh(99999) end)
      assert.has_no.errors(function() img.refresh() end)
    end)
  end)

  describe('moving blocks', function()
    it('draws at the new rows when the provider reports them after an edit', function()
      assert.equals(START, (collect())[1].row)
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'new 1', 'new 2' })
      local result = collect()
      assert.equals(START + 2, result[1].row)
      assert.equals(END + 2, result[1].diagram_end_row)
      assert.equals(END - START + 1, result[1].source_span_height)
    end)
  end)

  -- Q3: a link image right below the block (zero or one blank line) is the
  -- exported copy of the diagram; it draws, the block keeps its source.
  describe('exported image below the block', function()
    local png2, link

    before_each(function()
      png2 = tmpfile(PNG)
      link = '![exported](' .. png2 .. ')'
    end)

    local function below(extra)
      local lines = vim.list_slice(LINES, 1, END + 1) -- intro .. closing fence
      vim.list_extend(lines, extra)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end

    local function stored_paths()
      local paths = {}
      for id, entry in pairs(store) do
        if id:sub(1, 4) == 'buf:' then paths[#paths + 1] = entry.path end
      end
      table.sort(paths)
      return paths
    end

    it('hides the block image for a link with zero or one blank line between', function()
      below({ link })
      assert.equals(0, #(collect()))
      below({ '', link })
      assert.equals(0, #(collect()))
    end)

    it('keeps the block image for two or more blank lines', function()
      below({ '', '', link })
      assert.equals(1, #(collect()))
      below({ '', '', '', link })
      assert.equals(1, #(collect()))
    end)

    it('keeps the block image when the next paragraph has no image', function()
      below({ '', 'plain text', 'more text' })
      assert.equals(1, #(collect()))
    end)

    it('looks at the whole paragraph, but not past its end', function()
      below({ '', 'caption', link })
      assert.equals(0, #(collect()))
      below({ '', 'caption', '', link })
      assert.equals(1, #(collect()))
    end)

    it('ignores links in code spans, remote links and code fences', function()
      below({ '', '`' .. link .. '`' })
      assert.equals(1, #(collect()))
      below({ '', '![remote](https://example.com/a.png)' })
      assert.equals(1, #(collect()))
      below({ '```lua', link, '```' })
      assert.equals(1, #(collect()))
    end)

    it('counts an inline link inside the paragraph text', function()
      below({ 'text ' .. link .. ' text' })
      assert.equals(0, #(collect()))
    end)

    it('is not applied when diagram.hide_when_exported is false, and defaults to true', function()
      below({ link })
      vim.ui = old_ui -- no image backend: setup only reads the options
      img.setup({ diagram = { hide_when_exported = false } })
      assert.equals(1, #(collect()))
      img.setup({ diagram = { preview = { auto = true } } })
      assert.equals(0, #(collect()))
      img.setup({ diagram = { hide_when_exported = false } })
      img.setup()
      assert.equals(0, #(collect()))
    end)

    it('follows edits of the link on the first query after the edit', function()
      assert.equals(1, #(collect()))
      vim.api.nvim_buf_set_lines(buf, END + 1, END + 1, false, { link }) -- link right below the fence
      assert.equals(0, #(collect()))
      vim.api.nvim_buf_set_lines(buf, END + 1, END + 2, false, { 'no image any more' })
      assert.equals(1, #(collect()))
      vim.api.nvim_buf_set_lines(buf, END + 1, END + 1, false, { '', '' }) -- push it out of reach
      vim.api.nvim_buf_set_lines(buf, END + 3, END + 4, false, { link })
      assert.equals(1, #(collect()))
      vim.api.nvim_buf_set_lines(buf, END + 1, END + 2, false, {}) -- one blank line left
      assert.equals(0, #(collect()))
      vim.api.nvim_buf_set_lines(buf, END + 1, END + 3, false, {}) -- link deleted
      assert.equals(1, #(collect()))
    end)

    it('follows a provider refresh without an edit', function()
      below({ '', link })
      collect()
      img.refresh(buf)
      assert.equals(0, #(collect()))
    end)

    it('is fine when the block ends the buffer', function()
      below({})
      assert.equals(END + 1, vim.api.nvim_buf_line_count(buf))
      local result
      assert.has_no.errors(function() result = collect() end)
      assert.equals(1, #result)
      -- ... or a blank line is all that follows.
      below({ '' })
      assert.equals(1, #(collect()))
    end)

    it('reads only the rows after the block, never the whole buffer', function()
      -- The fake provider reads the whole buffer itself; answer without it.
      src.items = function()
        return { { start_row = START, end_row = END, key = 'k', lang = 'plantuml',
          path = png, format = 'png', stale = false, status = 'ready' } }
      end
      below({ '', link })
      img.refresh(buf)
      local reads = {}
      local real = vim.api.nvim_buf_get_lines
      vim.api.nvim_buf_get_lines = function(b, s, e, strict)
        reads[#reads + 1] = { b = b, s = s, e = e }
        return real(b, s, e, strict)
      end
      local ok, result = pcall(collect)
      vim.api.nvim_buf_get_lines = real
      assert(ok, result)
      assert.equals(0, #result)
      assert.equals(1, #reads)
      assert.same({ buf, END + 1 }, { reads[1].b, reads[1].s })
      assert.is_true(reads[1].e > 0 and reads[1].e - reads[1].s <= 32)
      -- Same tick: the verdict is reused, nothing is read.
      reads = {}
      vim.api.nvim_buf_get_lines = function(b, s, e, strict)
        reads[#reads + 1] = { s, e }
        return real(b, s, e, strict)
      end
      ok, result = pcall(collect)
      vim.api.nvim_buf_get_lines = real
      assert(ok, result)
      assert.equals(0, #reads)
    end)

    it('draws only the link image, with no reservation or conceal for the block', function()
      below({ '', link })
      src.item_calls = 0
      img.refresh(buf)
      img.send_images()
      img.send_images()
      assert.same({ png2 }, stored_paths())
      local ns = img.ensure_image_namespace()
      -- Image-namespace marks (conceals, reservations) on the block rows.
      local function marks_in_block()
        return #vim.api.nvim_buf_get_extmarks(buf, ns, { START, 0 }, { END, -1 }, {})
      end
      assert.equals(0, marks_in_block())
      assert.is_true(#vim.api.nvim_buf_get_extmarks(buf, ns, { END + 1, 0 }, { -1, -1 }, {}) > 0)

      -- Without the option the block is drawn as well (both images, reservations for both).
      vim.ui = old_ui
      img.setup({ diagram = { hide_when_exported = false } })
      vim.ui = { img = { set = function(id, path, opts) store[id] = { path = path, opts = opts } end,
        del = function(id) store[id] = nil end, get = function(id) return store[id] end } }
      img.refresh(buf)
      img.send_images()
      img.send_images()
      assert.same({ png, png2 }, stored_paths())
      assert.is_true(marks_in_block() > 0)
    end)

    it('drops the block image and its reservation when a link is added, and restores them when removed', function()
      local ns = img.ensure_image_namespace()
      local function marks_in_block()
        return #vim.api.nvim_buf_get_extmarks(buf, ns, { START, 0 }, { END, -1 }, {})
      end
      img.send_images()
      img.send_images()
      assert.same({ png }, stored_paths())
      assert.is_true(marks_in_block() > 0)

      vim.api.nvim_buf_set_lines(buf, END + 1, END + 1, false, { link })
      img.send_images()
      img.send_images()
      assert.same({ png2 }, stored_paths())
      assert.equals(0, marks_in_block())

      vim.api.nvim_buf_set_lines(buf, END + 1, END + 2, false, {})
      img.send_images()
      img.send_images()
      assert.same({ png }, stored_paths())
      assert.is_true(marks_in_block() > 0)
    end)

    it('leaves the active block preview as it was', function()
      below({ '', link })
      vim.api.nvim_win_set_cursor(win, { START + 2, 0 })
      img.refresh(buf)
      local result = collect()
      assert.equals(0, #result)
      local previews = preview_windows()
      assert.equals(1, #previews)
      assert.equals(png, previews[1].meta.path)
    end)

    it('still reports a failed render', function()
      src.status, src.path, src.error = 'failed', nil, 'boom'
      below({ '', link })
      img.refresh(buf)
      local _, errors = collect()
      assert.same({ { buf = buf, row = END, msg = 'boom' } }, errors)
    end)
  end)

  describe('settings', function()
    local old_notify_once
    before_each(function()
      old_notify_once = vim.notify_once
    end)
    after_each(function()
      vim.notify_once = old_notify_once
    end)

    it('prefers diagram.preview and accepts plantuml.preview with a one-line warning', function()
      vim.ui = old_ui -- no image backend: setup only reads the options
      local warnings = {}
      vim.notify_once = function(msg, level) warnings[#warnings + 1] = { msg, level } end
      img.setup({ diagram = { preview = { auto = false } } })
      assert.is_false(img.preview_active())
      assert.equals(0, #warnings)

      img.setup({ plantuml = { preview = { auto = false } } })
      assert.is_false(img.preview_active())
      assert.equals(1, #warnings)
      assert.equals(vim.log.levels.WARN, warnings[1][2])
      assert.is_truthy(warnings[1][1]:find('opts.diagram.preview', 1, true))

      img.setup({ diagram = { preview = { auto = true } }, plantuml = { preview = { auto = false } } })
      assert.is_true(img.preview_active())
    end)
  end)
end)
