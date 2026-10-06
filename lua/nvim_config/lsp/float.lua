local api = vim.api
local M = {}
local wrapper

function M.setup()
    if vim.lsp.util.open_floating_preview == wrapper then return end
    local orig_util_open_floating_preview = vim.lsp.util.open_floating_preview
    local fence_conceal_ns = api.nvim_create_namespace('lsp_hover_fence_conceal')
    wrapper = function(contents, syntax, opts, ...)
        opts = opts or {}
        local fbuf, fwin = orig_util_open_floating_preview(contents, syntax, opts, ...)
        -- Conceal ``` fence lines in hover/signature floats and shrink the float.
        if fbuf and fwin and vim.bo[fbuf].filetype == 'markdown' then
            local lines = api.nvim_buf_get_lines(fbuf, 0, -1, false)
            local hidden = 0
            for i, line in ipairs(lines) do
                if line:match('^%s*[`~][`~][`~]') then
                    api.nvim_buf_set_extmark(fbuf, fence_conceal_ns, i - 1, 0, { conceal_lines = '' })
                    hidden = hidden + 1
                end
            end
            if hidden > 0 then
                local h = api.nvim_win_get_height(fwin)
                if h - hidden >= 1 then
                    api.nvim_win_set_height(fwin, h - hidden)
                end
            end
        end
        return fbuf, fwin
    end
    
    vim.lsp.util.open_floating_preview = wrapper
end

return M
