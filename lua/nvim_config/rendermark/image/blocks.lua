local Module = {}

local bitops = bit or bit32

function Module.stable_hash(s)
  local h = 2166136261
  for i = 1, #s do
    h = (bitops.bxor(h, s:byte(i)) * 16777619) % 4294967296
  end
  return string.format('%08x', h)
end

function Module.new(M, state)
  local api = {}
  local function trim(s)
    return (s or ''):gsub('^%s+', ''):gsub('%s+$', '')
  end

  local function markdown_fence(line)
    if type(line) ~= 'string' then return nil end
    local ticks, info = line:match('^%s*(```+)(.*)$')
    if ticks then return ticks:sub(1, 1), #ticks, trim(info or '') end
    local tildes
    tildes, info = line:match('^%s*(~~~+)(.*)$')
    if tildes then return tildes:sub(1, 1), #tildes, trim(info or '') end
    return nil
  end



  function api.markdown_plantuml_block_height(buf, row)
    M.plantuml_find_blocks(buf)
    local cached = state.block_cache[buf]
    for _, span in ipairs(cached and cached.heights or {}) do
      if row >= span.start_row and row <= span.end_row then
        return span.end_row - span.start_row + 1
      end
    end
    return nil
  end

  local plantuml_languages = { plantuml = true, puml = true, uml = true }

  local function plantuml_lang_of(info)
    local lang = (info or ''):match('^([^%s`~]*)')
    return lang and plantuml_languages[lang:lower()] == true
  end

  function api.plantuml_find_blocks(buf)
    local ok_tick, tick = pcall(vim.api.nvim_buf_get_changedtick, buf)
    if not ok_tick then return {} end
    local cached = state.block_cache[buf]
    if cached and cached.tick == tick then return cached.blocks end
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
    if not ok or not lines then return {} end
    local blocks, heights = {}, {}
    local fence
    for i, line in ipairs(lines) do
      local char, len, info = markdown_fence(line)
      if not fence then
        if char then
          fence = { char = char, len = len, info = (info or ''):lower(), start_row = i - 1 }
        end
      elseif char == fence.char and len >= fence.len then
        if fence.info:find('plantuml', 1, true) then
          heights[#heights + 1] = { start_row = fence.start_row, end_row = i - 1 }
        end
        if plantuml_lang_of(fence.info) then
          local body = {}
          for k = fence.start_row + 2, i - 1 do body[#body + 1] = lines[k] end
          blocks[#blocks + 1] = {
            start_row = fence.start_row,
            end_row = i - 1,
            lang = fence.info,
            text = table.concat(body, '\n') .. '\n',
          }
        end
        fence = nil
      end
    end
    if fence and fence.info:find('plantuml', 1, true) then
      heights[#heights + 1] = { start_row = fence.start_row, end_row = #lines - 1 }
    end
    state.block_cache[buf] = { tick = tick, blocks = blocks, heights = heights }
    return blocks
  end


  return api
end

return Module
