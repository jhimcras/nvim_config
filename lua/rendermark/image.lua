-- rendermark.image: markdown image + PlantUML producer for the neopp GUI.
--
-- Relocated out of neopp's bundled bridge.lua: neopp is now a pure image backend
-- exposing the Neovim 0.13 vim.ui.img surface (set/get/del). This module parses
-- markdown `![alt](path)` links and ```plantuml fenced blocks, reads image sizes
-- cheaply (header bytes only), reserves vertical space with virt_lines, conceals
-- the source text, computes placement/cursor rules/preview-float geometry, and
-- drives vim.ui.img.set / vim.ui.img.del. neopp loads (decodes), renders, deletes.
--
-- Cell metrics come from vim.g.neopp_cell_width_px / neopp_cell_height_px, which
-- neopp publishes (bridge_trigger 'metrics'); a 'User NeoppMetrics' autocmd fires
-- when they change.

local M = {}

local image_ns
local layout_sig = ''
local image_reservation_sig = ''
local image_resyncing = false
local image_sync_pending = false
local autocmd_group
local bitops = bit or bit32
local extmark_virt_lines_sig
local live_ids = {}  -- id -> true: images currently set in the GUI backend

local function trim(s)
  return (s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

-- ---------------------------------------------------------------------------
-- GUI image backend (vim.ui.img) plumbing
-- ---------------------------------------------------------------------------

local function img_available()
  return vim.ui and vim.ui.img and type(vim.ui.img.set) == 'function'
end

-- Terminal verification stub: when neopp is absent (plain terminal) and the user
-- opts in via RENDERMARK_IMG_STUB / vim.g.rendermark_img_stub, install a no-op
-- vim.ui.img backend so img_available() is true and the whole non-pixel UI
-- pipeline (space reservation, conceal, preview floats, cursor rules, autocmds)
-- runs. M._stub_active makes make_virt_lines draw a labelled box in the reserved
-- area so the secured region/size is visible without real image pixels.
local stub_store = {}  -- id -> { path = , opts = }

local function stub_requested()
  return (not img_available())
     and (vim.env.RENDERMARK_IMG_STUB or vim.g.rendermark_img_stub)
end

local function install_terminal_stub()
  if not stub_requested() then return end
  vim.ui = vim.ui or {}
  vim.ui.img = {
    set = function(id, path, opts) stub_store[id] = { path = path, opts = opts } end,
    get = function(id) return stub_store[id] end,
    del = function(id) stub_store[id] = nil end,
  }
  M._stub_active = true
end

-- Diff a freshly computed payload against the live set: set every entry (its
-- position/size may have changed) and del ids that are no longer present.
local function apply_payload(payload)
  if not img_available() then return end
  local next_ids = {}
  for _, entry in ipairs(payload) do
    local id, path = entry.id, entry.path
    local opts = {}
    for k, v in pairs(entry) do
      if k ~= 'id' and k ~= 'path' then opts[k] = v end
    end
    next_ids[id] = true
    vim.ui.img.set(id, path, opts)
  end
  for id in pairs(live_ids) do
    if not next_ids[id] then vim.ui.img.del(id) end
  end
  live_ids = next_ids
end

local function clear_all_images()
  if not img_available() then live_ids = {}; return end
  for id in pairs(live_ids) do vim.ui.img.del(id) end
  live_ids = {}
end

local function notify_redraw()
  local ch = vim.g.neopp_channel
  if ch then pcall(vim.rpcnotify, ch, 'force_redraw') end
end

-- ---------------------------------------------------------------------------
-- Geometry / extmark helpers
-- ---------------------------------------------------------------------------

function M.safe_screenpos(win, lnum, col)
  local ok, sp = pcall(vim.fn.screenpos, win, lnum, col)
  if ok and sp and sp.row ~= nil then return sp end
  return { row = 0, col = 0, endcol = 0, curscol = 0 }
end

function M.screenpos_display_col(sp)
  if not sp then return 0 end
  return tonumber(sp.col) or 0
end

function M.strip_indent_space_chars(text)
  if type(text) ~= 'string' then return '' end
  return text
    :gsub('[%s]', '')
    :gsub('\194\160', '')
    :gsub('\226\128[\128-\138]', '')
    :gsub('\226\128\175', '')
    :gsub('\226\129\159', '')
    :gsub('\227\128\128', '')
end

function M.is_indent_text(text, highlight)
  local rest = M.strip_indent_space_chars(text)
  if rest == '' then return true end

  if type(highlight) == 'string' and highlight:lower():find('indent', 1, true) then
    return true
  end
  if type(highlight) == 'table' then
    for _, hl in ipairs(highlight) do
      if type(hl) == 'string' and hl:lower():find('indent', 1, true) then
        return true
      end
    end
  end

  return rest == '▎' or rest == '▏' or rest == '▕' or rest == '│' or rest == '┃' or rest == '|'
end

function M.virt_text_width(virt_text)
  if type(virt_text) ~= 'table' then return 0 end
  local width = 0
  for _, chunk in ipairs(virt_text) do
    local text = type(chunk) == 'table' and chunk[1] or nil
    local highlight = type(chunk) == 'table' and chunk[2] or nil
    if type(text) ~= 'string' then return 0 end
    if not M.is_indent_text(text, highlight) then return 0 end
    width = width + vim.fn.strdisplaywidth(text)
  end
  return width
end

function M.virtual_indent_anchor_min_col(buf, row, col, base_col, buffer_col)
  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, { row, 0 }, { row + 1, 0 }, { details = true })
  if not ok then return base_col + buffer_col - 1 end

  local min_col = base_col + buffer_col - 1
  local prefix_width = 0
  for _, mark in ipairs(marks) do
    local mark_row = mark[2]
    local mark_col = mark[3]
    local details = mark[4] or {}
    if mark_row == row then
      local virt_width = M.virt_text_width(details.virt_text)
      if virt_width > 0 and (details.virt_text_pos == 'inline' or details.virt_text_pos == 'overlay' or details.virt_text_win_col ~= nil) then
        if details.virt_text_win_col ~= nil then
          local win_col = tonumber(details.virt_text_win_col) or 0
          min_col = math.max(min_col, base_col + win_col + virt_width)
        elseif mark_col <= col or (col == 0 and mark_col <= 1) then
          prefix_width = prefix_width + virt_width
        end
      end
    end
  end
  return math.max(min_col, base_col + buffer_col - 1 + prefix_width)
end

function M.virtual_indent_width(buf, row, col)
  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, { row, 0 }, { row + 1, 0 }, { details = true })
  if not ok then return 0 end

  local width = 0
  for _, mark in ipairs(marks) do
    local mark_row = mark[2]
    local mark_col = mark[3]
    local details = mark[4] or {}
    if mark_row == row and (mark_col <= col or (col == 0 and mark_col <= 1)) then
      local virt_width = M.virt_text_width(details.virt_text)
      if virt_width > 0 and (details.virt_text_pos == 'inline' or details.virt_text_pos == 'overlay' or details.virt_text_win_col ~= nil) then
        width = width + virt_width
      end
    end
  end
  return width
end

function M.image_anchor_extmark_sig(buf, start_row, end_row)
  local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, { start_row, 0 }, { end_row, 0 }, { details = true })
  if not ok then return '' end

  local parts = {}
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.ns_id ~= image_ns then
      local virt_width = M.virt_text_width(details.virt_text)
      local virt_text = M.virt_text_to_plain(details.virt_text)
      local virt_image = type(virt_text) == 'string' and virt_text:find('!%[[^%]]*%]%(([^%)%s]+)%)') ~= nil
      local virt_lines = M.virt_lines_to_plain(details.virt_lines)
      local virt_lines_image = false
      for _, text in ipairs(virt_lines) do
        if type(text) == 'string' and text:find('!%[[^%]]*%]%(([^%)%s]+)%)') ~= nil then
          virt_lines_image = true
          break
        end
      end
      if virt_width > 0 or virt_image or virt_lines_image or details.conceal ~= nil or details.virt_text_win_col ~= nil then
        parts[#parts + 1] = table.concat({
          tostring(mark[2] or 0),
          tostring(mark[3] or 0),
          tostring(details.end_col or ''),
          tostring(details.virt_text_pos or ''),
          tostring(details.virt_text_win_col or ''),
          tostring(virt_width),
          virt_image and virt_text or '',
          virt_lines_image and extmark_virt_lines_sig(details.virt_lines) or '',
          tostring(details.conceal or ''),
        }, ':')
      end
    end
  end
  table.sort(parts)
  return table.concat(parts, '|')
end

function M.buffer_display_col(buf, row, col)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, row, row + 1, false)
  if not ok or not lines or not lines[1] then return nil end
  local prefix = lines[1]:sub(1, math.max(0, col))
  return vim.fn.strdisplaywidth(prefix) + 1
end

local function markdown_fence(line)
  if type(line) ~= 'string' then return nil end
  local ticks, info = line:match('^%s*(```+)(.*)$')
  if ticks then return ticks:sub(1, 1), #ticks, trim(info or '') end
  local tildes
  tildes, info = line:match('^%s*(~~~+)(.*)$')
  if tildes then return tildes:sub(1, 1), #tildes, trim(info or '') end
  return nil
end

