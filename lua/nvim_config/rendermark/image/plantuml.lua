local Module = {}

local stable_hash = require('nvim_config.rendermark.image.blocks').stable_hash

function Module.new(M, state)
  local api = {}
  local delete_image = state.backend.delete_image
  local plantuml_states = state.plantuml_states
  local plantuml_missing_notified = false
  local function plantuml_norm_path(p)
    if not p or p == '' then return nil end
    return vim.fn.fnamemodify(p, ':p')
  end

  local function plantuml_jar()
    return vim.g.rendermark_plantuml_jar or vim.env.RENDERMARK_PLANTUML_JAR or vim.env.PLANTUML_JAR
  end

  function api.plantuml_resolve_command()
    local jar = plantuml_norm_path(plantuml_jar())
    if jar and vim.fn.filereadable(jar) == 1 then
      local java = vim.fn.exepath('java')
      if java ~= '' then return java, { '-jar', jar, '-tpng' } end
    end
    local wrapper = vim.fn.exepath('plantuml')
    if wrapper ~= '' then return wrapper, { '-tpng' } end
    return nil, nil, 'PlantUML disabled: install plantuml or set RENDERMARK_PLANTUML_JAR / PLANTUML_JAR.'
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
        if vim.api.nvim_buf_is_valid(buf) then state.on_images_changed() end
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

  -- Debounced render of the cursor block. Returns the cached entry, or nil.
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
        state.on_images_changed()
      end
    end))
    return nil
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

  local function plantuml_close_float(st)
    if not st then return end
    if not st.float then preview_restore_equalize(st); return end
    -- Programmatic: WinClosed must not treat it as a user dismissal.
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

  -- Open or refresh the 1-cell preview carrier float; emit_preview_float sizes it.
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

  -- Open or reuse the preview split; shares the st.float slot (kind='split').
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
      pcall(function() vim.w[st.float.win].rendermark_plantuml_preview_source = meta end)
      return
    end
    plantuml_close_float(st)

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
    pcall(function() vim.w[fwin].rendermark_plantuml_preview_source = meta end)
    st.float = { buf = fbuf, win = fwin, path = png, kind = 'split' }
    stamp_source(st.float)
  end

  function api.plantuml_cleanup_buf(buf)
    state.block_cache[buf] = nil
    local st = plantuml_states[buf]
    if not st then return end
    if st.active_timer then pcall(function() st.active_timer:stop(); st.active_timer:close() end) end
    for _, job in pairs(st.jobs) do if job.kill then job.kill() end end
    plantuml_close_float(st)
    if st.temp_dir then pcall(vim.fn.delete, st.temp_dir, 'rf') end
    plantuml_states[buf] = nil
  end

  -- Block under the cursor, in the focused source window only.
  local function plantuml_active_block(buf, blocks)
    local cur = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(cur) then return nil, nil end
    if vim.w[cur].read_mode_active then return nil, nil end

    if vim.api.nvim_win_get_buf(cur) == buf then
      local row = vim.api.nvim_win_get_cursor(cur)[1] - 1
      for _, block in ipairs(blocks) do
        if row >= block.start_row and row <= block.end_row then
          return block, cur
        end
      end
      return nil, nil
    end

    -- Focus in our preview keeps its block; any other window closes it.
    local st = plantuml_states[buf]
    if st and st.float and st.float.win == cur
        and st.float.source_win and vim.api.nvim_win_is_valid(st.float.source_win) then
      return { start_row = st.float.start_row, end_row = st.float.end_row }, st.float.source_win
    end

    return nil, nil
  end

  -- Render PlantUML blocks: inactive ones into `result`, the active one previewed.
  function api.collect_plantuml_images(buf, result, errors)
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

    -- Concealing needs conceallevel >= 2.
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.api.nvim_win_is_valid(win) and (vim.wo[win].conceallevel or 0) < 2 then
        pcall(function() vim.wo[win].conceallevel = 2 end)
      end
    end

    local st = plantuml_state_for(buf)

    -- `gpp` clears a <C-w>z dismissal and reopens the preview.
    if not st.mapped then
      st.mapped = true
      pcall(vim.keymap.set, 'n', 'gpp', function()
        local s = plantuml_states[buf]
        if s then s.dismissed_id = nil end
        state.on_images_changed()
      end, { buffer = buf, desc = 'Reopen the PlantUML preview for the current block' })
    end

    local active_block, active_win = plantuml_active_block(buf, blocks)
    local active_id = active_block
      and (tostring(active_block.start_row) .. ':' .. tostring(active_block.end_row)) or nil
    -- Clear the dismissal once the cursor leaves the block.
    if st.dismissed_id and st.dismissed_id ~= active_id then
      st.dismissed_id = nil
    end
    local active_floated = false

    for _, block in ipairs(blocks) do
      local is_active = active_block ~= nil and block.start_row == active_block.start_row

      if is_active then
        -- Keep the source raw and preview it (debounced).
        if M.preview_active() and not st.dismissed_id then
          local entry = plantuml_debounce_active(buf, block)
          if entry and entry.status == 'ready' then
            if state.preview_cfg.mode == 'split' then
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

    -- No active block: close the preview (a persistent split keeps its last diagram).
    if not active_floated then
      local st = plantuml_states[buf]
      if st then
        local keep_persistent_split = state.preview_cfg.mode == 'split'
          and state.preview_cfg.split.lifecycle == 'persistent'
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

  -- Normalize a carrier float's preview-source metadata for emit_preview_float.

  state.restore_equalize = preview_restore_equalize
  return api
end

return Module
