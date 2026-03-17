local cmp = require 'cmp'
M = {}

local function feedkey(key, mode)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, true, true), mode, true)
end

function M.setup()
    cmp.setup {
        mapping = cmp.mapping.preset.insert {
            ['<c-k>'] = cmp.mapping.scroll_docs(-4),
            ['<c-j>'] = cmp.mapping.scroll_docs(4),
            ['<cr>'] = cmp.mapping.confirm({ select = false }),
            ['<c-tab>'] = cmp.mapping(function(fallback)
                if vim.fn['vsnip#jumpable'](1) then
                    feedkey('<Plug>(vsnip-jump-next)', '')
                elseif vim.fn['vsnip#expandable']() then
                    feedkey('<Plug>(vsnip-expand)', '')
                else
                    fallback()
                end
            end, {"i", "s"}),
            ['<c-s-tab>'] = cmp.mapping(function(fallback)
                if vim.fn['vsnip#jumpable'](-1) then
                    feedkey('<Plug>(vsnip-jump-prev)', '')
                else
                    fallback()
                end
            end, {"i", "s"}),
        },
        sources = cmp.config.sources({
            { name = 'vsnip' },
            { name = 'nvim_lsp' },
            { name = 'nvim_lsp_signature_help' },
        }, {
            { name = 'buffer' },
        }),
        sorting = { -- TODO: this setting shouldn't update automatically with default setting
            priority_weight = 2,
            comparators = {
                function(entry1, entry2) -- for clangd completion score
                    local score1 = entry1.completion_item.score
                    local score2 = entry2.completion_item.score
                    if score1 and score2 then
                        local diff = score1 - score2
                        if diff < 0 then
                            return false
                        elseif diff > 0 then
                            return true
                        end
                    end
                end,
                cmp.config.compare.offset,
                cmp.config.compare.exact,
                cmp.config.compare.score,
                cmp.config.compare.recently_used,
                cmp.config.compare.locality,
                cmp.config.compare.kind,
                cmp.config.compare.sort_text,
                cmp.config.compare.length,
                cmp.config.compare.order,
            },
        },
        snippet = {
            expand = function(args)
                vim.fn["vsnip#anonymous"](args.body) -- For `vsnip` users.
            end,
        },
        window = {
            completion = cmp.config.window.bordered(),
            documentation = cmp.config.window.bordered(),
        },
    }

    -- require 'lspconfig'.clangd.setup {
    --     capabilities = capabilities,
    -- }
end

return M
