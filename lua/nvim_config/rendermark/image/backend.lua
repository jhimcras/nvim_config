local Backend = {}

function Backend.new(host)
  local state = rawget(_G, '__rendermark_image_backend')
  if not state then
    state = { live_ids = {}, stub_store = {}, failed = {} }
    rawset(_G, '__rendermark_image_backend', state)
  end

  state.entries = state.entries or {}
  state.failed = state.failed or {}
  local self = {}
  local dirty = false

  function self.mark_changed() dirty = true end

  function self.img_available()
    return vim.ui and vim.ui.img and type(vim.ui.img.set) == 'function'
  end

  function self.is_active()
    return self.img_available() and vim.g.neopp_images_enabled ~= false
  end

  -- Text-box stub for terminals without an image provider: RENDERMARK_IMG_STUB=1
  -- or vim.g.rendermark_img_stub (the stub flag of the former LSP drawing plugin). '', '0' and 0 mean off.
  local function flag_on(flag)
    return flag ~= nil and flag ~= false and flag ~= '' and flag ~= '0' and flag ~= 0
  end

  local function stub_requested()
    return not self.img_available()
      and (flag_on(vim.env.RENDERMARK_IMG_STUB) or flag_on(vim.g.rendermark_img_stub))
  end

  function self.install_terminal_stub()
    if not stub_requested() then return end
    vim.ui = vim.ui or {}
    vim.ui.img = {
      set = function(id, path, opts) state.stub_store[id] = { path = path, opts = opts } end,
      get = function(id) return state.stub_store[id] end,
      del = function(id) state.stub_store[id] = nil end,
    }
    host._stub_active = true
  end

  -- A provider that fails (no terminal support) or lacks `del` must not break
  -- the sync. `set` fails when it raises or returns `false`; a failed entry is
  -- not retried until its revision changes (see `revision`).
  local function safe_set(id, path, opts)
    local ok, ret, err = pcall(vim.ui.img.set, id, path, opts)
    if ok and ret ~= false then return true end
    local msg = ok and (err ~= nil and tostring(err) or 'returned false') or tostring(ret)
    vim.notify_once('rendermark: vim.ui.img.set failed for ' .. tostring(path) .. ': ' .. msg, vim.log.levels.WARN)
    return false
  end

  local function safe_del(id)
    if type(vim.ui.img.del) == 'function' then pcall(vim.ui.img.del, id) end
  end

  -- What a failure depends on: the file (mtime, size) and the size it is shown
  -- at. Scrolling changes the entry (clip, position) but not this.
  local function revision(path, width, height)
    local st = path and vim.uv.fs_stat(path)
    return table.concat({
      path or '', st and st.mtime.sec or 0, st and st.mtime.nsec or 0, st and st.size or 0,
      width or 0, height or 0,
    }, ':')
  end

  -- True while `id` failed to display and nothing it depends on has changed.
  function self.is_failed(id, path, width, height)
    local failure = state.failed[id]
    return failure ~= nil and failure.rev == revision(path, width, height)
  end

  -- Forget every failure, so the next sync tries each image again.
  function self.forget_failures()
    for id in pairs(state.failed) do state.failed[id] = nil end
  end

  -- Returns true when an entry newly failed: the caller then redraws so the
  -- failure box replaces the blank reservation.
  function self.apply_payload(payload)
    if not self.img_available() then return false end
    local next_ids = {}
    local new_failure = false
    for _, entry in ipairs(payload) do
      local id, path = entry.id, entry.path
      next_ids[id] = true
      local failure = state.failed[id]
      local rev = failure and revision(path, entry.display_width_px, entry.display_height_px)
      -- A failed image changed on disk or in size is asked again even if the entry is equal.
      local changed = (failure and rev ~= failure.rev) or not vim.deep_equal(state.entries[id], entry)
      if changed then
        if failure and rev == failure.rev then
          -- Same revision as the failure: remember the entry, do not ask again.
          state.entries[id] = vim.deepcopy(entry)
        else
          local opts = {}
          for k, v in pairs(entry) do
            if k ~= 'id' and k ~= 'path' then opts[k] = v end
          end
          local was_shown = state.entries[id] ~= nil and not failure
          if safe_set(id, path, opts) then
            state.failed[id] = nil
          else
            state.failed[id] = {
              rev = rev or revision(path, entry.display_width_px, entry.display_height_px),
              buf = entry.buf,
            }
            new_failure = true
            -- An earlier successful set may still be on screen under the box.
            if was_shown then safe_del(id) end
          end
          state.entries[id] = vim.deepcopy(entry)
          dirty = true
        end
      end
    end
    for id in pairs(state.live_ids) do
      if not next_ids[id] then
        safe_del(id)
        state.entries[id] = nil
        dirty = true
      end
    end
    state.live_ids = next_ids
    for id, failure in pairs(state.failed) do
      if failure.buf and not vim.api.nvim_buf_is_valid(failure.buf) then state.failed[id] = nil end
    end
    return new_failure
  end

  function self.delete_image(id)
    if not id then return end
    state.live_ids[id] = nil
    state.entries[id] = nil
    state.failed[id] = nil
    dirty = true
    if self.img_available() then safe_del(id) end
  end

  function self.clear_all_images()
    if not self.img_available() then state.live_ids = {}; state.entries = {}; return end
    for id in pairs(state.live_ids) do safe_del(id); dirty = true end
    state.live_ids = {}
    state.entries = {}
  end

  function self.notify_redraw()
    if not dirty then return end
    dirty = false
    local ch = vim.g.neopp_channel
    if ch then pcall(vim.rpcnotify, ch, 'force_redraw') end
  end

  return self
end

return Backend
