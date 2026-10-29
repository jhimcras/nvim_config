-- rendermark.image scan: HTML <img src> and wiki image embeds (![[name.png|300]]),
-- including the asynchronous, cached name search under the project root.

local scan = require('nvim_config.rendermark.image.scan')
local wikisearch = require('nvim_config.rendermark.image.wikisearch')

local function bytes(arr) return string.char(unpack(arr)) end

-- 200x120 PNG header (enough for the size reader).
local PNG = bytes({ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
  0, 0, 0, 200, 0, 0, 0, 120 })

local function write(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local f = assert(io.open(path, 'wb'))
  f:write(data or PNG)
  f:close()
  return path
end

local function raws(links)
  local out = {}
  for _, l in ipairs(links) do out[#out + 1] = l[3] end
  return out
end

describe('find_image_links: HTML <img>', function()
  it('reads src in double, single and no quotes, in any case, several per line', function()
    local text = [=[<img src="a.png"> x <IMG SRC='b.png' /> <Img alt=t src=c.png/> end]=]
    local links = scan.find_image_links(text)
    assert.same({ 'a.png', 'b.png', 'c.png' }, raws(links))
    assert.same({ 1, #'<img src="a.png">' }, { links[1][1], links[1][2] })
    assert.equals('<IMG SRC=\'b.png\' />', text:sub(links[2][1], links[2][2]))
    assert.equals('<Img alt=t src=c.png/>', text:sub(links[3][1], links[3][2]))
  end)

  it('reads width and height in pixels and ignores other units', function()
    local meta = function(t) return scan.find_image_links(t)[1][5] end
    assert.same({ html = true, want_width = 300 }, meta('<img src="a.png" width="300">'))
    assert.same({ html = true, want_width = 300, want_height = 80 }, meta('<img src=a.png width=300px height="80">'))
    assert.same({ html = true }, meta('<img src="a.png" width="50%" height="2em">'))
  end)

  it('decodes entities and keeps a > inside a quoted value', function()
    assert.same({ 'a&b.png' }, raws(scan.find_image_links('<img src="a&amp;b.png">')))
    assert.same({ 'a>b.png' }, raws(scan.find_image_links('<img alt="x" src="a>b.png">')))
  end)

  it('ignores tags without src, other tags, code spans, comments and tags that do not close', function()
    assert.same({}, scan.find_image_links('<img alt="x"> <img src=""> <img> <imgx src="a.png"> <image src="a.png">'))
    assert.same({ 'y.png' }, raws(scan.find_image_links('`<img src="x.png">` <img src="y.png">')))
    assert.same({ 'y.png' }, raws(scan.find_image_links('<!-- <img src="x.png"> --> <img src="y.png">')))
    assert.same({}, scan.find_image_links('<img src="a.png"'))
    assert.same({}, scan.find_image_links('<img src="a.png'))
    assert.same({}, scan.find_image_links('<img'))
  end)

  it('keeps links in text order next to markdown images', function()
    local links = scan.find_image_links('![a](x.png) <img src="y.png"> ![b](z.png)')
    assert.same({ 'x.png', 'y.png', 'z.png' }, raws(links))
  end)

  it('counts an <img> in a link text and drops one inside an image alt', function()
    assert.same({ 'b.png' }, raws(scan.find_image_links('[<img src="b.png">](http://x)')))
    assert.same({ 'd.png' }, raws(scan.find_image_links('![<img src="c.png">](d.png)')))
  end)
end)

describe('find_image_links: wiki embeds', function()
  it('reads name, folder path, width, size and drops the heading', function()
    local links = scan.find_image_links('![[a.png]] ![[dir/b.png|300]] ![[c.png#sec|alt|200x100]] ![[d.png|just text]]')
    assert.same({ 'a.png', 'dir/b.png', 'c.png', 'd.png' }, raws(links))
    assert.same({ wiki = true }, links[1][5])
    assert.same({ wiki = true, want_width = 300 }, links[2][5])
    assert.same({ wiki = true, want_width = 200, want_height = 100 }, links[3][5])
    assert.same({ wiki = true }, links[4][5])
    assert.same({ 1, #'![[a.png]]' }, { links[1][1], links[1][2] })
  end)

  it('takes an escaped bar as the option separator (table cells)', function()
    local links = scan.find_image_links([=[![[a.png\|120]]]=])
    assert.same({ 'a.png' }, raws(links))
    assert.equals(120, links[1][5].want_width)
  end)

  it('is not an image for notes, other files, empty or unclosed embeds', function()
    assert.same({}, scan.find_image_links('![[note]] ![[x.pdf]] ![[note#h]] ![[]] ![[a.png'))
  end)

  it('skips code spans and is not confused with markdown images', function()
    assert.same({ 'b.png', 'c.png' }, raws(scan.find_image_links('`![[a.png]]` ![[b.png]] ![t](c.png)')))
  end)

  it('has a cheap prefilter for both forms', function()
    assert.is_true(scan.has_image_candidate('see ![[a.png]]'))
    assert.is_true(scan.has_image_candidate('<IMG src=a.png>'))
    assert.is_true(scan.has_image_candidate('<img/>'))
    assert.is_false(scan.has_image_candidate('plain <b>text</b> <image>'))
    assert.is_false(scan.has_image_candidate('no images here'))
  end)
end)

describe('HTML and wiki images in a document', function()
  local dir, buf, old_on_ready, old_limits, old_home
  local image = require('nvim_config.rendermark.image')

  local function open(lines)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. '/docs/doc.md')
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end
  local function collect()
    return image.collect_markdown_images(buf, 0, vim.api.nvim_buf_line_count(buf))
  end
  local function wait_for(cond)
    assert.is_true(vim.wait(3000, cond, 5), 'timed out')
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/.git', 'p') -- project root marker
    write(dir .. '/docs/pic.png')
    wikisearch.reset()
    old_on_ready, old_limits = wikisearch.on_ready, vim.deepcopy(wikisearch.limits)
    old_home = vim.uv.os_getenv('HOME')
  end)
  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    wikisearch.on_ready, wikisearch.limits = old_on_ready, old_limits
    wikisearch.min_age_ms = 2000
    wikisearch.reset()
    vim.uv.os_setenv('HOME', old_home)
    vim.fn.delete(dir, 'rf')
  end)

  describe('HTML <img src>', function()
    it('resolves a local src against the document with its conceal range', function()
      open({ 'text <img src="pic.png"> and <img src=\'./pic.png\' width=\'100\'> end' })
      local found = collect()
      assert.equals(2, #found)
      assert.equals(dir .. '/docs/pic.png', found[1].path)
      assert.is_nil(found[1].error)
      assert.same({ 5, 5 + #'<img src="pic.png">' }, { found[1].byte_col, found[1].byte_end_col })
      assert.equals(200, found[1].source_width)
      assert.is_nil(found[1].native_width)
      assert.equals(100, found[2].native_width)
    end)

    it('turns a lone height into the width of that height and prefers a width', function()
      open({ '<img src="pic.png" height="60">', '<img src="pic.png" width="50" height="60">' })
      local found = collect()
      assert.equals(100, found[1].native_width) -- 60 high at 200:120
      assert.equals(50, found[2].native_width)
    end)

    it('expands ~ and reports a missing file as not_found', function()
      vim.uv.os_setenv('HOME', dir)
      open({ '<img src="~/docs/pic.png">', '<img src="gone.png">' })
      local found = collect()
      assert.equals(dir .. '/docs/pic.png', found[1].path)
      assert.is_nil(found[1].error)
      assert.equals('not_found', found[2].error)
    end)

    it('leaves remote and inline data sources alone', function()
      open({ '<img src="https://example.com/a.png">', '<img src="data:image/png;base64,AAAA">' })
      assert.same({}, collect())
    end)

    it('ignores code spans and fenced code blocks', function()
      open({ '`<img src="pic.png">` x', '```html', '<img src="pic.png">', '```', '<img src="pic.png">' })
      local found = collect()
      assert.equals(1, #found)
      assert.equals(4, found[1].row)
    end)

    it('does not see a tag split over several lines (the scan is per line)', function()
      open({ '<img', '  src="pic.png"', '>' })
      assert.same({}, collect())
    end)

    it('is an image link for wrap and as an exported image under a diagram block', function()
      local H = require('tests.spec.rendermark.image.helpers')
      open({ '```plantuml', 'a -> b', '```', '', '<img src="pic.png" width="100">' })
      assert.is_true(image.line_has_image_link('<img src="pic.png">', buf))
      assert.is_false(image.line_has_image_link('<img alt="none">', buf))
      image.set_diagram_source(H.fence_source({ status = 'ready', path = dir .. '/docs/pic.png' }))
      local hide = image.diagram_exported_below(buf, image.diagram_items(buf)[1])
      image.clear_diagram_source()
      assert.is_true(hide)
    end)
  end)

  describe('wiki paths', function()
    it('resolves a folder part, ./ and ../ against the document', function()
      write(dir .. '/docs/sub/in.png')
      write(dir .. '/up.png')
      open({ '![[sub/in.png]] ![[./pic.png]] ![[../up.png]] ![[sub/none.png]]' })
      local found = collect()
      assert.equals(4, #found)
      assert.equals(dir .. '/docs/sub/in.png', found[1].path)
      assert.equals(dir .. '/docs/pic.png', found[2].path)
      assert.equals(dir .. '/up.png', found[3].path)
      assert.equals('not_found', found[4].error)
      assert.equals(0, wikisearch.stats.started)
    end)

    it('takes |width and drops #heading, and expands ~', function()
      vim.uv.os_setenv('HOME', dir)
      open({ '![[pic.png|100]] ![[pic.png#top]] ![[~/docs/pic.png|x|50x30]]' })
      local found = collect()
      assert.equals(3, #found)
      assert.equals(100, found[1].native_width)
      assert.is_nil(found[2].native_width)
      assert.equals(dir .. '/docs/pic.png', found[2].path)
      assert.equals(50, found[3].native_width)
      assert.equals('![[pic.png|100]]', vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:sub(found[1].byte_col + 1, found[1].byte_end_col))
    end)

    it('does not treat notes or other files as images and skips remote targets', function()
      open({ '![[pic]] ![[pic.pdf]] ![[https://example.com/a.png]]', '`![[pic.png]]`', '```', '![[pic.png]]', '```' })
      assert.same({}, collect())
      assert.equals(0, wikisearch.stats.started)
    end)

    it('finds a bare name in the document folder without any search', function()
      open({ '![[pic.png]]' })
      local found = collect()
      assert.equals(1, #found)
      assert.equals(dir .. '/docs/pic.png', found[1].path)
      assert.equals(0, wikisearch.stats.started)
    end)
  end)

  describe('wiki name search', function()
    local ready

    before_each(function()
      ready = 0
      wikisearch.on_ready = function() ready = ready + 1 end
    end)

    it('draws nothing while the project root is walked, then finds the image', function()
      write(dir .. '/assets/deep/shot.png')
      open({ '![[shot.png]]' })
      assert.same({}, collect())
      assert.equals(1, wikisearch.stats.started)
      wait_for(function() return ready > 0 end)
      local found = collect()
      assert.equals(1, #found)
      assert.equals(dir .. '/assets/deep/shot.png', found[1].path)
      assert.is_nil(found[1].error)
      assert.equals(1, wikisearch.stats.started) -- the answer came from the cache
    end)

    it('merges requests made while the walk is running', function()
      write(dir .. '/assets/shot.png')
      open({ '![[shot.png]] ![[other.png]]', '![[shot.png]]' })
      for _ = 1, 6 do collect() end
      assert.equals(1, wikisearch.stats.started)
      wait_for(function() return ready > 0 end)
      assert.equals(1, ready)
      for _ = 1, 6 do collect() end
      assert.equals(1, wikisearch.stats.started)
    end)

    it('prefers the image closest to the document', function()
      write(dir .. '/docs/near/shot.png')
      write(dir .. '/far/er/shot.png')
      open({ '![[shot.png]]' })
      collect()
      wait_for(function() return ready > 0 end)
      assert.equals(dir .. '/docs/near/shot.png', collect()[1].path)
    end)

    it('reports equally close images as ambiguous and a missing one as not_found', function()
      write(dir .. '/a/shot.png')
      write(dir .. '/b/shot.png')
      open({ '![[shot.png]] ![[nothing.png]]' })
      collect()
      wait_for(function() return ready > 0 end)
      local found = collect()
      assert.equals('ambiguous', found[1].error)
      assert.equals(dir .. '/docs/shot.png', found[1].path)
      assert.equals('not_found', found[2].error)
      assert.equals(dir .. '/docs/nothing.png', found[2].path)
      assert.is_truthy(image.image_error_text(found[1]):find('ambiguous', 1, true))
    end)

    it('skips hidden folders, node_modules and target', function()
      write(dir .. '/.cache/shot.png')
      write(dir .. '/node_modules/shot.png')
      write(dir .. '/target/shot.png')
      write(dir .. '/ok/other.png')
      open({ '![[shot.png]]' })
      collect()
      wait_for(function() return ready > 0 end)
      assert.equals('not_found', collect()[1].error)
    end)

    it('stops at the entry and depth limits', function()
      write(dir .. '/l1/l2/l3/deep.png')
      write(dir .. '/l1/shallow.png')
      wikisearch.limits = { max_entries = 1000, max_depth = 2 }
      open({ '![[deep.png]] ![[shallow.png]]' })
      collect()
      wait_for(function() return ready > 0 end)
      local found = collect()
      assert.equals('not_found', found[1].error)
      assert.is_nil(found[2].error)

      wikisearch.reset()
      wikisearch.limits = { max_entries = 2, max_depth = 8 }
      ready = 0
      collect()
      wait_for(function() return ready > 0 end)
      assert.equals('not_found', collect()[1].error)
    end)

    it('searches the document folder tree when there is no project root', function()
      local bare = vim.fn.tempname()
      write(bare .. '/n/sub/shot.png')
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, bare .. '/n/doc.md')
      vim.bo[buf].filetype = 'markdown'
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '![[shot.png]]' })
      collect()
      wait_for(function() return ready > 0 end)
      assert.equals(bare .. '/n/sub/shot.png', collect()[1].path)
      vim.fn.delete(bare, 'rf')
    end)

    it('keeps answering from the old index while a stale one is re-walked', function()
      write(dir .. '/assets/shot.png')
      open({ '![[shot.png]] ![[late.png]]' })
      collect()
      wait_for(function() return ready > 0 end)
      assert.equals('not_found', collect()[2].error)
      write(dir .. '/assets/late.png')
      wikisearch.invalidate(buf, 'write')
      local found = collect() -- starts the re-walk, answers from the old index
      assert.equals(2, wikisearch.stats.started)
      assert.equals(dir .. '/assets/shot.png', found[1].path)
      assert.equals('not_found', found[2].error)
      wait_for(function() return ready > 1 end)
      assert.equals(dir .. '/assets/late.png', collect()[2].path)
    end)

    it('does not re-walk when the answer did not change', function()
      write(dir .. '/assets/shot.png')
      open({ '![[shot.png]]' })
      collect()
      wait_for(function() return ready > 0 end)
      wikisearch.invalidate(buf, 'write')
      collect()
      assert.equals(2, wikisearch.stats.started)
      wait_for(function() return wikisearch.stats.finished == 2 end)
      vim.wait(50, function() return false end, 10)
      assert.equals(1, ready) -- same files: nobody is told again
    end)

    it('lets BufEnter re-walk only an index older than min_age_ms, a save always', function()
      write(dir .. '/assets/shot.png')
      open({ '![[shot.png]]' })
      collect()
      wait_for(function() return ready > 0 end)
      wikisearch.invalidate(buf, 'enter') -- just built: too young
      collect()
      assert.equals(1, wikisearch.stats.started)
      wikisearch.invalidate(buf, 'write')
      collect()
      assert.equals(2, wikisearch.stats.started)
      wait_for(function() return wikisearch.stats.finished == 2 end)
      wikisearch.min_age_ms = 0
      wikisearch.invalidate(buf, 'enter')
      collect()
      assert.equals(3, wikisearch.stats.started)
    end)
  end)
end)

describe('rendering HTML and wiki images', function()
  local old_ui, old_store, img, store, buf, win, dir

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
    vim.fn.mkdir(dir .. '/.git', 'p')
    write(dir .. '/docs/pic.png')
    wikisearch.reset()
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = 10, 20
  end)
  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, 'rendermark_image')
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_store)
    package.loaded['nvim_config.rendermark.image'] = nil
    wikisearch.min_age_ms = 2000
    wikisearch.reset()
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px = nil, nil
    vim.fn.delete(dir, 'rf')
  end)

  -- `immediate`: one send_images and no loop turn, so a background search cannot finish.
  local function open(lines, immediate)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. '/docs/doc.md')
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.cmd('new')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.cmd('resize 20')
    img.send_images()
    if immediate then return end
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

  local function only()
    local ids = vim.tbl_keys(store)
    assert.equals(1, #ids)
    return store[ids[1]]
  end

  it('reserves space, conceals the tag and draws the file for an <img>', function()
    open({ 'before', '<img src="pic.png">', 'after' })
    local reserved, conceals = {}, {}
    for _, m in ipairs(marks()) do
      if m.d.virt_lines then reserved[#reserved + 1] = m.row end
      if m.d.conceal then conceals[#conceals + 1] = { m.row, m.col, m.d.end_col } end
    end
    assert.same({ 1 }, reserved)
    assert.same({ { 1, 0, #'<img src="pic.png">' } }, conceals)
    local e = only()
    assert.equals(dir .. '/docs/pic.png', e.path)
    assert.equals(200, e.opts.display_width_px)
    assert.equals('<img src="pic.png">', vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
  end)

  it('sizes an <img> by its width and a wiki embed by its |width', function()
    open({ '<img src="pic.png" width="100">', 'x', '![[pic.png|50]]' })
    local widths = {}
    for _, e in pairs(store) do widths[#widths + 1] = e.opts.display_width_px end
    table.sort(widths)
    assert.same({ 50, 100 }, widths)
  end)

  it('places an <img>, a wiki embed and a markdown image side by side', function()
    open({ '<img src="pic.png" width="50"> ![[pic.png|50]] ![a](pic.png) tail', 'x' })
    local xs = {}
    for _, e in pairs(store) do xs[#xs + 1] = e.opts.dest_x_px end
    table.sort(xs)
    assert.equals(3, #xs)
    assert.is_true(xs[1] < xs[2] and xs[2] < xs[3])
  end)

  it('draws a wiki name found by the background search once it is done', function()
    write(dir .. '/assets/shot.png')
    open({ 'top', '![[shot.png]]', 'tail' }, true)
    assert.is_nil(next(store))
    assert.same({}, marks())
    for _ = 1, 5 do img.send_images() end -- scrolling and cursor moves ask again
    assert.equals(1, wikisearch.stats.started)
    assert.is_true(vim.wait(3000, function() return next(store) ~= nil end, 5))
    assert.equals(dir .. '/assets/shot.png', only().path)
    local conceals = {}
    for _, m in ipairs(marks()) do
      if m.d.conceal then conceals[#conceals + 1] = { m.row, m.col, m.d.end_col } end
    end
    assert.same({ { 1, 0, #'![[shot.png]]' } }, conceals)
    assert.equals(1, wikisearch.stats.started)
  end)

  it('shows an error box for an ambiguous or missing wiki name', function()
    write(dir .. '/a/shot.png')
    write(dir .. '/b/shot.png')
    open({ '![[shot.png]]', '![[none.png]]' })
    local function boxes()
      local out = {}
      for _, m in ipairs(marks()) do
        if m.d.virt_lines then out[#out + 1] = m.d.virt_lines[1][1][1] end
      end
      return out
    end
    assert.is_true(vim.wait(3000, function() img.send_images(); return #boxes() == 2 end, 20))
    local text = table.concat(boxes(), '\n')
    assert.is_truthy(text:find('ambiguous', 1, true))
    assert.is_truthy(text:find('not found', 1, true))
    assert.is_nil(next(store))
  end)

  it('re-walks after a save or a visit once setup has installed the autocmds', function()
    write(dir .. '/assets/shot.png')
    img.setup({})
    open({ '![[shot.png]]' })
    assert.is_true(vim.wait(3000, function() return next(store) ~= nil end, 5))
    local started = wikisearch.stats.started
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = buf })
    img.send_images()
    assert.equals(started + 1, wikisearch.stats.started)
    assert.is_true(vim.wait(3000, function() return wikisearch.stats.finished == started + 1 end, 5))
    wikisearch.min_age_ms = 0
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = buf })
    img.send_images()
    assert.equals(started + 2, wikisearch.stats.started)
  end)
end)
