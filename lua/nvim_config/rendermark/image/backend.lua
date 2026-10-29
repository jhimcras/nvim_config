local Backend = {}

function Backend.new(host)
  local state = rawget(_G, '__rendermark_image_backend')
  if not state then
    state = { live_ids = {}, stub_store = {} }
    rawset(_G, '__rendermark_image_backend', state)
  end

  state.entries = state.entries or {}
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
  -- the sync, and a failed entry is not retried until it changes.
  local function safe_set(id, path, opts)
    local ok, err = pcall(vim.ui.img.set, id, path, opts)
    if not ok then
      vim.notify_once('rendermark: vim.ui.img.set failed: ' .. tostring(err), vim.log.levels.WARN)
    end
  end

  local function safe_del(id)
    if type(vim.ui.img.del) == 'function' then pcall(vim.ui.img.del, id) end
  end

  function self.apply_payload(payload)
    if not self.img_available() then return end
    local next_ids = {}
    for _, entry in ipairs(payload) do
      local id, path = entry.id, entry.path
      next_ids[id] = true
      if not vim.deep_equal(state.entries[id], entry) then
        local opts = {}
        for k, v in pairs(entry) do
          if k ~= 'id' and k ~= 'path' then opts[k] = v end
        end
        safe_set(id, path, opts)
        state.entries[id] = vim.deepcopy(entry)
        dirty = true
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
  end

  function self.delete_image(id)
    if not id then return end
    state.live_ids[id] = nil
    state.entries[id] = nil
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
