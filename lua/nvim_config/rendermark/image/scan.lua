local M = {}
local docindex = require('nvim_config.rendermark.image.docindex')

-- Prefix test, not equality with ':p': on Windows ':p' normalizes slashes.
function M.is_absolute_path(path, is_windows)
  if is_windows then
    return path:match('^%a:[/\\]') ~= nil or path:match('^[/\\]') ~= nil
  end
  return path:sub(1, 1) == '/'
end

local function percent_decode(s)
  return (s:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

-- `~` and `~/…` (vim.fn.expand would also glob '?' and '#').
local function expand_home(path)
  if path:find('^~[/\\]') or path == '~' then
    local home = vim.uv.os_homedir()
    if home then return home .. path:sub(2) end
  elseif path:find('^%$') then
    return vim.fn.expand(path)
  end
  return path
end

local function absolutize(buf, path)
  path = expand_home(path)
  if M.is_absolute_path(path, vim.fn.has('win32') == 1) then
    return vim.fn.fnamemodify(path, ':p')
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local base = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  return vim.fn.fnamemodify(base .. '/' .. path, ':p')
end

-- Absolute file path of a markdown image destination, nil for empty or remote
-- (`scheme://`) ones. `<…>` wrapping is dropped. '?query', '#anchor' and
-- '%xx' escapes (%20 included) are not part of the file name, but a file that
-- really has such characters wins: the as-written name is tried first and the
-- others only when it does not exist.
function M.resolve_image_path(buf, raw_path)
  raw_path = raw_path:match('^<(.*)>$') or raw_path
  if raw_path == '' or raw_path:match('^%a[%w+.-]*://') then return nil end
  local seen, variants = {}, {}
  local function add(path)
    if not seen[path] then seen[path] = true; variants[#variants + 1] = path end
  end
  local bare = raw_path:match('^[^?#]+') or raw_path
  add(raw_path)
  add(bare)
  add(percent_decode(raw_path))
  add(percent_decode(bare))
  -- Most likely intent when nothing exists: no query/anchor, escapes decoded.
  local best = variants[#variants]
  if #variants == 1 then return absolutize(buf, best) end
  for _, variant in ipairs(variants) do
    local path = absolutize(buf, variant)
    if vim.uv.fs_stat(path) then return path end
  end
  return absolutize(buf, best)
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

-- Byte ranges { first, last } (1-based, inclusive) of inline code spans.
local function code_spans(text)
  local spans, opening = {}, nil
  for pos, ticks in text:gmatch('()(`+)') do
    if opening and #ticks == opening.len then
      spans[#spans + 1] = { opening.pos, pos + #ticks - 1 }
      opening = nil
    elseif not opening then
      opening = { pos = pos, len = #ticks }
    end
  end
  return spans
end

local function in_code_span(spans, pos)
  for _, span in ipairs(spans) do
    if pos >= span[1] and pos <= span[2] then return true end
  end
  return false
end

-- Destination of an inline link; `pos` is just after the '('. Accepts
-- `path`, `<path with spaces>`, balanced parentheses in a bare path and an
-- optional "title" / 'title' / (title). Returns the raw destination and the
-- index of the closing ')', or nil.
local function inline_destination(text, pos)
  pos = text:find('[^ \t]', pos) or #text + 1
  local raw
  if text:sub(pos, pos) == '<' then
    local close = text:find('>', pos + 1, true)
    if not close then return nil end
    raw, pos = text:sub(pos + 1, close - 1), close + 1
  else
    local depth, i = 0, pos
    while i <= #text do
      local c = text:byte(i)
      if c == 32 or c == 9 then break end
      if c == 40 then
        depth = depth + 1
      elseif c == 41 then
        if depth == 0 then break end
        depth = depth - 1
      end
      i = i + 1
    end
    raw, pos = text:sub(pos, i - 1), i
  end
  if raw == '' then return nil end
  local after = text:find('[^ \t]', pos) or #text + 1
  local opener = text:sub(after, after)
  if after > pos and (opener == '"' or opener == "'" or opener == '(') then
    local close = text:find(opener == '(' and ')' or opener, after + 1, true)
    if not close then return nil end
    pos = text:find('[^ \t]', close + 1) or #text + 1
  else
    pos = after
  end
  if text:sub(pos, pos) ~= ')' then return nil end
  return raw, pos
end

-- Image links outside inline code, as { s, e, raw, ref } (1-based bytes; `ref`
-- is the label of a reference image). `![alt](path "title")` always counts.
-- `![alt][ref]`, `![ref][]` and `![ref]` count only when `defs` (label ->
-- destination, or a function returning it) defines the label.
local function find_image_links(text, defs)
  local links = {}
  if not text:find('![', 1, true) then return links end
  local spans = nil
  local search_at = 1
  while search_at <= #text do
    local s, bracket_end, alt = text:find('!%[([^%]]*)%]', search_at)
    if not s then break end
    local e, raw, ref
    local following = text:sub(bracket_end + 1, bracket_end + 1)
    if following == '(' then
      local dest, close = inline_destination(text, bracket_end + 2)
      if dest then e, raw = close, dest end
    elseif defs then
      if following == '[' then
        local label, after = text:match('^%[([^%]]*)%]()', bracket_end + 1)
        if label then ref, e = label ~= '' and label or alt, after - 1 end
      else
        ref, e = alt, bracket_end
      end
      if ref then
        if type(defs) == 'function' then defs = defs() or {} end
        raw = defs[docindex.normalize_label(ref)]
        if not raw then e, ref = nil, nil end
      end
    end
    if e then
      spans = spans or code_spans(text)
      -- A link inside inline code is literal text.
      if not in_code_span(spans, s) then links[#links + 1] = { s, e, raw, ref } end
      search_at = e + 1
    else
      search_at = s + 2
    end
  end
  return links
end

M.find_image_links = find_image_links

-- Reference definitions of `buf`, as a lazy getter for find_image_links.
function M.buf_defs(buf)
  return function()
    local ok, index = pcall(docindex.get, buf)
    return ok and index.defs or nil
  end
end

function M.scan_markdown_image_text(deps, buf, row0, text, result, opts)
  if type(text) ~= 'string' or text == '' then return end
  opts = opts or {}
  local base_col = math.max(0, tonumber(opts.base_col) or 0)
  local virtual = opts.virtual == true
  for _, link in ipairs(find_image_links(text, M.buf_defs(buf))) do
    local s, e, raw = link[1], link[2], link[3]

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
    if link[4] then extra.ref_label = link[4] end
    add_markdown_image_link(deps, buf, row0, col0, col0 + math.max(1, match_width), raw, result, extra)
  end
end

-- `buf` lets `![ref]` forms count when the document defines the label.
function M.line_has_image_link(text, buf)
  -- Plain '![' prefilter: the pattern alone tries a match at every byte.
  return type(text) == 'string' and text:find('![', 1, true) ~= nil
    and #find_image_links(text, buf and M.buf_defs(buf)) > 0
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

  local table_state = require('nvim_config.rendermark.table_state')
  -- Table rows the wrap has not drawn (off screen) carry no image at all.
  local table_rows = table_state.table_source_rows(buf, start_row, end_row)
  for i, line in ipairs(lines) do
    local row0 = start_row + i - 1
    local table_images = table_state.table_row(buf, row0)
    if table_images then
      for _, image in ipairs(table_images) do result[#result + 1] = vim.deepcopy(image) end
    elseif not table_rows[row0] and line:find('![', 1, true)
        and not docindex.in_fence(docindex.get(buf), row0) then
      -- Fenced code is literal text; the document is indexed once per tick.
      M.scan_markdown_image_text(deps, buf, row0, line, result, { base_col = 0 })
    end
  end

  local ok_marks, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1, { start_row, 0 }, { end_row, 0 }, { details = true })
  if ok_marks then
    for _, mark in ipairs(marks) do
      local row0 = mark[2]
      local col0 = mark[3]
      local details = mark[4] or {}
      if table_state.table_row(buf, row0) or table_rows[row0] then goto continue_mark end
      if row0 and details.ns_id ~= deps.image_ns() and details.virt_text ~= nil then
        local text = M.virt_text_to_plain(details.virt_text)
        if M.line_has_image_link(text) then
          M.scan_markdown_image_text(deps, buf, row0, text, result, {
            base_col = col0,
            virtual = true,
            virt_text_pos = details.virt_text_pos,
            virt_text_win_col = details.virt_text_win_col,
            source_span_height = deps.diagram_block_span(buf, row0),
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
      ::continue_mark::
    end
  end

  return result
end

return M
