local M = {}

function M.setup()
    require'nvim-treesitter.configs'.setup{
        ensure_installed = {
            'bash', 'c', 'cpp', 'lua', 'vim', 'vimdoc', 'query',
            'markdown', 'markdown_inline',
            'javascript', 'typescript', 'json', 'python', 'rust', 'regex',
        },
        highlight = { enable = true },
        textobjects = {
            select = {
                enable = true,
                lookahead = true,
                keymaps = {
                    ['af'] = '@function.outer',  ['if'] = '@function.inner',
                    ['ac'] = '@class.outer',     ['ic'] = '@class.inner',
                    ['a,'] = '@parameter.outer', ['i,'] = '@parameter.inner',
                },
            },
            move = {
                enable = true,
                set_jumps = true,
                goto_next_start     = { [']m'] = '@function.outer', [']]'] = '@class.outer' },
                goto_next_end       = { [']M'] = '@function.outer', ['][']  = '@class.outer' },
                goto_previous_start = { ['[m'] = '@function.outer', ['[['] = '@class.outer' },
                goto_previous_end   = { ['[M'] = '@function.outer', ['[]']  = '@class.outer' },
            },
            swap = {
                enable = true,
                swap_next     = { ['>,'] = '@parameter.inner' },
                swap_previous = { ['<,'] = '@parameter.inner' },
            },
        },
    }

    -- Neovim 0.12's iter_matches() yields TSNode[] per capture, which the pinned
    -- nvim-treesitter/-textobjects masters treat as a TSNode and crash on.
    -- These wrappers unwrap only real TSNode[] arrays, so they're harmless on <0.12.
    do
        -- A capture array is a plain table whose [1] is a TSNode (userdata).
        local function unwrap(v)
            if type(v) == 'table' and type(v[1]) == 'userdata' then
                return v[#v] -- last match, matching the old all=false semantics
            end
            return v
        end

        -- 1) make-range!: let from_nodes accept TSNode[] arrays.
        local tsrange = require'nvim-treesitter.tsrange'
        local TSRange = tsrange.TSRange
        local orig_from_nodes = TSRange.from_nodes
        function TSRange.from_nodes(buf, start_node, end_node)
            start_node, end_node = unwrap(start_node), unwrap(end_node)
            if not start_node and not end_node then
                return nil
            end
            return orig_from_nodes(buf, start_node, end_node)
        end

        -- 2) regular captures: unwrap every yielded `.node` array.
        local nt_query = require'nvim-treesitter.query'
        local orig_iter = nt_query.iter_prepared_matches
        local function unwrap_nodes(t)
            if type(t) ~= 'table' or getmetatable(t) ~= nil then
                return -- skip TSRange (has a metatable) and non-tables
            end
            for k, v in pairs(t) do
                if k == 'node' then
                    t[k] = unwrap(v)
                else
                    unwrap_nodes(v)
                end
            end
        end
        function nt_query.iter_prepared_matches(...)
            local iter = orig_iter(...)
            return function()
                local prepared_match = iter()
                unwrap_nodes(prepared_match)
                return prepared_match
            end
        end
    end

    -- nvim-treesitter directives assume single TSNodes; 0.12 breaks markdown injections.
    if vim.fn.has('nvim-0.12') == 1 then
        require'nvim-treesitter.query_predicates'
        local query = require'vim.treesitter.query'
        local html_script_type_languages = {
            importmap = 'json',
            module = 'javascript',
            ['application/ecmascript'] = 'javascript',
            ['text/ecmascript'] = 'javascript',
        }
        local non_filetype_match_injection_language_aliases = {
            ex = 'elixir',
            pl = 'perl',
            sh = 'bash',
            uxn = 'uxntal',
            ts = 'typescript',
        }
        local function first_node(match, capture_id)
            local nodes = match[capture_id]
            if type(nodes) == 'table' then
                return nodes[1]
            end
            return nodes
        end
        local function parser_from_markdown_info_string(injection_alias)
            local match = vim.filetype.match { filename = 'a.' .. injection_alias }
            return match or non_filetype_match_injection_language_aliases[injection_alias] or injection_alias
        end
        query.add_directive('set-lang-from-mimetype!', function(match, _, bufnr, pred, metadata)
            local node = first_node(match, pred[2])
            if not node then
                return
            end
            local type_attr_value = vim.treesitter.get_node_text(node, bufnr)
            local configured = html_script_type_languages[type_attr_value]
            if configured then
                metadata['injection.language'] = configured
            else
                local parts = vim.split(type_attr_value, '/', {})
                metadata['injection.language'] = parts[#parts]
            end
        end, { force = true })
        query.add_directive('set-lang-from-info-string!', function(match, _, bufnr, pred, metadata)
            local node = first_node(match, pred[2])
            if not node then
                return
            end
            local injection_alias = vim.treesitter.get_node_text(node, bufnr):lower()
            metadata['injection.language'] = parser_from_markdown_info_string(injection_alias)
        end, { force = true })
        query.add_directive('downcase!', function(match, _, bufnr, pred, metadata)
            local id = pred[2]
            local node = first_node(match, id)
            if not node then
                return
            end
            local text = vim.treesitter.get_node_text(node, bufnr, { metadata = metadata[id] }) or ''
            if not metadata[id] then
                metadata[id] = {}
            end
            metadata[id].text = string.lower(text)
        end, { force = true })
    end
end

return M
