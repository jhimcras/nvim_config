-- Fake diagram provider shared by the rendermark image specs. It scans the
-- buffer for ```<lang> fences the way a real provider would and answers with
-- DiagramItems whose status/path/stale/error the test can change at any time.
local H = {}

function H.fence_source(opts)
  opts = opts or {}
  local src = {
    langs = opts.langs or { plantuml = true, puml = true, uml = true },
    status = opts.status or 'none',
    path = opts.path,
    stale = opts.stale or false,
    error = opts.error,
    item_calls = 0,
    live_calls = {},
    live_result = true,
  }
  function src.items(buf)
    src.item_calls = src.item_calls + 1
    if src.raise then error(src.raise) end
    local items, open = {}, nil
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if not open then
        local lang = line:match('^```(%w+)')
        if lang and src.langs[lang:lower()] then open = { lang = lang, row = i - 1 } end
      elseif line:match('^```%s*$') then
        items[#items + 1] = {
          start_row = open.row, end_row = i - 1, key = open.lang .. ':' .. open.row,
          lang = open.lang, path = src.path, format = src.path and 'png' or nil,
          stale = src.stale, status = src.status, error = src.error,
        }
        open = nil
      end
    end
    return items
  end
  function src.request_live(buf, row)
    src.live_calls[#src.live_calls + 1] = { buf = buf, row = row }
    return src.live_result
  end
  return src
end

return H
