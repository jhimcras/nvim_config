local Module = {}

function Module.new(M, state)
  local api = {}
  local decorations = state.decorations
  function api.make_virt_lines(virt_height, label)
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

  -- Terminal stub: bordered box in the h-1 virt_lines below the anchor (fold-above path).
  function api.make_stub_box(h, label)
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

  -- Greedy display-width wrap; hard-breaks long words / CJK. Returns >= 1 row.
  -- Local copy of wrap.lua's wrap_indices to avoid a circular require.
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

  -- Pure: lay boxes { name, w_px, h_px, start_cell } into virt_h rows of chunks.
  -- Overlapping boxes are bumped right.
  function api.build_stub_box_rows(boxes, virt_h, cell_w)
    virt_h = math.max(1, virt_h or 1)
    cell_w = math.max(1, cell_w or 10)
    local hl = 'Comment'
    if not boxes or #boxes == 0 then return {} end

    local prepared = {}
    for _, b in ipairs(boxes) do
      local name = b.name or '?'
      local size = string.format('%dx%dpx  (%d rows)', b.w_px or 0, b.h_px or 0, virt_h)
      -- Width follows the image, not the label; floored so borders render.
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

  -- Pure: wrap text segments into their slots, bottom-aligned within virt_h rows.
  function api.build_image_text_rows(segments, virt_h, opts)
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

  -- Overlay `over` onto `base`, treating its spaces as transparent.
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

  -- Route footprint rows: v=0 -> anchor overlay, v<reserve_h -> virt_lines, else
  -- lower source rows. Cursor rows are skipped so conceal reveals them.
  local function emit_band_rows(buf, ns, row, reserve_h, source_span, virt_h, rows, cursor_rows)
    reserve_h = math.max(1, reserve_h or 1)
    source_span = math.max(1, source_span or 1)
    virt_h = math.max(1, virt_h or 1)
    local function overlay(brow, chunks)
      if cursor_rows and cursor_rows[brow] then return end
      if not chunks or #chunks == 0 then return end
      pcall(decorations.set, buf, ns, brow, 0, {
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
      pcall(decorations.set, buf, ns, row, 0,
        { virt_lines = virt_lines, virt_lines_above = false })
    end
  end

  -- Terminal stub boxes over the full image footprint; allocation is untouched.
  function api.draw_stub_footprint_box(buf, ns, reservation, cell_w, cursor_rows)
    local label = reservation.label
    local row = reservation.row
    local reserve_h = math.max(1, reservation.reserve_h or 1)
    local source_span = math.max(1, label.source_span or 1)
    local virt_h = math.max(1, label.virt_h or 1)
    local boxes = label.boxes or {}
    if #boxes == 0 then return end

    local box_rows = M.build_stub_box_rows(boxes, virt_h, cell_w)
    -- Weave gap text between the boxes.
    local rows = box_rows
    if label.text_rows then
      rows = {}
      for v = 0, virt_h - 1 do
        rows[v] = merge_chunk_rows(box_rows[v], label.text_rows[v])
      end
    end
    emit_band_rows(buf, ns, row, reserve_h, source_span, virt_h, rows, cursor_rows)
  end

  -- Terminal stub box filling the PlantUML preview float.
  function api.draw_stub_preview_box(buf, place, path, rect)
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
    -- Split carrier is larger than the box: pad to center it.
    if rect then
      local pad_left = math.max(0, (place.col or 0) - (rect.col or 0))
      if pad_left > 0 then
        local prefix = string.rep(' ', pad_left)
        for i = 1, #lines do lines[i] = prefix .. lines[i] end
      end
      local pad_top = math.max(0, (place.row or 0) - (rect.row or 0))
      for _ = 1, pad_top do table.insert(lines, 1, '') end
    end
    -- Drop markdown ft so `|...|` rows aren't reflowed as a table. Set only on
    -- change: FileType re-enters send_images (E218).
    if vim.bo[buf].filetype ~= '' then
      pcall(function() vim.bo[buf].filetype = '' end)
    end
    pcall(function() vim.bo[buf].modifiable = true end)
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
    pcall(function() vim.bo[buf].modifiable = false end)
  end


  state.emit_band_rows = emit_band_rows
  return api
end

return Module
