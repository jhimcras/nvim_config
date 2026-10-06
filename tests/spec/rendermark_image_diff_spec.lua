local extmarks = require('nvim_config.rendermark.image.extmarks')
local backend = require('nvim_config.rendermark.image.backend')

describe('image differential updates', function()
  it('reuses unchanged rows, updates changed rows and clears moved or removed marks', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two', 'three' })
    local ns = vim.api.nvim_create_namespace('image_diff_test')
    local marks = extmarks.new()
    local function render(text)
      marks.begin()
      marks.set(buf, ns, 0, 0, { conceal = '', end_col = 1 })
      marks.set(buf, ns, 2, 0, { virt_lines = { { { text, 'Normal' } } } })
      return marks.apply(ns)
    end
    assert.is_true(render('a'))
    local original = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.is_false(render('a'))
    assert.same(original, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
    assert.is_true(render('b'))
    local changed = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.equals(original[1][1], changed[1][1])
    assert.are_not.equals(original[2][1], changed[2][1])
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted' })
    assert.is_true(render('b'))
    local moved = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.equals(0, moved[1][2])
    assert.equals(2, moved[2][2])
    marks.begin()
    assert.is_true(marks.apply(ns))
    assert.same({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
    marks.begin()
    assert.is_false(marks.apply(ns))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('sends only changed images and redraws only after changes', function()
    local old_ui, old_rpc, old_channel = vim.ui, vim.rpcnotify, vim.g.neopp_channel
    local old_state = rawget(_G, '__rendermark_image_backend')
    rawset(_G, '__rendermark_image_backend', nil)
    local sets, deletes, redraws = 0, 0, 0
    vim.ui = { img = { set = function() sets = sets + 1 end, del = function() deletes = deletes + 1 end } }
    vim.g.neopp_channel = 1
    vim.rpcnotify = function() redraws = redraws + 1 end
    local b = backend.new({})
    local payload = { { id = 'one', path = 'a', row = 1 }, { id = 'two', path = 'b', row = 2 } }
    b.apply_payload(payload); b.notify_redraw()
    b.apply_payload(payload); b.notify_redraw()
    local unchanged = { sets, deletes, redraws }
    payload[1].row = 3
    b.apply_payload(payload); b.notify_redraw()
    local changed = { sets, deletes, redraws }
    b.apply_payload({ payload[1] }); b.notify_redraw()
    b.clear_all_images(); b.notify_redraw()
    b.apply_payload({ payload[1] }); b.notify_redraw()
    local final = { sets, deletes, redraws }
    vim.ui, vim.rpcnotify, vim.g.neopp_channel = old_ui, old_rpc, old_channel
    rawset(_G, '__rendermark_image_backend', old_state)
    assert.same({ 2, 0, 1 }, unchanged)
    assert.same({ 3, 0, 2 }, changed)
    assert.same({ 4, 2, 5 }, final)
  end)
end)
