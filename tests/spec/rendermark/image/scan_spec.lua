-- rendermark.image scan: link grammar, path resolution, fenced code, reference
-- images, GIF sizes and a failing image provider.

local scan = require('nvim_config.rendermark.image.scan')
local size = require('nvim_config.rendermark.image.size')
local docindex = require('nvim_config.rendermark.image.docindex')

local function bytes(arr) return string.char(unpack(arr)) end

-- 200x120 PNG header (enough for the size reader).
local PNG = bytes({ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
  0, 0, 0, 200, 0, 0, 0, 120 })

local function write(path, data)
  local f = assert(io.open(path, 'wb'))
  f:write(data)
  f:close()
  return path
end

local function raws(links)
  local out = {}
  for _, l in ipairs(links) do out[#out + 1] = l[3] end
  return out
end

describe('GIF image size', function()
  it('reads GIF87a and GIF89a logical screen sizes', function()
    assert.same({ width = 200, height = 120, format = 'gif' }, size.parse_image_size('GIF89a\200\0\120\0'))
    assert.same({ width = 200, height = 120, format = 'gif' }, size.parse_image_size('GIF87a\200\0\120\0\0\0'))
  end)

  it('ignores truncated GIF headers and SVG', function()
    assert.is_nil(size.parse_image_size('GIF89a\200\0\120'))
    assert.is_nil(size.parse_image_size('GIF89'))
    assert.is_nil(size.parse_image_size('<svg xmlns="http://www.w3.org/2000/svg"/>'))
  end)
end)

describe('find_image_links grammar', function()
  it('accepts a title in double, single or parenthesised form', function()
    local links = scan.find_image_links([[![a](x.png "t") ![b](y.png 't') ![c](z.png (t))]])
    assert.same({ 'x.png', 'y.png', 'z.png' }, raws(links))
    assert.equals(1, links[1][1])
    assert.equals(#'![a](x.png "t")', links[1][2])
  end)

  it('accepts <path with spaces> and balanced parentheses', function()
    assert.same({ 'a b.png', 'c d.png', 'img(1).png' },
      raws(scan.find_image_links('![a](<a b.png>) ![b](<c d.png> "t") ![c](img(1).png)')))
  end)

  it('rejects empty, unterminated and spaced bare destinations', function()
    assert.same({}, scan.find_image_links('![a]() ![b](<x.png) ![c](a b) ![d](x.png "unclosed)'))
  end)

  it('ignores reference forms unless the label is defined', function()
    local text = '![a][r] ![r][] ![r] ![z][] ![q]'
    assert.same({}, scan.find_image_links(text))
    assert.same({}, scan.find_image_links(text, {}))
    local links = scan.find_image_links(text, { r = 'r.png' })
    assert.same({ 'r.png', 'r.png', 'r.png' }, raws(links))
    assert.same({ 'r', 'r', 'r' }, { links[1][4], links[2][4], links[3][4] })
    assert.same({ 1, 7 }, { links[1][1], links[1][2] })
  end)

  it('does not read a plain link as an image and skips code spans', function()
    local defs = { r = 'r.png' }
    assert.same({}, scan.find_image_links('[text][r] [r]', defs))
    assert.same({ 'd.png' }, raws(scan.find_image_links('`![a](b.png)` ![c](d.png) `![r]`', defs)))
  end)
end)

describe('resolve_image_path', function()
  local dir, buf

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. '/doc.md')
  end)
  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.fn.delete(dir, 'rf')
  end)

  it('drops ?query and #anchor and unwraps <…>', function()
    assert.equals(dir .. '/a.png', scan.resolve_image_path(buf, 'a.png?raw=1'))
    assert.equals(dir .. '/a.png', scan.resolve_image_path(buf, 'a.png#top'))
    assert.equals(dir .. '/a.png', scan.resolve_image_path(buf, '<a.png>'))
    assert.equals(dir .. '/a b.png', scan.resolve_image_path(buf, '<a b.png>'))
  end)

  it('decodes %20 and other %xx escapes', function()
    assert.equals(dir .. '/a b.png', scan.resolve_image_path(buf, 'a%20b.png'))
    assert.equals(dir .. '/한.png', scan.resolve_image_path(buf, '%ED%95%9C.png'))
  end)

  it('prefers a file that really has #, ? or % in its name', function()
    write(dir .. '/C#.png', PNG)
    write(dir .. '/100%25.png', PNG)
    assert.equals(dir .. '/C#.png', scan.resolve_image_path(buf, 'C#.png'))
    assert.equals(dir .. '/100%25.png', scan.resolve_image_path(buf, '100%25.png'))
  end)

  it('expands ~ to the home directory', function()
    assert.equals(vim.uv.os_homedir() .. '/img.png', scan.resolve_image_path(buf, '~/img.png'))
  end)

  it('keeps a Windows drive letter intact', function()
    local has = vim.fn.has
    vim.fn.has = function(feature) return feature == 'win32' and 1 or has(feature) end
    local ok, path = pcall(scan.resolve_image_path, buf, 'C:/pics/a.png?x=1')
    vim.fn.has = has
    assert.is_true(ok)
    -- Only a Windows host can make it absolute; the colon must survive stripping.
    assert.is_truthy(path:find('C:/pics/a%.png$'))
  end)

  it('still ignores remote destinations', function()
    assert.is_nil(scan.resolve_image_path(buf, 'https://example.com/a.png?x'))
    assert.is_nil(scan.resolve_image_path(buf, '<https://example.com/a.png>'))
    assert.is_nil(scan.resolve_image_path(buf, '<>'))
  end)
