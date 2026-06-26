-- Tests for the rendermark.image performance optimizations:
--   * parse_image_size (pure header decode) + read_image_size stat-gated cache
--   * cursor-move render gate (cursor_block_id / cursor_active_block_sig /
--     handle_cursor_moved)
--   * util.debounce (used to coalesce TextChanged renders)
-- plus regression coverage for adjacent pure helpers reachable from these paths.

local image = require('rendermark.image')
local image_backend = require('rendermark.image.backend')
local util = require('util')

-- Reload the module so module-local state (cursor_block_sig, image_size_cache)
-- starts fresh for state-sensitive tests.
local function fresh_image()
  package.loaded['rendermark.image'] = nil
  return require('rendermark.image')
end

local function bytes(arr)
  return string.char(unpack(arr))
end

-- 100x50 fixtures, header-only (parse reads just the leading bytes).
local PNG = bytes({
  137, 80, 78, 71, 13, 10, 26, 10,  -- signature
  0, 0, 0, 13,                      -- IHDR length
  73, 72, 68, 82,                   -- "IHDR"
  0, 0, 0, 100,                     -- width  = 100
  0, 0, 0, 50,                      -- height = 50
})

local JPEG = bytes({
  255, 216,        -- SOI
  255, 192,        -- SOF0 marker
  0, 11,           -- segment length
  8,               -- precision
  0, 50,           -- height = 50
  0, 100,          -- width  = 100
  1, 34, 0, 0, 0,  -- component data / pad
})

local WEBP = bytes({
  82, 73, 70, 70,  -- "RIFF"
  0, 0, 0, 0,      -- file size
  87, 69, 66, 80,  -- "WEBP"
  86, 80, 56, 88,  -- "VP8X"
  0, 0, 0, 0,      -- chunk size
  0,               -- flags
  0, 0, 0,         -- reserved
  99, 0, 0,        -- width  - 1 (u24le) = 99  -> 100
  49, 0, 0,        -- height - 1 (u24le) = 49  -> 50
})

local function tmpfile(data)
  local p = vim.fn.tempname()
  local f = assert(io.open(p, 'wb'))
  f:write(data)
  f:close()
  return p
end

describe('parse_image_size', function()
  it('decodes a PNG header', function()
    assert.same({ width = 100, height = 50, format = 'png' }, image.parse_image_size(PNG))
  end)

  it('decodes a JPEG SOF0 header', function()
    assert.same({ width = 100, height = 50, format = 'jpeg' }, image.parse_image_size(JPEG))
  end)

  it('decodes a WEBP VP8X header', function()
    assert.same({ width = 100, height = 50, format = 'webp' }, image.parse_image_size(WEBP))
  end)

  it('returns nil for garbage / truncated / non-string input', function()
    assert.is_nil(image.parse_image_size('not an image at all'))
    assert.is_nil(image.parse_image_size(''))
    assert.is_nil(image.parse_image_size(nil))
    assert.is_nil(image.parse_image_size('\137PNG\r\n\026\n'))  -- signature only, < 24 bytes
  end)
end)

describe('read_image_size cache', function()
  it('reads dimensions from a real file', function()
    local img = fresh_image()
    assert.same({ width = 100, height = 50, format = 'png' }, img.read_image_size(tmpfile(PNG)))
  end)

  it('serves a second read from cache without reopening the file', function()
    local img = fresh_image()
    local path = tmpfile(PNG)
    assert.same({ width = 100, height = 50, format = 'png' }, img.read_image_size(path))

    local orig = io.open
    local opens = 0
    io.open = function(...) opens = opens + 1; return orig(...) end
    local second = img.read_image_size(path)
    io.open = orig

    assert.same({ width = 100, height = 50, format = 'png' }, second)
    assert.equals(0, opens)
  end)

  it('invalidates when the file changes', function()
    local img = fresh_image()
    local path = tmpfile(PNG)
    assert.same({ width = 100, height = 50, format = 'png' }, img.read_image_size(path))

    -- Overwrite with a different image (different size + format).
    local f = assert(io.open(path, 'wb')); f:write(JPEG); f:close()
    assert.same({ width = 100, height = 50, format = 'jpeg' }, img.read_image_size(path))
  end)

  it('returns nil for a missing file', function()
    local img = fresh_image()
    assert.is_nil(img.read_image_size(vim.fn.tempname() .. '_does_not_exist.png'))
  end)
end)

