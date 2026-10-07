-- Markdown image orchestration and public API.
local M = {}
local util = require('nvim_config.util.cache')
local image_scan = require('nvim_config.rendermark.image.scan')
local image_size = require('nvim_config.rendermark.image.size')
local state = {
  block_cache = {},
  plantuml_states = {},
  reservation_sig = '',
  resyncing = false,
  stub_source_rows = {},
  decorations = require('nvim_config.rendermark.image.extmarks').new(),
}
local backend = require('nvim_config.rendermark.image.backend').new(M)
state.backend = backend
state.on_images_changed = function() M.send_images() end
local decorations = state.decorations
local read_image_size_impl = image_size.new_reader()
local layout_sig = ''
local image_sync_pending = false
local autocmd_group
local cursor_block_sig
local plantuml_states = state.plantuml_states
local install_terminal_stub = backend.install_terminal_stub
local notify_redraw = backend.notify_redraw

local function export(functions)
  for name, fn in pairs(functions) do M[name] = fn end
end

export(require('nvim_config.rendermark.image.blocks').new(M, state))
export(require('nvim_config.rendermark.image.screen').new(M, state))
export(require('nvim_config.rendermark.image.stub').new(M, state))
export(require('nvim_config.rendermark.image.layout').new(M, state))
export(require('nvim_config.rendermark.image.preview').new(M, state))
export(require('nvim_config.rendermark.image.plantuml').new(M, state))
export(require('nvim_config.rendermark.image.place').new(M, state))

function M.is_active()
  return backend.is_active()
end

function M.parse_image_size(data)
  return image_size.parse_image_size(data)
end

-- Image dimensions from `path`, cached by (mtime, size).
function M.read_image_size(path)
  return read_image_size_impl(path)
end

function M.resolve_image_path(buf, raw_path)
  return image_scan.resolve_image_path(buf, raw_path)
end

local function image_scan_deps()
  return {
    read_image_size = M.read_image_size,
    image_ns = function() return state.image_ns end,
    markdown_plantuml_block_height = M.markdown_plantuml_block_height,
  }
end

function M.scan_markdown_image_text(buf, row0, text, result, opts)
  return image_scan.scan_markdown_image_text(image_scan_deps(), buf, row0, text, result, opts)
end

-- True if `text` contains a markdown image link.
function M.line_has_image_link(text)
  return image_scan.line_has_image_link(text)
end

function M.virt_text_to_plain(virt_text)
  return image_scan.virt_text_to_plain(virt_text)
end

function M.virt_lines_to_plain(virt_lines)
  return image_scan.virt_lines_to_plain(virt_lines)
end

function M.collect_markdown_images(buf, start_row, end_row)
  return image_scan.collect_markdown_images(image_scan_deps(), buf, start_row, end_row)
end

function M.ensure_image_namespace()
  if not state.image_ns then state.image_ns = vim.api.nvim_create_namespace('rendermark_neopp_images') end
  return state.image_ns
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
  if pcall(decorations.set, buf, nsid, image.row, image.end_col or image.col or 0, opts) then
    return
  end
  pcall(decorations.set, buf, nsid, image.row, 0, opts)
end

function M.clear_image_extmarks()
  if decorations.reset() then backend.mark_changed() end
  local nsid = state.image_ns
  if not nsid then return end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, nsid, 0, -1)
    end
  end
end

function M.clear_images_for_buf(buf)
  if decorations.reset(buf) then backend.mark_changed() end
  local nsid = state.image_ns
  if nsid and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, nsid, 0, -1)
  end
  -- Schedule a sync so this buffer's images are freed early.
  vim.schedule(function() M.send_images() end)
end

-- Place the preview float beside its block (first fit of top/bottom/left/right).
function M.cursor_block_id(cursor_row, blocks)
  for _, block in ipairs(blocks or {}) do
    if cursor_row >= block.start_row and cursor_row <= block.end_row then
      return tostring(block.start_row) .. ':' .. tostring(block.end_row)
    end
  end
  return ''
end

-- Which block the focused cursor is in; CursorMoved skips rendering while stable.
function M.cursor_active_block_sig()
  local win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then return '' end
  -- In a preview window, mirror the source block's sig to avoid thrashing.
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
      -- topfill: scrolling through virt_lines changes neither topline nor
      -- WinScrolled, so this is the only resync path.
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

local ANCHOR_FILETYPES = { markdown = true, rmd = true, quarto = true, vimwiki = true }

local function tab_has_image_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if ANCHOR_FILETYPES[vim.bo[buf].filetype] then return true end
    local name = vim.api.nvim_buf_get_name(buf):lower()
    if name:find('%.md$') or name:find('%.markdown$') then return true end
  end
  return false
end

-- Only image-link rows: a layout change already shows in get_layout_sig, and
-- wrap/deco repaints resync through schedule_image_sync.
local function get_image_anchor_sig()
  local seen, parts = {}, {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local wi = vim.fn.getwininfo(win)
    local buf = vim.api.nvim_win_get_buf(win)
    if wi and wi[1] and ANCHOR_FILETYPES[vim.bo[buf].filetype] then
      -- Per window, not merged per buffer: two far-apart splits would span the gap.
      local start_row = math.max(0, wi[1].topline - 2)
      local end_row = math.max(start_row, wi[1].botline)
      local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, start_row, end_row, false)
      if ok then
        for i, line in ipairs(lines) do
          local row = start_row + i - 1
          local key = tostring(buf) .. ':' .. tostring(row)
          if not seen[key] and image_scan.line_has_image_link(line) then
            seen[key] = true
            parts[#parts + 1] = key .. '=' .. M.image_anchor_extmark_sig(buf, row, row + 1)
          end
        end
      end
    end
  end
  table.sort(parts)
  return table.concat(parts, '#')
end

function M.get_layout_sync_sig()
  if not tab_has_image_win() then return '' end
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

-- Whether a cursor is on a stub image source row in any window ('' without stub).
function M.stub_cursor_sig()
  if not M._stub_active then return '' end
  local parts = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local rows = state.stub_source_rows[buf]
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

-- Re-render on CursorMoved only when block (or stub row) membership changes.
function M.handle_cursor_moved()
  local sig = M.cursor_active_block_sig() .. '\0' .. M.stub_cursor_sig()
  if sig == cursor_block_sig then return end
  cursor_block_sig = sig
  M.send_images()
  notify_redraw()
end

function M.setup(opts)
  state.preview_cfg = state.normalize_preview(opts and opts.plantuml and opts.plantuml.preview)
  install_terminal_stub()
  if backend.img_available() then
    M._init()
  else
    -- neopp installs vim.ui.img after config load; wait for NeoppReady.
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

  -- Show/hide overrides M._preview_user, which wins over the configured `auto`.
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

  -- Coalesce TextChanged bursts; SafeState renders once typing pauses.
  local debounce_ms = tonumber(vim.g.rendermark_image_debounce_ms) or 30
  local debounced_send = util.debounce(function() M.send_images() end, debounce_ms)
  vim.api.nvim_create_autocmd(
    { 'TextChanged', 'TextChangedI' },
    { group = autocmd_group, callback = function() debounced_send() end })

  vim.api.nvim_create_autocmd(
    { 'WinScrolled', 'WinResized', 'WinNew', 'BufWinEnter', 'WinClosed' },
    { group = autocmd_group, callback = function() M.schedule_image_sync() end })

  -- User dismissal (<C-w>z / :pclose) suppresses reopen until the cursor leaves.
  -- Unscheduled: st.programmatic_close is only set during synchronous teardown.
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
            state.restore_equalize(st)
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