end)

describe('document index', function()
  local buf
  local function set(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return docindex.get(buf)
  end
  after_each(function() pcall(vim.api.nvim_buf_delete, buf, { force = true }) end)

  it('finds backtick and tilde fences, honouring length and info strings', function()
    local idx = set({
      'a', '```lua', 'x', '```', 'b', '~~~~', '~~~', '~~~~', '````', '```', '````', 'c', '``` not fence```', 'd',
    })
    assert.same({ { 1, 3 }, { 5, 7 }, { 8, 10 } }, idx.fences)
    assert.is_true(docindex.in_fence(idx, 2))
    assert.is_false(docindex.in_fence(idx, 4))
    assert.is_true(docindex.in_fence(idx, 9))
    assert.is_false(docindex.in_fence(idx, 11))
    assert.is_false(docindex.in_fence(idx, 12))
  end)

  it('lets an unclosed fence run to the end and sees indented and quoted fences', function()
    local idx = set({ 'a', '  ```', 'b', 'c' })
    assert.same({ { 1, 3 } }, idx.fences)
    idx = set({ '> ```', '> x', '> ```', 'y' })
    assert.same({ { 0, 2 } }, idx.fences)
  end)

  it('collects definitions: case/space-insensitive, first wins, no footnotes or fenced ones', function()
    local idx = set({
      '[Foo  Bar]: a.png "T"', '[foo bar]: b.png', '  [x]: <c d.png>', "[y]: e.png 'T'", '[z]: f.png (T)',
      '[^1]: note', '[bad]: g.png trailing junk', '    [indented]: h.png', '```', '[fenced]: i.png', '```',
    })
    assert.same({ ['foo bar'] = 'a.png', x = 'c d.png', y = 'e.png', z = 'f.png' }, idx.defs)
  end)

  it('is rebuilt after an edit and reused otherwise', function()
    local idx = set({ '[r]: a.png' })
    assert.equals(idx, docindex.get(buf))
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { '[r]: b.png' })
    assert.equals('b.png', docindex.get(buf).defs.r)
  end)
end)

