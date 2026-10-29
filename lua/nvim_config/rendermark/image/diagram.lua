-- Diagram blocks supplied by an external provider (see image/init.lua
-- `set_diagram_source`): drawing of rendered images, errors and the preview of
-- the block under the cursor. Nothing here runs a renderer.
local Module = {}

local scan = require('nvim_config.rendermark.image.scan')

-- Rows read below a block when looking for an exported image: one optional
-- blank line plus at most this many paragraph lines.
local EXPORT_PARAGRAPH_LINES = 30

function Module.new(M, state)
  local api = {}
  local delete_image = state.backend.delete_image
  local diagram_states = state.diagram_states
  local item_cache = state.item_cache

  local function is_markdown(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    local ext = vim.fn.fnamemodify(name, ':e'):lower()
    return vim.bo[buf].filetype == 'markdown' or ext == 'md' or ext == 'markdown'
  end

  -- Provider items for `buf`. The provider only reads memory, but it is still
  -- called once per changedtick (so edits never reuse old rows) and once per
  -- `refresh`; every other query reuses the cached list. Provider errors and
  -- malformed items are dropped so rendering never breaks.
  function api.diagram_items(buf)
    local source = state.diagram_source
    if not source or not vim.api.nvim_buf_is_valid(buf) then return {} end
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local cached = item_cache[buf]
    if cached and cached.tick == tick then return cached.items end
    local ok, list = pcall(source.items, buf)
    local items = {}
    if ok and type(list) == 'table' then
      local line_count = vim.api.nvim_buf_line_count(buf)
      for _, item in ipairs(list) do
        if type(item) == 'table' and type(item.start_row) == 'number' and type(item.end_row) == 'number'
            and item.start_row >= 0 and item.start_row <= item.end_row and item.start_row < line_count then
          items[#items + 1] = item
        end
      end
    end
    -- `exported`: end_row -> whether a link image follows the block (this tick only).
    item_cache[buf] = { tick = tick, items = items, exported = {} }
    return items
  end

  -- Whether the paragraph after the block ending at `item.end_row` (zero or one
  -- blank line in between) holds a local image link, i.e. the block was exported
  -- next to its source. The paragraph ends at a blank line or a code fence, and
  -- only those rows are read. The verdict is kept with the items of this
  -- changedtick, so an edit (of the link, the gap or the block) re-decides it on
  -- the next query.
  function api.diagram_exported_below(buf, item)
    M.diagram_items(buf)
    local cached = item_cache[buf]
    if not cached then return false end
    local verdict = cached.exported[item.end_row]
    if verdict ~= nil then return verdict end
    verdict = false
    local first = item.end_row + 1
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, first, first + 1 + EXPORT_PARAGRAPH_LINES, false)
    if ok then
      local i = 1
      if lines[i] and lines[i]:match('^%s*$') then i = i + 1 end
      while lines[i] and not lines[i]:match('^%s*$')
          and not lines[i]:match('^%s*```') and not lines[i]:match('^%s*~~~') do
        if scan.has_image_candidate(lines[i]) then
          for _, link in ipairs(scan.find_image_links(lines[i], scan.buf_defs(buf))) do
            -- Remote links are never drawn, so they cannot stand in for the block.
            if scan.resolve_image_path(buf, link[3]) then verdict = true; break end
          end
        end
        if verdict then break end
        i = i + 1
      end
    end
    cached.exported[item.end_row] = verdict
    return verdict
  end

  -- Height in rows of the diagram block containing `row` (nil outside blocks).
  function api.diagram_block_span(buf, row)
    for _, item in ipairs(M.diagram_items(buf)) do
      if row >= item.start_row and row <= item.end_row then
        return item.end_row - item.start_row + 1
      end
    end
    return nil
  end

  local function diagram_state_for(buf)
    local st = diagram_states[buf]
    if st then return st end
    st = { float = nil }
    diagram_states[buf] = st
    return st
  end

  -- 'equalalways' off while a preview split is open, so only the source window resizes.
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

  local function diagram_close_float(st)
    if not st then return end
    if not st.float then preview_restore_equalize(st); return end
    -- Programmatic: WinClosed must not treat it as a user dismissal.
    st.programmatic_close = true
    if st.float.win and vim.api.nvim_win_is_valid(st.float.win) then
      pcall(function()
        delete_image(vim.w[st.float.win].rendermark_diagram_preview_image_id)
        delete_image(vim.w[st.float.win].rendermark_diagram_preview_legacy_image_id)
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

  -- Open or refresh the 1-cell preview carrier float; emit_preview_float sizes it.
  local function diagram_open_float(buf, win, block, png)
    local st = diagram_state_for(buf)
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
      pcall(function() vim.w[st.float.win].rendermark_diagram_preview_source = meta end)
      return
    end
    diagram_close_float(st)

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
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { '![diagram](' .. png:gsub('\\', '/') .. ')' })
    vim.bo[fbuf].modifiable = false
    local ok, fwin = pcall(vim.api.nvim_open_win, fbuf, false, seed)
    if not ok then
      pcall(vim.api.nvim_buf_delete, fbuf, { force = true })
      return
    end
    pcall(function() vim.w[fwin].rendermark_diagram_preview_source = meta end)
    st.float = { buf = fbuf, win = fwin, path = png }
  end

  local split_dir_map = { left = 'left', right = 'right', top = 'above', bottom = 'below' }

  -- Open or reuse the preview split; shares the st.float slot (kind='split').
  local function diagram_open_split(buf, win, block, png)
    local st = diagram_state_for(buf)
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
    local link = '![diagram](' .. png:gsub('\\', '/') .. ')'

    -- Source block, for focus changes and WinClosed dismissal.
    local function stamp_source(f)
      f.source_win = win
      f.source_buf = buf
      f.start_row = block.start_row
      f.end_row = block.end_row
      f.block_id = block_id
    end

    -- Reuse the open pane, keeping its orientation.
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
      pcall(function() vim.w[st.float.win].rendermark_diagram_preview_source = meta end)
      return
    end
    diagram_close_float(st)

    -- Landscape source -> right, portrait -> bottom.
    local ok_w, w_cells = pcall(vim.api.nvim_win_get_width, win)
    local ok_h, h_cells = pcall(vim.api.nvim_win_get_height, win)
    local direction = M.smart_split_direction(
      ok_w and w_cells or vim.o.columns, ok_h and h_cells or vim.o.lines,
      vim.g.neopp_cell_width_px, vim.g.neopp_cell_height_px)
    local vertical = direction == 'vertical'
    local position = vertical and 'right' or 'bottom'
    local total = vertical and (tonumber(vim.o.columns) or 80) or (tonumber(vim.o.lines) or 24)
    local size = M.resolve_split_size(state.preview_cfg.split.size, total)

    local fbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[fbuf].buftype = 'nofile'
    vim.bo[fbuf].bufhidden = 'wipe'
    vim.bo[fbuf].filetype = 'markdown'
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { link })
    vim.bo[fbuf].modifiable = false

    local wcfg = { split = split_dir_map[position], win = win }
    if vertical then wcfg.width = size else wcfg.height = size end
    -- Split without re-equalizing siblings.
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
      -- Preview window for <C-w>z / :pclose; pcall since E590 if one exists.
      previewwindow = true,
    }) do
      pcall(vim.api.nvim_set_option_value, opt, val, { win = fwin })
    end
    pcall(function() vim.w[fwin].rendermark_diagram_preview_source = meta end)
    st.float = { buf = fbuf, win = fwin, path = png, kind = 'split' }
    stamp_source(st.float)
  end

  -- Timers, preview and caches of `buf` (the provider's own state is untouched).
  function api.diagram_cleanup_buf(buf)
    item_cache[buf] = nil
    local st = diagram_states[buf]
    if not st then return end
    if st.active_timer then pcall(function() st.active_timer:stop(); st.active_timer:close() end) end
    diagram_close_float(st)
    diagram_states[buf] = nil
  end

  -- Block under the cursor, in the focused source window only.
  local function diagram_active_block(buf, items)
    local cur = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(cur) then return nil, nil end
    if vim.w[cur].read_mode_active then return nil, nil end

    if vim.api.nvim_win_get_buf(cur) == buf then
      local row = vim.api.nvim_win_get_cursor(cur)[1] - 1
      for _, item in ipairs(items) do
        if row >= item.start_row and row <= item.end_row then
          return item, cur
        end
      end
      return nil, nil
    end

    -- Focus in our preview keeps its block; any other window closes it.
    local st = diagram_states[buf]
    if st and st.float and st.float.win == cur
        and st.float.source_win and vim.api.nvim_win_is_valid(st.float.source_win) then
      return { start_row = st.float.start_row, end_row = st.float.end_row }, st.float.source_win
    end

    return nil, nil
  end

  -- Ask the provider to render the cursor block's current text, 400 ms after
  -- the last call (typing keeps pushing it back). The provider caches by its
  -- own render key, so repeats are cheap; `live_sig` only stops this module
  -- from re-asking for the same text once a request was accepted.
  local function diagram_debounce_live(buf, item)
    local source = state.diagram_source
    if not source or type(source.request_live) ~= 'function' then return end
    local st = diagram_state_for(buf)
    local sig = tostring(vim.api.nvim_buf_get_changedtick(buf)) .. ':' .. tostring(item.start_row)
    if st.live_sig == sig then return end
    st.active_pending = sig
    if not st.active_timer then st.active_timer = vim.uv.new_timer() end
    st.active_timer:stop()
    st.active_timer:start(400, 0, vim.schedule_wrap(function()
      if not vim.api.nvim_buf_is_valid(buf) or st.active_pending ~= sig then return end
      if st.live_sig == sig then return end
      local ok, accepted = pcall(source.request_live, buf, item.start_row)
      if ok and accepted ~= false then st.live_sig = sig end
    end))
  end

  -- Draw provider diagram blocks: inactive ones into `result` (or `errors`),
  -- the active one previewed.
  function api.collect_diagram_images(buf, result, errors)
    local st_existing = diagram_states[buf]
    if not is_markdown(buf) then
      if st_existing then diagram_close_float(st_existing) end
      return
    end

    local items = M.diagram_items(buf)
    if #items == 0 then
      if st_existing then diagram_close_float(st_existing) end
      return
    end

    -- Concealing needs conceallevel >= 2.
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.api.nvim_win_is_valid(win) and (vim.wo[win].conceallevel or 0) < 2 then
        pcall(function() vim.wo[win].conceallevel = 2 end)
      end
    end

    local st = diagram_state_for(buf)

    -- `gpp` clears a <C-w>z dismissal and reopens the preview.
    if not st.mapped then
      st.mapped = true
      pcall(vim.keymap.set, 'n', 'gpp', function()
        local s = diagram_states[buf]
        if s then s.dismissed_id = nil end
        state.on_images_changed()
      end, { buffer = buf, desc = 'Reopen the diagram preview for the current block' })
    end

    local active_block, active_win = diagram_active_block(buf, items)
    local active_id = active_block
      and (tostring(active_block.start_row) .. ':' .. tostring(active_block.end_row)) or nil
    -- Clear the dismissal once the cursor leaves the block.
    if st.dismissed_id and st.dismissed_id ~= active_id then
      st.dismissed_id = nil
    end
    local active_floated = false

    for _, item in ipairs(items) do
      local is_active = active_block ~= nil and item.start_row == active_block.start_row
      -- A stale image stays up while its replacement is pending.
      local drawable = type(item.path) == 'string' and item.path ~= ''
        and (item.status == 'ready' or (item.status == 'pending' and item.stale == true))

      if is_active then
        -- Keep the source raw and preview it (live render requested, debounced).
        if M.preview_active() and not st.dismissed_id then
          if drawable then
            if state.preview_cfg.mode == 'split' then
              diagram_open_split(buf, active_win, item, item.path)
            else
              diagram_open_float(buf, active_win, item, item.path)
            end
            active_floated = true
          end
          if item.status == 'none' or (item.status == 'ready' and item.stale == true) then
            diagram_debounce_live(buf, item)
          end
        end
      elseif drawable then
        -- An exported image next to the block already shows the diagram: keep the source.
        local hidden = state.hide_when_exported and M.diagram_exported_below(buf, item)
        local size = not hidden and M.read_image_size(item.path)
        if size and size.width and size.height then
          local first = (vim.api.nvim_buf_get_lines(buf, item.start_row, item.start_row + 1, false) or {})[1] or ''
          result[#result + 1] = {
            row = item.start_row,
            col = 0,
            end_col = math.max(1, vim.fn.strdisplaywidth(first)),
            raw_path = item.path,
            path = item.path,
            source_width = size.width,
            source_height = size.height,
            source_span_height = item.end_row - item.start_row + 1,
            diagram = true,
            diagram_end_row = item.end_row,
            virtual = false,
          }
        end
      elseif item.status == 'failed' and errors then
        errors[#errors + 1] = { buf = buf, row = item.end_row, msg = item.error or 'render failed' }
      end
    end

    -- No active block: close the preview (a persistent split keeps its last diagram).
    if not active_floated then
      local st = diagram_states[buf]
      if st then
        local keep_persistent_split = state.preview_cfg.mode == 'split'
          and state.preview_cfg.split.lifecycle == 'persistent'
          and M.preview_active()
          and st.float and st.float.kind == 'split'
        if not keep_persistent_split then
          diagram_close_float(st)
        end
      end
    end
  end

  state.restore_equalize = preview_restore_equalize
  return api
end

return Module