describe('cursor_block_id', function()
  local blocks = { { start_row = 2, end_row = 5 }, { start_row = 10, end_row = 12 } }

  it('returns the block identity when the cursor is inside (boundaries inclusive)', function()
    assert.equals('2:5', image.cursor_block_id(2, blocks))
    assert.equals('2:5', image.cursor_block_id(3, blocks))
    assert.equals('2:5', image.cursor_block_id(5, blocks))
    assert.equals('10:12', image.cursor_block_id(11, blocks))
  end)

  it('returns empty when the cursor is outside every block', function()
    assert.equals('', image.cursor_block_id(0, blocks))
    assert.equals('', image.cursor_block_id(7, blocks))
    assert.equals('', image.cursor_block_id(20, blocks))
  end)

  it('handles an empty or nil block list', function()
    assert.equals('', image.cursor_block_id(3, {}))
    assert.equals('', image.cursor_block_id(3, nil))
  end)
end)

describe('cursor_active_block_sig', function()
  it('reflects whether the cursor sits inside a PlantUML block', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'intro',        -- row 0
      '```plantuml',  -- row 1  (fence open)
      '@startuml',     -- row 2
      'a -> b',        -- row 3
      '@enduml',       -- row 4
      '```',           -- row 5  (fence close)
      'outro',        -- row 6
    })
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_win_set_buf(0, buf)

    vim.api.nvim_win_set_cursor(0, { 4, 0 })  -- 1-based line 4 = row 3, inside block [1,5]
    assert.is_truthy(image.cursor_active_block_sig():find('=1:5', 1, true))

    vim.api.nvim_win_set_cursor(0, { 1, 0 })  -- row 0, outside
    assert.equals('', image.cursor_active_block_sig())

    vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it('is empty for a non-markdown buffer', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '```plantuml', '@startuml', '@enduml', '```' })
    vim.bo[buf].filetype = 'lua'
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    assert.equals('', image.cursor_active_block_sig())
    vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it('is empty while focus is in another buffer even if a markdown window cursor is in a PlantUML block', function()
    local original_win = vim.api.nvim_get_current_win()
    local markdown_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(markdown_buf, 0, -1, false, {
      'intro',
      '```plantuml',
      '@startuml',
      'a -> b',
      '@enduml',
      '```',
      'outro',
    })
    vim.bo[markdown_buf].filetype = 'markdown'
    vim.api.nvim_win_set_buf(original_win, markdown_buf)
    vim.api.nvim_win_set_cursor(original_win, { 4, 0 })

    local other_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[other_buf].filetype = 'TelescopePrompt'
    vim.cmd('botright split')
    local other_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(other_win, other_buf)

    assert.equals('', image.cursor_active_block_sig())

    vim.api.nvim_set_current_win(original_win)
    assert.is_truthy(image.cursor_active_block_sig():find('=1:5', 1, true))

    pcall(vim.api.nvim_win_close, other_win, true)
    vim.api.nvim_win_set_buf(original_win, vim.api.nvim_create_buf(false, true))
    pcall(vim.api.nvim_buf_delete, markdown_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
  end)
end)

