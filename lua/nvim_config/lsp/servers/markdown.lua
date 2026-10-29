local M = {}

-- `vim.g.mdloom_dir` (optional): a development checkout of mdloom. It supplies the
-- Neovim plugin (`editors/nvim`) when it is not installed, and a fallback binary
-- (`target/debug|release/mdloom`) when `mdloom` is not on PATH.
local function dev_dir()
    local dir = vim.g.mdloom_dir
    if type(dir) ~= 'string' or dir == '' then return nil end
    return vim.fn.expand(dir)
end

-- A PATH binary wins over the development build. Returns nil when neither exists.
function M.cmd(dir)
    local exe = vim.fn.exepath('mdloom')
    if exe == '' and dir then
        for _, profile in ipairs({ 'debug', 'release' }) do
            local candidate = dir .. '/target/' .. profile .. '/mdloom'
            if vim.fn.executable(candidate) == 1 then
                exe = candidate
                break
            end
        end
    end
    if exe == '' then return nil end
    return { exe, 'lsp' }
end

function M.setup()
    local dir = dev_dir()
    if dir and vim.uv.fs_stat(dir .. '/editors/nvim') then
        vim.opt.rtp:prepend(dir .. '/editors/nvim')
    end
    local ok, mdloom = pcall(require, 'mdloom')
    if not ok then return end
    local cmd = M.cmd(dir)
    if not cmd then return end

    local on_attach = require('nvim_config.lsp.attach').make_on_attach(nil)
    vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('nvim_config_mdloom_attach', { clear = true }),
        callback = function(ev)
            local client = vim.lsp.get_client_by_id(ev.data.client_id)
            if client and client.name == 'mdloom' then
                vim.api.nvim_buf_call(ev.buf, function() on_attach(client, ev.buf) end)
            end
        end,
    })
    mdloom.setup({ cmd = cmd })
end

return M
