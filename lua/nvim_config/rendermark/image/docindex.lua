-- Per-buffer facts the image scan needs from the whole document: fenced code
-- block rows (their image syntax is literal text) and reference definitions
-- (`[label]: path "title"`). One line pass, cached per changedtick, built only
-- when a scanned line actually holds an image candidate.
local M = {}

local cache = {}

function M.normalize_label(label)
  label = vim.trim(label):gsub('%s+', ' ')
  if label:find('[\128-\255]') then return vim.fn.tolower(label) end
  return label:lower()
end

-- Destination of a one-line reference definition, or nil. At most 3 leading
-- spaces, optional "title" / 'title' / (title) after the destination.
local function definition(line)
  local label, rest = line:match('^ ? ? ?%[([^%]]+)%]:%s*(.-)%s*$')
  if not label or label:sub(1, 1) == '^' or label:find('^%s*$') then return nil end
  local dest, tail = rest:match('^<([^>]*)>(.*)$')
  if not dest then dest, tail = rest:match('^(%S+)(.*)$') end
  if not dest or dest == '' then return nil end
  if tail ~= '' and not (tail:match('^%s+"[^"]*"$') or tail:match("^%s+'[^']*'$")
      or tail:match('^%s+%b()$')) then
    return nil
  end
  return M.normalize_label(label), dest
end

-- Opening/closing fence of `line`: char, run length and the rest of the line.
local function fence(line)
  if not (line:find('```', 1, true) or line:find('~~~', 1, true)) then return nil end
  local run, rest = line:match('^[ \t>]*(```+)(.*)$')
  if run and rest:find('`', 1, true) then run = nil end -- an info string has no backticks
  if not run then run, rest = line:match('^[ \t>]*(~~~+)(.*)$') end
  if not run then return nil end
  return run:sub(1, 1), #run, rest
end

local function build(buf, tick)
  local index = { tick = tick, fences = {}, defs = {} }
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok then return index end
  local open
  for i, line in ipairs(lines) do
    local ch, len, rest = fence(line)
    if open then
      if ch == open.ch and len >= open.len and rest:find('^%s*$') then
        index.fences[#index.fences + 1] = { open.row, i - 1 }
        open = nil
      end
    elseif ch then
      open = { ch = ch, len = len, row = i - 1 }
    elseif line:find(']:', 1, true) then
      local label, dest = definition(line)
      -- The first definition of a label wins.
      if label and index.defs[label] == nil then index.defs[label] = dest end
    end
  end
  -- An unclosed fence runs to the end of the document.
  if open then index.fences[#index.fences + 1] = { open.row, #lines - 1 } end
  return index
end

function M.get(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cached = cache[buf]
  if cached and cached.tick == tick then return cached end
  cached = build(buf, tick)
  cache[buf] = cached
  return cached
end

-- Whether 0-based `row` lies on or between the fence lines of a code block.
function M.in_fence(index, row)
  local fences = index.fences
  local lo, hi = 1, #fences
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local f = fences[mid]
    if row < f[1] then
      hi = mid - 1
    elseif row > f[2] then
      lo = mid + 1
    else
      return true
    end
  end
  return false
end

function M.forget(buf)
  cache[buf] = nil
end

return M