describe('handle_cursor_moved gate', function()
  it('renders only when the active-block signature changes', function()
    local img = fresh_image()
    local sends = 0
    img.send_images = function() sends = sends + 1 end
    local sig = ''
    img.cursor_active_block_sig = function() return sig end

    sig = '';          img.handle_cursor_moved()  -- nil -> '' : first observation, render
    assert.equals(1, sends)
    sig = '';          img.handle_cursor_moved()  -- '' -> '' : no change, skip
    assert.equals(1, sends)
    sig = 'w1=2:5';    img.handle_cursor_moved()  -- enter a block
    assert.equals(2, sends)
    sig = 'w1=2:5';    img.handle_cursor_moved()  -- move within the same block, skip
    assert.equals(2, sends)
    sig = 'w1=10:12';  img.handle_cursor_moved()  -- move into a different block
    assert.equals(3, sends)
    sig = '';          img.handle_cursor_moved()  -- leave the block
    assert.equals(4, sends)
  end)

  it('also renders when the stub image-row signature changes', function()
    local img = fresh_image()
    local sends = 0
    img.send_images = function() sends = sends + 1 end
    img.cursor_active_block_sig = function() return '' end
    local stub = ''
    img.stub_cursor_sig = function() return stub end

    stub = '';      img.handle_cursor_moved()  -- first observation, render
    assert.equals(1, sends)
    stub = 'w1=4';  img.handle_cursor_moved()  -- cursor enters an image row
    assert.equals(2, sends)
    stub = 'w1=4';  img.handle_cursor_moved()  -- still on the row, skip
    assert.equals(2, sends)
    stub = '';      img.handle_cursor_moved()  -- leaves the image row
    assert.equals(3, sends)
  end)
end)

