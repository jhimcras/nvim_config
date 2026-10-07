local Module = {}

local stable_hash = require('nvim_config.rendermark.image.blocks').stable_hash

function Module.new(M, state)
  local api = {}
  local delete_image = state.backend.delete_image
  local preview_defaults = {
    mode = 'float',            -- 'float' | 'split'
    auto = true,               -- open when the cursor enters a block
    split = {
      position = 'right',      -- 'left'|'right' (vertical) | 'top'|'bottom' (horizontal)
      size = 0.5,              -- 'half' | fraction (<1) | absolute cells (>=1)
      lifecycle = 'cursor',    -- 'cursor' | 'persistent' (pane stays, keeps last diagram)
    },
  }
  state.preview_cfg = vim.deepcopy(preview_defaults)

  -- nil: follow state.preview_cfg.auto; true/false: explicit Show/Hide.
  M._preview_user = nil

  -- Fill invalid fields from defaults; `position` implies the direction.
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

  function api.preview_config() return state.preview_cfg end

  function api.preview_active()
    if M._preview_user ~= nil then return M._preview_user end
    return state.preview_cfg.auto ~= false
  end

  -- Split `size`: fraction (<1) of `total`, or absolute cells (>=1).
  function api.resolve_split_size(size, total)
    total = math.max(1, tonumber(total) or 1)
    local n = tonumber(size)
    if not n or n <= 0 then n = 0.5 end
    local cells = (n < 1) and math.floor(total * n + 0.5) or math.floor(n + 0.5)
    return math.max(1, math.min(total, cells))
  end

  -- Fit an image into a 0-based cell rect { row, col, width, height }, centered.
  function api.center_in_rect(rect, image, cell_w, cell_h)
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

  -- Split direction from the window's pixel aspect (cells aren't square).
  function api.smart_split_direction(w_cells, h_cells, cell_w, cell_h)
    cell_w = math.max(1, tonumber(cell_w) or 10)
    cell_h = math.max(1, tonumber(cell_h) or 18)
    local w_px = math.max(1, tonumber(w_cells) or 1) * cell_w
    local h_px = math.max(1, tonumber(h_cells) or 1) * cell_h
    return (w_px >= h_px) and 'vertical' or 'horizontal'
  end

  function api.preview_image_id(ps, place)
    return table.concat({
      'preview',
      tostring(ps and ps.buf or 0),
      tostring(ps and ps.start_row or 0),
      tostring(place and place.disp_w or 0) .. 'x' .. tostring(place and place.disp_h or 0),
    }, ':')
  end

  function api.preview_legacy_image_id(carrier_buf, path, place)
    return table.concat({
      'preview',
      tostring(carrier_buf or 0),
      stable_hash(path or ''),
      tostring(place and place.disp_w or 0) .. 'x' .. tostring(place and place.disp_h or 0),
    }, ':')
  end

  function api.compute_preview_placement(ps, image, cell_w, cell_h)
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

    -- Shrink to fit the editor (aspect preserving), then round up to whole cells.
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

  -- Move/resize the carrier float; last geometry is cached to avoid a set_config loop.
  M._preview_float_geom = M._preview_float_geom or {}
  function api.reposition_preview_float(win, place)
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
      -- No 'wrap': the long link line would spill under the image.
      pcall(vim.api.nvim_set_option_value, 'wrap', false, { win = win })
      M._preview_float_geom[key] = { row = place.row, col = place.col, width = place.width, height = place.height }
    end
  end

  function api.emit_preview_float(info, buf_images, payload, cell_w, cell_h)
    local ps = info.preview_source
    if not ps then return end

    -- The float may have been wiped since the `wins` snapshot.
    if not (vim.api.nvim_win_is_valid(info.win) and vim.api.nvim_buf_is_valid(info.buf)) then
      return
    end

    -- Size from ps.path: the carrier isn't markdown, so scanning it finds nothing.
    local image
    if ps.path then
      local size = M.read_image_size(ps.path)
      if size and size.width and size.height then
        image = { path = ps.path, row = 0, col = 0,
                  source_width = size.width, source_height = size.height }
      end
    end
    if not image then
      -- Fallback: scanned image link.
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
      -- Split carrier is user-sized: center, don't resize.
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
      -- Terminal: draw the stub box into the carrier buffer.
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


  state.normalize_preview = normalize_preview
  return api
end

return Module
