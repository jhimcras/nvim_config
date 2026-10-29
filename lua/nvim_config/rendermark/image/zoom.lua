-- Enlarged view of one image: `:RendermarkImageOpen` opens a scratch tab and
-- fits the image under the cursor to its window (aspect kept, upscaling allowed).
--
-- Deliberately outside the body pipeline (send_images / reservations / payload):
-- it draws no extmarks in the document and allocates no document space. It talks
-- to vim.ui.img directly with its own ids (`rendermark:zoom:<buf>`), which are not
-- in the backend's live set, so a body sync can neither delete nor re-add them.
local scan = require('nvim_config.rendermark.image.scan')
local docindex = require('nvim_config.rendermark.image.docindex')

local Module = {}

local ZOOM_ZINDEX = 50

local WIN_OPTIONS = {
  number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0',
  cursorline = false, cursorcolumn = false, colorcolumn = '', list = false,
  wrap = false, spell = false, statuscolumn = '',
}

function Module.new(M, state)
  local api = {}
  local backend = state.backend
  local zooms = {} -- scratch buffer -> { buf, win, tab, origin_tab, id, path, src_w, src_h, last, shown }

  local function notify(msg, level)
    vim.notify('rendermark: ' .. msg, level or vim.log.levels.WARN)
  end

  -- Largest size with the image's aspect that fits area_w x area_h (pixels).
  -- Pure. Small images are enlarged too: the point is to fill the window.
  function api.zoom_fit(src_w, src_h, area_w, area_h)
    if not (src_w and src_h and src_w > 0 and src_h > 0 and area_w and area_h and area_w > 0 and area_h > 0) then
      return nil
    end
    local w, h
    if area_w * src_h <= area_h * src_w then
      w = area_w
      h = math.min(area_h, math.max(1, math.floor(area_w * src_h / src_w + 0.5)))
    else
      h = area_h
      w = math.min(area_w, math.max(1, math.floor(area_h * src_w / src_h + 0.5)))
    end
    return w, h
  end

  local function is_markdown(buf)
    local ext = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':e'):lower()
    return vim.bo[buf].filetype == 'markdown' or ext == 'md' or ext == 'markdown'
  end

  local function describe(error_kind, raw)
    if error_kind == 'not_found' then return 'image not found: ' .. raw end
    if error_kind == 'ambiguous' then return 'image name is ambiguous: ' .. raw end
    return 'image unsupported (cannot read its size): ' .. raw
  end

  -- A readable image file as { path, width, height }, or nil + message.
  local function open_file(path, raw)
    if vim.fn.filereadable(path) ~= 1 then return nil, describe('not_found', raw or path) end
    local size = M.read_image_size(path)
    if not (size and size.width and size.height and size.width > 0 and size.height > 0) then
      return nil, describe('unsupported', raw or path)
    end
    return { path = path, width = size.width, height = size.height }
  end

  -- The image `win`'s cursor stands on: the rendered picture of the diagram block
  -- containing it (ready items only), else the image link in the cursor line that
  -- holds the cursor column, else the nearest one. Returns { path, width, height }
  -- or nil + message.
  function api.zoom_target(buf, win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local row, col = cursor[1] - 1, cursor[2]

    for _, item in ipairs(M.diagram_items(buf)) do
      if row >= item.start_row and row <= item.end_row then
        if item.status == 'ready' and item.path then
          return open_file(item.path)
        elseif item.status == 'failed' then
          return nil, 'diagram render failed' .. (item.error and (': ' .. tostring(item.error)) or '')
        end
        return nil, 'diagram is not rendered yet (' .. tostring(item.status or 'none') .. ')'
      end
    end

    if not is_markdown(buf) then return nil, 'no image under the cursor' end
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    if not scan.has_image_candidate(line) or docindex.in_fence(docindex.get(buf), row) then
      return nil, 'no image under the cursor'
    end

    local items = {}
    M.scan_markdown_image_text(buf, row, line, items, { base_col = 0 })
    if #items == 0 then
      if #scan.find_image_links(line, scan.buf_defs(buf)) > 0 then
        return nil, 'no local image under the cursor (remote, or a wiki name still being searched)'
      end
      return nil, 'no image under the cursor'
    end

    local best, best_dist
    for _, image in ipairs(items) do
      local first, last = image.byte_col, image.byte_end_col - 1
      local dist = col < first and first - col or (col > last and col - last or 0)
      if not best_dist or dist < best_dist then best, best_dist = image, dist end
    end
    if best.error then return nil, describe(best.error, best.raw_path or best.path or '') end
    return { path = best.path, width = best.source_width, height = best.source_height }
  end

  local function img_del(id)
    if type(vim.ui.img.del) == 'function' then pcall(vim.ui.img.del, id) end
  end

  local function hide(z)
    if not z.shown then return end
    z.shown, z.last = false, nil
    if backend.img_available() then img_del(z.id) end
    backend.mark_changed()
    backend.notify_redraw()
  end

  -- Fit the image to the zoom window and (re)send it when the placement changed.
  local function fit(z)
    if not (vim.api.nvim_win_is_valid(z.win) and vim.api.nvim_get_current_tabpage() == z.tab) then return end
    if not backend.img_available() then return end
    local info = vim.fn.getwininfo(z.win)[1]
    if not info then return end
    local cell_w = tonumber(vim.g.neopp_cell_width_px) or 10
    local cell_h = tonumber(vim.g.neopp_cell_height_px) or 18
    local textoff = tonumber(info.textoff) or 0
    local area_w = math.max(1, (info.width - textoff) * cell_w)
    local area_h = math.max(1, info.height * cell_h)
    local disp_w, disp_h = api.zoom_fit(z.src_w, z.src_h, area_w, area_h)
    if not disp_w then return end

    local clip_x = (info.wincol - 1 + textoff) * cell_w
    local clip_y = (info.winrow - 1) * cell_h
    local dest_x = clip_x + math.floor((area_w - disp_w) / 2)
    local dest_y = clip_y + math.floor((area_h - disp_h) / 2)
    local grid_row, grid_col = math.floor(dest_y / cell_h), math.floor(dest_x / cell_w)
    local opts = {
      buf = z.buf, row = 0, col = 0,
      grid_row = grid_row, grid_col = grid_col, text_grid_row = grid_row,
      -- No link text to occlude (-1, as for table cells).
      text_col = -1, text_end_col = -1, virtual = false,
      win_left = info.wincol - 1, win_width = info.width,
      win_top = info.winrow - 1, win_height = info.height, text_offset = textoff,
      source_width = z.src_w, source_height = z.src_h,
      dest_x_px = dest_x, dest_y_px = dest_y,
      display_width_px = disp_w, display_height_px = disp_h,
      clip_x_px = clip_x, clip_y_px = clip_y, clip_width_px = area_w, clip_height_px = area_h,
      virt_height = math.ceil(disp_h / cell_h), zindex = ZOOM_ZINDEX, above_floats = false,
    }

    if z.shown and vim.deep_equal(z.last, opts) then return end
    if M._stub_active then
      -- Terminal stub: text box over the same rectangle (window text area, centered).
      local rect = { row = info.winrow - 1, col = info.wincol - 1 + textoff,
                     width = math.max(1, info.width - textoff), height = math.max(1, info.height) }
      local place = {
        row = grid_row, col = grid_col,
        width = math.max(1, math.min(rect.width, math.ceil(disp_w / cell_w))),
        height = math.max(1, math.min(rect.height, math.ceil(disp_h / cell_h))),
        disp_w = disp_w, disp_h = disp_h,
      }
      M.draw_stub_preview_box(z.buf, place, z.path, rect)
    end

    local ok, err = pcall(vim.ui.img.set, z.id, z.path, opts)
    if not ok then
      vim.notify_once('rendermark: vim.ui.img.set failed: ' .. tostring(err), vim.log.levels.WARN)
      return
    end
    z.last, z.shown = opts, true
    backend.mark_changed()
    backend.notify_redraw()
  end

  local function cleanup(z)
    if z.done then return end
    z.done = true
    hide(z)
    zooms[z.buf] = nil
    pcall(vim.api.nvim_del_augroup_by_id, z.group)
  end

  -- Close the zoom tab of scratch buffer `buf` (the current zoom when omitted).
  function api.zoom_close(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local z = zooms[buf]
    if not z then return end
    local origin = z.origin_tab
    cleanup(z)
    if vim.api.nvim_tabpage_is_valid(z.tab) then
      local nr = vim.api.nvim_tabpage_get_number(z.tab)
      if #vim.api.nvim_list_tabpages() > 1 then
        pcall(vim.cmd, nr .. 'tabclose')
      else
        pcall(vim.api.nvim_buf_delete, z.buf, { force = true })
      end
    end
    if origin and vim.api.nvim_tabpage_is_valid(origin) and vim.api.nvim_get_current_tabpage() ~= origin then
      pcall(vim.api.nvim_set_current_tabpage, origin)
    end
  end

  -- Zoom scratch buffers that are open (for tests and diagnostics).
  function api.zoom_list()
    local list = {}
    for buf, z in pairs(zooms) do list[#list + 1] = { buf = buf, win = z.win, tab = z.tab, id = z.id, path = z.path } end
    table.sort(list, function(a, b) return a.buf < b.buf end)
    return list
  end

  -- Open the image under the cursor of `win` (current) in a new tab. Returns the
  -- scratch buffer, or nil when there was nothing to open (the reason is notified).
  function api.zoom_open(win)
    win = (win and win ~= 0) and win or vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    if not backend.img_available() then
      notify('no image backend (vim.ui.img): cannot open the image')
      return nil
    end
    if vim.g.neopp_images_enabled == false then
      notify('images are disabled (vim.g.neopp_images_enabled = false)')
      return nil
    end
    local target, msg = api.zoom_target(buf, win)
    if not target then
      notify(msg)
      return nil
    end

    local origin_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd.tabnew()
    local zbuf, zwin = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    for name, value in pairs({ buftype = 'nofile', bufhidden = 'wipe', swapfile = false,
                               buflisted = false, modifiable = false,
                               filetype = 'rendermark_zoom' }) do
      vim.bo[zbuf][name] = value
    end
    pcall(vim.api.nvim_buf_set_name, zbuf, 'rendermark-zoom://' .. vim.fn.fnamemodify(target.path, ':t'))
    for name, value in pairs(WIN_OPTIONS) do
      pcall(vim.api.nvim_set_option_value, name, value, { win = zwin, scope = 'local' })
    end

    local z = {
      buf = zbuf, win = zwin, tab = vim.api.nvim_get_current_tabpage(), origin_tab = origin_tab,
      id = 'rendermark:zoom:' .. zbuf, path = target.path, src_w = target.width, src_h = target.height,
      shown = false,
    }
    z.group = vim.api.nvim_create_augroup('rendermark_zoom_' .. zbuf, { clear = true })
    zooms[zbuf] = z

    local function close() api.zoom_close(zbuf) end
    vim.keymap.set('n', 'q', close, { buffer = zbuf, nowait = true, silent = true, desc = 'Close the image tab' })
    vim.keymap.set('n', '<Esc>', close, { buffer = zbuf, nowait = true, silent = true, desc = 'Close the image tab' })

    local function refit() fit(z) end
    vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized', 'TabEnter', 'WinEnter', 'BufEnter' },
      { group = z.group, callback = refit })
    vim.api.nvim_create_autocmd('User', { group = z.group, pattern = 'NeoppMetrics', callback = refit })
    -- The image belongs to this tab only; the document tab draws its own.
    vim.api.nvim_create_autocmd('TabLeave', { group = z.group, callback = function()
      if vim.api.nvim_get_current_tabpage() == z.tab then hide(z) end
    end })
    vim.api.nvim_create_autocmd('BufWipeout', { group = z.group, buffer = zbuf, callback = function() cleanup(z) end })
    vim.api.nvim_create_autocmd('WinClosed', { group = z.group, pattern = tostring(zwin),
      callback = function() cleanup(z) end })

    fit(z)
    return zbuf
  end

  -- Command and the markdown-buffer keymap. Always installed: without a backend
  -- the command explains itself instead of being unknown.
  function api.zoom_setup()
    vim.api.nvim_create_user_command('RendermarkImageOpen', function() api.zoom_open() end,
      { desc = 'Open the image under the cursor, enlarged, in a new tab' })
    local group = vim.api.nvim_create_augroup('rendermark_image_zoom', { clear = true })
    local function attach(buf)
      if vim.bo[buf].filetype ~= 'markdown' then return end
      vim.keymap.set('n', '<leader>i', function() api.zoom_open() end,
        { buffer = buf, silent = true, desc = 'RendermarkImageOpen' })
    end
    vim.api.nvim_create_autocmd('FileType', { group = group, pattern = 'markdown',
      callback = function(args) attach(args.buf) end })
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then attach(buf) end
    end
  end

  return api
end

return Module
