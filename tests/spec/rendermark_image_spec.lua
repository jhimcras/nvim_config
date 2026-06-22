-- Tests for the rendermark.image performance optimizations:
--   * parse_image_size (pure header decode) + read_image_size stat-gated cache
--   * cursor-move render gate (cursor_block_id / cursor_active_block_sig /
--     handle_cursor_moved)
--   * util.debounce (used to coalesce TextChanged renders)
-- plus regression coverage for adjacent pure helpers reachable from these paths.

local image = require('rendermark.image')
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
