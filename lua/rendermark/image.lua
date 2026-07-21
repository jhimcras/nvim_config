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

local util = require('util')
local image_backend = require('rendermark.image.backend')
local image_scan = require('rendermark.image.scan')
local image_size = require('rendermark.image.size')

local image_ns
local layout_sig = ''
local image_reservation_sig = ''
local image_resyncing = false
local image_sync_pending = false
local autocmd_group
local bitops = bit or bit32
local extmark_virt_lines_sig
local cursor_block_sig  -- last seen M.cursor_active_block_sig(); gates CursorMoved
local stub_source_rows = {}  -- buf -> set of 0-based stub image source rows (last render)
local backend = image_backend.new(M)
local read_image_size_impl = image_size.new_reader()

local function trim(s)
  return (s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

-- ---------------------------------------------------------------------------
-- PlantUML preview configuration (set via require'rendermark'.setup{ plantuml =
-- { preview = {...} } }). The "preview" is the diagram shown for the block the
-- cursor is editing -- either a float beside the block (default) or a dedicated
-- non-modifiable split window with the image centered.
-- ---------------------------------------------------------------------------
local preview_defaults = {
  mode = 'float',            -- 'float' | 'split'
  auto = true,               -- auto-open the preview when the cursor enters a block
  split = {
    position = 'right',      -- 'left'|'right' (vertical) | 'top'|'bottom' (horizontal)
    size = 0.5,              -- 'half' | 0<n<1 fraction of editor | n>=1 absolute cells
    lifecycle = 'cursor',    -- 'cursor' (close when cursor leaves the block) | 'persistent' (reuse pane, keep last when outside)
  },
}
local preview_cfg = vim.deepcopy(preview_defaults)

-- nil  => follow preview_cfg.auto; true/false => explicit Show/Hide override.
M._preview_user = nil

-- Normalize a user-supplied preview opts table, falling back to defaults for any
-- invalid field. `position` alone implies the split direction.
local function normalize_preview(opts)
  local cfg = vim.tbl_deep_extend('force', vim.deepcopy(preview_defaults), opts or {})
  if cfg.mode ~= 'split' then cfg.mode = 'float' end
  cfg.auto = cfg.auto ~= false
  local sp = cfg.split
  local pos = tostring(sp.position or 'right'):lower()
  if pos ~= 'left' and pos ~= 'right' and pos ~= 'top' and pos ~= 'bottom' then
    pos = 'right'
  end
  sp.position = pos
  sp.direction = (pos == 'left' or pos == 'right') and 'vertical' or 'horizontal'
  if sp.size == 'half' then sp.size = 0.5 end
  if type(sp.size) ~= 'number' or sp.size <= 0 then sp.size = 0.5 end
  if sp.lifecycle ~= 'persistent' then sp.lifecycle = 'cursor' end
  return cfg
end

function M.preview_config() return preview_cfg end

-- Whether the active-block preview should currently be shown: an explicit
-- Show/Hide override wins, otherwise follow the configured auto flag.
function M.preview_active()
  if M._preview_user ~= nil then return M._preview_user end
  return preview_cfg.auto ~= false
end

-- Resolve a split `size` (fraction <1 or absolute cells >=1) against the host
-- editor extent (columns for a vertical split, rows for a horizontal one).
function M.resolve_split_size(size, total)
  total = math.max(1, tonumber(total) or 1)
  local n = tonumber(size)
  if not n or n <= 0 then n = 0.5 end
  local cells = (n < 1) and math.floor(total * n + 0.5) or math.floor(n + 0.5)
  return math.max(1, math.min(total, cells))
end

-- Fit an image (aspect-preserving) inside a screen-cell rect and center it.
-- rect = { row, col, width, height } in 0-based screen grid cells. Returns the
-- same placement shape compute_preview_placement produces.
function M.center_in_rect(rect, image, cell_w, cell_h)
  cell_w = math.max(1, tonumber(cell_w) or 10)
  cell_h = math.max(1, tonumber(cell_h) or 18)
  local avail_w = math.max(1, tonumber(rect.width) or 1)
  local avail_h = math.max(1, tonumber(rect.height) or 1)
  local iw = math.max(1, tonumber(image.source_width) or 1)
  local ih = math.max(1, tonumber(image.source_height) or 1)
  local scale = math.min(1, (avail_w * cell_w) / iw, (avail_h * cell_h) / ih)
  local disp_w = math.max(1, math.floor(iw * scale))
  local disp_h = math.max(1, math.floor(ih * scale))
  local pw = math.max(1, math.min(avail_w, math.ceil(disp_w / cell_w)))
  local ph = math.max(1, math.min(avail_h, math.ceil(disp_h / cell_h)))
  return {
    row = (tonumber(rect.row) or 0) + math.floor((avail_h - ph) / 2),
    col = (tonumber(rect.col) or 0) + math.floor((avail_w - pw) / 2),
    width = pw, height = ph, disp_w = disp_w, disp_h = disp_h,
  }
end

-- Choose the preview split orientation from the SOURCE window's pixel aspect.
-- A portrait (taller-than-wide) window opens a vertical split (preview on the
-- right); a landscape window opens a horizontal split (preview on top). Cells
-- are not square, so compare pixel extents, not raw cell counts.
function M.smart_split_direction(w_cells, h_cells, cell_w, cell_h)
  cell_w = math.max(1, tonumber(cell_w) or 10)
  cell_h = math.max(1, tonumber(cell_h) or 18)
  local w_px = math.max(1, tonumber(w_cells) or 1) * cell_w
  local h_px = math.max(1, tonumber(h_cells) or 1) * cell_h
  return (w_px >= h_px) and 'vertical' or 'horizontal'
end

-- ---------------------------------------------------------------------------
-- GUI image backend (vim.ui.img) plumbing
-- ---------------------------------------------------------------------------

-- True when the image pipeline will actually decorate image-link lines (real neopp
-- backend or terminal stub, and not globally disabled). wrap.lua uses this to decide
-- whether to skip image-link lines (image.lua owns their layout) or wrap them itself.
function M.is_active()
  return backend.is_active()
end

local function install_terminal_stub()
  backend.install_terminal_stub()
end

-- Diff a freshly computed payload against the live set: set every entry (its
-- position/size may have changed) and del ids that are no longer present.
local function apply_payload(payload)
  backend.apply_payload(payload)
end

local function clear_all_images()
  backend.clear_all_images()
end

local function delete_image(id)
  backend.delete_image(id)
end

local function notify_redraw()
  backend.notify_redraw()
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

-- Grid row (0-based screen row, possibly negative) where a buffer line scrolled
-- above the window top would sit. screenpos() returns 0 for off-screen lines, so
-- for a PlantUML block whose top fence is above the viewport the anchor row is
-- synthesized from the display height of the hidden lines. nvim_win_text_height
-- counts folds, wraps and virt_lines, but NOT virt_lines below end_row -- so end
-- the range at the topline line with end_vcol = 0: that contributes zero rows of
-- the topline itself while still counting the fill above it. Subtracting the
-- window's topfill (the part of that fill still visible at the top) leaves the
-- rows truly hidden. The result may be negative / point into a window above;
-- clip_* confines drawing.
function M.offscreen_anchor_grid_row(win, w, anchor_row)
  local topline = tonumber(w and w.topline) or 1
  if anchor_row + 1 >= topline then return nil end
  local ok, hidden = pcall(function()
    local h = vim.api.nvim_win_text_height(win, { start_row = anchor_row, end_row = topline - 1, end_vcol = 0 })
    local topfill = vim.api.nvim_win_call(win, function()
      return vim.fn.winsaveview().topfill
    end)
    return (tonumber(h and h.all) or 0) - (tonumber(topfill) or 0)
  end)
  if not ok or type(hidden) ~= 'number' or hidden <= 0 then return nil end
  return ((tonumber(w.winrow) or 1) - 1) - hidden
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
-- anchor buffer line; the anchor line keeps the (concealed) source link. Only
-- used for the fold-above reservation path; it labels just the first image on
-- the line (the footprint box handles multiple images side-by-side).
function M.make_stub_box(h, label)
  local hl = 'Comment'
  local n = h - 1  -- number of virt_lines to emit
  if n < 1 then return {} end
  local first = (label.boxes or {})[1] or {}
  local name = first.name or '?'
  local size = string.format('%dx%dpx  (%d rows)', first.w_px or 0, first.h_px or 0, h)
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

-- Greedy display-width wrap of `text` into rows of at most `width` cells. Breaks
-- at whitespace when possible, hard-breaks over-long words / CJK. Mirrors wrap.lua's
-- wrap_indices but returns plain strings (kept local to avoid a circular require).
-- Always returns at least one row (possibly '').
local function wrap_text_to_width(text, width)
  width = math.max(1, width)
  local chars = vim.fn.split(text or '', '\\zs')
  if #chars == 0 then return { '' } end
  local rows = {}
  local line_start = 1
  local cur_w = 0
  local last_space = nil
  local function push(stop_exclusive)
    local e = stop_exclusive - 1
    while e >= line_start and chars[e]:match('%s') do e = e - 1 end
    local parts = {}
    for k = line_start, e do parts[#parts + 1] = chars[k] end
    rows[#rows + 1] = table.concat(parts)
  end
  local i = 1
  while i <= #chars do
    local c = chars[i]
    local w = vim.fn.strdisplaywidth(c)
    if c:match('%s') then last_space = i end
    if cur_w + w > width and i > line_start then
      local stop, next_start
      if last_space and last_space >= line_start then
        stop = last_space
        next_start = last_space + 1
        while next_start <= #chars and chars[next_start]:match('%s') do next_start = next_start + 1 end
      else
        stop = i
        next_start = i
      end
      push(stop)
      line_start = next_start
      last_space = nil
      cur_w = 0
      i = next_start
    else
      cur_w = cur_w + w
      i = i + 1
    end
  end
  if line_start <= #chars then push(#chars + 1) end
  if #rows == 0 then rows[1] = '' end
  return rows
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
-- Pure: lay every image box on a line into virt_h visual rows of virt_text
-- chunks. `boxes` is a list of { name, w_px, h_px, start_cell } (one per image,
-- left-to-right as the GUI paints them). Each box keeps its text-relative
-- start_cell (so leading prose can push the leftmost box right), later boxes bumped
-- right when they would overlap. Returns rows[0..virt_h-1], each a list of
-- { text, 'Comment' } chunks. Split out from draw_stub_footprint_box for
-- unit-testing, like parse_image_size.
function M.build_stub_box_rows(boxes, virt_h, cell_w)
  virt_h = math.max(1, virt_h or 1)
  cell_w = math.max(1, cell_w or 10)
  local hl = 'Comment'
  if not boxes or #boxes == 0 then return {} end

  -- Per-box geometry + per-visual-row text.
  local prepared = {}
  for _, b in ipairs(boxes) do
    local name = b.name or '?'
    local size = string.format('%dx%dpx  (%d rows)', b.w_px or 0, b.h_px or 0, virt_h)
    -- Box width = the image's real display width in cells (NOT the label length),
    -- so a box never spills past the actual image footprint. Capped/floored so
    -- borders always render; label text is clipped to fit.
    local box_w = math.min(200, math.max(4, math.floor((b.w_px or 0) / cell_w + 0.5)))
    local inner = box_w - 2
    local function clip(s)
      if #s > inner then return s:sub(1, inner) end
      return s
    end
    local function bar(open, fill, text, close)
      text = clip(text)
      return open .. text .. string.rep(fill, math.max(0, inner - #text)) .. close
    end
    local text_by_row = {}
    if virt_h <= 1 then
      text_by_row[0] = clip('[img: ' .. name .. '  ' .. size .. ']')
    else
      text_by_row[0] = bar('+', '-', '- img: ' .. name .. ' ', '+')
      text_by_row[virt_h - 1] = bar('+', '-', '', '+')
      for v = 1, virt_h - 2 do
        text_by_row[v] = bar('|', ' ', v == 1 and (' ' .. size .. ' ') or '', '|')
      end
    end
    prepared[#prepared + 1] = {
      start_cell = math.max(0, b.start_cell or 0),
      box_w = box_w,
      text_by_row = text_by_row,
    }
  end

  table.sort(prepared, function(a, b) return a.start_cell < b.start_cell end)
  local prev_end = -1
  for _, p in ipairs(prepared) do
    p.col = math.max(p.start_cell, prev_end + 1)
    prev_end = p.col + p.box_w - 1
  end

  local rows = {}
  for v = 0, virt_h - 1 do
    local chunks = {}
    local col = 0
    for _, p in ipairs(prepared) do
      local text = p.text_by_row[v]
      if text and #text > 0 then
        if p.col > col then
          chunks[#chunks + 1] = { string.rep(' ', p.col - col), hl }
          col = p.col
        end
        chunks[#chunks + 1] = { text, hl }
        col = col + #text
      end
    end
    rows[v] = chunks
  end
  return rows
end

-- Pure: lay non-image text segments into virt_h visual rows of column-positioned
-- virt_text chunks, each segment WRAPPED to its slot width and BOTTOM-aligned within
-- the band (last wrapped row on visual row virt_h-1, stacking upward; clipped to the
-- bottom virt_h rows so text never spills below the image). `segments` is a list of
--   { text = string, start_cell = N, width_cells = N }   (text-relative columns)
-- Returns rows[0..virt_h-1] (each a list of { text, hl } chunks; nil for empty
-- rows), like build_stub_box_rows. Split out for unit-testing.
function M.build_image_text_rows(segments, virt_h, opts)
  opts = opts or {}
  local hl = opts.hl or 'Normal'
  virt_h = math.max(1, virt_h or 1)
  if not segments or #segments == 0 then return {} end

  local by_row = {}  -- v -> list of { col, text }
  for _, seg in ipairs(segments) do
    local text = seg.text
    local width = math.max(1, math.floor(seg.width_cells or 0))
    if type(text) == 'string' and text ~= '' and (seg.width_cells or 0) >= 1 then
      local wrapped = wrap_text_to_width(text, width)
      while #wrapped > 0 and wrapped[#wrapped] == '' do table.remove(wrapped) end
      local m = #wrapped
      local clip = math.max(0, m - virt_h)  -- rows that don't fit are dropped from the top
      for k = clip + 1, m do
        local v = virt_h - 1 - m + k  -- 0-based visual row; k==m -> virt_h-1 (bottom)
        by_row[v] = by_row[v] or {}
        by_row[v][#by_row[v] + 1] = { col = math.max(0, math.floor(seg.start_cell or 0)), text = wrapped[k] }
      end
    end
  end

  local rows = {}
  for v = 0, virt_h - 1 do
    local segs = by_row[v]
    if segs then
      table.sort(segs, function(a, b) return a.col < b.col end)
      local chunks = {}
      local col = 0
      for _, s in ipairs(segs) do
        if s.col > col then
          chunks[#chunks + 1] = { string.rep(' ', s.col - col), hl }
          col = s.col
        end
        chunks[#chunks + 1] = { s.text, hl }
        col = col + vim.fn.strdisplaywidth(s.text)
      end
      rows[v] = chunks
    end
  end
  return rows
end

-- Merge two column-positioned chunk-rows: paint `base` (e.g. stub boxes), then
-- overlay `over` (e.g. gap text) treating over's spaces as transparent, so the text
-- only fills the columns the boxes leave blank. Both are chunk lists positioned from
-- column 0; returns one positioned chunk list. Width-aware (CJK/wide chars).
local function merge_chunk_rows(base, over)
  if not over or #over == 0 then return base or {} end
  if not base or #base == 0 then return over end
  local grid = {}  -- col -> { c, hl } | false (wide-char continuation) | nil (blank)
  local maxcol = 0
  local function paint(chunks, transparent_space)
    local col = 0
    for _, ch in ipairs(chunks) do
      for _, c in ipairs(vim.fn.split(ch[1] or '', '\\zs')) do
        local w = math.max(1, vim.fn.strdisplaywidth(c))
        if not (transparent_space and c == ' ') then
          grid[col] = { c = c, hl = ch[2] }
          for k = 1, w - 1 do grid[col + k] = false end
        end
        col = col + w
      end
    end
    if col > maxcol then maxcol = col end
  end
  paint(base, false)
  paint(over, true)
  local out = {}
  local col = 0
  while col < maxcol do
    local cell = grid[col]
    if cell == false then
      col = col + 1
    elseif cell == nil then
      local s = col
      while col < maxcol and grid[col] == nil do col = col + 1 end
      out[#out + 1] = { string.rep(' ', col - s), 'Normal' }
    else
      local hl = cell.hl
      local parts = {}
      while col < maxcol do
        local cc = grid[col]
        if cc == false then
          col = col + 1
        elseif cc == nil or cc.hl ~= hl then
          break
        else
          parts[#parts + 1] = cc.c
          col = col + 1
        end
      end
      out[#out + 1] = { table.concat(parts), hl }
    end
  end
  return out
end

-- Emit per-visual-row chunk lists across the image footprint, routing each visual
-- row to a virt_line or a source-row overlay exactly like draw_stub_footprint_box:
-- v=0 -> overlay on the anchor row; v in [1,reserve_h-1] -> reserved virt_lines;
-- v>=reserve_h -> overlay on lower source rows (multi-line sources). Overlays on a
-- cursor row are skipped so native conceal reveals the raw text there.
local function emit_band_rows(buf, ns, row, reserve_h, source_span, virt_h, rows, cursor_rows)
  reserve_h = math.max(1, reserve_h or 1)
  source_span = math.max(1, source_span or 1)
  virt_h = math.max(1, virt_h or 1)
  local function overlay(brow, chunks)
    if cursor_rows and cursor_rows[brow] then return end
    if not chunks or #chunks == 0 then return end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, brow, 0, {
      virt_text = chunks, virt_text_pos = 'overlay', priority = 260,
    })
  end
  local virt_lines = {}
  for v = 0, virt_h - 1 do
    if v == 0 then
      overlay(row, rows[v])
    elseif v <= reserve_h - 1 then
      local chunks = rows[v]
      virt_lines[#virt_lines + 1] = (chunks and #chunks > 0) and chunks or { { ' ', 'Normal' } }
    else
      local src_index = v - (reserve_h - 1)
      if src_index < source_span then overlay(row + src_index, rows[v]) end
    end
  end
  if #virt_lines > 0 then
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0,
      { virt_lines = virt_lines, virt_lines_above = false })
  end
end

-- Terminal stub, footprint-faithful box(es) (PlantUML blocks AND image links).
-- Unlike make_stub_box (which lives wholly in the virt_lines slice), this draws
-- across the FULL image footprint: virt_h visual rows starting at the source's
-- first row, exactly where the GUI image(s) would paint. Space allocation is
-- left untouched -- the box is split between (a) the already-reserved virt_lines
-- and (b) zero-height virt_text overlays on the (concealed) source rows. Visual-
-- row routing matches nvim's render order: src0, then reserve_h-1 virt_lines
-- anchored below src0, then src1..src(source_span-1). When the cursor sits on a
-- source row (`cursor_rows[brow]`), its overlay is skipped so native conceal can
-- reveal the raw link text there.
function M.draw_stub_footprint_box(buf, ns, reservation, cell_w, cursor_rows)
  local label = reservation.label
  local row = reservation.row
  local reserve_h = math.max(1, reservation.reserve_h or 1)
  local source_span = math.max(1, label.source_span or 1)
  local virt_h = math.max(1, label.virt_h or 1)
  local boxes = label.boxes or {}
  if #boxes == 0 then return end

  local box_rows = M.build_stub_box_rows(boxes, virt_h, cell_w)
  -- Weave the bottom-aligned gap text into the (disjoint) gap columns between boxes.
  local rows = box_rows
  if label.text_rows then
    rows = {}
    for v = 0, virt_h - 1 do
      rows[v] = merge_chunk_rows(box_rows[v], label.text_rows[v])
    end
  end
  emit_band_rows(buf, ns, row, reserve_h, source_span, virt_h, rows, cursor_rows)
end

-- Terminal stub box drawn into the PlantUML preview float buffer (the GUI would
-- paint the image over the float). Fills exactly the place.width x place.height
-- geometry the placement logic already sized the window to -- no placement change.
function M.draw_stub_preview_box(buf, place, path, rect)
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
  -- Split carrier: the window is larger than the box, so pad the box to the
  -- centered position (place already includes the window-origin offset).
  if rect then
    local pad_left = math.max(0, (place.col or 0) - (rect.col or 0))
    if pad_left > 0 then
      local prefix = string.rep(' ', pad_left)
      for i = 1, #lines do lines[i] = prefix .. lines[i] end
    end
    local pad_top = math.max(0, (place.row or 0) - (rect.row or 0))
    for _ = 1, pad_top do table.insert(lines, 1, '') end
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

function M.compute_image_display_size(image, max_w_px, max_rows, cell_h, zoom)
  if not image or not image.source_width or not image.source_height or image.source_width <= 0 or image.source_height <= 0 then
    return nil
  end
  zoom = zoom or 1.0
  local native_w = image.source_width * zoom
  local native_h = image.source_height * zoom
  local display_w = math.min(native_w, math.max(1, math.floor(max_w_px or native_w)))
  local display_h = math.max(1, math.floor(display_w * native_h / native_w + 0.5))
  local virt_h = math.max(1, math.ceil(display_h / math.max(1, cell_h or 1)))
  if max_rows and max_rows > 0 and virt_h > max_rows then
    virt_h = max_rows
    display_h = virt_h * math.max(1, cell_h or 1)
    display_w = math.max(1, math.floor(display_h * native_w / native_h + 0.5))
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
  local zoom = tonumber(opts.zoom) or 1.0
  local base_grid_row = tonumber(opts.base_grid_row) or 0
  local clip_x = tonumber(opts.clip_x_px) or 0
  local clip_y = tonumber(opts.clip_y_px) or 0
  local clip_w = math.max(1, tonumber(opts.clip_width_px) or cell_w)
  local clip_h = math.max(1, tonumber(opts.clip_height_px) or cell_h)
  local text_left_px = tonumber(opts.text_left_px) or clip_x
  local text_right_px = tonumber(opts.text_right_px) or (clip_x + clip_w)
  local dest_y_px = tonumber(opts.dest_y_px) or (base_grid_row * cell_h)
  if text_right_px <= text_left_px then text_right_px = text_left_px + cell_w end
  -- Image-line text layout (opt-in): start packing at row_start_x_override (= text
  -- left + leading-prose width) and use per-gap widths from gaps_px[i] (the reserved
  -- room for the prose between image i and i+1) instead of the constant gap_px.
  local row_start_override = tonumber(opts.row_start_x_override)
  local gaps_px = opts.gaps_px or {}
  -- Room reserved to the right of the last image for the trailing prose slot, so
  -- the images don't pack all the way to text_right_px and squeeze it out.
  local trailing_reserve = math.max(0, tonumber(opts.trailing_px) or 0)
  -- gap_scale shrinks the reserved text gaps only in the narrow-window edge case
  -- where images alone can't shrink enough to fit (see the fit logic below).
  local gap_scale = 1
  local function gap_after(i) return math.max(0, math.floor((tonumber(gaps_px[i]) or gap_px) * gap_scale)) end

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
    local display_w, display_h = M.compute_image_display_size(image, max_image_w, max_rows, cell_h, zoom)
    if display_w and display_h then
      sized[#sized + 1] = { image = image, width = display_w, height = display_h }
      common_h = math.max(common_h, display_h)
    end
  end

  if #sized == 0 then return layouts, 1 end

  common_h = math.max(1, common_h)
  if max_rows and max_rows > 0 then common_h = math.min(common_h, max_rows * cell_h) end

  row_start_x = row_start_override or row_start_x or text_left_px
  local available_w = math.max(1, text_right_px - row_start_x - trailing_reserve)
  local function images_width_for(height)
    local total = 0
    for _, item in ipairs(sized) do
      total = total + math.max(1, math.floor(height * item.image.source_width / item.image.source_height + 0.5))
    end
    return total
  end
  local function gaps_total()
    local total = 0
    for i = 1, #sized - 1 do total = total + gap_after(i) end
    return total
  end

  -- Fit images + the fixed gap slots within available_w. Gaps are reserved text
  -- columns that do NOT scale with image height, so shrink images against the
  -- budget left after the gaps. If the gaps alone leave less than 1px per image,
  -- scale the gaps down too so the band never spills past text_right_px.
  local min_imgs_w = images_width_for(1)  -- images collapsed to the 1px floor
  local budget = available_w - gaps_total()
  if budget < min_imgs_w then
    local room = math.max(0, available_w - min_imgs_w)
    local g = gaps_total()
    gap_scale = (g > 0) and (room / g) or 1
    budget = available_w - gaps_total()
  end
  local imgs_w = images_width_for(common_h)
  if imgs_w > budget then
    common_h = math.max(1, math.floor(common_h * budget / imgs_w))
    common_h = math.max(1, math.floor(common_h / cell_h) * cell_h)
  end

  local dest_x = row_start_x
  for i, item in ipairs(sized) do
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
    dest_x = dest_x + display_w + (i < #sized and gap_after(i) or 0)
  end

  return layouts, math.max(1, math.ceil(common_h / cell_h))
end

-- Pure: decode width/height/format from leading image bytes (no I/O). Split out
-- from read_image_size so the format detection is unit-testable on byte fixtures.
function M.parse_image_size(data)
  return image_size.parse_image_size(data)
end

-- Read image dimensions from `path`, caching by (mtime, size) so repeated renders
-- don't re-read the same files. fs_stat is a cheap syscall vs the 512KB read it
-- guards, and mtime/size keying guarantees fresh dims if the file changes on disk.
function M.read_image_size(path)
  return read_image_size_impl(path)
end

local function stable_hash(s)
  local h = 2166136261
  for i = 1, #s do
    h = (bitops.bxor(h, s:byte(i)) * 16777619) % 4294967296
  end
  return string.format('%08x', h)
end

function M.preview_image_id(ps, place)
  return table.concat({
    'preview',
    tostring(ps and ps.buf or 0),
    tostring(ps and ps.start_row or 0),
    tostring(place and place.disp_w or 0) .. 'x' .. tostring(place and place.disp_h or 0),
  }, ':')
end

function M.preview_legacy_image_id(carrier_buf, path, place)
  return table.concat({
    'preview',
    tostring(carrier_buf or 0),
    stable_hash(path or ''),
    tostring(place and place.disp_w or 0) .. 'x' .. tostring(place and place.disp_h or 0),
  }, ':')
end

function M.resolve_image_path(buf, raw_path)
  return image_scan.resolve_image_path(buf, raw_path)
end

local function image_scan_deps()
  return {
    read_image_size = M.read_image_size,
    image_ns = function() return image_ns end,
    markdown_plantuml_block_height = M.markdown_plantuml_block_height,
  }
end

function M.scan_markdown_image_text(buf, row0, text, result, opts)
  return image_scan.scan_markdown_image_text(image_scan_deps(), buf, row0, text, result, opts)
end

-- True if `text` contains at least one markdown image link. Shared with wrap.lua so
-- it can skip these lines (image.lua owns their layout). Same pattern as the scanner.
function M.line_has_image_link(text)
  return image_scan.line_has_image_link(text)
end

function M.virt_text_to_plain(virt_text)
  return image_scan.virt_text_to_plain(virt_text)
end

function M.virt_lines_to_plain(virt_lines)
  return image_scan.virt_lines_to_plain(virt_lines)
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
  return image_scan.collect_markdown_images(image_scan_deps(), buf, start_row, end_row)
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

  local src_w = ps.w
  local block_lines = vim.api.nvim_buf_get_lines(src_buf, start_row, end_row + 1, false) or {}
  local fallback_left = (tonumber(src_w.wincol) or 1) - 1 + (tonumber(src_w.textoff) or 0)
  local block_top, block_bottom, block_left, block_right

  for i, line in ipairs(block_lines) do
    local lnum = start_row + i
    local leading = #(line:match('^%s*') or '')
    local sp_left = M.safe_screenpos(src_win, lnum, leading + 1)
    if sp_left.row and sp_left.row > 0 then
      local row = sp_left.row - 1
      local left = (sp_left.col and sp_left.col > 0) and (sp_left.col - 1) or fallback_left
      block_top = block_top and math.min(block_top, row) or row
      block_bottom = block_bottom and math.max(block_bottom, row) or row
      block_left = block_left and math.min(block_left, left) or left

      local sp_end = M.safe_screenpos(src_win, lnum, #line + 1)
      local right = (sp_end.col and sp_end.col > 0)
        and (sp_end.col - 1)
        or (left + vim.fn.strdisplaywidth(line))
      block_right = block_right and math.max(block_right, right) or right
    end
  end
  if not block_top then return nil end
  block_left = block_left or fallback_left
  block_right = block_right or block_left

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
  local code_obstacles = {}
  if type(M.plantuml_find_blocks) == 'function' then
    for _, block in ipairs(M.plantuml_find_blocks(src_buf) or {}) do
      local lines = vim.api.nvim_buf_get_lines(src_buf, block.start_row, block.end_row + 1, false) or {}
      local top, bottom, left, right
      for i, line in ipairs(lines) do
        local lnum = block.start_row + i
        local leading = #(line:match('^%s*') or '')
        local sp_left = M.safe_screenpos(src_win, lnum, leading + 1)
        if sp_left.row and sp_left.row > 0 then
          local row = sp_left.row - 1
          local lcol = (sp_left.col and sp_left.col > 0) and (sp_left.col - 1) or fallback_left
          local sp_end = M.safe_screenpos(src_win, lnum, #line + 1)
          local rcol = (sp_end.col and sp_end.col > 0)
            and (sp_end.col - 1)
            or (lcol + vim.fn.strdisplaywidth(line))
          top = top and math.min(top, row) or row
          bottom = bottom and math.max(bottom, row) or row
          left = left and math.min(left, lcol) or lcol
          right = right and math.max(right, rcol) or rcol
        end
      end
      if top then
        code_obstacles[#code_obstacles + 1] = { top = top, bottom = bottom, left = left, right = right }
      end
    end
  end

  local function avoids_code_blocks(r, c)
    local bottom = r + ph - 1
    local right = c + pw - 1
    for _, ob in ipairs(code_obstacles) do
      local row_overlap = r <= ob.bottom and ob.top <= bottom
      local col_overlap = c <= ob.right and ob.left <= right
      if row_overlap and col_overlap then return false end
    end
    return true
  end

  local top_r, top_c = block_top - ph, math.min(block_left, cols - pw)
  local bot_r, bot_c = block_bottom + 1, top_c
  local left_c, left_r = block_left - pw, math.min(block_top, rows - ph)
  local right_c, right_r = block_right + 1, left_r

  local fr, fc
  if fits_rows(top_r) and fits_cols(top_c) and avoids_code_blocks(top_r, top_c) then
    fr, fc = top_r, top_c
  elseif fits_rows(bot_r) and fits_cols(bot_c) and avoids_code_blocks(bot_r, bot_c) then
    fr, fc = bot_r, bot_c
  elseif fits_cols(left_c) and fits_rows(left_r) and avoids_code_blocks(left_r, left_c) then
    fr, fc = left_r, left_c
  elseif fits_cols(right_c) and fits_rows(right_r) and avoids_code_blocks(right_r, right_c) then
    fr, fc = right_r, right_c
  else
    return nil
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

  local place, stub_rect
  if ps.kind == 'split' then
    -- The split carrier IS info.win, sized by the user. Center the image within
    -- its screen rect rather than moving/resizing the window.
    local wi = info.w
    local textoff = tonumber(wi.textoff) or 0
    stub_rect = {
      row = math.max(0, (tonumber(wi.winrow) or 1) - 1),
      col = math.max(0, (tonumber(wi.wincol) or 1) - 1 + textoff),
      width = math.max(1, (tonumber(wi.width) or 1) - textoff),
      height = math.max(1, tonumber(wi.height) or 1),
    }
    place = M.center_in_rect(stub_rect, image, cell_w, cell_h)
  else
    place = M.compute_preview_placement(ps, image, cell_w, cell_h)
    if not place then
      pcall(function()
        delete_image(vim.w[info.win].rendermark_plantuml_preview_image_id)
        delete_image(vim.w[info.win].rendermark_plantuml_preview_legacy_image_id)
      end)
      if vim.api.nvim_win_is_valid(info.win) then
        pcall(vim.api.nvim_win_close, info.win, true)
      end
      if vim.api.nvim_buf_is_valid(info.buf) then
        pcall(vim.api.nvim_buf_delete, info.buf, { force = true })
      end
      return
    end
    M.reposition_preview_float(info.win, place)
  end

  if M._stub_active then
    -- No pixels in a terminal: draw the box into the carrier buffer instead. For a
    -- split, stub_rect lets the box be centered within the (larger) window.
    M.draw_stub_preview_box(info.buf, place, image.path, stub_rect)
    return
  end

  local preview_id = M.preview_image_id(ps, place)
  local legacy_preview_id = M.preview_legacy_image_id(info.buf, image.path, place)
  pcall(function()
    vim.w[info.win].rendermark_plantuml_preview_image_id = preview_id
    vim.w[info.win].rendermark_plantuml_preview_legacy_image_id = legacy_preview_id
  end)

  payload[#payload + 1] = {
    id = preview_id,
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

-- Keep global 'equalalways' disabled for as long as a preview split is open, so
-- that carving it (open) and removing it (close -- including a user <C-w>z) resizes
-- only the source window; sibling windows keep their size. The original value is
-- stashed on the buffer's state and restored once the preview is gone.
local function preview_suppress_equalize(st)
  if st.saved_equalalways == nil then
    st.saved_equalalways = vim.o.equalalways
    vim.o.equalalways = false
  end
end
local function preview_restore_equalize(st)
  if st.saved_equalalways ~= nil then
    vim.o.equalalways = st.saved_equalalways
    st.saved_equalalways = nil
  end
end

local function plantuml_close_float(st)
  if not st then return end
  if not st.float then preview_restore_equalize(st); return end
  -- Mark this as a programmatic teardown so the WinClosed handler does not treat
  -- it as a user <C-w>z dismissal.
  st.programmatic_close = true
  if st.float.win and vim.api.nvim_win_is_valid(st.float.win) then
    pcall(function()
      delete_image(vim.w[st.float.win].rendermark_plantuml_preview_image_id)
      delete_image(vim.w[st.float.win].rendermark_plantuml_preview_legacy_image_id)
    end)
    pcall(vim.api.nvim_win_close, st.float.win, true)
  end
  if st.float.buf and vim.api.nvim_buf_is_valid(st.float.buf) then
    pcall(vim.api.nvim_buf_delete, st.float.buf, { force = true })
  end
  st.float = nil
  st.programmatic_close = false
  preview_restore_equalize(st)
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

local split_dir_map = { left = 'left', right = 'right', top = 'above', bottom = 'below' }

-- Open (or reuse) a dedicated, non-modifiable split window for the active block's
-- preview. emit_preview_float centers the image inside it. The carrier slot is
-- shared with the float (st.float), tagged kind='split', so the existing close /
-- cleanup paths tear it down unchanged.
local function plantuml_open_split(buf, win, block, png)
  local st = plantuml_state_for(buf)
  local line = (vim.api.nvim_buf_get_lines(buf, block.start_row, block.start_row + 1, false) or {})[1] or ''
  local block_id = tostring(block.start_row) .. ':' .. tostring(block.end_row)
  local meta = {
    buf = buf,
    win = win,
    start_row = block.start_row,
    anchor_col = #(line:match('^%s*') or ''),
    path = png,
    kind = 'split',
  }
  local link = '![plantuml](' .. png:gsub('\\', '/') .. ')'

  -- Record the source block on st.float so active-block resolution can keep the
  -- preview alive while focus is inside the preview window, and so the WinClosed
  -- dismissal handler knows which block was dismissed.
  local function stamp_source(f)
    f.source_win = win
    f.source_buf = buf
    f.start_row = block.start_row
    f.end_row = block.end_row
    f.block_id = block_id
  end

  -- Reuse the existing split pane (re-renders); just refresh its image link and
  -- the source metadata. Orientation of an existing pane is kept as-is; a new
  -- orientation is only chosen when the pane is (re)opened from closed.
  if st.float and st.float.kind == 'split'
      and st.float.win and vim.api.nvim_win_is_valid(st.float.win)
      and st.float.buf and vim.api.nvim_buf_is_valid(st.float.buf) then
    if st.float.path ~= png then
      pcall(function() vim.bo[st.float.buf].modifiable = true end)
      pcall(vim.api.nvim_buf_set_lines, st.float.buf, 0, -1, false, { link })
      pcall(function() vim.bo[st.float.buf].modifiable = false end)
      st.float.path = png
    end
    stamp_source(st.float)
    pcall(function() vim.w[st.float.win].rendermark_plantuml_preview_source = meta end)
    return
  end
  plantuml_close_float(st)

  -- Smart position from the SOURCE window's pixel aspect: landscape -> vertical
  -- split (preview right), portrait -> horizontal split (preview bottom).
  local ok_w, w_cells = pcall(vim.api.nvim_win_get_width, win)
  local ok_h, h_cells = pcall(vim.api.nvim_win_get_height, win)
  local direction = M.smart_split_direction(
    ok_w and w_cells or vim.o.columns, ok_h and h_cells or vim.o.lines,
    vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px)
  local vertical = direction == 'vertical'
  local position = vertical and 'right' or 'bottom'
  local total = vertical and (tonumber(vim.o.columns) or 80) or (tonumber(vim.o.lines) or 24)
  local size = M.resolve_split_size(preview_cfg.split.size, total)

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[fbuf].buftype = 'nofile'
  vim.bo[fbuf].bufhidden = 'wipe'
  vim.bo[fbuf].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { link })
  vim.bo[fbuf].modifiable = false

  local wcfg = { split = split_dir_map[position], win = win }
  if vertical then wcfg.width = size else wcfg.height = size end
  -- Carve the split without re-equalizing sibling windows (only `win` shrinks);
  -- equalize stays suppressed until the preview closes (see plantuml_close_float).
  preview_suppress_equalize(st)
  local ok, fwin = pcall(vim.api.nvim_open_win, fbuf, false, wcfg)
  if not ok or not fwin then
    preview_restore_equalize(st)
    pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
    return
  end
  for opt, val in pairs({
    number = false, relativenumber = false, wrap = false, list = false,
    cursorline = false, signcolumn = 'no',
    winfixwidth = vertical, winfixheight = not vertical,
    -- A real preview window: closable with <C-w>z / :pclose, no custom keymap.
    -- May raise E590 if a preview window already exists; pcall degrades quietly.
    previewwindow = true,
  }) do
    pcall(vim.api.nvim_set_option_value, opt, val, { win = fwin })
  end
  pcall(function() vim.w[fwin].rendermark_plantuml_preview_source = meta end)
  st.float = { buf = fbuf, win = fwin, path = png, kind = 'split' }
  stamp_source(st.float)
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

-- Which block (if any) the cursor sits inside for the focused source window.
-- The preview float is an editing aid for the current buffer only: when focus
-- moves to Telescope, another buffer, or any other window, the source window's
-- stale cursor must not keep the preview floating over the new UI.
local function plantuml_active_block(buf, blocks)
  local cur = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(cur) then return nil, nil end
  if vim.w[cur].read_mode_active then return nil, nil end

  -- Focus in the source window with the cursor inside a block: that block is active.
  if vim.api.nvim_win_get_buf(cur) == buf then
    local row = vim.api.nvim_win_get_cursor(cur)[1] - 1
    for _, block in ipairs(blocks) do
      if row >= block.start_row and row <= block.end_row then
        return block, cur
      end
    end
    return nil, nil
  end

  -- Focus inside our own preview window: keep the block it was built for alive so
  -- the preview stays open, attributed to the still-valid source window. Moving
  -- focus to any other (third) window falls through to nil and closes it.
  local st = plantuml_states[buf]
  if st and st.float and st.float.win == cur
      and st.float.source_win and vim.api.nvim_win_is_valid(st.float.source_win) then
    return { start_row = st.float.start_row, end_row = st.float.end_row }, st.float.source_win
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

  local st = plantuml_state_for(buf)

  -- Install the buffer-local reopen keymap once. After the user dismisses the
  -- preview with <C-w>z, `gpp` clears the dismissal and re-opens it.
  if not st.mapped then
    st.mapped = true
    pcall(vim.keymap.set, 'n', 'gpp', function()
      local s = plantuml_states[buf]
      if s then s.dismissed_id = nil end
      M.send_images()
    end, { buffer = buf, desc = 'Reopen the PlantUML preview for the current block' })
  end

  local active_block, active_win = plantuml_active_block(buf, blocks)
  local active_id = active_block
    and (tostring(active_block.start_row) .. ':' .. tostring(active_block.end_row)) or nil
  -- Drop a stale dismissal once the cursor leaves the dismissed block, so
  -- re-entering it re-opens the preview.
  if st.dismissed_id and st.dismissed_id ~= active_id then
    st.dismissed_id = nil
  end
  local active_floated = false

  for _, block in ipairs(blocks) do
    local is_active = active_block ~= nil and block.start_row == active_block.start_row

    if is_active then
      -- Leave the source raw for editing; show a preview (float or split) instead.
      -- The block text changes while typing, so debounce its render. Honor the
      -- show/hide state (M.preview_active()) and any user dismissal of this block.
      if M.preview_active() and not st.dismissed_id then
        local entry = plantuml_debounce_active(buf, block)
        if entry and entry.status == 'ready' then
          if preview_cfg.mode == 'split' then
            plantuml_open_split(buf, active_win, block, entry.png)
          else
            plantuml_open_float(buf, active_win, block, entry.png)
          end
          active_floated = true
        end
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

  -- Tear down the preview when no block is active. A persistent split pane is the
  -- exception: it stays open and keeps showing the last diagram. A hidden/disabled
  -- preview always closes.
  if not active_floated then
    local st = plantuml_states[buf]
    if st then
      local keep_persistent_split = preview_cfg.mode == 'split'
        and preview_cfg.split.lifecycle == 'persistent'
        and M.preview_active()
        and st.float and st.float.kind == 'split'
      if not keep_persistent_split then
        plantuml_close_float(st)
      end
    end
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
    kind = source_meta.kind == 'split' and 'split' or 'float',
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
  if not backend.img_available() then return end

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
  local zoom_scale = tonumber(vim.g.neopp_font_zoom_scale) or 1.0
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
      -- An image's display footprint extends max(source span, image rows) below
      -- its anchor (reserve_h = virt_h - span + 1 virt_lines plus the concealed
      -- source rows; virt_h <= max_rows, +1 margin for the fold/above
      -- reservation). Keep it while any of that can intersect the viewport so
      -- both PlantUML blocks and inline image lines stay concealed and
      -- clipped-rendered -- and, critically, keep their virt_lines reservation
      -- so scrolling through the block never collapses the layout.
      local span = math.max(1, tonumber(measured_image.source_span_height) or 1)
      local keep = lnum <= measure_w.botline
        and lnum + math.max(span, max_rows + 1) - 1 >= measure_w.topline
      if keep then
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
      -- screenpos() is 0 for lines above topline. A block whose anchor line
      -- scrolled off the top can still be partially visible; synthesize its
      -- grid row so the image keeps rendering (clipped), the source lines stay
      -- concealed, and -- most importantly -- the virt_lines reservation below
      -- survives, keeping the window's topfill valid while scrolling through it.
      local offscreen_grid_row = nil
      if sp_line.row <= 0 and lnum < measure_w.topline then
        offscreen_grid_row = M.offscreen_anchor_grid_row(measure_win, measure_w, row)
      end
      if sp_line.row > 0 or offscreen_grid_row then
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
        local source_grid_row = offscreen_grid_row or (sp_line.row - 1)
        -- Stack vertically below the previous block's image when this block's
        -- anchor is bunched against it (two adjacent closed folds, whose
        -- separating virt_lines nvim refuses to render) so images never overlap.
        local layout_grid_row = source_grid_row
        if stack_bottom_grid_row and source_grid_row < stack_bottom_grid_row then
          layout_grid_row = stack_bottom_grid_row
        end
        -- Image-line text layout: pull the prose around/between the (real) image
        -- links off the raw row so it can be re-rendered bottom-aligned in the gaps
        -- between images. Reserve horizontal room for the leading + between prose so
        -- the images are spaced to leave the text a slot (capped so a long caption
        -- wraps instead of shoving images off-screen). Only for real buffer links.
        local TEXT_SLOT_MAX_CELLS = 30
        local text_layout = nil
        do
          local eligible = #line_images > 0
          for _, img in ipairs(line_images) do
            if img.virtual or not img.byte_col or img.plantuml then eligible = false break end
          end
          if eligible then
            local imgs = {}
            for _, img in ipairs(line_images) do imgs[#imgs + 1] = img end
            table.sort(imgs, function(a, b) return (a.byte_col or 0) < (b.byte_col or 0) end)
            local raw_line = (vim.api.nvim_buf_get_lines(measure_buf, row, row + 1, false) or {})[1] or ''
            local segs = {}
            segs[1] = vim.trim(raw_line:sub(1, imgs[1].byte_col))
            for i = 1, #imgs - 1 do
              segs[i + 1] = vim.trim(raw_line:sub(imgs[i].byte_end_col + 1, imgs[i + 1].byte_col))
            end
            segs[#imgs + 1] = vim.trim(raw_line:sub(imgs[#imgs].byte_end_col + 1))
            local function cap_w(s) return math.min(vim.fn.strdisplaywidth(s), TEXT_SLOT_MAX_CELLS) end
            local leading_px = cap_w(segs[1]) * cell_w
            local gaps = {}
            for i = 1, #imgs - 1 do
              local w = cap_w(segs[i + 1])
              gaps[i] = (w > 0) and (w * cell_w + gap_px) or gap_px
            end
            local trailing_w = cap_w(segs[#imgs + 1])
            local trailing_px = (trailing_w > 0) and (trailing_w * cell_w + gap_px) or 0
            text_layout = {
              segs = segs, raw_line = raw_line,
              row_start_x_override = text_left_px + leading_px,
              gaps_px = gaps,
              trailing_px = trailing_px,
            }
          end
        end

        local layouts, image_rows = M.layout_image_line(line_images, {
          cell_w = cell_w,
          cell_h = cell_h,
          gap_px = gap_px,
          max_ratio = max_ratio,
          max_rows = layout_max_rows,
          zoom = zoom_scale,
          base_grid_row = layout_grid_row,
          dest_y_px = layout_grid_row * cell_h,
          clip_x_px = clip_x_px,
          clip_y_px = clip_y_px,
          clip_width_px = clip_w_px,
          clip_height_px = clip_h_px,
          text_left_px = text_left_px,
          text_right_px = layout_text_right_px,
          row_start_x_override = text_layout and text_layout.row_start_x_override,
          gaps_px = text_layout and text_layout.gaps_px,
          trailing_px = text_layout and text_layout.trailing_px,
        })

        local virt_h = image_rows
        if #layouts > 0 then
          stack_bottom_grid_row = layout_grid_row + image_rows
          local source_span_height = nil
          for _, layout in ipairs(layouts) do
            source_span_height = math.min(source_span_height or math.huge, layout.image.source_span_height or 1)
          end
          local text_left_cell = math.floor(text_left_px / math.max(1, cell_w))
          local label = { source_span = source_span_height or 1, virt_h = virt_h }
          if M._stub_active then
            -- One box per image, placed at the same text-relative cell offset the
            -- GUI image uses (grid_col - text_left_cell), so boxes and gap text share
            -- one coordinate space.
            local stub_boxes = {}
            for _, layout in ipairs(layouts) do
              local path = layout.image.path or layout.image.raw_path or '?'
              stub_boxes[#stub_boxes + 1] = {
                name = vim.fn.fnamemodify(path, ':t'),
                w_px = layout.display_width_px or 0,
                h_px = layout.display_height_px or 0,
                start_cell = math.max(0, layout.grid_col - text_left_cell),
              }
            end
            label.boxes = stub_boxes
          end
          if text_layout then
            -- Slots from the laid-out images: leading (left of image 1), the gap after
            -- each image (= prose before the next image), and the trailing slot.
            local text_right_cell = math.floor(layout_text_right_px / math.max(1, cell_w))
            local segments = {}
            for i, layout in ipairs(layouts) do
              local left_cell = layout.grid_col
              local right_cell = layout.grid_col + math.ceil((layout.display_width_px or cell_w) / math.max(1, cell_w))
              if i == 1 and text_layout.segs[1] ~= '' then
                local w = left_cell - text_left_cell
                if w >= 1 then
                  segments[#segments + 1] = { text = text_layout.segs[1], start_cell = 0, width_cells = w }
                end
              end
              local seg = text_layout.segs[i + 1]
              if seg and seg ~= '' then
                local next_left = layouts[i + 1] and layouts[i + 1].grid_col or text_right_cell
                local w = next_left - right_cell
                if w >= 1 then
                  segments[#segments + 1] = { text = seg, start_cell = right_cell - text_left_cell, width_cells = w }
                end
              end
            end
            if #segments > 0 then
              label.text_rows = M.build_image_text_rows(segments, virt_h, {})
            end
          end
          if not label.boxes and not label.text_rows then label = nil end
          remember_image_reservation(measure_win, measure_buf, row, virt_h, source_span_height or 1, label)
          if text_layout then
            -- Conceal the whole raw row (links + surrounding prose); the prose is
            -- re-rendered bottom-aligned in the gaps via label.text_rows.
            local cbuf = (line_images[1] and line_images[1].payload_buf) or info.buf
            image_conceals[cbuf] = image_conceals[cbuf] or {}
            image_conceals[cbuf][#image_conceals[cbuf] + 1] = {
              row = row,
              col = 0,
              end_col = #text_layout.raw_line,
            }
          end
        end

        for idx, layout in ipairs(layouts) do
          local image = layout.image
          local payload_buf = image.payload_buf or info.buf
          -- Conceal the raw link text (and its highlight) for real buffer links so
          -- it never reaches the grid under the image overlay. When this line is a
          -- text-layout line the WHOLE raw row is concealed once (below) instead --
          -- its prose is re-rendered bottom-aligned in the gaps -- so skip the
          -- per-link conceal here.
          if text_layout then
            -- handled by the whole-line conceal added once per row below
          elseif not image.virtual and image.byte_col then
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
            -- Identity is the logical image per window (buf:row:col:path scoped by
            -- the owning window). The window handle scopes it so the SAME buffer shown
            -- in several split windows yields a distinct placement (id) each -- otherwise
            -- the per-window entries collide on one id and only the last window's image
            -- draws. The display size is NOT part of the id: neopp keys its decode cache
            -- on path+size and remaps the id to the new size on every set, so a size
            -- change (e.g. cell-metric settling or a mid-scroll re-fit) is an in-place
            -- update instead of a del+re-alloc of the same image -- which otherwise
            -- churns the overlay and blinks the image for a frame while it slides.
            id = 'buf:' .. payload_buf .. ':win:' .. info.win .. ':' .. image.row .. ':' .. image.col .. ':' .. stable_hash(image.path),
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
            -- Owning window's row band: lets the GUI crop at the window top even
            -- when grid_row is offscreen (or inside another window's band).
            win_top = win_top_row,
            win_height = measure_w.height or (measure_w.botline - measure_w.topline + 1),
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
  -- Cursor buffer-rows for each window, so the stub can step its overlay aside
  -- on the cursor's line (letting native conceal reveal the raw link there).
  -- READ mode forces concealcursor='nvic' and pins the cursor, so a READ
  -- window's own cursor row is excluded here. Limitation: extmarks can't
  -- render differently per window on the same buffer position, so if a
  -- Normal-mode window on the same buffer has its cursor on the same row, that
  -- row still reveals in both windows -- accepted Neovim limitation.
  local function cursor_rows_for(buf)
    local set = nil
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
          and not vim.w[win].read_mode_active then
        set = set or {}
        set[vim.api.nvim_win_get_cursor(win)[1] - 1] = true
      end
    end
    return set
  end

  stub_source_rows = {}
  for buf, reservations in pairs(image_reservations) do
    for _, reservation in pairs(reservations) do
      local label = reservation.label
      if M._stub_active and label and not reservation.above then
        -- Footprint-faithful box across the concealed source rows + reserved
        -- virt_lines, for both PlantUML blocks and inline image links. Allocation
        -- (reserve_h/anchor/count) is unchanged.
        local span = math.max(1, label.source_span or 1)
        stub_source_rows[buf] = stub_source_rows[buf] or {}
        for r = reservation.row, reservation.row + span - 1 do
          stub_source_rows[buf][r] = true
        end
        M.draw_stub_footprint_box(buf, image_ns, reservation, cell_w, cursor_rows_for(buf))
      elseif label and label.text_rows and not reservation.above then
        -- GUI path with bottom-aligned gap text: route the text rows into the
        -- reserved virt_lines / source-row overlays (no stub boxes).
        emit_band_rows(buf, image_ns, reservation.row, reservation.reserve_h,
          label.source_span or 1, label.virt_h or reservation.reserve_h,
          label.text_rows, cursor_rows_for(buf))
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

-- Pure: stable identity of the block containing `cursor_row` (0-based), or '' if
-- the cursor is outside every block. Matches plantuml_active_block's containment
-- test (start_row <= row <= end_row).
function M.cursor_block_id(cursor_row, blocks)
  for _, block in ipairs(blocks or {}) do
    if cursor_row >= block.start_row and cursor_row <= block.end_row then
      return tostring(block.start_row) .. ':' .. tostring(block.end_row)
    end
  end
  return ''
end

-- Signature of "which PlantUML block (if any) the focused cursor sits in". The
-- only cursor-dependent output is the preview float that opens for the block
-- under focus, so this fingerprint changes exactly when a cursor/focus move
-- could change rendering -- letting the CursorMoved handler skip a full render
-- for ordinary navigation.
function M.cursor_active_block_sig()
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then return '' end
  -- Focus inside a preview window: mirror the sig of its source block, so moving
  -- focus source<->preview within one block yields an identical sig and does not
  -- thrash the render.
  for _, st in pairs(plantuml_states) do
    if st.float and st.float.win == win and st.float.source_win and st.float.block_id then
      return tostring(st.float.source_win) .. '@' .. tostring(st.float.source_buf) .. '=' .. st.float.block_id
    end
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  local ext = vim.fn.fnamemodify(name, ':e'):lower()
  if vim.bo[buf].filetype ~= 'markdown' and ext ~= 'md' and ext ~= 'markdown' then
    return ''
  end
  local blocks = M.plantuml_find_blocks(buf)
  if #blocks == 0 then return '' end
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local id = M.cursor_block_id(row, blocks)
  if id == '' then return '' end
  return tostring(win) .. '@' .. tostring(buf) .. '=' .. id
end

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
      -- topfill: scrolling row-by-row through reservation virt_lines changes the
      -- on-screen anchor of a partially-visible block without touching topline/
      -- botline, and WinScrolled's v:event does not track it either -- this sig
      -- is the only resync path for those scrolls.
      local topfill = 0
      local okf, tf = pcall(vim.api.nvim_win_call, w, function()
        return vim.fn.winsaveview().topfill
      end)
      if okf then topfill = tonumber(tf) or 0 end
      s[#s + 1] = table.concat({
        tostring(w), tostring(buf), tostring(relative), tostring(row), tostring(col),
        tostring(width), tostring(height), tostring(info.topline or 0),
        tostring(info.botline or 0), tostring(topfill), ft, tostring(changedtick),
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

-- Signature of "is the cursor on a stub image source row" across every window.
-- In stub mode the cursor's line is the only other cursor-driven output (its
-- overlay is suppressed so the raw link reveals), so this fingerprint changes
-- exactly when the cursor enters/leaves an image row. Empty unless the stub is
-- active. Uses the source rows recorded by the last render.
function M.stub_cursor_sig()
  if not M._stub_active then return '' end
  local parts = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local rows = stub_source_rows[buf]
      if rows then
        local crow = vim.api.nvim_win_get_cursor(win)[1] - 1
        if rows[crow] then
          parts[#parts + 1] = tostring(win) .. '=' .. tostring(crow)
        end
      end
    end
  end
  table.sort(parts)
  return table.concat(parts, '|')
end

-- CursorMoved fires constantly; the cursor-driven outputs are the PlantUML
-- preview float and (in stub mode) the per-line reveal. Re-render only when the
-- cursor's block membership -- or, under the stub, its image-row membership --
-- actually changes; ordinary navigation is a no-op.
function M.handle_cursor_moved()
  local sig = M.cursor_active_block_sig() .. '\0' .. M.stub_cursor_sig()
  if sig == cursor_block_sig then return end
  cursor_block_sig = sig
  M.send_images()
  notify_redraw()
end

function M.setup(opts)
  preview_cfg = normalize_preview(opts and opts.plantuml and opts.plantuml.preview)
  install_terminal_stub()
  if backend.img_available() then
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
  if not backend.img_available() then return end
  M.ensure_image_namespace()
  autocmd_group = vim.api.nvim_create_augroup('rendermark_image', { clear = true })

  -- Preview show/hide controls. These set an explicit override (M._preview_user)
  -- that wins over the configured `auto` flag until toggled back.
  vim.api.nvim_create_user_command('RendermarkPreviewShow', function()
    M._preview_user = true
    M.send_images()
  end, { desc = 'Show the PlantUML preview for the current block' })
  vim.api.nvim_create_user_command('RendermarkPreviewHide', function()
    M._preview_user = false
    M.send_images()
  end, { desc = 'Hide the PlantUML preview' })
  vim.api.nvim_create_user_command('RendermarkPreviewToggle', function()
    M._preview_user = not M.preview_active()
    M.send_images()
  end, { desc = 'Toggle the PlantUML preview' })

  vim.api.nvim_create_autocmd(
    { 'BufEnter', 'BufReadPost', 'FileType' },
    { group = autocmd_group, callback = function() M.send_images() end })

  -- TextChanged fires per keystroke; coalesce bursts into one render. SafeState
  -- still issues the authoritative render once typing pauses, so the final on-
  -- screen state is identical -- only intermediate per-keystroke renders are saved.
  local debounce_ms = tonumber(vim.g.rendermark_image_debounce_ms) or 30
  local debounced_send = util.debounce(function() M.send_images() end, debounce_ms)
  vim.api.nvim_create_autocmd(
    { 'TextChanged', 'TextChangedI' },
    { group = autocmd_group, callback = function() debounced_send() end })

  vim.api.nvim_create_autocmd(
    { 'WinScrolled', 'WinResized', 'WinNew', 'BufWinEnter', 'WinClosed' },
    { group = autocmd_group, callback = function() M.schedule_image_sync() end })

  -- User dismissal of the preview (<C-w>z / :pclose). This fires synchronously
  -- during the close, while st.programmatic_close is only true mid-teardown -- so
  -- it must NOT be scheduled. A user close suppresses auto-reopen until the cursor
  -- leaves the dismissed block.
  vim.api.nvim_create_autocmd('WinClosed', {
    group = autocmd_group,
    callback = function(args)
      local closed = tonumber(args.match)
      if not closed then return end
      for _, st in pairs(plantuml_states) do
        if st.float and st.float.win == closed then
          if not st.programmatic_close then
            st.dismissed_id = st.float.block_id
            st.float = nil
            preview_restore_equalize(st)
          end
          break
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd(
    { 'CursorMoved', 'CursorMovedI' },
    { group = autocmd_group, callback = function()
      vim.schedule(M.handle_cursor_moved)
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
  cursor_block_sig = M.cursor_active_block_sig() .. '\0' .. M.stub_cursor_sig()
end

return M
