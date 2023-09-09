local M = {}

function M.setup()
    --require "nvim-treesitter.parsers".get_parser_configs().markdown = {
        --install_info = {
            --url = "https://github.com/ikatyang/tree-sitter-markdown",
            --files = {"src/parser.c", "src/scanner.cc"}
        --},
        --filetype = 'markdown',
    --}
    require'nvim-treesitter.configs'.setup {
        -- one of "all", "language", or a list of languages
        ensure_installed = { 'c', 'cpp', 'lua', 'json', 'bash', 'regex', 'query', 'rust', 'python', 'markdown', 'markdown_inline' };
        highlight = {
            enable = true,
            disable = {},
            custom_captures = { checkedlist = 'Folded' },
        },
        incremental_selection = {
            enable = true,
            keymaps = {
                init_selection = "<s-right>",
                node_incremental = "<s-right>",
                scope_incremental = "<s-up>",
                node_decremental = "<s-left>",
            },
        },
        -- 'nvim-treesitter-refactor' plugin options
        --refactor = {
            --highlight_definitions = { enable = true },
            --highlight_current_scope = { enable = false },
        --},
        textobjects = {
            move = {
                enable = true,
                goto_next_start = {
                    ["]m"] = "@function.outer",
                    ["]]"] = "@class.outer",
                },
                goto_next_end = {
                    ["]M"] = "@function.outer",
                    ["]["] = "@class.outer",
                },
                goto_previous_start = {
                    ["[m"] = "@function.outer",
                    ["[["] = "@class.outer",
                },
                goto_previous_end = {
                    ["[M"] = "@function.outer",
                    ["[]"] = "@class.outer",
                },
            },
            swap = {
                enable = true,
                swap_next = {
                    [">,"] = "@parameter.inner",
                },
                swap_previous = {
                    ["<,"] = "@parameter.inner",
                },
            },
            select = {
                enable = true,
                keymaps = {
                    ["af"] = "@function.outer",
                    ["if"] = "@function.inner",
                    ["ac"] = "@class.outer",
                    ["ic"] = "@class.inner",
                    ["a,"] = "@parameter.outer",
                    ["i,"] = "@parameter.inner",
                }
            }
        },
        playground = {
            enable = true,
            disable = {},
            updatetime = 25, -- Debounced time for highlighting nodes in the playground from source code
            persist_queries = false -- Whether the query persists across vim sessions
        },
    }
end

return M