function M.markdown_plantuml_block_height(buf, row)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or not lines then return nil end

  local in_fence = false
  local fence_char = nil
  local fence_len = 0
  local fence_start = 0
  local fence_info = ''
  for i, line in ipairs(lines) do
    local row0 = i - 1
    local char, len, info = markdown_fence(line)
    if not in_fence then
      if char then
        in_fence = true
        fence_char = char
        fence_len = len
        fence_start = row0
        fence_info = (info or ''):lower()
      end
    elseif char == fence_char and len >= fence_len then
      if row >= fence_start and row <= row0 and fence_info:find('plantuml', 1, true) then
        return row0 - fence_start + 1
      end
      in_fence = false
      fence_char = nil
      fence_len = 0
      fence_start = 0
      fence_info = ''
    end
  end

  if in_fence and row >= fence_start and fence_info:find('plantuml', 1, true) then
    return #lines - fence_start
  end
  return nil
end

function M.image_anchor_display_col(buf, row, col, sp, win_info)
  local display_col = M.screenpos_display_col(sp)
  local wincol = win_info and (tonumber(win_info.wincol) or 1) or 1
  local textoff = win_info and (tonumber(win_info.textoff) or 0) or 0
  local base_col = wincol + textoff
  local buffer_col = M.buffer_display_col(buf, row, col)
  if buffer_col and buffer_col > 0 then
    local min_col = M.virtual_indent_anchor_min_col(buf, row, col, base_col, buffer_col)
    display_col = math.max(display_col, min_col)
  end
  return display_col
end

function M.virtual_image_anchor_display_col(buf, row, image, sp, win_info)
  if not image or not image.virtual then
    return M.image_anchor_display_col(buf, row, image and image.col or 0, sp, win_info)
  end

  local wincol = win_info and (tonumber(win_info.wincol) or 1) or 1
  local textoff = win_info and (tonumber(win_info.textoff) or 0) or 0
  local prefix_width = math.max(0, tonumber(image.virtual_prefix_width) or 0)

  if image.virt_text_win_col ~= nil then
    return wincol + math.max(0, tonumber(image.virt_text_win_col) or 0) + prefix_width
  end

  local mark_col = math.max(0, tonumber(image.virtual_mark_col) or tonumber(image.col) or 0)
  local base_col = M.image_anchor_display_col(buf, row, mark_col, sp, win_info)
  return math.max(base_col, wincol + textoff) + prefix_width
end