describe('collecting markdown images', function()
  local dir, buf, png
  local image = require('nvim_config.rendermark.image')

  local function open(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. '/doc.md')
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end
  local function rows(images)
    local out = {}
    for _, im in ipairs(images) do out[#out + 1] = im.row end
    return out
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    png = write(dir .. '/pic.png', PNG)
  end)
  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.fn.delete(dir, 'rf')
  end)

  it('shows an image with a title and a <path with spaces>', function()
    write(dir .. '/my pic.png', PNG)
    open({ '![a](pic.png "title")', '![b](<my pic.png> \'t\')' })
    local found = image.collect_markdown_images(buf, 0, 2)
    assert.equals(2, #found)
    assert.is_nil(found[1].error)
    assert.is_nil(found[2].error)
    assert.equals(dir .. '/my pic.png', found[2].path)
    assert.equals(200, found[2].source_width)
  end)

  it('shows a GIF (header size) and keeps an SVG as an unsupported box', function()
    write(dir .. '/anim.gif', 'GIF89a\200\0\120\0')
    write(dir .. '/draw.svg', '<svg/>')
    open({ '![a](anim.gif)', '![b](draw.svg)' })
    local found = image.collect_markdown_images(buf, 0, 2)
    assert.equals(200, found[1].source_width)
    assert.is_nil(found[1].error)
    assert.equals('unsupported', found[2].error)
  end)

  it('ignores image syntax inside fenced code blocks', function()
    open({ '![a](pic.png)', '```md', '![b](pic.png)', '```', '![c](pic.png)', '~~~', '![d](pic.png)', '~~~', '![e](pic.png)' })
    assert.same({ 0, 4, 8 }, rows(image.collect_markdown_images(buf, 0, 9)))
  end)

  it('treats an unclosed fence as code to the end', function()
    open({ '![a](pic.png)', '```', '![b](pic.png)' })
    assert.same({ 0 }, rows(image.collect_markdown_images(buf, 0, 3)))
  end)

  it('knows a fence opened above the scanned range', function()
    open({ '```', 'x', '![b](pic.png)', '```', '![c](pic.png)' })
    assert.same({ 4 }, rows(image.collect_markdown_images(buf, 2, 5)))
  end)

  it('follows an edit that closes or opens a fence', function()
    open({ '![a](pic.png)', '![b](pic.png)' })
    assert.same({ 0, 1 }, rows(image.collect_markdown_images(buf, 0, 2)))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '```' })
    assert.same({}, rows(image.collect_markdown_images(buf, 0, 3)))
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
    assert.same({ 0, 1 }, rows(image.collect_markdown_images(buf, 0, 2)))
  end)

  describe('reference images', function()
    it('shows ![alt][ref], ![ref][] and ![ref] at their use, not at the definition', function()
      open({ '[download](pic.png)', '![a][pic]', 'text ![Pic][] and ![PIC]', '', '[pic]: pic.png "Title"' })
      local found = image.collect_markdown_images(buf, 0, 5)
      assert.same({ 1, 2, 2 }, rows(found))
      for _, im in ipairs(found) do
        assert.equals(png, im.path)
        assert.equals('pic.png', im.raw_path)
        assert.is_nil(im.error)
      end
      assert.equals(0, found[1].byte_col)
      assert.equals(#'![a][pic]', found[1].byte_end_col)
      assert.equals(5, found[2].byte_col)
      assert.equals('pic', found[1].ref_label)
    end)

    it('shows nothing when the label is not defined', function()
      open({ '![a][nope]', '![nope][]', '![nope]', '[other]: pic.png' })
      assert.same({}, rows(image.collect_markdown_images(buf, 0, 4)))
    end)

    it('does not take a plain link [text][ref] or a fenced definition', function()
      open({ '[text][pic]', '[pic]', '', '```', '[pic]: pic.png', '```', '![x][pic]' })
      assert.same({}, rows(image.collect_markdown_images(buf, 0, 7)))
    end)

    it('uses the first definition and decides not_found at the use', function()
      open({ '![a][r]', '[r]: gone.png', '[r]: pic.png' })
      local found = image.collect_markdown_images(buf, 0, 1)
      assert.equals('not_found', found[1].error)
      assert.equals('gone.png', found[1].raw_path)
    end)

    it('follows edits of the definition', function()
      open({ '![a][r]', '[r]: pic.png' })
      assert.equals(1, #image.collect_markdown_images(buf, 0, 1))
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '[q]: pic.png' })
      assert.equals(0, #image.collect_markdown_images(buf, 0, 1))
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '[R]: pic.png' })
      assert.equals(1, #image.collect_markdown_images(buf, 0, 1))
    end)

    it('is recognised by line_has_image_link only with the buffer', function()
      open({ '![a][r]', '[r]: pic.png' })
      assert.is_true(image.line_has_image_link('![a][r]', buf))
      assert.is_false(image.line_has_image_link('![a][r]'))
      assert.is_false(image.line_has_image_link('![a][zz]', buf))
    end)

    it('counts as an exported image next to a diagram block', function()
      local H = require('tests.spec.rendermark.image.helpers')
      open({ '```plantuml', 'a -> b', '```', '', '![x][r]', '', '[r]: pic.png' })
      image.set_diagram_source(H.fence_source({ status = 'ready', path = png }))
      local item = image.diagram_items(buf)[1]
      local hide = image.diagram_exported_below(buf, item)
      image.clear_diagram_source()
      assert.is_true(hide)
    end)
  end)
