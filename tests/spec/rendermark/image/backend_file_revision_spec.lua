local Backend = require('nvim_config.rendermark.image.backend')

describe('image backend file revisions', function()
  local old_ui, old_state, backend, path, calls, entry

  before_each(function()
    old_ui, old_state = vim.ui, rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)
    calls = 0
    -- An asynchronous decode rejection still returns success to Lua.
    vim.ui = { img = { set = function() calls = calls + 1 end, del = function() end } }
    backend = Backend.new({})
    path = vim.fn.tempname()
    vim.fn.writefile({ 'broken' }, path, 'b')
    entry = { id = 'image', path = path, display_width_px = 160, display_height_px = 80 }
  end)

  after_each(function()
    vim.ui = old_ui
    rawset(_G, '__rendermark_image_backend', old_state)
    vim.fn.delete(path)
  end)

  it('resends an equal payload when a same-size file changes', function()
    backend.apply_payload({ entry })
    backend.apply_payload({ entry })
    assert.equals(1, calls)
    local st = assert(vim.uv.fs_stat(path))
    vim.fn.writefile({ 'normal' }, path, 'b')
    assert(vim.uv.fs_utime(path, st.atime.sec, st.mtime.sec + 2))
    assert.equals(st.size, vim.uv.fs_stat(path).size)
    backend.apply_payload({ entry })
    assert.equals(2, calls)
    backend.apply_payload({ entry })
    assert.equals(2, calls)
  end)

  it('clears revisions when an entry leaves the payload or is deleted', function()
    backend.apply_payload({ entry })
    backend.apply_payload({})
    assert.is_nil(rawget(_G, '__rendermark_image_backend').entry_revisions.image)
    backend.apply_payload({ entry })
    backend.delete_image(entry.id)
    assert.is_nil(rawget(_G, '__rendermark_image_backend').entry_revisions.image)
    backend.apply_payload({ entry })
    assert.equals(3, calls)
  end)

  it('clears revisions with and without an available provider', function()
    for _, available in ipairs({ true, false }) do
      backend.apply_payload({ entry })
      if not available then vim.ui = {} end
      backend.clear_all_images()
      assert.same({}, rawget(_G, '__rendermark_image_backend').entry_revisions)
    end
  end)
end)
