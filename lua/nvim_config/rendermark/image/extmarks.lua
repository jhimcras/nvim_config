-- Collect desired marks and replace only rows whose decorations changed.
local M = {}

function M.owned_namespaces()
  local owned = {}
  for name, ns in pairs(vim.api.nvim_get_namespaces()) do
    if name == 'rendermark_neopp_images' or name:match('^rendermark_neopp_images_win_') then
      owned[ns] = true
    end
  end
  return owned
end

local function new_namespace()
  local cached, pending = {}, nil
  local self = {}

  function self.begin()
    pending = {}
  end

  function self.set(buf, ns, row, col, opts)
    if not pending then return vim.api.nvim_buf_set_extmark(buf, ns, row, col, opts) end
    pending[buf] = pending[buf] or {}
    pending[buf][row] = pending[buf][row] or {}
    table.insert(pending[buf][row], { col = col, opts = opts })
  end

  function self.reset(buf)
    local changed = buf and cached[buf] ~= nil or (not buf and next(cached) ~= nil)
    if buf then cached[buf] = nil else cached = {} end
    return changed
  end

  function self.cancel()
    pending = nil
  end

  function self.apply(ns)
    local desired = pending
    pending = nil
    local changed = false
    local buffers = {}
    for buf in pairs(cached) do buffers[buf] = true end
    for buf in pairs(desired) do buffers[buf] = true end
    for buf in pairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        local tick = vim.api.nvim_buf_get_changedtick(buf)
        local old = cached[buf] or { rows = {}, tick = tick }
        -- Edits can move extmarks; invalidate their old row coordinates.
        if old.tick ~= tick then
          vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
          old.rows = {}
          changed = true
        end
        local rows = desired[buf] or {}
        local all_rows = {}
        for row in pairs(old.rows) do all_rows[row] = true end
        for row in pairs(rows) do all_rows[row] = true end
        for row in pairs(all_rows) do
          if not vim.deep_equal(old.rows[row], rows[row]) then
            vim.api.nvim_buf_clear_namespace(buf, ns, row, row + 1)
            for _, mark in ipairs(rows[row] or {}) do
              pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, mark.col, mark.opts)
            end
            changed = true
          end
        end
        cached[buf] = next(rows) and { rows = rows, tick = tick } or nil
      else
        cached[buf] = nil
      end
    end
    return changed
  end

  return self
end

-- Keep independent differential caches for window-scoped namespaces.
function M.new()
  local scopes, active = {}, false
  local self = {}
  function self.begin()
    active = true
    for _, scope in pairs(scopes) do scope.begin() end
  end
  function self.set(buf, ns, row, col, opts)
    ns = ns or vim.api.nvim_create_namespace('rendermark_neopp_images')
    if not scopes[ns] then
      scopes[ns] = new_namespace()
      if active then scopes[ns].begin() end
    end
    return scopes[ns].set(buf, ns, row, col, opts)
  end
  function self.apply()
    active = false
    local changed = false
    for ns, scope in pairs(scopes) do
      if scope.apply(ns) then changed = true end
    end
    return changed
  end
  function self.cancel()
    active = false
    for _, scope in pairs(scopes) do scope.cancel() end
  end
  function self.reset(buf)
    local changed = false
    for ns, scope in pairs(scopes) do
      if scope.reset(buf) then changed = true end
      for _, b in ipairs(buf and { buf } or vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) then
          vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
        end
      end
    end
    return changed
  end
  return self
end

return M
