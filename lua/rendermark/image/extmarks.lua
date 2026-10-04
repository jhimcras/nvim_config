-- Collect desired marks and replace only rows whose decorations changed.
local M = {}

function M.new()
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

return M