describe('build_stub_box_rows', function()
  local function row_text(chunks)
    local s = {}
    for _, c in ipairs(chunks or {}) do s[#s + 1] = c[1] end
    return table.concat(s)
  end

  it('draws a single box across virt_h rows, anchored at column 0', function()
    local rows = image.build_stub_box_rows(
      { { name = 'a.png', w_px = 100, h_px = 50, start_cell = 0 } }, 3, 10)
    assert.is_truthy(rows[0]); assert.is_truthy(rows[1]); assert.is_truthy(rows[2])
    assert.is_nil(rows[3])
    local top = row_text(rows[0])
    assert.equals('+', top:sub(1, 1))
    assert.equals('+', top:sub(-1))
    assert.equals(10, #top)  -- box_w = round(100/10) = 10 cells
    local mid = row_text(rows[1])
    assert.equals('|', mid:sub(1, 1))
    assert.equals('|', mid:sub(-1))
  end)

  it('lays multiple images side-by-side, normalized so the leftmost is at col 0', function()
    local rows = image.build_stub_box_rows({
      { name = 'a.png', w_px = 100, h_px = 50, start_cell = 0 },   -- cols 0..9
      { name = 'b.png', w_px = 100, h_px = 50, start_cell = 15 },  -- cols 15..24
    }, 3, 10)
    local top = row_text(rows[0])
    assert.equals(25, #top)
    assert.equals('+', top:sub(1, 1))     -- first box opens
    assert.equals('+', top:sub(10, 10))   -- first box closes
    assert.equals(' ', top:sub(11, 11))   -- gap between boxes
    assert.equals('+', top:sub(16, 16))   -- second box opens (col 15, 1-based 16)
    assert.equals('+', top:sub(25, 25))   -- second box closes
  end)

  it('bumps overlapping boxes right so they never collide', function()
    local rows = image.build_stub_box_rows({
      { name = 'a.png', w_px = 100, h_px = 50, start_cell = 0 },  -- cols 0..9
      { name = 'b.png', w_px = 100, h_px = 50, start_cell = 3 },  -- bumped to col 10
    }, 3, 10)
    assert.equals(20, #row_text(rows[0]))  -- two adjacent 10-wide boxes
  end)

  it('renders a single-line label when virt_h <= 1', function()
    local rows = image.build_stub_box_rows(
      { { name = 'a.png', w_px = 100, h_px = 50, start_cell = 0 } }, 1, 10)
    assert.is_truthy(rows[0])
    assert.is_nil(rows[1])
  end)

  it('returns no rows for an empty box list', function()
    assert.same({}, image.build_stub_box_rows({}, 3, 10))
  end)

  it('keeps the leftmost box at its start_cell so leading prose can push it right', function()
    local rows = image.build_stub_box_rows(
      { { name = 'a.png', w_px = 100, h_px = 50, start_cell = 4 } }, 1, 10)
    local top = row_text(rows[0])
    assert.equals('    ', top:sub(1, 4))  -- 4-cell leading offset preserved
    assert.equals('[', top:sub(5, 5))     -- single-line label begins after the offset
  end)
end)

describe('build_image_text_rows', function()
  local function row_text(chunks)
    local s = {}
    for _, c in ipairs(chunks or {}) do s[#s + 1] = c[1] end
    return table.concat(s)
  end

  it('bottom-aligns a short segment on the last visual row', function()
    local rows = image.build_image_text_rows(
      { { text = 'hi', start_cell = 0, width_cells = 10 } }, 3, {})
    assert.is_nil(rows[0])
    assert.is_nil(rows[1])
    assert.equals('hi', row_text(rows[2]))
  end)

  it('positions the segment at its start_cell', function()
    local rows = image.build_image_text_rows(
      { { text = 'hi', start_cell = 4, width_cells = 10 } }, 1, {})
    assert.equals('    hi', row_text(rows[0]))
  end)

  it('wraps within the slot width, stacking bottom-aligned', function()
    local rows = image.build_image_text_rows(
      { { text = 'aa bb cc', start_cell = 0, width_cells = 3 } }, 3, {})
    assert.equals('aa', row_text(rows[0]))
    assert.equals('bb', row_text(rows[1]))
    assert.equals('cc', row_text(rows[2]))
  end)

  it('clips from the top when the wrapped text is taller than the band', function()
    local rows = image.build_image_text_rows(
      { { text = 'aa bb cc', start_cell = 0, width_cells = 3 } }, 2, {})
    assert.equals('bb', row_text(rows[0]))  -- 'aa' (top) dropped
    assert.equals('cc', row_text(rows[1]))
  end)

  it('merges multiple segments onto the same visual row by column', function()
    local rows = image.build_image_text_rows({
      { text = 'lead', start_cell = 0, width_cells = 10 },
      { text = 'end', start_cell = 20, width_cells = 10 },
    }, 1, {})
    assert.equals('lead' .. string.rep(' ', 16) .. 'end', row_text(rows[0]))
  end)

  it('returns no rows for an empty segment list', function()
    assert.same({}, image.build_image_text_rows({}, 3, {}))
  end)
end)

describe('layout_image_line fit', function()
  local cell_w, cell_h = 10, 18
  local function layout(images, opts)
    opts = opts or {}
    opts.cell_w = cell_w; opts.cell_h = cell_h; opts.gap_px = cell_w
    opts.max_ratio = 1.0; opts.max_rows = 30
    opts.clip_x_px = 0; opts.clip_y_px = 0
    opts.clip_width_px = opts.text_right_px; opts.clip_height_px = 1000
    return image.layout_image_line(images, opts)
  end
  local function right_edge(layouts)
    local last = layouts[#layouts]
    return last.dest_x_px + last.display_width_px
  end
  local two = {
    { source_width = 600, source_height = 400, byte_col = 0,  byte_end_col = 10, col = 0,  anchor_x_px = 0 },
    { source_width = 600, source_height = 400, byte_col = 40, byte_end_col = 50, col = 40, anchor_x_px = 400 },
  }

  it('keeps the band within text_right_px when wide gaps are reserved', function()
    -- Pre-fix this overflowed to 1150 against a 1000px (100-col) window because the
    -- scale-down divided by images+gaps but only shrank the images.
    local layouts = layout(two, { text_left_px = 0, text_right_px = 1000,
      row_start_x_override = 300, gaps_px = { 310 } })
    assert.is_true(right_edge(layouts) <= 1000)
  end)

  it('shrinks gaps too when images alone cannot fit a narrow window', function()
    local layouts = layout(two, { text_left_px = 0, text_right_px = 400,
      row_start_x_override = 300, gaps_px = { 310 } })
    assert.is_true(right_edge(layouts) <= 400)
  end)

  it('does not alter a single image with no reserved gaps', function()
    local layouts = layout({ two[1] }, { text_left_px = 0, text_right_px = 1000 })
    assert.is_true(right_edge(layouts) <= 1000)
    assert.equals(600, layouts[1].display_width_px)  -- source width, unshrunk
  end)

  it('fits two images packed with the default gap (no text layout)', function()
    local layouts = layout(two, { text_left_px = 0, text_right_px = 1000 })
    assert.is_true(right_edge(layouts) <= 1000)
  end)

  it('reserves a trailing slot so prose after the last image keeps room', function()
    -- Without trailing_px the images packed to the right edge and the trailing
    -- text slot collapsed to < 1 cell (the line-18 bug).
    local layouts = layout(two, { text_left_px = 0, text_right_px = 1000,
      row_start_x_override = 0, gaps_px = { 260 }, trailing_px = 70 })
    local last = layouts[#layouts]
    local last_right_cell = last.grid_col + math.ceil(last.display_width_px / cell_w)
    local text_right_cell = math.floor(1000 / cell_w)
    assert.is_true(text_right_cell - last_right_cell >= 6)  -- room for ~6-cell trailing
  end)
end)

describe('compute_preview_placement', function()
  it('places a PlantUML preview when the fence start is scrolled above the viewport', function()
    local img = fresh_image()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      'intro',
      'more intro',
      'still intro',
      '```plantuml',
      '@startuml',
      'class Test1',
      'class Base',
      'class Test2',
      'Base <-- Test1',
      '@enduml',
      '```',
    })

    local old_block_height = img.markdown_plantuml_block_height
    local old_screenpos = img.safe_screenpos
    local old_columns = vim.o.columns
    local old_lines = vim.o.lines
    local old_cmdheight = vim.o.cmdheight

    img.markdown_plantuml_block_height = function() return 8 end
    img.safe_screenpos = function(_, lnum, col)
      if lnum < 7 then
        return { row = 0, col = 0, curscol = 0, endcol = 0 }
      end
      return { row = lnum - 5, col = 7 + col - 1, curscol = 7 + col - 1, endcol = 7 + col - 1 }
    end
    vim.o.columns = 81
    vim.o.lines = 40
    vim.o.cmdheight = 1

    local place = img.compute_preview_placement({
      buf = buf,
      win = 1007,
      w = { wincol = 1, textoff = 6 },
      start_row = 3,
    }, {
      source_width = 181,
      source_height = 169,
    }, 10, 18)

    img.markdown_plantuml_block_height = old_block_height
    img.safe_screenpos = old_screenpos
    vim.o.columns = old_columns
    vim.o.lines = old_lines
    vim.o.cmdheight = old_cmdheight
    pcall(vim.api.nvim_buf_delete, buf, { force = true })

    assert.is_truthy(place)
    assert.equals(19, place.width)
    assert.equals(10, place.height)
    assert.equals(6, place.row)
    assert.equals(6, place.col)
    local visible_block_top = 1
    local visible_block_bottom = 5
    assert.is_false(place.row <= visible_block_bottom and visible_block_top < place.row + place.height)
  end)

  it('does not place a PlantUML preview over another visible PlantUML block', function()
    local img = fresh_image()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      '# test',
      '',
      '## plantuml',
      '```plantuml',
      '@startuml',
      'class Test1',
      'class Base',
      'class Test2',
      'Base <-- Test1',
      '@enduml',
      '```',
      '',
      '```plantuml',
      '@startuml',
      'class What',
      '@enduml',
      '```',
    })

    local old_block_height = img.markdown_plantuml_block_height
    local old_screenpos = img.safe_screenpos
    local old_columns = vim.o.columns
    local old_lines = vim.o.lines
    local old_cmdheight = vim.o.cmdheight

    img.markdown_plantuml_block_height = function(_, start_row)
      return start_row == 12 and 5 or 8
    end
    img.safe_screenpos = function(_, lnum, col)
      local rows = {
        [5] = 2, [6] = 3, [7] = 4, [8] = 5, [9] = 6, [10] = 7, [11] = 8,
        [13] = 10, [14] = 11, [15] = 12, [16] = 13, [17] = 14,
      }
      local row = rows[lnum]
      if not row then
        return { row = 0, col = 0, curscol = 0, endcol = 0 }
      end
      return { row = row, col = 7 + col - 1, curscol = 7 + col - 1, endcol = 7 + col - 1 }
    end
    vim.o.columns = 80
    vim.o.lines = 24
    vim.o.cmdheight = 1

    local place = img.compute_preview_placement({
      buf = buf,
      win = 1000,
      w = { wincol = 1, textoff = 6 },
      start_row = 12,
    }, {
      source_width = 86,
      source_height = 68,
    }, 10, 18)

    img.markdown_plantuml_block_height = old_block_height
    img.safe_screenpos = old_screenpos
    vim.o.columns = old_columns
    vim.o.lines = old_lines
    vim.o.cmdheight = old_cmdheight
    pcall(vim.api.nvim_buf_delete, buf, { force = true })

    assert.is_truthy(place)
    assert.equals(9, place.width)
    assert.equals(4, place.height)
    assert.equals(14, place.row)
    assert.equals(6, place.col)
  end)
end)

describe('image backend', function()
  it('uses the source block, not the carrier buffer or temp path, for preview ids', function()
    local img = fresh_image()
    local id1 = img.preview_image_id({ buf = 6, start_row = 12 }, { disp_w = 86, disp_h = 68 })
    local id2 = img.preview_image_id({ buf = 6, start_row = 12 }, { disp_w = 86, disp_h = 68 })
    local id3 = img.preview_image_id({ buf = 6, start_row = 3 }, { disp_w = 86, disp_h = 68 })

    assert.equals(id1, id2)
    assert.equals('preview:6:12:86x68', id1)
    assert.are_not.equals(id1, id3)
  end)

  it('keeps live ids across backend instances so reloads can delete stale images', function()
    local old_ui = vim.ui
    local old_store = rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)

    local calls = {}
    vim.ui = {
      img = {
        set = function(id) calls[#calls + 1] = 'set:' .. id end,
        del = function(id) calls[#calls + 1] = 'del:' .. id end,
      },
    }

    local first = image_backend.new({})
    first.apply_payload({ { id = 'old', path = '/tmp/old.png' } })
    local second = image_backend.new({})
    second.apply_payload({})

    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_store)

    assert.same({ 'set:old', 'del:old' }, calls)
  end)
end)

describe('util.debounce', function()
  it('coalesces rapid calls into a single trailing invocation', function()
    local count = 0
    local d = util.debounce(function() count = count + 1 end, 20)
    d(); d(); d()
    assert.equals(0, count)  -- nothing has fired synchronously
    vim.wait(200, function() return count > 0 end)
    assert.equals(1, count)
  end)

  it('fires again for a call made after the interval elapses', function()
    local count = 0
    local d = util.debounce(function() count = count + 1 end, 20)
    d()
    vim.wait(200, function() return count >= 1 end)
    assert.equals(1, count)
    d()
    vim.wait(200, function() return count >= 2 end)
    assert.equals(2, count)
  end)

  it('invokes with the most recent call arguments', function()
    local got
    local d = util.debounce(function(x) got = x end, 20)
    d('a'); d('b')
    vim.wait(200, function() return got ~= nil end)
    assert.equals('b', got)
  end)
end)

describe('resolve_image_path', function()
  local buf

  before_each(function() buf = vim.api.nvim_create_buf(false, true) end)
  after_each(function() pcall(vim.api.nvim_buf_delete, buf, { force = true }) end)

  it('returns nil for protocol URLs and empty input', function()
    assert.is_nil(image.resolve_image_path(buf, 'http://example.com/y.png'))
    assert.is_nil(image.resolve_image_path(buf, 'https://example.com/y.png'))
    assert.is_nil(image.resolve_image_path(buf, ''))
  end)

  it('resolves a relative path to an absolute path', function()
    local p = image.resolve_image_path(buf, 'foo.png')
    assert.is_truthy(p)
    assert.equals('/', p:sub(1, 1))
    assert.is_truthy(p:find('foo.png', 1, true))
  end)
end)

describe('scan_markdown_image_text', function()
  it('extracts an image link with byte offsets', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local result = {}
    image.scan_markdown_image_text(buf, 0, 'see ![alt](missing.png) end', result, {})
    assert.equals(1, #result)
    assert.equals('missing.png', result[1].raw_path)
    assert.equals('not_found', result[1].error)  -- file does not exist
    assert.equals(4, result[1].byte_col)          -- '!' is the 5th byte -> s-1 = 4
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it('ignores a line with no image link', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local result = {}
    image.scan_markdown_image_text(buf, 0, 'just plain text', result, {})
    assert.equals(0, #result)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)
