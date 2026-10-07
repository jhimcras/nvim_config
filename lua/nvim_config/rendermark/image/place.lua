local Module = {}

local stable_hash = require('nvim_config.rendermark.image.blocks').stable_hash

function Module.new(M, state)
  local api = {}
  local backend = state.backend
  local decorations = state.decorations
  local apply_payload = backend.apply_payload
  local clear_all_images = backend.clear_all_images
  local notify_redraw = backend.notify_redraw
  local emit_band_rows = state.emit_band_rows
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

  -- Re-entrancy guard: autocmds fired by send_images call it back (E218); drop them.
  function api.send_images()
    if M._send_images_active then return end
    M._send_images_active = true
    local ok, err = pcall(M._send_images_impl)
    M._send_images_active = false
    if not ok then decorations.cancel(); error(err) end
  end

  local function VisibleWindows(max_rows)
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

    return wins, buf_ranges
  end

  local function CollectImages(buf_ranges)
    local buf_images = {}
    local plantuml_errors = {}
    for buf, range in pairs(buf_ranges) do
      if vim.api.nvim_buf_is_valid(buf) then
        buf_images[buf] = M.collect_markdown_images(buf, range.start_row, range.end_row)
        M.collect_plantuml_images(buf, buf_images[buf], plantuml_errors)
      end
    end

    return buf_images, plantuml_errors
  end

  local function AddPreviewCarriers(wins)
    -- Include a carrier float created after the `wins` snapshot so it gets sized.
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

  end

  local function NewReservations()
    local image_reservations = {}
    local image_conceals = {}
    local reservation_carry_h = 0
    local function remember_image_reservation(win, buf, row, virt_h, source_span_height, label)
      local reserve_row = row
      local reserve_above = false
      local span = math.max(1, source_span_height or 1)
      local reserve_h = math.max(1, (virt_h or 1) - span + 1)

      local ok, fold = pcall(vim.api.nvim_win_call, win, function()
        return { start = vim.fn.foldclosed(row + 1), finish = vim.fn.foldclosedend(row + 1) }
      end)
      if ok and fold and fold.start and fold.start > 0 and fold.finish and fold.finish >= fold.start then
        local line_count = vim.api.nvim_buf_line_count(buf)
        -- A folded block is one display row; reserve below it for trailing text.
        reserve_h = math.max(1, virt_h or 1)
        if fold.finish < line_count then
          reserve_row = fold.finish
          reserve_above = true
        end
      end

      -- virt_lines inside a closed fold are swallowed; carry the height to the next anchor.
      local hidden = false
      local okc, fc = pcall(vim.api.nvim_win_call, win, function()
        return vim.fn.foldclosed(reserve_row + 1)
      end)
      if okc and type(fc) == 'number' and fc > 0 then hidden = true end
      if hidden then
        -- The fold line itself takes a row, so carry one less.
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
        current.span = math.min(current.span or math.huge, span)
        current.label = current.label or label
      else
        image_reservations[buf][key] = {
          row = reserve_row,
          reserve_h = reserve_h,
          -- Hiding a source row shifts rows below, so it belongs in the signature.
          span = span,
          above = reserve_above,
          label = label,
        }
      end
    end

    return image_reservations, image_conceals, remember_image_reservation, function() reservation_carry_h = 0 end
  end

  local function GroupWindowImages(ctx, info)
    local buf_images, payload, cell_w, cell_h, max_rows = ctx.buf_images, ctx.payload, ctx.cell_w, ctx.cell_h, ctx.max_rows
    local by_row = {}
    for _, image in ipairs(buf_images[info.buf] or {}) do
      if image.table_layout then
        local sp = M.safe_screenpos(info.win, image.row + 1, 1)
        local anchor = sp.row > 0 and (sp.row - 1)
          or M.offscreen_anchor_grid_row(info.win, info.w, image.row)
        if anchor then
          local w, layout = info.w, image.table_layout
          local grid_row = anchor + layout.row
          local grid_col = w.wincol - 1 + w.textoff + layout.col
          payload[#payload + 1] = {
            id = 'buf:' .. info.buf .. ':win:' .. info.win .. ':' .. image.row .. ':' .. image.col .. ':' .. stable_hash(image.path),
            buf = info.buf, row = image.row, col = image.col, path = image.path,
            source_width = image.source_width, source_height = image.source_height,
            grid_row = grid_row, grid_col = grid_col, text_grid_row = grid_row,
            -- The table already blanked the link; occlusion would hide its borders.
            text_col = -1, text_end_col = -1,
            virtual = false, win_left = w.wincol - 1, win_width = w.width,
            win_top = w.winrow - 1, win_height = w.height, text_offset = w.textoff,
            dest_x_px = grid_col * cell_w, dest_y_px = grid_row * cell_h,
            display_width_px = layout.width, display_height_px = layout.height,
            clip_x_px = (w.wincol - 1 + w.textoff) * cell_w,
            clip_y_px = (w.winrow - 1) * cell_h,
            clip_width_px = math.max(1, (w.width - w.textoff) * cell_w),
            clip_height_px = w.height * cell_h,
            virt_height = math.ceil(layout.height / cell_h), zindex = 50,
            above_floats = info.above_floats == true,
          }
        end
        goto continue_image
      end
      if image.error then
        M.set_image_error_extmark(info.buf, image)
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
      -- Keep the image while its footprint touches the viewport (mid-block scrolling).
      local span = math.max(1, tonumber(measured_image.source_span_height) or 1)
      local keep = lnum <= measure_w.botline
        and lnum + math.max(span, max_rows + 1) - 1 >= measure_w.topline
      if keep then
        by_row[measured_image.row] = by_row[measured_image.row] or {}
        by_row[measured_image.row][#by_row[measured_image.row] + 1] = measured_image
      end
      ::continue_image::
    end

    return by_row
  end

  local function TextLayout(line_images, measure_buf, row, text_left_px, cell_w, gap_px)
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

    return text_layout
  end

  local function ReserveRow(ctx, r, layouts, image_rows)
    local row, info, line_images = r.row, r.info, r.line_images
    local measure_win, measure_buf = r.measure_win, r.measure_buf
    local text_left_px, layout_text_right_px, text_layout = r.text_left_px, r.layout_text_right_px, r.text_layout
    local layout_grid_row, stack_bottom_grid_row = r.layout_grid_row, r.stack_bottom_grid_row
    local cell_w, image_conceals, remember_image_reservation = ctx.cell_w, ctx.image_conceals, ctx.remember_image_reservation
    local virt_h = image_rows
    -- Source rows kept on screen; the conceal pass below hides the rest.
    local visible_span = nil
    if #layouts > 0 then
      stack_bottom_grid_row = layout_grid_row + image_rows
      local source_span_height = nil
      for _, layout in ipairs(layouts) do
        source_span_height = math.min(source_span_height or math.huge, layout.image.source_span_height or 1)
      end
      -- Concealed rows still take space: cap the span at virt_h, drop the rest.
      visible_span = math.min(math.max(1, source_span_height or 1), virt_h)
      local text_left_cell = math.floor(text_left_px / math.max(1, cell_w))
      local label = { source_span = visible_span, virt_h = virt_h }
      if M._stub_active then
        -- One box per image at its text-relative offset.
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
        -- Slots: leading, the gap after each image, and the trailing slot.
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
      remember_image_reservation(measure_win, measure_buf, row, virt_h, visible_span, label)
      if text_layout then
        -- Conceal the raw row; label.text_rows redraws the prose.
        local cbuf = (line_images[1] and line_images[1].payload_buf) or info.buf
        image_conceals[cbuf] = image_conceals[cbuf] or {}
        image_conceals[cbuf][#image_conceals[cbuf] + 1] = {
          row = row,
          col = 0,
          end_col = #text_layout.raw_line,
        }
      end
    end

    return virt_h, visible_span, stack_bottom_grid_row
  end

  local function EmitRow(ctx, r, layouts, virt_h, visible_span)
    local info, text_layout = r.info, r.text_layout
    local source_grid_row, win_left_col, win_top_row = r.source_grid_row, r.win_left_col, r.win_top_row
    local measure_w = r.measure_w
    local payload, image_conceals = ctx.payload, ctx.image_conceals
    local cell_w, cell_h, above_floats = ctx.cell_w, ctx.cell_h, r.above_floats
    for idx, layout in ipairs(layouts) do
      local image = layout.image
      local payload_buf = image.payload_buf or info.buf
      -- Conceal the link text (text-layout lines conceal the whole row).
      if text_layout then
        -- handled by the whole-line conceal below
      elseif not image.virtual and image.byte_col then
        image_conceals[payload_buf] = image_conceals[payload_buf] or {}
        image_conceals[payload_buf][#image_conceals[payload_buf] + 1] = {
          row = image.row,
          col = image.byte_col,
          end_col = image.byte_end_col,
        }
      elseif image.plantuml then
        -- Conceal fence + body so the raw code never shows under the image.
        image_conceals[payload_buf] = image_conceals[payload_buf] or {}
        local last = math.max(image.row, tonumber(image.plantuml_end_row) or image.row)
        local block_lines = vim.api.nvim_buf_get_lines(payload_buf, image.row, last + 1, false) or {}
        local keep = visible_span or #block_lines
        for li, line in ipairs(block_lines) do
          if li > keep then
            -- Surplus row: drop it.
            image_conceals[payload_buf][#image_conceals[payload_buf] + 1] = {
              row = image.row + li - 1,
              hide_line = true,
            }
          else
            image_conceals[payload_buf][#image_conceals[payload_buf] + 1] = {
              row = image.row + li - 1,
              col = 0,
              end_col = #line,
            }
          end
        end
      end
      payload[#payload + 1] = {
        -- Per-window id so splits don't collide. Size is excluded so a re-fit
        -- updates in place instead of blinking.
        id = 'buf:' .. payload_buf .. ':win:' .. info.win .. ':' .. image.row .. ':' .. image.col .. ':' .. stable_hash(image.path),
        buf = payload_buf,
        row = image.row,
        col = image.col,
        grid_row = layout.grid_row,
        grid_col = layout.grid_col,
        -- Grid row of the link text to occlude (differs from grid_row when stacked).
        text_grid_row = source_grid_row,
        -- Grid columns of the full link text to occlude.
        text_col = layout.grid_col,
        text_end_col = layout.grid_col + math.max(1, (image.end_col or image.col) - image.col),
        virtual = image.virtual == true,
        win_left = win_left_col,
        win_width = measure_w.width,
        -- Owning window's row band, so the GUI can crop at the window top.
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

  local function LayoutRow(ctx, info, row, line_images, stack_bottom_grid_row)
    local cell_w, cell_h, max_rows, gap_px = ctx.cell_w, ctx.cell_h, ctx.max_rows, ctx.gap_px
    local zoom_scale, max_ratio = ctx.zoom_scale, ctx.max_ratio
      local first_image = line_images[1] or {}
    local measure_win = first_image.measure_win or info.win
    local measure_buf = first_image.measure_buf or info.buf
    local measure_w = first_image.measure_w or info.w
    local above_floats = first_image.above_floats == true
    local lnum = row + 1
    local sp_line = M.safe_screenpos(measure_win, lnum, 1)
    -- Anchor above topline: synthesize its grid row so the image renders clipped.
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
      -- Adjacent closed folds: stack below the previous image.
      local layout_grid_row = source_grid_row
      if stack_bottom_grid_row and source_grid_row < stack_bottom_grid_row then
        layout_grid_row = stack_bottom_grid_row
      end
      -- Text layout: re-render the prose around links in the gaps (width capped).
      local text_layout = TextLayout(line_images, measure_buf, row, text_left_px, cell_w, gap_px)

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

      local r = {
        row = row, info = info, line_images = line_images,
        measure_win = measure_win, measure_buf = measure_buf, measure_w = measure_w,
        text_left_px = text_left_px, layout_text_right_px = layout_text_right_px,
        text_layout = text_layout, layout_grid_row = layout_grid_row,
        stack_bottom_grid_row = stack_bottom_grid_row, source_grid_row = source_grid_row,
        win_left_col = win_left_col, win_top_row = win_top_row, above_floats = above_floats,
      }
      local virt_h, visible_span
      virt_h, visible_span, stack_bottom_grid_row = ReserveRow(ctx, r, layouts, image_rows)
      EmitRow(ctx, r, layouts, virt_h, visible_span)
    end
    return stack_bottom_grid_row
  end

  local function LayoutWindow(ctx, info)
    ctx.reset_carry()
    if info.preview_source then
      M.emit_preview_float(info, ctx.buf_images, ctx.payload, ctx.cell_w, ctx.cell_h)
      return
    end
    local by_row = GroupWindowImages(ctx, info)
    local rows = {}
    for row in pairs(by_row) do rows[#rows + 1] = row end
    table.sort(rows)
    local stack_bottom_grid_row
    for _, row in ipairs(rows) do
      stack_bottom_grid_row = LayoutRow(ctx, info, row, by_row[row], stack_bottom_grid_row)
    end
  end

  local function ReservationSignature(image_reservations)
    local reservation_parts = {}
    for buf, reservations in pairs(image_reservations) do
      for _, reservation in pairs(reservations) do
        reservation_parts[#reservation_parts + 1] = table.concat({
          tostring(buf),
          tostring(reservation.row),
          tostring(reservation.reserve_h),
          tostring(reservation.span),
          tostring(reservation.above),
        }, ':')
      end
    end
    table.sort(reservation_parts)
    local new_reservation_sig = table.concat(reservation_parts, '|')
    local reservation_changed = new_reservation_sig ~= state.reservation_sig

    return new_reservation_sig, reservation_changed
  end

  local function EmitDecorations(ctx)
    local image_reservations, image_conceals, plantuml_errors, cell_w = ctx.image_reservations, ctx.image_conceals, ctx.plantuml_errors, ctx.cell_w
    -- Cursor rows per window: the stub skips them so conceal reveals the link.
    -- READ windows are excluded (concealcursor='nvic').
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

    state.stub_source_rows = {}
    for buf, reservations in pairs(image_reservations) do
      for _, reservation in pairs(reservations) do
        local label = reservation.label
        if M._stub_active and label and not reservation.above then
          -- Box over the concealed rows + virt_lines; allocation unchanged.
          local span = math.max(1, label.source_span or 1)
          state.stub_source_rows[buf] = state.stub_source_rows[buf] or {}
          for r = reservation.row, reservation.row + span - 1 do
            state.stub_source_rows[buf][r] = true
          end
          M.draw_stub_footprint_box(buf, state.image_ns, reservation, cell_w, cursor_rows_for(buf))
        elseif label and label.text_rows and not reservation.above then
          -- GUI: route gap text into virt_lines / row overlays.
          emit_band_rows(buf, state.image_ns, reservation.row, reservation.reserve_h,
            label.source_span or 1, label.virt_h or reservation.reserve_h,
            label.text_rows, cursor_rows_for(buf))
        else
          local virt_lines = M.make_virt_lines(reservation.reserve_h, label)
          if #virt_lines > 0 then
            pcall(decorations.set, buf, state.image_ns, reservation.row, 0,
              { virt_lines = virt_lines, virt_lines_above = reservation.above })
          end
        end
      end
    end
    for buf, conceals in pairs(image_conceals) do
      for _, c in ipairs(conceals) do
        if c.hide_line then
          pcall(decorations.set, buf, state.image_ns, c.row, 0, {
            conceal_lines = '',
            priority = 250,
          })
        else
          pcall(decorations.set, buf, state.image_ns, c.row, c.col, {
            end_col = c.end_col,
            conceal = '',
            priority = 250,
          })
        end
      end
    end
    for _, e in ipairs(plantuml_errors) do
      if vim.api.nvim_buf_is_valid(e.buf) then
        pcall(decorations.set, e.buf, state.image_ns, e.row, 0, {
          virt_lines = { { { ' [plantuml: ' .. e.msg .. ']', 'WarningMsg' } } },
          virt_lines_above = false,
        })
      end
    end

  end

  function api._send_images_impl()
    if not backend.img_available() then return end

    local enabled = vim.g.neopp_images_enabled
    if enabled == false then
      M.clear_image_extmarks()
      state.reservation_sig = ''
      clear_all_images()
      notify_redraw()
      return
    end

    decorations.begin()
    local payload = {}
    local cell_w = tonumber(vim.g.neopp_cell_width_px) or 10
    local cell_h = tonumber(vim.g.neopp_cell_height_px) or 18
    local max_ratio = tonumber(vim.g.neopp_image_max_width_ratio) or 1.0
    local max_rows = tonumber(vim.g.neopp_image_max_height_rows) or 30
    local gap_px = tonumber(vim.g.neopp_image_gap_px) or cell_w
    local zoom_scale = tonumber(vim.g.neopp_font_zoom_scale) or 1.0
    local ctx = {
      payload = payload, cell_w = cell_w, cell_h = cell_h, max_ratio = max_ratio,
      max_rows = max_rows, gap_px = gap_px, zoom_scale = zoom_scale,
    }
    local wins, buf_ranges = VisibleWindows(max_rows)
    ctx.buf_images, ctx.plantuml_errors = CollectImages(buf_ranges)
    AddPreviewCarriers(wins)
    ctx.image_reservations, ctx.image_conceals, ctx.remember_image_reservation, ctx.reset_carry = NewReservations()
    for _, info in ipairs(wins) do LayoutWindow(ctx, info) end
    local new_reservation_sig, reservation_changed = ReservationSignature(ctx.image_reservations)
    EmitDecorations(ctx)

    if decorations.apply(M.ensure_image_namespace()) then backend.mark_changed() end

    if reservation_changed then
      -- virt_lines changes shift rows: drop images and resync once layout settles.
      state.reservation_sig = new_reservation_sig
      clear_all_images()
    else
      apply_payload(payload)
    end

    if reservation_changed then
      vim.schedule(function()
        pcall(vim.cmd, 'redraw!')
        if not state.resyncing then
          state.resyncing = true
          pcall(M.send_images)
          state.resyncing = false
        end
        notify_redraw()
      end)
    else
      notify_redraw()
    end
  end


  return api
end

return Module