function M.make_virt_lines(virt_height, label)
  local h = math.max(1, virt_height or 1)
  if M._stub_active and label then
    return M.make_stub_box(h, label)
  end
  local lines = {}
  for _ = 2, h do
    lines[#lines + 1] = { { ' ', 'Normal' } }
  end
  return lines
end

-- Terminal stub: draw a bordered box inside the reserved rows so the secured
-- render area (boundary + computed pixel size) is visible without real pixels.
-- Like the blank variant, the box lives entirely in the h-1 virt_lines below the
-- anchor buffer line; the anchor line keeps the (concealed) source link.
function M.make_stub_box(h, label)
  local hl = 'NonText'
  local n = h - 1  -- number of virt_lines to emit
  if n < 1 then return {} end
  local name = label.name or '?'
  local size = string.format('%dx%dpx  (%d rows)', label.w_px or 0, label.h_px or 0, h)
  if n == 1 then
    return { { { '[img: ' .. name .. '  ' .. size .. ']', hl } } }
  end
  local inner = math.min(200, math.max(#('- img: ' .. name .. ' '), #(' ' .. size .. ' ')))
  local function row(open, fill, text, close)
    local pad = math.max(0, inner - #text)
    return open .. text .. string.rep(fill, pad) .. close
  end
  local lines = {}
  lines[1] = { { row('+', '-', '- img: ' .. name .. ' ', '+'), hl } }
  for i = 2, n - 1 do
    local text = (i == 2) and (' ' .. size .. ' ') or ''
    lines[i] = { { row('|', ' ', text, '|'), hl } }
  end
  lines[n] = { { row('+', '-', '', '+'), hl } }
  return lines
end

-- Terminal stub, footprint-faithful box (PlantUML blocks AND image links). Unlike
-- make_stub_box (which lives wholly in the virt_lines slice), this draws the box
-- across the FULL image footprint: virt_h visual rows starting at the source's
-- first row, exactly where the GUI image would paint. Space allocation is left
-- untouched -- the box is split between (a) the already-reserved virt_lines and
-- (b) zero-height virt_text overlays on the (concealed) source rows. Visual-row
-- routing matches nvim's render order: src0, then the reserve_h-1 virt_lines
-- anchored below src0, then src1..src(source_span-1). For a single-line image link
-- source_span==1, so only src0 is overlaid (top border) and the rest are virt_lines.
function M.draw_stub_footprint_box(buf, ns, reservation, cell_w)
  local hl = 'NonText'
  local label = reservation.label
  local row = reservation.row
  local reserve_h = math.max(1, reservation.reserve_h or 1)
  local source_span = math.max(1, label.source_span or 1)
  local virt_h = math.max(1, label.virt_h or 1)
  local name = label.name or '?'
  local size = string.format('%dx%dpx  (%d rows)', label.w_px or 0, label.h_px or 0, virt_h)

  -- Box width = the image's real display width in cells (NOT the label length), so
  -- the overlay never spills past the actual image footprint. Label text is clipped
  -- to fit. Capped at 200 and floored so borders always render.
  local box_w = math.min(200, math.max(4, math.floor((label.w_px or 0) / math.max(1, cell_w or 10) + 0.5)))
  local inner = box_w - 2
  local function clip(s)
    if #s > inner then return s:sub(1, inner) end
    return s
  end

  if virt_h <= 1 then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
      virt_text = { { clip('[img: ' .. name .. '  ' .. size .. ']'), hl } },
      virt_text_pos = 'overlay', priority = 260,
    })
    return
  end

  local name_text = '- img: ' .. name .. ' '
  local size_text = ' ' .. size .. ' '
  local function bar(open, fill, text, close)
    text = clip(text)
    local pad = math.max(0, inner - #text)
    return open .. text .. string.rep(fill, pad) .. close
  end

  -- Box content per visual row 0..virt_h-1.
  local box = {}
  box[0] = bar('+', '-', name_text, '+')
  box[virt_h - 1] = bar('+', '-', '', '+')
  for v = 1, virt_h - 2 do
    box[v] = bar('|', ' ', v == 1 and size_text or '', '|')
  end

  local function overlay(brow, text)
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, brow, 0, {
      virt_text = { { text, hl } }, virt_text_pos = 'overlay', priority = 260,
    })
  end

  local virt_lines = {}
  for v = 0, virt_h - 1 do
    if v == 0 then
      overlay(row, box[v])
    elseif v <= reserve_h - 1 then
      virt_lines[#virt_lines + 1] = { { box[v], hl } }
    else
      local src_index = v - (reserve_h - 1)
      if src_index < source_span then overlay(row + src_index, box[v]) end
    end
  end
  if #virt_lines > 0 then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0,
      { virt_lines = virt_lines, virt_lines_above = false })
  end
end

-- Terminal stub box drawn into the PlantUML preview float buffer (the GUI would
-- paint the image over the float). Fills exactly the place.width x place.height
-- geometry the placement logic already sized the window to -- no placement change.
function M.draw_stub_preview_box(buf, place, path)
  local w = math.max(2, place.width or 2)
  local h = math.max(1, place.height or 1)
  local name = vim.fn.fnamemodify(path or '?', ':t')
  local size = string.format('%dx%dpx', place.disp_w or 0, place.disp_h or 0)
  local function fit(s)
    if #s > w - 2 then return s:sub(1, w - 2) end
    return s .. string.rep(' ', w - 2 - #s)
  end
  local lines = {}
  if h == 1 then
    lines[1] = ('[' .. name .. ' ' .. size .. ']'):sub(1, w)
  else
    lines[1] = '+' .. string.rep('-', w - 2) .. '+'
    for i = 2, h - 1 do
      local text = (i == 2) and (' img: ' .. name) or ((i == 3) and (' ' .. size) or '')
      lines[i] = '|' .. fit(text) .. '|'
    end
    lines[h] = '+' .. string.rep('-', w - 2) .. '+'
  end
  -- Drop markdown ft so render-markdown/treesitter doesn't reflow the ASCII box
  -- (the `|...|` rows would otherwise be mistaken for a pipe table). Only assign
  -- when it actually differs: a FileType autocmd re-enters send_images
  -- synchronously, so churning the filetype every draw recurses to E218.
  if vim.bo[buf].filetype ~= '' then
    pcall(function() vim.bo[buf].filetype = '' end)
  end
  pcall(function() vim.bo[buf].modifiable = true end)
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  pcall(function() vim.bo[buf].modifiable = false end)
end

function M.compute_image_display_size(image, max_w_px, max_rows, cell_h)
  if not image or not image.source_width or not image.source_height or image.source_width <= 0 or image.source_height <= 0 then
    return nil
  end
  local display_w = math.min(image.source_width, math.max(1, math.floor(max_w_px or image.source_width)))
  local display_h = math.max(1, math.floor(display_w * image.source_height / image.source_width + 0.5))
  local virt_h = math.max(1, math.ceil(display_h / math.max(1, cell_h or 1)))
  if max_rows and max_rows > 0 and virt_h > max_rows then
    virt_h = max_rows
    display_h = virt_h * math.max(1, cell_h or 1)
    display_w = math.max(1, math.floor(display_h * image.source_width / image.source_height + 0.5))
    display_w = math.min(display_w, math.max(1, math.floor(max_w_px or display_w)))
  end
  return display_w, display_h
end

function M.layout_image_line(images, opts)
  opts = opts or {}
  local cell_w = math.max(1, tonumber(opts.cell_w) or 10)
  local cell_h = math.max(1, tonumber(opts.cell_h) or 18)
  local gap_px = math.max(0, tonumber(opts.gap_px) or cell_w)
  local max_ratio = tonumber(opts.max_ratio) or 1.0
  local max_rows = tonumber(opts.max_rows) or 30
  local base_grid_row = tonumber(opts.base_grid_row) or 0
  local clip_x = tonumber(opts.clip_x_px) or 0
  local clip_y = tonumber(opts.clip_y_px) or 0
  local clip_w = math.max(1, tonumber(opts.clip_width_px) or cell_w)
  local clip_h = math.max(1, tonumber(opts.clip_height_px) or cell_h)
  local text_left_px = tonumber(opts.text_left_px) or clip_x
  local text_right_px = tonumber(opts.text_right_px) or (clip_x + clip_w)
  local dest_y_px = tonumber(opts.dest_y_px) or (base_grid_row * cell_h)
  if text_right_px <= text_left_px then text_right_px = text_left_px + cell_w end

  table.sort(images, function(a, b)
    if a.col == b.col then return (a.path or '') < (b.path or '') end
    return (a.col or 0) < (b.col or 0)
  end)

  local layouts = {}
  local sized = {}
  local max_image_w = math.max(1, math.floor((text_right_px - text_left_px) * max_ratio))
  local common_h = 0
  local row_start_x = nil

  for _, image in ipairs(images) do
    local anchor_x = tonumber(image.anchor_x_px) or text_left_px
    anchor_x = math.max(text_left_px, math.min(anchor_x, text_right_px - 1))
    row_start_x = row_start_x or anchor_x
    local display_w, display_h = M.compute_image_display_size(image, max_image_w, max_rows, cell_h)
    if display_w and display_h then
      sized[#sized + 1] = { image = image, width = display_w, height = display_h }
      common_h = math.max(common_h, display_h)
    end
  end

  if #sized == 0 then return layouts, 1 end

  common_h = math.max(1, common_h)
  if max_rows and max_rows > 0 then common_h = math.min(common_h, max_rows * cell_h) end

  row_start_x = row_start_x or text_left_px
  local available_w = math.max(1, text_right_px - row_start_x)
  local function total_width_for(height)
    local total = math.max(0, #sized - 1) * gap_px
    for _, item in ipairs(sized) do
      total = total + math.max(1, math.floor(height * item.image.source_width / item.image.source_height + 0.5))
    end
    return total
  end

  local total_w = total_width_for(common_h)
  if total_w > available_w then
    common_h = math.max(1, math.floor(common_h * available_w / total_w))
    common_h = math.max(1, math.floor(common_h / cell_h) * cell_h)
  end

  local dest_x = row_start_x
  for _, item in ipairs(sized) do
    local display_w = math.max(1, math.floor(common_h * item.image.source_width / item.image.source_height + 0.5))
    layouts[#layouts + 1] = {
      image = item.image,
      grid_row = base_grid_row,
      grid_col = math.floor(dest_x / cell_w),
      dest_x_px = math.floor(dest_x + 0.5),
      dest_y_px = math.floor(dest_y_px + 0.5),
      display_width_px = display_w,
      display_height_px = common_h,
      clip_x_px = math.floor(clip_x + 0.5),
      clip_y_px = math.floor(clip_y + 0.5),
      clip_width_px = math.floor(clip_w + 0.5),
      clip_height_px = math.floor(clip_h + 0.5),
    }
    dest_x = dest_x + display_w + gap_px
  end

  return layouts, math.max(1, math.ceil(common_h / cell_h))
end

local function u32be(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u16be(s, i)
  local a, b = s:byte(i, i + 1)
  if not b then return nil end
  return a * 256 + b
end

local function u16le(s, i)
  local a, b = s:byte(i, i + 1)
  if not b then return nil end
  return a + b * 256
end

local function u24le(s, i)
  local a, b, c = s:byte(i, i + 2)
  if not c then return nil end
  return a + b * 256 + c * 65536
end

function M.read_image_size(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read(512 * 1024) or ''
  f:close()

  if data:sub(1, 8) == '\137PNG\r\n\026\n' and #data >= 24 then
    return { width = u32be(data, 17), height = u32be(data, 21), format = 'png' }
  end

  if data:sub(1, 2) == '\255\216' then
    local i = 3
    while i + 8 <= #data do
      if data:byte(i) ~= 0xFF then return nil end
      local marker = data:byte(i + 1)
      i = i + 2
      while marker == 0xFF and i <= #data do
        marker = data:byte(i)
        i = i + 1
      end
      if marker == 0xD9 or marker == 0xDA then return nil end
      local len = u16be(data, i)
      if not len or len < 2 or i + len - 1 > #data then return nil end
      if (marker >= 0xC0 and marker <= 0xC3) or
         (marker >= 0xC5 and marker <= 0xC7) or
         (marker >= 0xC9 and marker <= 0xCB) or
         (marker >= 0xCD and marker <= 0xCF) then
        return { width = u16be(data, i + 5), height = u16be(data, i + 3), format = 'jpeg' }
      end
      i = i + len
    end
  end

  if data:sub(1, 4) == 'RIFF' and data:sub(9, 12) == 'WEBP' then
    local chunk = data:sub(13, 16)
    if chunk == 'VP8X' and #data >= 30 then
      return { width = u24le(data, 25) + 1, height = u24le(data, 28) + 1, format = 'webp' }
    elseif chunk == 'VP8 ' and #data >= 30 then
      return { width = bitops.band(u16le(data, 27) or 0, 0x3FFF), height = bitops.band(u16le(data, 29) or 0, 0x3FFF), format = 'webp' }
    elseif chunk == 'VP8L' and #data >= 25 then
      local b1, b2, b3, b4 = data:byte(22, 25)
      if b1 then
        local width = 1 + (bitops.band(b2 or 0, 0x3F) * 256 + b1)
        local height = 1 + (bitops.band(b4 or 0, 0x0F) * 1024 + (b3 or 0) * 4 + bitops.rshift(bitops.band(b2 or 0, 0xC0), 6))
        return { width = width, height = height, format = 'webp' }
      end
    end
  end
  return nil
end

local function stable_hash(s)
  local h = 2166136261
  for i = 1, #s do
    h = (bitops.bxor(h, s:byte(i)) * 16777619) % 4294967296
  end
  return string.format('%08x', h)
end

function M.resolve_image_path(buf, raw_path)
  if raw_path == '' or raw_path:match('^%a[%w+.-]*://') then return nil end
  raw_path = raw_path:gsub('%%20', ' ')
  local expanded = vim.fn.expand(raw_path)
  if vim.fn.fnamemodify(expanded, ':p') == expanded then return vim.fn.fnamemodify(expanded, ':p') end

  local name = vim.api.nvim_buf_get_name(buf)
  local base = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  return vim.fn.fnamemodify(base .. '/' .. expanded, ':p')
end

local function add_markdown_image_link(buf, row0, col0, end_col, raw, result, extra)
  local path = M.resolve_image_path(buf, raw)
  if not path then return end

  local item = {
    row = row0,
    col = col0,
    end_col = end_col,
    raw_path = raw,
    path = path,
  }
  if extra then
    for k, v in pairs(extra) do item[k] = v end
  end
  item.source_span_height = math.max(1, tonumber(item.source_span_height) or 1)

  if vim.fn.filereadable(path) ~= 1 then
    item.error = 'not_found'
    result[#result + 1] = item
    return
  end

  local size = M.read_image_size(path)
  if size and size.width and size.height and size.width > 0 and size.height > 0 then
    item.source_width = size.width
    item.source_height = size.height
  else
    item.error = 'unsupported'
  end
  result[#result + 1] = item
end

function M.scan_markdown_image_text(buf, row0, text, result, opts)
  if type(text) ~= 'string' or text == '' then return end
  opts = opts or {}
  local base_col = math.max(0, tonumber(opts.base_col) or 0)
  local virtual = opts.virtual == true
  local search_at = 1
  while search_at <= #text do
    local s, e, raw = text:find('!%[[^%]]*%]%(([^%)%s]+)%)', search_at)
    if not s then break end

    local prefix = text:sub(1, s - 1)
    local prefix_width = vim.fn.strdisplaywidth(prefix)
    local match_width = vim.fn.strdisplaywidth(text:sub(s, e))
    local col0 = base_col + prefix_width
    local extra = nil
    if virtual then
      extra = {
        virtual = true,
        virtual_mark_col = base_col,
        virtual_prefix_width = prefix_width,
        virt_text_pos = opts.virt_text_pos,
        virt_text_win_col = opts.virt_text_win_col,
        source_span_height = opts.source_span_height,
      }
    else
      -- Real buffer text: remember byte offsets (s,e are byte positions in the
      -- line) so the link can be concealed via an extmark. col0/end_col are
      -- *display* columns and must not be used for byte-based extmark ranges.
      extra = {
        byte_col = s - 1,
        byte_end_col = e,
      }
    end
    add_markdown_image_link(buf, row0, col0, col0 + math.max(1, match_width), raw, result, extra)
    search_at = e + 1
  end
end

function M.virt_text_to_plain(virt_text)
  if type(virt_text) ~= 'table' then return '' end
  local parts = {}
  for _, chunk in ipairs(virt_text) do
    local text = type(chunk) == 'table' and chunk[1] or nil
    if type(text) == 'string' then parts[#parts + 1] = text end
  end
  return table.concat(parts)
end

function M.virt_lines_to_plain(virt_lines)
  if type(virt_lines) ~= 'table' then return {} end
  local lines = {}
  for _, row in ipairs(virt_lines) do
    local parts = {}
    if type(row) == 'table' then
      for _, chunk in ipairs(row) do
        local text = type(chunk) == 'table' and chunk[1] or nil
        if type(text) == 'string' then parts[#parts + 1] = text end
      end
    end
    lines[#lines + 1] = table.concat(parts)
  end
  return lines
end

extmark_virt_lines_sig = function(virt_lines)
  if type(virt_lines) ~= 'table' then return '' end
  local parts = {}
  for i, row in ipairs(virt_lines) do
    local chunks = {}
    if type(row) == 'table' then
      for _, chunk in ipairs(row) do
        local text = type(chunk) == 'table' and chunk[1] or nil
        local hl = type(chunk) == 'table' and chunk[2] or nil
        if type(text) == 'string' then
          chunks[#chunks + 1] = text .. ':' .. tostring(hl or '')
        end
      end
    end
    parts[#parts + 1] = tostring(i) .. '=' .. table.concat(chunks, ',')
  end
  return table.concat(parts, ';')
end

function M.collect_markdown_images(buf, start_row, end_row)
  local result = {}
  local name = vim.api.nvim_buf_get_name(buf)
  local ext = vim.fn.fnamemodify(name, ':e'):lower()
  if vim.bo[buf].filetype ~= 'markdown' and ext ~= 'md' and ext ~= 'markdown' then return result end
  if start_row >= end_row then return result end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, start_row, end_row, false)
  if not ok then return result end

  for i, line in ipairs(lines) do
    local row0 = start_row + i - 1
    M.scan_markdown_image_text(buf, row0, line, result, { base_col = 0 })
  end

  local ok_marks, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, { start_row, 0 }, { end_row, 0 }, { details = true })
  if ok_marks then
    for _, mark in ipairs(marks) do
      local row0 = mark[2]
      local col0 = mark[3]
      local details = mark[4] or {}
      if row0 and details.ns_id ~= image_ns and details.virt_text ~= nil then
        local text = M.virt_text_to_plain(details.virt_text)
        if text ~= '' then
          M.scan_markdown_image_text(buf, row0, text, result, {
            base_col = col0,
            virtual = true,
            virt_text_pos = details.virt_text_pos,
            virt_text_win_col = details.virt_text_win_col,
            source_span_height = M.markdown_plantuml_block_height(buf, row0),
          })
        end
      end
      if row0 and details.ns_id ~= image_ns and details.virt_lines ~= nil then
        local lines = M.virt_lines_to_plain(details.virt_lines)
        for idx, text in ipairs(lines) do
          if text ~= '' then
            M.scan_markdown_image_text(buf, row0 + idx - 1, text, result, {
              base_col = 0,
              virtual = true,
            })
          end
        end
      end
    end
  end

  return result
end

function M.ensure_image_namespace()
  if not image_ns then image_ns = vim.api.nvim_create_namespace('rendermark_neopp_images') end
  return image_ns
end

function M.image_error_text(image)
  if image.error == 'not_found' then
    return ' [neopp: image not found: ' .. (image.raw_path or image.path or '') .. ']'
  end
  return ' [neopp: image unsupported: ' .. (image.raw_path or image.path or '') .. ']'
end

function M.set_image_error_extmark(buf, image)
  local nsid = M.ensure_image_namespace()
  local opts = {
    virt_lines = { { { M.image_error_text(image), 'WarningMsg' } } },
    virt_lines_above = false,
  }
  if pcall(vim.api.nvim_buf_set_extmark, buf, nsid, image.row, image.end_col or image.col or 0, opts) then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, nsid, image.row, 0, opts)
end

function M.clear_image_extmarks()
  local nsid = image_ns
  if not nsid then return end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, nsid, 0, -1)
    end
  end
end

function M.clear_images_for_buf(buf)
  local nsid = image_ns
  if nsid and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, nsid, 0, -1)
  end
  -- The buffer's images are dropped on the next sync diff (their ids vanish from
  -- the payload). Schedule one so the GUI backend frees them promptly.
  vim.schedule(function() M.send_images() end)
end

-- Compute where a PlantUML preview float should sit relative to its source code
-- block. The block itself stays fully visible; the preview is attached adjacent on
-- the first of top/bottom/left/right that fits entirely within the editor screen.
function M.compute_preview_placement(ps, image, cell_w, cell_h)
  local src_win = ps.win
  local src_buf = ps.buf
  local start_row = ps.start_row
  local block_h = M.markdown_plantuml_block_height(src_buf, start_row) or 1
  local end_row = start_row + math.max(1, block_h) - 1

  local sp_top = M.safe_screenpos(src_win, start_row + 1, 1)
  if sp_top.row <= 0 then return nil end
  local block_top = sp_top.row - 1
  local sp_bot = M.safe_screenpos(src_win, end_row + 1, 1)
  local block_bottom = (sp_bot.row > 0) and (sp_bot.row - 1) or block_top

  local src_w = ps.w
  local first_line = (vim.api.nvim_buf_get_lines(src_buf, start_row, start_row + 1, false) or {})[1] or ''
  local leading = #(first_line:match('^%s*') or '')
  local sp_left = M.safe_screenpos(src_win, start_row + 1, leading + 1)
  local block_left = (sp_left.col and sp_left.col > 0)
    and (sp_left.col - 1)
    or ((tonumber(src_w.wincol) or 1) - 1 + (tonumber(src_w.textoff) or 0))

  local block_right = block_left
  local block_lines = vim.api.nvim_buf_get_lines(src_buf, start_row, end_row + 1, false) or {}
  for i, line in ipairs(block_lines) do
    local sp_end = M.safe_screenpos(src_win, start_row + i, #line + 1)
    if sp_end.col and sp_end.col > 0 then
      block_right = math.max(block_right, sp_end.col - 1)
    end
  end

  local cols = math.max(1, tonumber(vim.o.columns) or 1)
  local rows = math.max(1, (tonumber(vim.o.lines) or 1) - (tonumber(vim.o.cmdheight) or 0))

  -- Image size: shrink (aspect preserving) to fit the editor, then round the
  -- carrier window up to whole grid cells.
  local iw = math.max(1, tonumber(image.source_width) or 1)
  local ih = math.max(1, tonumber(image.source_height) or 1)
  local scale = math.min(1, (cols * cell_w) / iw, (rows * cell_h) / ih)
  local disp_w = math.max(1, math.floor(iw * scale))
  local disp_h = math.max(1, math.floor(ih * scale))
  local pw = math.max(1, math.min(cols, math.ceil(disp_w / cell_w)))
  local ph = math.max(1, math.min(rows, math.ceil(disp_h / cell_h)))

  local function fits_cols(c) return c >= 0 and c + pw <= cols end
  local function fits_rows(r) return r >= 0 and r + ph <= rows end

  local top_r, top_c = block_top - ph, math.min(block_left, cols - pw)
  local bot_r, bot_c = block_bottom + 1, top_c
  local left_c, left_r = block_left - pw, math.min(block_top, rows - ph)
  local right_c, right_r = block_right + 1, left_r

  local fr, fc
  if fits_rows(top_r) and fits_cols(top_c) then
    fr, fc = top_r, top_c
  elseif fits_rows(bot_r) and fits_cols(bot_c) then
    fr, fc = bot_r, bot_c
  elseif fits_cols(left_c) and fits_rows(left_r) then
    fr, fc = left_r, left_c
  elseif fits_cols(right_c) and fits_rows(right_r) then
    fr, fc = right_r, right_c
  else
    fr = math.max(0, math.min(top_r, rows - ph))
    fc = math.max(0, math.min(top_c, cols - pw))
  end

  return { row = fr, col = fc, width = pw, height = ph, disp_w = disp_w, disp_h = disp_h }
end

-- Move/resize the carrier float to the computed geometry. We remember what we last
-- applied per window so we only call nvim_win_set_config on an actual change,
-- avoiding a win_float_pos -> sync -> set_config feedback loop.
M._preview_float_geom = M._preview_float_geom or {}
function M.reposition_preview_float(win, place)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local key = tostring(win)
  local prev = M._preview_float_geom[key]
  if prev and prev.row == place.row and prev.col == place.col
      and prev.width == place.width and prev.height == place.height then
    return
  end
  local ok = pcall(vim.api.nvim_win_set_config, win, {
    relative = 'editor',
    row = place.row,
    col = place.col,
    width = place.width,
    height = place.height,
  })
  if ok then
    -- The carrier buffer holds the (long) image link on a single line. Once the
    -- float is narrowed and grown taller than one row, 'wrap' would spill that
    -- link into the rows below the image; disable it so only the image shows.
    pcall(vim.api.nvim_set_option_value, 'wrap', false, { win = win })
    M._preview_float_geom[key] = { row = place.row, col = place.col, width = place.width, height = place.height }
  end
end

function M.emit_preview_float(info, buf_images, payload, cell_w, cell_h)
  local ps = info.preview_source
  if not ps then return end

  -- The `wins` snapshot predates collect_plantuml_images, which may have just
  -- closed this float (the cursor left the block), wiping its window and buffer
  -- (bufhidden='wipe'). Operating on the dead buffer/window then errors
  -- (Invalid buffer id). Bail when the snapshot is stale.
  if not (vim.api.nvim_win_is_valid(info.win) and vim.api.nvim_buf_is_valid(info.buf)) then
    return
  end

  -- Resolve the preview image from the source metadata path directly. We must
  -- NOT depend on scanning the carrier float's buffer: only markdown buffers are
  -- scanned for image links (collect_markdown_images gates on filetype), so if
  -- anything leaves the float buffer non-markdown the scan returns nothing and
  -- the preview silently vanishes AND the float never gets repositioned (it stays
  -- at its seed spot). ps.path is authoritative, so size it from the file.
  local image
  if ps.path then
    local size = M.read_image_size(ps.path)
    if size and size.width and size.height then
      image = { path = ps.path, row = 0, col = 0,
                source_width = size.width, source_height = size.height }
    end
  end
  if not image then
    -- Fallback: a scanned image link from the carrier buffer (when it is markdown).
    for _, im in ipairs(buf_images[info.buf] or {}) do
      if not im.error and (not ps.path or im.path == ps.path)
          and im.source_width and im.source_height then
        image = im
        break
      end
    end
  end
  if not image then return end

  local place = M.compute_preview_placement(ps, image, cell_w, cell_h)
  if not place then return end
  M.reposition_preview_float(info.win, place)

  if M._stub_active then
    -- No pixels in a terminal: draw the box into the already-sized float instead.
    M.draw_stub_preview_box(info.buf, place, image.path)
    return
  end

  payload[#payload + 1] = {
    id = 'preview:' .. info.buf .. ':' .. stable_hash(image.path) .. ':' .. place.disp_w .. 'x' .. place.disp_h,
    buf = info.buf,
    row = image.row,
    col = image.col,
    grid_row = place.row,
    grid_col = place.col,
    win_left = place.col,
    win_width = place.width,
    text_offset = 0,
    path = image.path,
    source_width = image.source_width,
    source_height = image.source_height,
    dest_x_px = place.col * cell_w,
    dest_y_px = place.row * cell_h,
    display_width_px = place.disp_w,
    display_height_px = place.disp_h,
    clip_x_px = place.col * cell_w,
    clip_y_px = place.row * cell_h,
    clip_width_px = place.width * cell_w,
    clip_height_px = place.height * cell_h,
    virt_height = place.height,
    zindex = 200,
    above_floats = true,
  }
end

-- ===========================================================================
-- PlantUML rendering
--
-- ```plantuml fenced code blocks are converted to PNGs and rendered as ordinary
-- (non-virtual) inline images: the source block is concealed exactly like a real
-- image link, and the generated PNG is injected into the normal image pipeline.
-- When the cursor is inside a block the source is left raw (editable) and a
-- preview float is shown beside it instead.
-- ===========================================================================

local plantuml_states = {}
local plantuml_missing_notified = false
local plantuml_languages = { plantuml = true, puml = true, uml = true }

local function plantuml_norm_path(p)
  if not p or p == '' then return nil end
  return vim.fn.fnamemodify(p, ':p')
end

local function plantuml_jar()
  return vim.g.rendermark_plantuml_jar or vim.env.RENDERMARK_PLANTUML_JAR or vim.env.PLANTUML_JAR
end

function M.plantuml_resolve_command()
  local jar = plantuml_norm_path(plantuml_jar())
  if jar and vim.fn.filereadable(jar) == 1 then
    local java = vim.fn.exepath('java')
    if java ~= '' then return java, { '-jar', jar, '-tpng' } end
  end
  local wrapper = vim.fn.exepath('plantuml')
  if wrapper ~= '' then return wrapper, { '-tpng' } end
  return nil, nil, 'PlantUML disabled: install plantuml or set RENDERMARK_PLANTUML_JAR / PLANTUML_JAR.'
end

local function plantuml_lang_of(info)
  local lang = (info or ''):match('^([^%s`~]*)')
  return lang and plantuml_languages[lang:lower()] == true
end

function M.plantuml_find_blocks(buf)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or not lines then return {} end
  local blocks = {}
  local i = 1
  while i <= #lines do
    local char, len, info = markdown_fence(lines[i])
    if char and plantuml_lang_of(info) then
      local start = i - 1
      local j = i + 1
      while j <= #lines do
        local c2, l2 = markdown_fence(lines[j])
        if c2 == char and l2 and l2 >= len then break end
        j = j + 1
      end
      if j <= #lines then
        local body = {}
        for k = i + 1, j - 1 do body[#body + 1] = lines[k] end
        blocks[#blocks + 1] = {
          start_row = start,
          end_row = j - 1,
          lang = (info or ''):lower(),
          text = table.concat(body, '\n') .. '\n',
        }
        i = j + 1
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return blocks
end

local function plantuml_state_for(buf)
  local st = plantuml_states[buf]
  if st then return st end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  st = { temp_dir = dir, cache = {}, jobs = {}, float = nil }
  plantuml_states[buf] = st
  return st
end

local function plantuml_sanitize_error(text)
  if not text or text == '' then return 'render failed' end
  text = text:gsub('%z', '\n'):gsub('\r', ''):gsub('%s+$', '')
  return text == '' and 'render failed' or text
end

local function plantuml_run(buf, hash)
  local st = plantuml_state_for(buf)
  local entry = st.cache[hash]
  if not entry then return end
  local cmd, base_args, err = M.plantuml_resolve_command()
  if not cmd then
    entry.status = 'disabled'
    if not plantuml_missing_notified then
      plantuml_missing_notified = true
      vim.schedule(function() vim.notify(err, vim.log.levels.WARN) end)
    end
    return
  end
  vim.fn.writefile(vim.split(entry.text, '\n', { plain = true, trimempty = false }), entry.puml, 'b')
  local argv = vim.list_extend({ cmd }, vim.deepcopy(base_args))
  argv[#argv + 1] = entry.puml
  local ok, job = pcall(vim.system, argv, { text = true }, function(obj)
    vim.schedule(function()
      local st2 = plantuml_states[buf]
      if not st2 then return end
      st2.jobs[hash] = nil
      local e = st2.cache[hash]
      if not e then return end
      if obj.code == 0 and vim.fn.filereadable(e.png) == 1 then
        e.status = 'ready'
        e.error = nil
      else
        e.status = 'error'
        e.error = plantuml_sanitize_error(obj.stderr)
      end
      if vim.api.nvim_buf_is_valid(buf) then M.send_images() end
    end)
  end)
  if ok then
    st.jobs[hash] = { kill = function() pcall(function() job:kill(15) end) end }
  else
    entry.status = 'error'
    entry.error = 'failed to launch plantuml'
  end
end

local function plantuml_block_hash(block)
  return stable_hash(block.lang .. '\n' .. block.text)
end

local function plantuml_ensure_render(buf, block)
  local st = plantuml_state_for(buf)
  local hash = plantuml_block_hash(block)
  local entry = st.cache[hash]
  if entry then return entry end
  entry = {
    status = 'pending',
    text = block.text,
    puml = st.temp_dir .. '/' .. hash .. '.puml',
    png = st.temp_dir .. '/' .. hash .. '.png',
  }
  st.cache[hash] = entry
  plantuml_run(buf, hash)
  return entry
end

-- The block under the cursor changes text on every keystroke; debounce its
-- render so we don't spawn a PlantUML process per character. Returns the cached
-- entry if it already exists, otherwise nil (and schedules a render).
local function plantuml_debounce_active(buf, block)
  local st = plantuml_state_for(buf)
  local hash = plantuml_block_hash(block)
  if st.cache[hash] then return st.cache[hash] end
  st.active_pending = hash
  if not st.active_timer then st.active_timer = vim.uv.new_timer() end
  st.active_timer:stop()
  st.active_timer:start(400, 0, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if st.active_pending == hash and not st.cache[hash] then
      plantuml_ensure_render(buf, block)
      M.send_images()
    end
  end))
  return nil
end

local function plantuml_close_float(st)
  if not st or not st.float then return end
  if st.float.win and vim.api.nvim_win_is_valid(st.float.win) then
    pcall(vim.api.nvim_win_close, st.float.win, true)
  end
  if st.float.buf and vim.api.nvim_buf_is_valid(st.float.buf) then
    pcall(vim.api.nvim_buf_delete, st.float.buf, { force = true })
  end
  st.float = nil
end

-- Open (or refresh) the preview carrier float for the active block. The
-- emit_preview_float path repositions/sizes it; we only need a 1-cell seed
-- window carrying the block path metadata in a window variable.
local function plantuml_open_float(buf, win, block, png)
  local st = plantuml_state_for(buf)
  local line = (vim.api.nvim_buf_get_lines(buf, block.start_row, block.start_row + 1, false) or {})[1] or ''
  local meta = {
    buf = buf,
    win = win,
    start_row = block.start_row,
    anchor_col = #(line:match('^%s*') or ''),
    path = png,
  }
  if st.float and st.float.path == png
      and st.float.win and vim.api.nvim_win_is_valid(st.float.win) then
    pcall(function() vim.w[st.float.win].rendermark_plantuml_preview_source = meta end)
    return
  end
  plantuml_close_float(st)

  local sp = M.safe_screenpos(win, block.start_row + 1, 1)
  local seed = {
    relative = 'editor',
    row = math.max(0, (sp.row > 0 and sp.row - 1 or 0)),
    col = math.max(0, (sp.col > 0 and sp.col - 1 or 0)),
    width = 1,
    height = 1,
    style = 'minimal',
    focusable = false,
    zindex = 70,
  }
  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].buftype = 'nofile'
  vim.bo[fbuf].bufhidden = 'wipe'
  vim.bo[fbuf].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { '![plantuml](' .. png:gsub('\\', '/') .. ')' })
  vim.bo[fbuf].modifiable = false
  local ok, fwin = pcall(vim.api.nvim_open_win, fbuf, false, seed)
  if not ok then
    pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
    return
  end
  pcall(function() vim.w[fwin].rendermark_plantuml_preview_source = meta end)
  st.float = { buf = fbuf, win = fwin, path = png }
end

function M.plantuml_cleanup_buf(buf)
  local st = plantuml_states[buf]
  if not st then return end
  if st.active_timer then pcall(function() st.active_timer:stop(); st.active_timer:close() end) end
  for _, job in pairs(st.jobs) do if job.kill then job.kill() end end
  plantuml_close_float(st)
  if st.temp_dir then pcall(vim.fn.delete, st.temp_dir, 'rf') end
  plantuml_states[buf] = nil
end

-- Which block (if any) the cursor sits inside, for a window showing `buf`.
-- We must NOT key off the global current window alone: creating/repositioning
-- the preview float re-fires send_images via window autocmds while the float is
-- transiently the current window. Its buffer isn't `buf`, so keying off the
-- current window would report "no active block" and tear the float down every
-- other cycle (create/destroy flicker). Prefer the current window when it shows
-- `buf`; otherwise fall back to any window displaying `buf` (the real source
-- window), using that window's own cursor.
local function plantuml_active_block(buf, blocks)
  local cur = vim.api.nvim_get_current_win()
  local candidates
  if vim.api.nvim_win_is_valid(cur) and vim.api.nvim_win_get_buf(cur) == buf then
    candidates = { cur }
  else
    candidates = vim.fn.win_findbuf(buf)
  end
  for _, win in ipairs(candidates) do
    if vim.api.nvim_win_is_valid(win) then
      local row = vim.api.nvim_win_get_cursor(win)[1] - 1
      for _, block in ipairs(blocks) do
        if row >= block.start_row and row <= block.end_row then
          return block, win
        end
      end
    end
  end
  return nil, nil
end

-- Render/refresh all PlantUML blocks for a markdown buffer. Appends ready,
-- inactive blocks to `result` as non-virtual image items (concealed + drawn by
-- the normal image pipeline). Opens a preview float for the active block.
-- Collects per-block render errors into `errors`.
function M.collect_plantuml_images(buf, result, errors)
  local st_existing = plantuml_states[buf]
  local name = vim.api.nvim_buf_get_name(buf)
  local ext = vim.fn.fnamemodify(name, ':e'):lower()
  if vim.bo[buf].filetype ~= 'markdown' and ext ~= 'md' and ext ~= 'markdown' then
    if st_existing then plantuml_close_float(st_existing) end
    return
  end

  local blocks = M.plantuml_find_blocks(buf)
  if #blocks == 0 then
    if st_existing then plantuml_close_float(st_existing) end
    return
  end

  -- Concealing the source block requires conceallevel >= 2. Ensure it on every
  -- window showing this buffer so the source hides on its own (without depending
  -- on render-markdown.nvim or other plugins to raise it).
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) and (vim.wo[win].conceallevel or 0) < 2 then
      pcall(function() vim.wo[win].conceallevel = 2 end)
    end
  end

  local active_block, active_win = plantuml_active_block(buf, blocks)
  local active_floated = false

  for _, block in ipairs(blocks) do
    local is_active = active_block ~= nil and block.start_row == active_block.start_row

    if is_active then
      -- Leave the source raw for editing; show a preview float instead. The
      -- block text changes while typing, so debounce its render.
      local entry = plantuml_debounce_active(buf, block)
      if entry and entry.status == 'ready' then
        plantuml_open_float(buf, active_win, block, entry.png)
        active_floated = true
      end
    else
      local entry = plantuml_ensure_render(buf, block)
      if entry.status == 'ready' then
        local size = M.read_image_size(entry.png)
        if size and size.width and size.height then
          local first = (vim.api.nvim_buf_get_lines(buf, block.start_row, block.start_row + 1, false) or {})[1] or ''
          result[#result + 1] = {
            row = block.start_row,
            col = 0,
            end_col = math.max(1, vim.fn.strdisplaywidth(first)),
            raw_path = entry.png,
            path = entry.png,
            source_width = size.width,
            source_height = size.height,
            source_span_height = block.end_row - block.start_row + 1,
            plantuml = true,
            plantuml_end_row = block.end_row,
            virtual = false,
          }
        end
      elseif entry.status == 'error' and errors then
        errors[#errors + 1] = { buf = buf, row = block.end_row, msg = entry.error or 'render failed' }
      end
    end
  end

  if not active_floated then
    local st = plantuml_states[buf]
    if st then plantuml_close_float(st) end
  end
end

-- ===========================================================================
-- Master sync: build the image payload and drive vim.ui.img
-- ===========================================================================

-- Resolve a window's PlantUML preview-source metadata (set on the carrier float by
-- plantuml_open_float) into the normalized table emit_preview_float expects, or nil.
local function resolve_preview_source(win)
  local ok_source, source_meta = pcall(function()
    return vim.w[win].rendermark_plantuml_preview_source
  end)
  if not (ok_source and type(source_meta) == 'table'
      and source_meta.buf and vim.api.nvim_buf_is_valid(source_meta.buf)
      and source_meta.win and vim.api.nvim_win_is_valid(source_meta.win)) then
    return nil
  end
  local source_w = vim.fn.getwininfo(source_meta.win)
  if not (source_w and source_w[1]) then return nil end
  return {
    buf = source_meta.buf,
    win = source_meta.win,
    w = source_w[1],
    start_row = math.max(0, tonumber(source_meta.start_row) or 0),
    anchor_col = math.max(0, tonumber(source_meta.anchor_col) or 0),
    path = source_meta.path,
  }
end

-- Re-entrancy guard. send_images mutates buffers/windows (opens the preview
-- float, toggles its filetype, sets extmarks); those fire FileType/WinNew/etc
-- autocmds that synchronously call send_images again. Without this guard the
-- float-creation path recurses (open_float -> FileType=markdown -> send_images
-- -> open_float -> ...) until E218 "autocommand nesting too deep". A nested call
-- is always redundant -- the outer pass already reflects the latest state -- so
-- drop it.
function M.send_images()
  if M._send_images_active then return end
  M._send_images_active = true
  local ok, err = pcall(M._send_images_impl)
  M._send_images_active = false
  if not ok then error(err) end
end

function M._send_images_impl()
  if not img_available() then return end

  local enabled = vim.g.neopp_images_enabled
  if enabled == false then
    M.clear_image_extmarks()
    image_reservation_sig = ''
    clear_all_images()
    return
  end

  local payload = {}
  local cell_w = tonumber(vim.g.neopp_cell_width_px) or 10
  local cell_h = tonumber(vim.g.neopp_cell_height_px) or 18
  local max_ratio = tonumber(vim.g.neopp_image_max_width_ratio) or 1.0
  local max_rows = tonumber(vim.g.neopp_image_max_height_rows) or 30
  local gap_px = tonumber(vim.g.neopp_image_gap_px) or cell_w
  local buf_ranges = {}
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local w = vim.fn.getwininfo(win)
    if w and w[1] then
      local info = w[1]
      local buf = vim.api.nvim_win_get_buf(win)
      local ok_config, win_config = pcall(vim.api.nvim_win_get_config, win)
      local above_floats = ok_config and win_config and win_config.relative and win_config.relative ~= ''
      local preview_source = resolve_preview_source(win)
      wins[#wins + 1] = { win = win, w = info, buf = buf, above_floats = above_floats, preview_source = preview_source }
      local start_row = math.max(0, info.topline - 1 - max_rows - 1)
      local end_row = math.max(start_row, info.botline)
      local range = buf_ranges[buf]
      if range then
        range.start_row = math.min(range.start_row, start_row)
        range.end_row = math.max(range.end_row, end_row)
      else
        buf_ranges[buf] = { start_row = start_row, end_row = end_row }
      end
    end
  end

  local buf_images = {}
  local plantuml_errors = {}
  for buf, range in pairs(buf_ranges) do
    if vim.api.nvim_buf_is_valid(buf) then
      buf_images[buf] = M.collect_markdown_images(buf, range.start_row, range.end_row)
      M.collect_plantuml_images(buf, buf_images[buf], plantuml_errors)
    end
  end

  -- collect_plantuml_images may have just created the preview carrier float for an
  -- active block. The `wins` snapshot above predates that, so without this the float
  -- only gets sized/drawn one cycle late -- with the cursor idle nothing re-triggers,
  -- leaving the 1x1 seed float (a single concealed char) on screen. Append any
  -- preview-source float that isn't already in the snapshot so emit_preview_float
  -- runs for it this cycle.
  do
    local seen = {}
    for _, info in ipairs(wins) do seen[info.win] = true end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if not seen[win] then
        local preview_source = resolve_preview_source(win)
        if preview_source then
          local w = vim.fn.getwininfo(win)
          if w and w[1] then
            wins[#wins + 1] = { win = win, w = w[1], buf = vim.api.nvim_win_get_buf(win),
                                above_floats = true, preview_source = preview_source }
          end
        end
      end
    end
  end

  local has_error_extmarks = false
  local image_reservations = {}
  local image_conceals = {}
  local reservation_carry_h = 0
  local function remember_image_reservation(win, buf, row, virt_h, source_span_height, label)
    local reserve_row = row
    local reserve_above = false
    local reserve_h = math.max(1, (virt_h or 1) - math.max(1, source_span_height or 1) + 1)

    local ok, fold = pcall(vim.api.nvim_win_call, win, function()
      return { start = vim.fn.foldclosed(row + 1), finish = vim.fn.foldclosedend(row + 1) }
    end)
    if ok and fold and fold.start and fold.start > 0 and fold.finish and fold.finish >= fold.start then
      local line_count = vim.api.nvim_buf_line_count(buf)
      -- A folded block collapses to a single display row that the image is
      -- drawn over. Reserving virt_h virtual lines above the following line
      -- seats trailing text directly under the image bottom with no extra gap.
      reserve_h = math.max(1, virt_h or 1)
      if fold.finish < line_count then
        reserve_row = fold.finish
        reserve_above = true
      end
    end

    -- If the reservation anchor lands inside a *closed fold* (the next block is
    -- itself a folded image block stacked directly below this one), nvim will not
    -- render virt_lines there -- they are swallowed by that fold, so no space gets
    -- reserved between the two fold lines. Carry this block's height forward and
    -- fold it into the next anchor that does render, so trailing buffer text still
    -- clears the whole stack of images instead of being drawn over.
    local hidden = false
    local okc, fc = pcall(vim.api.nvim_win_call, win, function()
      return vim.fn.foldclosed(reserve_row + 1)
    end)
    if okc and type(fc) == 'number' and fc > 0 then hidden = true end
    if hidden then
      -- The hidden block's own fold line still occupies one display row (covered
      -- by the image stacked above it), so it shifts the next renderable anchor
      -- down by one. Carry one less row to avoid an extra blank gap per block.
      reservation_carry_h = reservation_carry_h + math.max(0, reserve_h - 1)
      return
    end
    reserve_h = reserve_h + reservation_carry_h
    reservation_carry_h = 0

    image_reservations[buf] = image_reservations[buf] or {}
    local key = tostring(reserve_row) .. ':' .. tostring(reserve_above)
    local current = image_reservations[buf][key]
    if current then
      current.reserve_h = math.max(current.reserve_h, reserve_h)
      current.label = current.label or label
    else
      image_reservations[buf][key] = {
        row = reserve_row,
        reserve_h = reserve_h,
        above = reserve_above,
        label = label,
      }
    end
  end

  for _, info in ipairs(wins) do
    reservation_carry_h = 0
    -- PlantUML preview floats are placed adjacent to their source block by a
    -- dedicated path; skip the normal inline-image flow for them.
    if info.preview_source then
      M.emit_preview_float(info, buf_images, payload, cell_w, cell_h)
      goto continue_win
    end

    local stack_bottom_grid_row = nil
    local by_row = {}
    for _, image in ipairs(buf_images[info.buf] or {}) do
      if image.error then
        M.set_image_error_extmark(info.buf, image)
        has_error_extmarks = true
        goto continue_image
      end
      local measured_image = image
      local measure_win = info.win
      local measure_buf = info.buf
      local measure_w = info.w
      measured_image.measure_win = measure_win
      measured_image.measure_buf = measure_buf
      measured_image.measure_w = measure_w
      measured_image.above_floats = info.above_floats == true

      local lnum = measured_image.row + 1
      if lnum >= math.max(1, measure_w.topline - max_rows - 1) and lnum <= measure_w.botline then
        by_row[measured_image.row] = by_row[measured_image.row] or {}
        by_row[measured_image.row][#by_row[measured_image.row] + 1] = measured_image
      end
      ::continue_image::
    end

    local rows = {}
    for row, _ in pairs(by_row) do rows[#rows + 1] = row end
    table.sort(rows)

    for _, row in ipairs(rows) do
      local line_images = by_row[row]
      local first_image = line_images[1] or {}
      local measure_win = first_image.measure_win or info.win
      local measure_buf = first_image.measure_buf or info.buf
      local measure_w = first_image.measure_w or info.w
      local above_floats = first_image.above_floats == true
      local lnum = row + 1
      local sp_line = M.safe_screenpos(measure_win, lnum, 1)
      if sp_line.row > 0 then
        for _, image in ipairs(line_images) do
          local screen_col = ((image.virtual and image.virtual_mark_col) or image.col or 0) + 1
          local sp_image = M.safe_screenpos(measure_win, lnum, screen_col)
          local image_col = M.virtual_image_anchor_display_col(measure_buf, image.row, image, sp_image, measure_w)
          image.anchor_x_px = (image_col > 0 and (image_col - 1) or (measure_w.wincol - 1 + measure_w.textoff)) * cell_w
        end

        local win_left_col = measure_w.wincol - 1
        local win_top_row = measure_w.winrow and (measure_w.winrow - 1) or (sp_line.row - 1)
        local text_left_px = (win_left_col + measure_w.textoff) * cell_w
        local text_right_px = (win_left_col + measure_w.width) * cell_w
        local clip_x_px = win_left_col * cell_w
        local clip_y_px = win_top_row * cell_h
        local clip_w_px = math.max(1, measure_w.width * cell_w)
        local clip_h_px = math.max(1, (measure_w.height or (measure_w.botline - measure_w.topline + 1)) * cell_h)
        local layout_max_rows = max_rows
        local layout_text_right_px = text_right_px
        if above_floats then
          local screen_max_w_px = math.max(1, (tonumber(vim.o.columns) or 1) * cell_w)
          local screen_max_h_rows = math.max(1, (tonumber(vim.o.lines) or 1) - (tonumber(vim.o.cmdheight) or 0))
          if layout_max_rows and layout_max_rows > 0 then
            layout_max_rows = math.min(layout_max_rows, screen_max_h_rows)
          else
            layout_max_rows = screen_max_h_rows
          end
          if layout_text_right_px - text_left_px > screen_max_w_px then
            layout_text_right_px = text_left_px + screen_max_w_px
          end
        end
        local source_grid_row = sp_line.row - 1
        -- Stack vertically below the previous block's image when this block's
        -- anchor is bunched against it (two adjacent closed folds, whose
        -- separating virt_lines nvim refuses to render) so images never overlap.
        local layout_grid_row = source_grid_row
        if stack_bottom_grid_row and source_grid_row < stack_bottom_grid_row then
          layout_grid_row = stack_bottom_grid_row
        end
        local layouts, image_rows = M.layout_image_line(line_images, {
          cell_w = cell_w,
          cell_h = cell_h,
          gap_px = gap_px,
          max_ratio = max_ratio,
          max_rows = layout_max_rows,
          base_grid_row = layout_grid_row,
          dest_y_px = layout_grid_row * cell_h,
          clip_x_px = clip_x_px,
          clip_y_px = clip_y_px,
          clip_width_px = clip_w_px,
          clip_height_px = clip_h_px,
          text_left_px = text_left_px,
          text_right_px = layout_text_right_px,
        })

        local virt_h = image_rows
        if #layouts > 0 then
          stack_bottom_grid_row = layout_grid_row + image_rows
          local source_span_height = nil
          for _, layout in ipairs(layouts) do
            source_span_height = math.min(source_span_height or math.huge, layout.image.source_span_height or 1)
          end
          local label = nil
          if M._stub_active then
            local first = layouts[1]
            local path = first.image.path or first.image.raw_path or '?'
            label = {
              name = vim.fn.fnamemodify(path, ':t'),
              w_px = first.display_width_px or 0,
              h_px = first.display_height_px or 0,
              is_plantuml = first.image.plantuml == true,
              source_span = source_span_height or 1,
              virt_h = virt_h,
            }
          end
          remember_image_reservation(measure_win, measure_buf, row, virt_h, source_span_height or 1, label)
        end

        for idx, layout in ipairs(layouts) do
          local image = layout.image
          local payload_buf = image.payload_buf or info.buf
          -- Conceal the raw link text (and its highlight) for real buffer links so
          -- it never reaches the grid under the image overlay.
          if not image.virtual and image.byte_col then
            image_conceals[payload_buf] = image_conceals[payload_buf] or {}
            image_conceals[payload_buf][#image_conceals[payload_buf] + 1] = {
              row = image.row,
              col = image.byte_col,
              end_col = image.byte_end_col,
            }
          elseif image.plantuml then
            -- Conceal every source line of the PlantUML block (fence + body) so the
            -- raw code never shows under/around the generated image.
            image_conceals[payload_buf] = image_conceals[payload_buf] or {}
            local last = math.max(image.row, tonumber(image.plantuml_end_row) or image.row)
            local block_lines = vim.api.nvim_buf_get_lines(payload_buf, image.row, last + 1, false) or {}
            for li, line in ipairs(block_lines) do
              image_conceals[payload_buf][#image_conceals[payload_buf] + 1] = {
                row = image.row + li - 1,
                col = 0,
                end_col = #line,
              }
            end
          end
          payload[#payload + 1] = {
            id = 'buf:' .. payload_buf .. ':' .. image.row .. ':' .. image.col .. ':' .. stable_hash(image.path) .. ':' .. layout.display_width_px .. 'x' .. layout.display_height_px,
            buf = payload_buf,
            row = image.row,
            col = image.col,
            grid_row = layout.grid_row,
            grid_col = layout.grid_col,
            -- Grid row where the link's TEXT renders (the source line). Differs from
            -- grid_row when the image is reserved/stacked below its source line; the
            -- renderer occludes the link text on THIS row, not the image's row.
            text_grid_row = source_grid_row,
            -- Global grid columns covering the rendered link text on text_grid_row.
            -- Spans the link width so the renderer occludes the full link width incl.
            -- fold-fill / path tail for virtual overlays.
            text_col = layout.grid_col,
            text_end_col = layout.grid_col + math.max(1, (image.end_col or image.col) - image.col),
            virtual = image.virtual == true,
            win_left = win_left_col,
            win_width = measure_w.width,
            text_offset = measure_w.textoff,
            path = image.path,
            source_width = image.source_width,
            source_height = image.source_height,
            dest_x_px = layout.dest_x_px,
            dest_y_px = layout.dest_y_px,
            display_width_px = layout.display_width_px,
            display_height_px = layout.display_height_px,
            clip_x_px = layout.clip_x_px,
            clip_y_px = layout.clip_y_px,
            clip_width_px = layout.clip_width_px,
            clip_height_px = layout.clip_height_px,
            virt_height = virt_h,
            zindex = 50 + idx,
            above_floats = above_floats,
          }
        end
      end
    end
    ::continue_win::
  end

  local reservation_parts = {}
  for buf, reservations in pairs(image_reservations) do
    for _, reservation in pairs(reservations) do
      reservation_parts[#reservation_parts + 1] = table.concat({
        tostring(buf),
        tostring(reservation.row),
        tostring(reservation.reserve_h),
        tostring(reservation.above),
      }, ':')
    end
  end
  table.sort(reservation_parts)
  local new_reservation_sig = table.concat(reservation_parts, '|')
  local reservation_changed = new_reservation_sig ~= image_reservation_sig

  for buf, _ in pairs(buf_ranges) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ensure_image_namespace(), 0, -1)
    end
  end
  for buf, reservations in pairs(image_reservations) do
    for _, reservation in pairs(reservations) do
      local label = reservation.label
      if M._stub_active and label and not reservation.above then
        -- Footprint-faithful box across the concealed source rows + reserved
        -- virt_lines, for both PlantUML blocks and inline image links. Allocation
        -- (reserve_h/anchor/count) is unchanged.
        M.draw_stub_footprint_box(buf, image_ns, reservation, cell_w)
      else
        local virt_lines = M.make_virt_lines(reservation.reserve_h, label)
        if #virt_lines > 0 then
          pcall(vim.api.nvim_buf_set_extmark, buf, image_ns, reservation.row, 0,
            { virt_lines = virt_lines, virt_lines_above = reservation.above })
        end
      end
    end
  end
  for buf, conceals in pairs(image_conceals) do
    for _, c in ipairs(conceals) do
      pcall(vim.api.nvim_buf_set_extmark, buf, image_ns, c.row, c.col, {
        end_col = c.end_col,
        conceal = '',
        priority = 250,
      })
    end
  end
  for _, e in ipairs(plantuml_errors) do
    if vim.api.nvim_buf_is_valid(e.buf) then
      pcall(vim.api.nvim_buf_set_extmark, e.buf, image_ns, e.row, 0, {
        virt_lines = { { { ' [plantuml: ' .. e.msg .. ']', 'WarningMsg' } } },
        virt_lines_above = false,
      })
      has_error_extmarks = true
    end
  end

  if reservation_changed then
    -- Reserving/altering virt_lines shifts every following row; drop all images
    -- first so none are drawn at stale positions, then re-sync once the new
    -- layout has settled.
    image_reservation_sig = new_reservation_sig
    clear_all_images()
  else
    apply_payload(payload)
  end

  if reservation_changed then
    vim.schedule(function()
      pcall(vim.cmd, 'redraw!')
      if not image_resyncing then
        image_resyncing = true
        pcall(M.send_images)
        image_resyncing = false
      end
      notify_redraw()
    end)
  elseif has_error_extmarks or #payload > 0 then
    notify_redraw()
  end
end

-- ===========================================================================
-- Change detection + autocmds
-- ===========================================================================

function M.get_layout_sig()
  local s = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, w)
    local i = vim.fn.getwininfo(w)
    if ok_cfg and cfg and i and i[1] then
      local info = i[1]
      local buf = vim.api.nvim_win_get_buf(w)
      local relative = cfg.relative or ''
      local row = relative ~= '' and cfg.row or (info.winrow and (info.winrow - 1) or 0)
      local col = relative ~= '' and cfg.col or (info.wincol and (info.wincol - 1) or 0)
      local width = cfg.width or info.width or 0
      local height = cfg.height or info.height or 0
      local ft = vim.bo[buf].filetype or ''
      local changedtick = vim.b[buf].changedtick or 0
      s[#s + 1] = table.concat({
        tostring(w), tostring(buf), tostring(relative), tostring(row), tostring(col),
        tostring(width), tostring(height), tostring(info.topline or 0),
        tostring(info.botline or 0), ft, tostring(changedtick),
      }, ':')
    end
  end
  table.sort(s)
  return table.concat(s, '|')
end

local function get_image_anchor_sig()
  local ranges = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local wi = vim.fn.getwininfo(win)
    if wi and wi[1] then
      local w = wi[1]
      local buf = vim.api.nvim_win_get_buf(win)
      local ft = vim.bo[buf].filetype or ''
      if ft == 'markdown' or ft == 'rmd' or ft == 'quarto' or ft == 'vimwiki' then
        local start_row = math.max(0, w.topline - 2)
        local end_row = math.max(start_row, w.botline)
        local range = ranges[buf]
        if range then
          range.start_row = math.min(range.start_row, start_row)
          range.end_row = math.max(range.end_row, end_row)
        else
          ranges[buf] = { start_row = start_row, end_row = end_row }
        end
      end
    end
  end

  local parts = {}
  for buf, range in pairs(ranges) do
    parts[#parts + 1] = tostring(buf) .. '=' .. M.image_anchor_extmark_sig(buf, range.start_row, range.end_row)
  end
  table.sort(parts)
  return table.concat(parts, '#')
end

function M.get_layout_sync_sig()
  return M.get_layout_sig() .. '#' .. get_image_anchor_sig()
end

function M.schedule_image_sync()
  if image_sync_pending then return end
  image_sync_pending = true
  vim.schedule(function()
    image_sync_pending = false
    layout_sig = M.get_layout_sync_sig()
    M.send_images()
    notify_redraw()
  end)
end

function M.handle_safestate()
  local sig = M.get_layout_sync_sig()
  if sig ~= layout_sig then
    layout_sig = sig
    M.schedule_image_sync()
  end
end

function M.setup()
  install_terminal_stub()
  if img_available() then
    M._init()
  else
    -- neopp installs vim.ui.img at UI attach, which happens after startup has
    -- sourced plugins/user config. Defer real init until neopp signals ready.
    -- (If we are not running under neopp, NeoppReady never fires and this module
    -- stays dormant, which is correct.)
    vim.api.nvim_create_autocmd('User', {
      pattern = 'NeoppReady', once = true,
      callback = function() M._init() end,
    })
  end
end

function M._init()
  if not img_available() then return end
  M.ensure_image_namespace()
  autocmd_group = vim.api.nvim_create_augroup('rendermark_image', { clear = true })

  vim.api.nvim_create_autocmd(
    { 'BufEnter', 'BufReadPost', 'FileType', 'TextChanged', 'TextChangedI' },
    { group = autocmd_group, callback = function() M.send_images() end })

  vim.api.nvim_create_autocmd(
    { 'WinScrolled', 'WinResized', 'WinNew', 'BufWinEnter', 'WinClosed' },
    { group = autocmd_group, callback = function() M.schedule_image_sync() end })

  vim.api.nvim_create_autocmd(
    { 'CursorMoved', 'CursorMovedI' },
    { group = autocmd_group, callback = function()
      vim.schedule(function()
        M.send_images()
        notify_redraw()
      end)
    end })

  vim.api.nvim_create_autocmd(
    { 'BufUnload', 'BufDelete', 'BufWipeout' },
    { group = autocmd_group, callback = function(args)
      M.clear_images_for_buf(args.buf)
      M.plantuml_cleanup_buf(args.buf)
    end })

  vim.api.nvim_create_autocmd('SafeState', { group = autocmd_group, callback = M.handle_safestate })

  -- neopp republishes cell metrics on font/DPI change.
  vim.api.nvim_create_autocmd('User', {
    group = autocmd_group, pattern = 'NeoppMetrics',
    callback = function() M.send_images() end,
  })

  M.send_images()
  layout_sig = M.get_layout_sync_sig()
end

return M
