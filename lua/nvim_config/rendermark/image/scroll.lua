-- A tall body image owns a window-sized viewport, not thousands of filler rows.
local Module = {}

function Module.new(M, state)
  local api = {}
  local windows, mapped = {}, {}

  function api.image_scroll_viewport(win, buf, row, key, height, viewport)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local w = windows[win]
    if not w or w.buf ~= buf or w.tick ~= tick then
      w = { buf = buf, tick = tick, rows = {} }
      windows[win] = w
    end
    local item = w.rows[row]
    if not item or item.key ~= key then
      item = { key = key, offset = 0 }
      w.rows[row] = item
    end
    -- The GUI snaps image origins to screen rows. Round the last offset up
    -- to a row too, so the final few pixels aren't cropped by that snap.
    local cell_h = math.max(1, tonumber(vim.g.neopp_cell_height_px) or 18)
    item.maximum = math.max(0, math.ceil((height - viewport) / cell_h) * cell_h)
    item.offset = math.min(item.offset, item.maximum)
    return item.offset, item.maximum
  end

  local function current_item()
    if not M.is_active() or vim.fn.mode() ~= 'n' then return end
    local win = vim.api.nvim_get_current_win()
    local w = windows[win]
    if not w or w.buf ~= vim.api.nvim_get_current_buf()
        or w.tick ~= vim.api.nvim_buf_get_changedtick(w.buf) then return end
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    if vim.fn.foldclosed(row + 1) ~= -1 then return end
    return w.rows[row], w, row
  end

  -- Called on cursor movement as well as input: entering from below starts at
  -- the bottom, while an explicit jump/search still moves the real cursor.
  function api.image_scroll_cursor_moved()
    local item, w, row = current_item()
    local win = vim.api.nvim_get_current_win()
    local previous = state.image_scroll_cursor
    state.image_scroll_cursor = { win = win, buf = vim.api.nvim_get_current_buf(), row = vim.api.nvim_win_get_cursor(win)[1] - 1 }
    if item and previous and previous.win == win and previous.buf == w.buf and previous.row ~= row then
      item.offset = previous.row > row and item.maximum or 0
      return true
    end
    return false
  end

  function api.scroll_image(direction, count)
    -- Layout may have changed since the last queued resize/edit synchronization.
    M.send_images()
    if api.image_scroll_cursor_moved() then M.send_images() end
    local item = current_item()
    if not item or item.maximum == 0 then return false end
    local remaining = direction > 0 and item.maximum - item.offset or item.offset
    if remaining <= 0 then return false end
    local step = math.max(1, tonumber(vim.g.neopp_cell_height_px) or 18)
    local consumed = math.min(count or 1, math.ceil(remaining / step))
    item.offset = math.max(0, math.min(item.maximum, item.offset + direction * consumed * step))
    -- Keep the entire image viewport visible while the real cursor stays at
    -- its source row. zt also removes a partially visible top filler band.
    vim.cmd('normal! zt')
    M.send_images()
    local rest = (count or 1) - consumed
    if rest > 0 then
      vim.cmd('normal! ' .. rest .. (direction > 0 and 'j' or 'k'))
      api.image_scroll_cursor_moved()
      M.send_images()
    end
    return true
  end

  function api.image_scroll_setup(group)
    local function attach(buf)
      if mapped[buf] or vim.bo[buf].filetype ~= 'markdown' then return end
      mapped[buf] = true
      local keys = {
        { 'j', 1 }, { 'k', -1 }, { '<Down>', 1 }, { '<Up>', -1 },
        { '<C-e>', 1 }, { '<C-y>', -1 },
        { '<C-d>', 1, 0.5 }, { '<C-u>', -1, 0.5 },
        { '<C-f>', 1, 1 }, { '<C-b>', -1, 1 },
        { '<PageDown>', 1, 1 }, { '<PageUp>', -1, 1 },
        { '<ScrollWheelDown>', 1, 3 }, { '<ScrollWheelUp>', -1, 3 },
      }
      for _, spec in ipairs(keys) do
        local key, direction, page = unpack(spec)
        local previous = vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(key, 'n', false, true) end)
        vim.keymap.set('n', key, function()
          local count = vim.v.count1
          if page then
            local step = page <= 1 and math.max(1, math.floor(vim.api.nvim_win_get_height(0) * page)) or page
            count = count * step
          end
          if api.scroll_image(direction, count) then return end
          local rhs = previous.rhs or key
          if previous.callback then
            rhs = previous.callback()
            if previous.expr ~= 1 or rhs == nil then return end
          elseif previous.expr == 1 then
            rhs = vim.fn.eval(rhs)
          end
          local prefix = vim.v.count > 0 and tostring(vim.v.count) or ''
          -- 'i' inserts before keys already typed ahead (jx, @a), keeping their order.
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(prefix .. rhs, true, false, true), 'ni', false)
        end, { buffer = buf, silent = true, desc = 'Scroll tall image or move normally' })
      end
    end
    vim.api.nvim_create_autocmd({ 'FileType', 'BufEnter' }, {
      group = group, callback = function(args) attach(args.buf) end,
    })
    vim.api.nvim_create_autocmd('WinClosed', {
      group = group, callback = function(args) windows[tonumber(args.match)] = nil end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', {
      group = group, callback = function(args)
        mapped[args.buf] = nil
        for win, w in pairs(windows) do if w.buf == args.buf then windows[win] = nil end end
      end,
    })
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do attach(buf) end
  end

  return api
end

return Module