end)

describe('rendering reference images', function()
  local old_ui, old_store, old_screenpos, img, store, buf, win, dir

  before_each(function()
    old_ui = vim.ui
    old_store = rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)
    package.loaded['nvim_config.rendermark.image'] = nil
    img = require('nvim_config.rendermark.image')
    store = {}
    vim.ui = { img = {
      set = function(id, path, opts) store[id] = { path = path, opts = opts } end,
      del = function(id) store[id] = nil end,
    } }
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    write(dir .. '/pic.png', PNG)
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = 10, 20
  end)
  after_each(function()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_store)
    package.loaded['nvim_config.rendermark.image'] = nil
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = nil, nil
    vim.fn.delete(dir, 'rf')
  end)

  local function open(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. '/doc.md')
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.cmd('new')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd('resize 20')
    img.send_images()
    vim.wait(30)
    img.send_images()
  end

  local function marks()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, img.ensure_image_namespace(), 0, -1, { details = true })) do
      out[#out + 1] = { row = m[2], col = m[3], d = m[4] }
    end
    return out
  end

  it('reserves space and conceals the use, but leaves the definition line alone', function()
    open({ 'before', '![a][pic]', 'after', '', '[pic]: pic.png' })
    local reserved, conceals = {}, {}
    for _, m in ipairs(marks()) do
      if m.d.virt_lines then reserved[#reserved + 1] = m.row end
      if m.d.conceal then conceals[#conceals + 1] = { m.row, m.col, m.d.end_col } end
    end
    assert.same({ 1 }, reserved)
    assert.same({ { 1, 0, #'![a][pic]' } }, conceals)
    local ids = vim.tbl_keys(store)
    assert.equals(1, #ids)
    assert.equals(dir .. '/pic.png', store[ids[1]].path)
    assert.equals(1, store[ids[1]].opts.row)
    assert.equals('![a][pic]', vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it('draws nothing for an image inside a fenced block', function()
    open({ '```', '![a](pic.png)', '```', 'x' })
    assert.same({}, marks())
    assert.is_nil(next(store))
  end)

  it('hides the source through conceal, which the cursor row reveals (concealcursor empty)', function()
    local wrap = require('nvim_config.rendermark.wrap')
    open({ '![a](pic.png)', 'x' })
    vim.wo[win].conceallevel = 0
    wrap.apply(win)
    local level = vim.wo[win].conceallevel
    wrap.disable(win)
    assert.is_true(level >= 2)
    assert.equals('', vim.wo[win].concealcursor)
  end)

  it('lays several images of one line side by side in one band', function()
    local l = '![a](pic.png) ![b](pic.png) ![c](pic.png) ![d](pic.png) text'
    open({ l, 'tail' })
    local xs = {}
    for _, e in pairs(store) do xs[#xs + 1] = e.opts.dest_x_px end
    table.sort(xs)
    assert.equals(4, #xs)
    assert.is_true(xs[1] < xs[2] and xs[2] < xs[3] and xs[3] < xs[4])
    for _, e in pairs(store) do assert.equals(store[next(store)].opts.dest_y_px, e.opts.dest_y_px) end
  end)
end)

describe('a failing image provider', function()
  local old_ui, old_store, img, buf, dir

  before_each(function()
    old_ui = vim.ui
    old_store = rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)
    package.loaded['nvim_config.rendermark.image'] = nil
    img = require('nvim_config.rendermark.image')
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    write(dir .. '/pic.png', PNG)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. '/doc.md')
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '![a](pic.png)', 'tail' })
    vim.cmd('new')
    vim.api.nvim_win_set_buf(0, buf)
  end)
  after_each(function()
    vim.cmd('close')
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_store)
    package.loaded['nvim_config.rendermark.image'] = nil
    vim.fn.delete(dir, 'rf')
  end)

  it('raises no error and does not retry the same entry', function()
    local calls = 0
    vim.ui = { img = { set = function() calls = calls + 1; error('no image support') end, del = function() end } }
    for _ = 1, 4 do
      assert.has_no.errors(function() img.send_images() end)
      vim.wait(20)
    end
    assert.equals(1, calls)
  end)

  it('tolerates a provider without del and a bare vim.ui.img', function()
    vim.ui = { img = { set = function() end } }
    assert.has_no.errors(function() img.send_images() end)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'no image' })
    assert.has_no.errors(function() img.send_images() end)
    vim.ui = { img = {} }
    assert.has_no.errors(function() img.send_images() end)
    assert.has_no.errors(function() vim.api.nvim_exec_autocmds('SafeState', {}) end)
  end)
end)

describe('terminal stub switch', function()
  local old_ui, old_env, old_g

  before_each(function()
    old_ui, old_env, old_g = vim.ui, vim.env.RENDERMARK_IMG_STUB, vim.g.rendermark_img_stub
    vim.ui = {}
    vim.g.rendermark_img_stub = nil
  end)
  after_each(function()
    vim.ui = old_ui
    vim.env.RENDERMARK_IMG_STUB = old_env
    vim.g.rendermark_img_stub = old_g
  end)

  local function installed(value, via_global)
    vim.ui = {}
    vim.env.RENDERMARK_IMG_STUB = nil
    vim.g.rendermark_img_stub = nil
    if via_global then vim.g.rendermark_img_stub = value else vim.env.RENDERMARK_IMG_STUB = value end
    local host = {}
    require('nvim_config.rendermark.image.backend').new(host).install_terminal_stub()
    return host._stub_active == true and vim.ui.img ~= nil
  end

  it('turns on for RENDERMARK_IMG_STUB=1 and vim.g.rendermark_img_stub', function()
    assert.is_true(installed('1'))
    assert.is_true(installed(1, true))
    assert.is_true(installed(true, true))
  end)

  it('stays off for unset, empty and 0', function()
    assert.is_false(installed(nil))
    assert.is_false(installed(''))
    assert.is_false(installed('0'))
    assert.is_false(installed(0, true))
  end)

  it('is never installed over a real provider', function()
    vim.env.RENDERMARK_IMG_STUB = '1'
    local real = { set = function() end, del = function() end }
    vim.ui = { img = real }
    local host = {}
    require('nvim_config.rendermark.image.backend').new(host).install_terminal_stub()
    assert.equals(real, vim.ui.img)
    assert.is_nil(host._stub_active)
  end)
end)
