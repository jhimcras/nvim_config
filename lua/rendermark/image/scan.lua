local M = {}

function M.resolve_image_path(buf, raw_path)
  if raw_path == '' or raw_path:match('^%a[%w+.-]*://') then return nil end
  raw_path = raw_path:gsub('%%20', ' ')
  local expanded = vim.fn.expand(raw_path)
  if vim.fn.fnamemodify(expanded, ':p') == expanded then return vim.fn.fnamemodify(expanded, ':p') end

  local name = vim.api.nvim_buf_get_name(buf)
  local base = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  return vim.fn.fnamemodify(base .. '/' .. expanded, ':p')
end

local function add_markdown_image_link(deps, buf, row0, col0, end_col, raw, result, extra)
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

  local size = deps.read_image_size(path)
  if size and size.width and size.height and size.width > 0 and size.height > 0 then
    item.source_width = size.width
    item.source_height = size.height
  else
    item.error = 'unsupported'
  end
  result[#result + 1] = item
end

function M.scan_markdown_image_text(deps, buf, row0, text, result, opts)
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
      extra = {
        byte_col = s - 1,
        byte_end_col = e,
      }
    end
    add_markdown_image_link(deps, buf, row0, col0, col0 + math.max(1, match_width), raw, result, extra)
    search_at = e + 1
  end
end

function M.line_has_image_link(text)
  return type(text) == 'string' and text:find('!%[[^%]]*%]%(([^%)%s]+)%)') ~= nil
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

function M.collect_markdown_images(deps, buf, start_row, end_row)
  local result = {}
  local name = vim.api.nvim_buf_get_name(buf)
  local ext = vim.fn.fnamemodify(name, ':e'):lower()
  if vim.bo[buf].filetype ~= 'markdown' and ext ~= 'md' and ext ~= 'markdown' then return result end
  if start_row >= end_row then return result end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, start_row, end_row, false)
  if not ok then return result end

  for i, line in ipairs(lines) do
    local row0 = start_row + i - 1
    M.scan_markdown_image_text(deps, buf, row0, line, result, { base_col = 0 })
  end

  local ok_marks, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, { start_row, 0 }, { end_row, 0 }, { details = true })
  if ok_marks then
    for _, mark in ipairs(marks) do
      local row0 = mark[2]
      local col0 = mark[3]
      local details = mark[4] or {}
      if row0 and details.ns_id ~= deps.image_ns() and details.virt_text ~= nil then
        local text = M.virt_text_to_plain(details.virt_text)
        if text ~= '' then
          M.scan_markdown_image_text(deps, buf, row0, text, result, {
            base_col = col0,
            virtual = true,
            virt_text_pos = details.virt_text_pos,
            virt_text_win_col = details.virt_text_win_col,
            source_span_height = deps.markdown_plantuml_block_height(buf, row0),
          })
        end
      end
      if row0 and details.ns_id ~= deps.image_ns() and details.virt_lines ~= nil then
        local lines = M.virt_lines_to_plain(details.virt_lines)
        for idx, text in ipairs(lines) do
          if text ~= '' then
            M.scan_markdown_image_text(deps, buf, row0 + idx - 1, text, result, {
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

return M
