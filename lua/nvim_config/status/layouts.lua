local components = require('nvim_config.status.components')

local percentage_loc = '%p%%'
local column_loc = 'ﮇ %v'
local gap = '%<%='


local function general_statusline(activation, mode, winid)
    local hl = function(num)
        return 'StatuslineGeneral' .. (activation and ('Active_%d_%s'):format(num, mode) or 'Inactive')
    end
    return {
        {
            components.sh(components.proj_or_git_branch_memoized, 9),
            components.sh(components.filename_and_status_memoized, 1, components.filename_and_status_compact_memoized),
            activation and components.sh(components.lsp_status, 2) or false,
            hl = hl(1), sep = ' │ ', pad = ' '
        },
        gap,
        {
            activation and components.sh(components.current_function_memoized, 3) or false,
            components.sh(components.encoding_memoized, 4),
            hl = hl(1), sep = ' │ ', pad = ' '
        },
        activation and {
            components.sh(components.search_count, 5),
            components.sh(percentage_loc, 10),
            components.sh(column_loc, 6),
            hl = hl(2), sep = ' ', pad = ' '
        } or false,
        components.loclist_tag,
    }
end


local function quickfix_statusline(activation, mode, winid)
    local is_search = false
    if winid and winid ~= 0 then
        local filewinid = vim.fn.getloclist(winid, { filewinid = 0 }).filewinid
        if filewinid and filewinid ~= 0 then
            local title = vim.fn.getloclist(filewinid, { title = 0 }).title
            is_search = title ~= nil and title:sub(1, 8) == 'Search: '
        end
    end
    local hl1 = is_search and 'StatuslineSearch_1' or 'StatuslineGeneralActive_1_n'
    local hl2 = is_search and 'StatuslineSearch_2' or 'StatuslineGeneralActive_2_n'
    return {
        { 'ﴴ ', components.sh(components.quickfix_search_query, 1, components.quickfix_search_query_compact), hl = hl1, sep = ' ', pad = ' ' },
        gap,
        { components.grep_status_icon, activation and components.sh(components.search_count, 2) or false, components.sh('%l/%L', 3, '%l'), hl = hl2, sep = ' ', pad = ' ' },
        components.loclist_tag,
    }
end

local function help_statusline(activation)
    local active_only = function(st) return activation and st or '' end
    return {
        {' ', components.filename_only, hl = 'StatuslineGeneralActive_1_n', pad = ' ', sep = ' ' },
        gap,
        active_only{ components.sh(components.search_count, 1), components.sh(percentage_loc, 2), hl = 'StatuslineGeneralActive_2_n', pad = ' ', sep = ' ' },
     }
end

local function man_title(bufnr, winid)
    local name = vim.fn.bufname(bufnr)
    return name:gsub('^man://', '')
end

local function checkhealth_statusline(activation)
    return {
        { 'Checkhealth', hl = 'StatuslineGeneralActive_1_n', pad = ' ' },
        gap,
    }
end

local function man_statusline(activation)
    local active_only = function(st) return activation and st or '' end
    return {
        { 'ManPage', man_title, hl = 'StatuslineGeneralActive_1_n', sep = ' ', pad = ' ' },
        gap,
        active_only{ components.sh(components.search_count, 1), components.sh(percentage_loc, 2), components.sh(column_loc, 3),
                     hl = 'StatuslineGeneralActive_2_n', sep = ' ', pad = ' ' },
    }
end

local function fugitive_statusline(activation)
    local active_only = function(st) return activation and st or '' end
    return {
        { ' ', components.sh(components.fugitive_info, 2, components.fugitive_info_compact), hl = 'StatuslineGeneralActive_1_n', sep = ' ', pad = ' ' },
        gap,
        active_only{ components.sh(percentage_loc, 1), hl = 'StatuslineGeneralActive_2_n', sep = ' ', pad = ' ' },
    }
end

local function terminal_statusline(activation, mode)
    local hl = function()
        return 'StatuslineTerm' .. (activation and ('Active_1_%s'):format(mode) or 'Inactive')
    end
    return {' ', hl = hl(), sep = '',}
end


local function launcher_statusline(activation, mode, winid)
    local active_only = function(st) return activation and st or '' end
    local hl = function(num)
        return 'StatuslineGeneral' .. (activation and ('Active_%d_%s'):format(num, mode) or 'Inactive')
    end
    return {
        {
            components.launcher_status_icon,
            components.sh(components.launcher_folder, 1, components.launcher_folder_compact),
            '│',
            components.sh(components.launcher_command, 2),
            hl = hl(1), sep = ' ', pad = ' '
        },
        gap,
        active_only {
            components.search_count,
            components.sh('%l/%L', 10, '%l'),
            hl = hl(2), sep = ' ', pad = ' '
        },
    }
end

-- No function calls in 'statusline': component events update it, then redraw.
local statusline_setup = {
    components = {
        general = general_statusline,
        quickfix = quickfix_statusline,
        help = help_statusline,
        fugitive = fugitive_statusline,
        terminal = terminal_statusline,
        launcher = launcher_statusline,
        checkhealth = checkhealth_statusline,
        health      = checkhealth_statusline,
        man         = man_statusline,
    },
}

return statusline_setup.components
