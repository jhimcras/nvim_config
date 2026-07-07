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

  it('uses the right-side preview when top and bottom are blocked but the code rectangle is clear', function()
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
      return start_row == 3 and 8 or 5
    end
    img.safe_screenpos = function(_, lnum, col)
      local rows = {
        [4] = 2, [5] = 3, [6] = 4, [7] = 5, [8] = 6, [9] = 7, [10] = 8, [11] = 9,
        [13] = 9, [14] = 10, [15] = 11, [16] = 12, [17] = 13,
      }
      local row = rows[lnum]
      if not row then
        return { row = 0, col = 0, curscol = 0, endcol = 0 }
      end
      return { row = row, col = 7 + col - 1, curscol = 7 + col - 1, endcol = 7 + col - 1 }
    end
    vim.o.columns = 81
    vim.o.lines = 40
    vim.o.cmdheight = 1

    local place = img.compute_preview_placement({
      buf = buf,
      win = 1000,
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
    assert.equals(1, place.row)
    assert.equals(21, place.col)
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

  it('can still compute the old carrier-buffer preview id for cleanup', function()
    local img = fresh_image()
    local id = img.preview_legacy_image_id(14, '/tmp/source.png', { disp_w = 181, disp_h = 169 })

    assert.matches('^preview:14:%x%x%x%x%x%x%x%x:181x169$', id)
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

  it('delete_image removes an id from the live set immediately', function()
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

    local b = image_backend.new({})
    b.apply_payload({ { id = 'preview:old', path = '/tmp/old.png' } })
    b.delete_image('preview:old')
    b.apply_payload({})

    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_store)

    assert.same({ 'set:preview:old', 'del:preview:old' }, calls)
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

-- ---------------------------------------------------------------------------
-- PlantUML preview configuration (mode/auto/split) + pure geometry helpers.
-- ---------------------------------------------------------------------------

describe('preview_config (setup normalization)', function()
  local function cfg(opts)
    local img = fresh_image()
    img.setup({ plantuml = { preview = opts } })
    return img.preview_config()
  end

  it('defaults to float/auto with a right vertical cursor split', function()
    local c = cfg(nil)
    assert.equals('float', c.mode)
    assert.equals(true, c.auto)
    assert.equals('right', c.split.position)
    assert.equals('vertical', c.split.direction)
    assert.equals(0.5, c.split.size)
    assert.equals('cursor', c.split.lifecycle)
  end)

  it('falls back to float for an unknown mode', function()
    assert.equals('float', cfg({ mode = 'bogus' }).mode)
    assert.equals('split', cfg({ mode = 'split' }).mode)
  end)

  it("resolves size = 'half' to 0.5", function()
    assert.equals(0.5, cfg({ split = { size = 'half' } }).split.size)
  end)

  it('falls back to right for an invalid position', function()
    assert.equals('right', cfg({ split = { position = 'sideways' } }).split.position)
  end)

  it('infers direction from position', function()
    assert.equals('vertical', cfg({ split = { position = 'left' } }).split.direction)
    assert.equals('vertical', cfg({ split = { position = 'right' } }).split.direction)
    assert.equals('horizontal', cfg({ split = { position = 'top' } }).split.direction)
    assert.equals('horizontal', cfg({ split = { position = 'bottom' } }).split.direction)
  end)

  it('respects auto = false and an explicit persistent lifecycle', function()
    local c = cfg({ auto = false, split = { lifecycle = 'persistent' } })
    assert.equals(false, c.auto)
    assert.equals('persistent', c.split.lifecycle)
  end)

  it('falls back to cursor for an invalid lifecycle', function()
    assert.equals('cursor', cfg({ split = { lifecycle = 'wat' } }).split.lifecycle)
  end)
end)

describe('resolve_split_size', function()
  it('treats a fraction < 1 as a ratio of the host extent', function()
    assert.equals(60, image.resolve_split_size(0.5, 120))
    assert.equals(30, image.resolve_split_size(0.3, 100))
  end)

  it('treats a value >= 1 as an absolute cell count', function()
    assert.equals(80, image.resolve_split_size(80, 120))
  end)

  it('clamps to [1, total]', function()
    assert.equals(120, image.resolve_split_size(200, 120))
    assert.equals(1, image.resolve_split_size(0.001, 120))
  end)

  it('defaults to half on a non-positive / non-number size', function()
    assert.equals(60, image.resolve_split_size(0, 120))
    assert.equals(60, image.resolve_split_size(-1, 120))
    assert.equals(60, image.resolve_split_size('nope', 120))
  end)
end)

describe('smart_split_direction', function()
  it('opens a horizontal split (preview bottom) for a portrait window', function()
    -- 80x50 cells at 10x18px = 800x900px: taller than wide.
    assert.equals('horizontal', image.smart_split_direction(80, 50, 10, 18))
  end)

  it('opens a vertical split (preview right) for a landscape window', function()
    -- 120x20 cells at 10x18px = 1200x360px: wider than tall.
    assert.equals('vertical', image.smart_split_direction(120, 20, 10, 18))
  end)

  it('compares pixel extents, not raw cell counts', function()
    -- 50x40 cells: more columns than rows, but 500x720px in pixels -> portrait.
    assert.equals('horizontal', image.smart_split_direction(50, 40, 10, 18))
  end)

  it('falls back to default cell metrics when unset', function()
    -- nil cell sizes -> defaults 10x18; 50x40 -> 500x720 -> horizontal.
    assert.equals('horizontal', image.smart_split_direction(50, 40, nil, nil))
  end)
end)

describe('center_in_rect', function()
  it('centers an image that fits without scaling', function()
    -- 40x20 cells = 400x360px; 100x50 image fits at scale 1 -> 10x3 cells.
    local p = image.center_in_rect({ row = 0, col = 0, width = 40, height = 20 },
      { source_width = 100, source_height = 50 }, 10, 18)
    assert.equals(100, p.disp_w)
    assert.equals(50, p.disp_h)
    assert.equals(10, p.width)
    assert.equals(3, p.height)
    assert.equals(15, p.col)  -- (40-10)/2
    assert.equals(8, p.row)   -- (20-3)/2
  end)

  it('scales an oversized image to fit and still centers it', function()
    -- 1000x200 image into 40x20 cells (400x360px): scale 0.4 -> 400x80px -> 40x5.
    local p = image.center_in_rect({ row = 2, col = 4, width = 40, height = 20 },
      { source_width = 1000, source_height = 200 }, 10, 18)
    assert.equals(400, p.disp_w)
    assert.equals(40, p.width)
    assert.equals(5, p.height)
    assert.equals(4, p.col)   -- pad 0 + rect.col
    assert.equals(9, p.row)   -- (20-5)/2 + rect.row(2)
  end)

  it('never produces a sub-1-cell placement on a degenerate rect', function()
    local p = image.center_in_rect({ row = 0, col = 0, width = 1, height = 1 },
      { source_width = 100, source_height = 50 }, 10, 18)
    assert.equals(1, p.width)
    assert.equals(1, p.height)
  end)
end)

-- ---------------------------------------------------------------------------
-- Partially-visible PlantUML blocks (top fence scrolled above the window).
-- ---------------------------------------------------------------------------

describe('offscreen_anchor_grid_row', function()
  local function scratch_win(lines)
    vim.cmd('new')
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    local content = {}
    for i = 1, lines do content[i] = 'line ' .. i end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd('resize 6')
    return win, buf
  end

  local function teardown(win, buf)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  it('returns nil when the anchor is at or below topline', function()
    local win, buf = scratch_win(30)
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(win, { 12, 0 })
      vim.fn.winrestview({ topline = 11 })
    end)
    local w = vim.fn.getwininfo(win)[1]
    assert.is_nil(image.offscreen_anchor_grid_row(win, w, 10))  -- row 10 = line 11 = topline
    assert.is_nil(image.offscreen_anchor_grid_row(win, w, 15))  -- below topline
    teardown(win, buf)
  end)

  it('counts plain hidden lines above topline', function()
    local win, buf = scratch_win(30)
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(win, { 12, 0 })
      vim.fn.winrestview({ topline = 11 })
    end)
    local w = vim.fn.getwininfo(win)[1]
    -- anchor row 4 (line 5): hidden lines 5..10 = 6 rows above the window top.
    assert.equals((w.winrow - 1) - 6, image.offscreen_anchor_grid_row(win, w, 4))
    teardown(win, buf)
  end)

  it('includes virt_lines below the anchor minus the visible topfill', function()
    local win, buf = scratch_win(30)
    local ns = vim.api.nvim_create_namespace('rendermark_offscreen_test')
    -- 5 virt_lines below row 9 (line 10).
    vim.api.nvim_buf_set_extmark(buf, ns, 9, 0, {
      virt_lines = {
        { { 'v1', '' } }, { { 'v2', '' } }, { { 'v3', '' } }, { { 'v4', '' } }, { { 'v5', '' } },
      },
    })
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(win, { 11, 0 })
      vim.fn.winrestview({ topline = 11, topfill = 2 })
    end)
    local w = vim.fn.getwininfo(win)[1]
    -- hidden = line 10 (1) + virt_lines (5) - visible topfill (2) = 4.
    assert.equals((w.winrow - 1) - 4, image.offscreen_anchor_grid_row(win, w, 9))
    teardown(win, buf)
  end)

  it('returns nil for an invalid window', function()
    assert.is_nil(image.offscreen_anchor_grid_row(99999, { topline = 11, winrow = 1 }, 4))
  end)
end)

describe('partially visible plantuml block rendering', function()
  local FENCE = 10       -- 0-based row of '```plantuml'
  local FENCE_END = 16   -- 0-based row of closing '```'
  local CELL_W, CELL_H = 10, 18

  -- 100x600 PNG header: taller than the source block, like a real diagram, so
  -- the reservation emits actual virt_lines (reserve_h = virt_h - span + 1 > 1)
  -- and topfill scrolling through them is possible.
  local TALL_PNG = bytes({
    137, 80, 78, 71, 13, 10, 26, 10,  -- signature
    0, 0, 0, 13,                      -- IHDR length
    73, 72, 68, 82,                   -- "IHDR"
    0, 0, 0, 100,                     -- width  = 100
    0, 0, 2, 88,                      -- height = 600
  })

  -- Build a markdown-ish buffer: 10 intro lines, a 7-line plantuml block at
  -- rows FENCE..FENCE_END, then `outro` trailing lines.
  local function make_buf(outro)
    local lines = {}
    for i = 1, FENCE do lines[#lines + 1] = 'intro ' .. i end
    lines[#lines + 1] = '```plantuml'
    lines[#lines + 1] = '@startuml'
    lines[#lines + 1] = 'a -> b'
    lines[#lines + 1] = 'b -> c'
    lines[#lines + 1] = 'c -> d'
    lines[#lines + 1] = '@enduml'
    lines[#lines + 1] = '```'
    for i = 1, outro do lines[#lines + 1] = 'outro ' .. i end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    return buf
  end

  -- Fresh module + backend store + fake vim.ui.img capturing set/del calls.
  -- Stubs collect_plantuml_images with a ready 100x600 PNG record for `buf`.
  local function setup_e2e(outro, height)
    local old_ui = vim.ui
    local old_store = rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)
    local img = fresh_image()
    local store = {}
    vim.ui = {
      img = {
        set = function(id, path, opts) store[id] = { path = path, opts = opts } end,
        del = function(id) store[id] = nil end,
        get = function(id) return store[id] end,
      },
    }
    local buf = make_buf(outro)
    local png = tmpfile(TALL_PNG)
    img.collect_plantuml_images = function(target, result)
      if target ~= buf then return end
      result[#result + 1] = {
        row = FENCE, col = 0, end_col = 12, path = png, raw_path = png,
        source_width = 100, source_height = 600,
        source_span_height = FENCE_END - FENCE + 1, plantuml = true,
        plantuml_end_row = FENCE_END, virtual = false,
      }
    end
    vim.cmd('new')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd('resize ' .. height)
    local function teardown()
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      vim.ui = old_ui
      rawset(_G, '__rendermark_image_backend', old_store)
    end
    return img, buf, win, store, teardown
  end

  local function scroll(win, topline, topfill)
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(win, { topline + 1, 0 })
      vim.fn.winrestview({ topline = topline, topfill = topfill or 0 })
    end)
  end

  local function buf_image(store)
    for id, entry in pairs(store) do
      if id:sub(1, 4) == 'buf:' then return entry end
    end
    return nil
  end

  local function conceal_rows(img, buf)
    local ns = img.ensure_image_namespace()
    local rows = {}
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    for _, m in ipairs(marks) do
      if m[4] and m[4].conceal ~= nil then rows[m[2]] = true end
    end
    return rows
  end

  it('keeps rendering (clipped) when the top fence scrolls above the window', function()
    local img, buf, win, store, teardown = setup_e2e(30, 6)
    scroll(win, FENCE + 3)  -- topline 13: block rows 12..16 visible, fence hidden
    img.send_images()       -- first send reserves virt_lines, skips apply
    img.send_images()       -- second send applies the payload
    local w = vim.fn.getwininfo(win)[1]
    local expected_row = img.offscreen_anchor_grid_row(win, w, FENCE)

    local entry = buf_image(store)
    assert.is_truthy(entry)
    assert.is_truthy(expected_row)
    assert.is_true(expected_row < w.winrow - 1)  -- anchored above the window top
    assert.equals(expected_row, entry.opts.grid_row)
    assert.equals(expected_row * CELL_H, entry.opts.dest_y_px)
    assert.equals((w.winrow - 1) * CELL_H, entry.opts.clip_y_px)
    assert.equals(w.height * CELL_H, entry.opts.clip_height_px)
    -- The owning window's band travels with the payload so the GUI can crop
    -- at the window top instead of guessing the owner from the (offscreen) row.
    assert.equals(w.winrow - 1, entry.opts.win_top)
    assert.equals(w.height, entry.opts.win_height)

    -- Every source row of the block stays concealed.
    local rows = conceal_rows(img, buf)
    for r = FENCE, FENCE_END do assert.is_truthy(rows[r], 'row ' .. r .. ' concealed') end

    -- The virt_lines reservation on the fence row survives.
    local ns = img.ensure_image_namespace()
    local reserved = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[2] == FENCE and m[4] and m[4].virt_lines then reserved = true end
    end
    assert.is_true(reserved)
    teardown()
  end)

  it('shifts the anchor one grid row per topfill step through the virt_lines', function()
    local img, _, win, store, teardown = setup_e2e(30, 6)
    scroll(win, FENCE + 2)  -- topline right below the fence's virt_lines
    img.send_images(); img.send_images()
    local a = buf_image(store)
    assert.is_truthy(a)
    local row_a = a.opts.grid_row

    scroll(win, FENCE + 2, 1)
    local applied_fill = vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview().topfill
    end)
    assert.equals(1, applied_fill)
    img.send_images()
    local b = buf_image(store)
    assert.is_truthy(b)
    assert.equals(row_a + 1, b.opts.grid_row)
    teardown()
  end)

  it('still renders clipped to the window when the block is cut at the bottom', function()
    local img, _, win, store, teardown = setup_e2e(30, 4)
    scroll(win, FENCE - 1)  -- fence visible near the bottom of a 4-row window
    img.send_images(); img.send_images()
    local w = vim.fn.getwininfo(win)[1]
    local entry = buf_image(store)
    assert.is_truthy(entry)
    assert.is_true(entry.opts.grid_row >= w.winrow - 1)  -- on-screen anchor
    assert.equals(w.height * CELL_H, entry.opts.clip_height_px)
    -- Window band is sent for on-screen anchors too, not only offscreen ones.
    assert.equals(w.winrow - 1, entry.opts.win_top)
    assert.equals(w.height, entry.opts.win_height)
    teardown()
  end)

  it('emits nothing once the block is fully scrolled past the margin', function()
    local img, buf, win, store, teardown = setup_e2e(60, 6)
    scroll(win, FENCE_END + 1 + 30 + 5)  -- beyond span and max_rows margins
    img.send_images(); img.send_images()
    assert.is_nil(buf_image(store))
    local rows = conceal_rows(img, buf)
    for r = FENCE, FENCE_END do assert.is_nil(rows[r]) end
    teardown()
  end)

  it('emits nothing for an image link fully scrolled past the margin', function()
    local old_ui = vim.ui
    local old_store = rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)
    local img = fresh_image()
    local store = {}
    vim.ui = {
      img = {
        set = function(id, path, opts) store[id] = { path = path, opts = opts } end,
        del = function(id) store[id] = nil end,
      },
    }
    local png = tmpfile(PNG)
    local lines = { 'intro', '![alt](' .. png .. ')' }
    for i = 1, 70 do lines[#lines + 1] = 'outro ' .. i end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    vim.cmd('new')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd('resize 6')
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(win, { 51, 0 })
      vim.fn.winrestview({ topline = 50 })
    end)
    img.send_images(); img.send_images()
    local found = false
    for id in pairs(store) do
      if id:sub(1, 4) == 'buf:' then found = true end
    end
    assert.is_false(found)
    local ns = img.ensure_image_namespace()
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      assert.is_nil(m[4].virt_lines, 'no reservation should remain past the margin')
    end
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_store)
  end)
end)

describe('partially visible inline image link rendering', function()
  local IMG = 5          -- 0-based row of the image link line
  local CELL_H = 18

  -- 100x600 PNG header: taller than one text row so the reservation emits
  -- virt_lines (virt_h = max_rows = 30 -> 29 reserved virt_lines) and topfill
  -- scrolling through them is possible.
  local TALL_PNG = bytes({
    137, 80, 78, 71, 13, 10, 26, 10,  -- signature
    0, 0, 0, 13,                      -- IHDR length
    73, 72, 68, 82,                   -- "IHDR"
    0, 0, 0, 100,                     -- width  = 100
    0, 0, 2, 88,                      -- height = 600
  })

  -- Fresh module + backend store + fake vim.ui.img. Buffer: IMG intro lines,
  -- one image link, `outro` trailing lines; shown in a `height`-row split.
  local function setup_e2e(outro, height)
    local old_ui = vim.ui
    local old_store = rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)
    local img = fresh_image()
    local store = {}
    vim.ui = {
      img = {
        set = function(id, path, opts) store[id] = { path = path, opts = opts } end,
        del = function(id) store[id] = nil end,
        get = function(id) return store[id] end,
      },
    }
    local png = tmpfile(TALL_PNG)
    local lines = {}
    for i = 1, IMG do lines[#lines + 1] = 'intro ' .. i end
    lines[#lines + 1] = '![alt](' .. png .. ')'
    for i = 1, outro do lines[#lines + 1] = 'outro ' .. i end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    vim.cmd('new')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd('resize ' .. height)
    local function teardown()
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      vim.ui = old_ui
      rawset(_G, '__rendermark_image_backend', old_store)
    end
    return img, buf, win, store, teardown
  end

  local function scroll(win, topline, topfill)
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(win, { topline + 1, 0 })
      vim.fn.winrestview({ topline = topline, topfill = topfill or 0 })
    end)
  end

  local function buf_image(store)
    for id, entry in pairs(store) do
      if id:sub(1, 4) == 'buf:' then return entry end
    end
    return nil
  end

  local function reservation_mark(img, buf)
    local ns = img.ensure_image_namespace()
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if m[2] == IMG and m[4].virt_lines then return m end
    end
    return nil
  end

  it('keeps the reservation and emits (clipped) when the link scrolls above the window', function()
    local img, buf, win, store, teardown = setup_e2e(40, 6)
    scroll(win, IMG + 2)    -- topline right below the link line
    img.send_images()       -- first send reserves virt_lines, skips apply
    img.send_images()       -- second send applies the payload
    local w = vim.fn.getwininfo(win)[1]

    local entry = buf_image(store)
    assert.is_truthy(entry)
    assert.is_true(entry.opts.grid_row < w.winrow - 1)  -- anchored above the window top
    assert.equals((w.winrow - 1) * CELL_H, entry.opts.clip_y_px)
    assert.equals(w.height * CELL_H, entry.opts.clip_height_px)

    -- The virt_lines reservation on the link row survives: this is what keeps
    -- the window's topfill valid so C-e/C-y scroll row-by-row through the image
    -- instead of snapping back when the anchor leaves the viewport.
    assert.is_truthy(reservation_mark(img, buf))
    teardown()
  end)

  it('shifts the anchor one grid row per topfill step through the virt_lines', function()
    local img, _, win, store, teardown = setup_e2e(40, 6)
    scroll(win, IMG + 2)
    img.send_images(); img.send_images()
    local a = buf_image(store)
    assert.is_truthy(a)
    local row_a = a.opts.grid_row

    scroll(win, IMG + 2, 1)
    local applied_fill = vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview().topfill
    end)
    assert.equals(1, applied_fill)
    img.send_images()
    local b = buf_image(store)
    assert.is_truthy(b)
    assert.equals(row_a + 1, b.opts.grid_row)
    teardown()
  end)
end)

describe('get_layout_sig topfill', function()
  it('changes when only topfill differs', function()
    local img = fresh_image()
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 30 do lines[i] = 'line ' .. i end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ns = vim.api.nvim_create_namespace('rendermark_sig_test')
    vim.api.nvim_buf_set_extmark(buf, ns, 9, 0, {
      virt_lines = { { { 'v1', '' } }, { { 'v2', '' } }, { { 'v3', '' } } },
    })
    vim.cmd('new')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd('resize 6')
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(win, { 11, 0 })
      vim.fn.winrestview({ topline = 11, topfill = 0 })
    end)
    local sig_a = img.get_layout_sig()
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ topline = 11, topfill = 2 })
    end)
    local sig_b = img.get_layout_sig()
    assert.are_not.equals(sig_a, sig_b)
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

describe('preview_active (show/hide state machine)', function()
  it('follows the configured auto flag when no override is set', function()
    local img = fresh_image()
    img.setup({ plantuml = { preview = { auto = true } } })
    assert.is_true(img.preview_active())

    img = fresh_image()
    img.setup({ plantuml = { preview = { auto = false } } })
    assert.is_false(img.preview_active())
  end)

  it('lets an explicit Show/Hide override win over auto', function()
    local img = fresh_image()
    img.setup({ plantuml = { preview = { auto = false } } })
    img._preview_user = true   -- :RendermarkPreviewShow
    assert.is_true(img.preview_active())
    img._preview_user = false  -- :RendermarkPreviewHide
    assert.is_false(img.preview_active())
    img._preview_user = nil    -- back to following config
    assert.is_false(img.preview_active())
  end)
end)
