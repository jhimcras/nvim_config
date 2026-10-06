local M = {}

function M.current_function(bufnr, winid)
    local ok, parser = pcall(vim.treesitter.get_parser)
    if ok and parser then
        parser:parse()
        local node = vim.treesitter.get_node()
        while node do
            local ntype = node:type()

            if ntype == "function_definition" or ntype == "function_declaration" then
                -- Python / Lua: name is the function name
                local name_node = node:field("name")[1]
                if name_node then
                    local name_type = name_node:type()
                    if name_type == "identifier" then
                        return vim.treesitter.get_node_text(name_node, 0)
                    elseif name_type == "dot_index_expression" then
                        local table = name_node:field("table")[1]
                        local field = name_node:field("field")[1]
                        if table and field then
                            return vim.treesitter.get_node_text(table, 0)
                                .. "." .. vim.treesitter.get_node_text(field, 0)
                        end
                    end
                end

                -- C / C++: name is in the declarator
                local decl = node:field("declarator")[1]
                if decl then
                    local inner = decl:field("declarator")[1]
                    if inner then
                        local itype = inner:type()

                        if itype == "qualified_identifier" then
                            local scope = inner:field("scope")[1]
                            local name = inner:field("name")[1]
                            if scope and name then
                                return vim.treesitter.get_node_text(scope, 0)
                                    .. "::" .. vim.treesitter.get_node_text(name, 0)
                            end
                        elseif itype == "field_identifier" then
                            return vim.treesitter.get_node_text(inner, 0)
                        end
                    end
                end
            end

            node = node:parent()
        end
    end

    return ""
end

return M
