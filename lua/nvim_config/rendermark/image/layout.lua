local Module = {}

function Module.new(M, state)
  local api = {}
  function api.compute_image_display_size(image, max_w_px, max_rows, cell_h, zoom)
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

  function api.layout_image_line(images, opts)
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
    -- Opt-in text layout: start at row_start_x_override, per-gap widths in gaps_px.
    local row_start_override = tonumber(opts.row_start_x_override)
    local gaps_px = opts.gaps_px or {}
    -- Room kept right of the last image so the trailing prose isn't squeezed out.
    local trailing_reserve = math.max(0, tonumber(opts.trailing_px) or 0)
    -- gap_scale shrinks the text gaps only when images alone can't shrink enough.
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

    -- Shrink images to the budget left after the gaps; below 1px each, shrink gaps too.
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

  -- Pure: decode width/height/format from leading image bytes (no I/O).

  return api
end

return Module
