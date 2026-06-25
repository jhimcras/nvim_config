local Backend = {}

function Backend.new(host)
  local live_ids = {}
  local stub_store = {}

  local self = {}

  function self.img_available()
    return vim.ui and vim.ui.img and type(vim.ui.img.set) == 'function'
  end

  function self.is_active()
    return self.img_available() and vim.g.neopp_images_enabled ~= false
  end

  local function stub_requested()
    return (not self.img_available())
       and (vim.env.RENDERMARK_IMG_STUB or vim.g.rendermark_img_stub)
  end

  function self.install_terminal_stub()
    if not stub_requested() then return end
    vim.ui = vim.ui or {}
    vim.ui.img = {
      set = function(id, path, opts) stub_store[id] = { path = path, opts = opts } end,
      get = function(id) return stub_store[id] end,
      del = function(id) stub_store[id] = nil end,
    }
    host._stub_active = true
  end

  function self.apply_payload(payload)
    if not self.img_available() then return end
    local next_ids = {}
    for _, entry in ipairs(payload) do
      local id, path = entry.id, entry.path
      local opts = {}
      for k, v in pairs(entry) do
        if k ~= 'id' and k ~= 'path' then opts[k] = v end
      end
      next_ids[id] = true
      vim.ui.img.set(id, path, opts)
    end
    for id in pairs(live_ids) do
      if not next_ids[id] then vim.ui.img.del(id) end
    end
    live_ids = next_ids
  end

  function self.clear_all_images()
    if not self.img_available() then live_ids = {}; return end
    for id in pairs(live_ids) do vim.ui.img.del(id) end
    live_ids = {}
  end

  function self.notify_redraw()
    local ch = vim.g.neopp_channel
    if ch then pcall(vim.rpcnotify, ch, 'force_redraw') end
  end

  return self
end

return Backend
