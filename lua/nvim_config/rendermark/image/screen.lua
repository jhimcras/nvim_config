local Module = {}

function Module.new(M, state)
  local api = {}
  local function extmark_virt_lines_sig(virt_lines)
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

  function api.safe_screenpos(win, lnum, col)
    local ok, sp = pcall(vim.fn.screenpos, win, lnum, col)
    if ok and sp and sp.row ~= nil then return sp end
    return { row = 0, col = 0, endcol = 0, curscol = 0 }
  end

  function api.screenpos_display_col(sp)
    if not sp then return 0 end
    return tonumber(sp.col) or 0
  end

  -- Grid row (may be negative) of a line above topline; screenpos() returns 0 there.
  -- end_vcol = 0 counts the fill above topline but not the line; minus topfill = hidden rows.
  function api.offscreen_anchor_grid_row(win, w, anchor_row)
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

  function api.strip_indent_space_chars(text)
    if type(text) ~= 'string' then return '' end
    return text
      :gsub('[%s]', '')
      :gsub('\194\160', '')
      :gsub('\226\128[\128-\138]', '')
      :gsub('\226\128\175', '')
      :gsub('\226\129\159', '')
      :gsub('\227\128\128', '')
  end

  function api.is_indent_text(text, highlight)
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

  function api.virt_text_width(virt_text)
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

  function api.virtual_indent_anchor_min_col(buf, row, col, base_col, buffer_col)
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

  function api.image_anchor_extmark_sig(buf, start_row, end_row)
    local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, { start_row, 0 }, { end_row, 0 }, { details = true })
    if not ok then return '' end

    local parts = {}
    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      if details.ns_id ~= state.image_ns then
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

  function api.buffer_display_col(buf, row, col)
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, row, row + 1, false)
    if not ok or not lines or not lines[1] then return nil end
    local prefix = lines[1]:sub(1, math.max(0, col))
    return vim.fn.strdisplaywidth(prefix) + 1
  end

  function api.image_anchor_display_col(buf, row, col, sp, win_info)
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

  function api.virtual_image_anchor_display_col(buf, row, image, sp, win_info)
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


  return api
end

return Module
