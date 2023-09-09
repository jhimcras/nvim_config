local cmp = require 'cmp'
M = {}

function M.setup()
    cmp.setup {
        mapping = cmp.mapping.preset.insert {
            ['<C-M-k>'] = cmp.mapping.scroll_docs(-4),
            ['<C-M-j>'] = cmp.mapping.scroll_docs(4),
            ['<C-Space>'] = cmp.mapping.complete(),
            ['<C-e>'] = cmp.mapping.abort(),
            ['<CR>'] = cmp.mapping.confirm({ select = false }), -- Accept currently selected item. Set `select` to `false` to only confirm explicitly selected items.
        },
        sources = cmp.config.sources({
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
