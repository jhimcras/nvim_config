local env = require 'nvim_config.env'
local util_buffer = require('nvim_config.util.buffer')
local ut = require('nvim_config.util.cache')
local status_mode = require('nvim_config.status.mode')
local M = {}

local spinner_frames = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local function launcher_status_icon(bufnr, winid)
    local b = bufnr and vim.b[bufnr] or vim.b
    local status = b.launcher_status
    if status == 'running' then
        return spinner_frames[(math.floor(vim.uv.now() / 120) % #spinner_frames) + 1]
    elseif status == 'done' then
        return '✓'
    elseif status == 'terminated' then
        return '✗'
    end
    return ''
end

local function grep_status_icon(bufnr, winid)
    local gs = vim.w[winid] and vim.w[winid].grep_status
    if gs == 'searching' then
        return spinner_frames[(math.floor(vim.uv.now() / 120) % #spinner_frames) + 1]
    elseif gs == 'done' then
        return '✓'
    elseif gs == 'killed' then
        return '✗'
    end
    return ''
end


local function launcher_folder(bufnr)
    local b = bufnr and vim.b[bufnr] or vim.b
    return b.prjroot_folder or '?'
end

local function launcher_folder_compact(bufnr)
    local b = bufnr and vim.b[bufnr] or vim.b
    local folder = b.prjroot_folder
    return folder and vim.fn.fnamemodify(folder, ':t') or '?'
end

local function launcher_command(bufnr)
    local b = bufnr and vim.b[bufnr] or vim.b
    return b.lc_command or b.lc_object or '?'
end

function M.lsp(bufnr)
    bufnr = bufnr or 0
    local clients = vim.lsp.get_clients{bufnr = bufnr}
    if next(clients) == nil then
        return ''
    end
    local ls = require 'nvim_config.lsp_setting'
    local S = vim.diagnostic.severity
    local counts = vim.diagnostic.count(bufnr)
    local parts = {}
    for _, seg in ipairs({
        { counts[S.ERROR], ls.SymError },
        { counts[S.WARN],  ls.SymWarn  },
        { counts[S.INFO],  ls.SymInfo  },
        { counts[S.HINT],  ls.SymHint  },
    }) do
        if seg[1] and seg[1] > 0 then
            parts[#parts + 1] = seg[2] .. seg[1]
        end
    end
    -- vim.lsp.status() concatenates every buffered report; keep only the newest.
    local prog = ''
    for _, c in ipairs(clients) do
        for progress in c.progress do
            local value = progress.value
            if type(value) == 'table' and value.kind then
                prog = value.message and (value.title .. ': ' .. value.message)
                    or value.title
            end
        end
    end
    prog = vim.trim(prog)
    if prog ~= '' then
        parts[#parts + 1] = prog
    else
        local any_running, any_done = false, false
        for _, c in ipairs(clients) do
            local state = ls.progress_state[c.id]
            if state == 'running' then any_running = true end
            if state == 'done' then any_done = true end
        end
        if any_done and not any_running and #parts == 0 then
            parts[#parts + 1] = '✓'
        end
    end
    return table.concat(parts, ' ')
end

function M.titlecontext()
    local session = vim.fn.fnamemodify(vim.v.this_session, ':t:r')
    if session ~= '' then
        return session
    end
    return vim.fn.fnamemodify(vim.fn.getcwd(), ':~')
end


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

local function branch_or_commit(dir)
    local branch, commit = require'nvim_config.git'.git_branch_commit(dir)
    if branch and branch ~= 'HEAD' then
        return branch
    end
    return commit and commit:sub(1, 10)
end

local function project_or_git_branch_name(bufnr, winid)
    local pr = require'nvim_config.prjroot'.GetProjectRoot(util_buffer.GetBufferDir(bufnr))
    if pr then
        local fi = {}
        local git_branch = nil
        if pr ~= '' then
            git_branch = branch_or_commit(pr)
            if git_branch and git_branch ~= '' then
                fi[#fi+1] = (' %s'):format(git_branch)
            end
        end
        local project_folder_name = vim.fn.fnamemodify(pr, ':t')
        if project_folder_name ~= git_branch then
            fi[#fi+1] = ('🖿 %s'):format(project_folder_name)
        end
        return fi
    end
end


local function encoding(bufnr, winid)
    local fe = vim.bo[bufnr].fileencoding
    local bom = vim.bo[bufnr].bomb and ' bom' or ''
    return fe .. bom
end


local function filename_only(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    return vim.fn.fnamemodify(name, ':t:r')
end


local function filename_and_status(bufnr, winid)
    local buf_name, protocol = util_buffer.GetBufferName(bufnr)
    if protocol == 'oil' then
        if env.os.win then
            buf_name = buf_name:gsub('^/(%a)/', '%1:/')
            buf_name = buf_name:gsub('\\', '/')
        else
            local home = os.getenv('HOME')
            if home and buf_name:sub(1, #home) == home then
                buf_name = '~' .. buf_name:sub(#home + 1)
            end
        end
    end
    if env.os.win then
        buf_name = buf_name:gsub('\\', '/')
    end
    local is_dir = buf_name:sub(buf_name:len()) == '/'
    local filename
    local fileicon = is_dir and ' ' or '🗎'
    local pr = require'nvim_config.prjroot'.GetProjectRoot(buf_name)
    if pr and not is_dir then
        local bname = buf_name:sub(pr:len()+2)
        if bname == '' then return '' end
        filename = ('%s%s'):format(fileicon, bname)
    else
        if buf_name ~= '' then
            filename = ('%s%s'):format(fileicon, buf_name)
        else
            filename = 'No Name'
        end
    end
    local file_status = ('%s%s%s'):format(
        vim.bo[bufnr].modified and ' ' or '',
        vim.bo[bufnr].readonly and '' or '',
        not vim.bo[bufnr].modifiable and '-'  or '')
    return filename .. (file_status ~= '' and (' ' .. file_status) or '')
end


local function filename_and_status_compact(bufnr, winid)
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local name = bufname ~= '' and vim.fn.fnamemodify(bufname, ':t') or 'No Name'
    local mods = (vim.bo[bufnr].modified and ' ' or '')
               .. (vim.bo[bufnr].readonly and '' or '')
               .. (not vim.bo[bufnr].modifiable and '-' or '')
    return name .. (mods ~= '' and (' ' .. mods) or '')
end


local function current_function(bufnr, winid)
    local curfunc =  M.current_function()
    if curfunc and curfunc ~= '' then
        return 'ℱ ' .. curfunc
    end
end


local function lsp_status(bufnr, winid)
    local s = M.lsp(bufnr)
    if s ~= '' then return s end
end


local function search_count(bufnr, winid)
    if vim.v.hlsearch == 0 then return end

    local winids = vim.fn.win_findbuf(bufnr)
    if #winids == 0 then return end

    local searchcount = vim.api.nvim_win_call(winids[1], function()
        return {pcall(vim.fn.searchcount, { maxcount = 999999, timeout = 1000 })}
    end)
    if not searchcount[1] or not searchcount[2].total or searchcount[2].total == 0 then return end

    return ('  %d/%d'):format(searchcount[2].current, searchcount[2].total)
end


--- Mark a component as shrinkable.
--- priority: 1 shrinks first, 10 last. compact: fn(bufnr, winid) -> string, nil = remove.
local function sh(fn, priority, compact)
    return { __sh = true, fn = fn, priority = priority, compact = compact }
end

local function measure_sl_text(s)
    s = s:gsub('%%#[^#]*#', '')   -- strip %#HighlightGroup# codes
    s = s:gsub('%%p%%%%', '100')  -- %p%% -> percentage estimate
    s = s:gsub('%%v', '999')      -- %v -> virtual column estimate
    s = s:gsub('%%[lL]', '9999') -- %l/%L -> line estimate
    s = s:gsub('%%[<=]', '')      -- %< and %= are zero-width separators
    s = s:gsub('%%%%', '%%')      -- %% -> literal %
    return vim.fn.strdisplaywidth(s)
end

local percentage_loc = '%p%%'
local column_loc = 'ﮇ %v'
local gap = '%<%='


local function fugitive_info(bufnr, winid)
    local info = require'nvim_config.git'.get_fugitive_info(bufnr)
    if not info then return 'Fugitive' end

    if info.type == 'summary' then
        return {
            'Git status',
            info.cwd,
            info.head,
            info.upstream,
            info.ab,
            sep = ' │ '
        }
    elseif info.type == 'blob' then
        return { 'Git blob', info.obj, info.file, sep = ' │ ' }
    elseif info.type == 'diff' then
        return { 'Git diff', info.file, sep = ' │ ' }
    end
    return 'Fugitive'
end

local function fugitive_info_compact(bufnr, winid)
    local info = require'nvim_config.git'.get_fugitive_info(bufnr)
    if not info then return 'FUG' end

    if info.type == 'summary' then
        return 'SUM │ ' .. info.head
    elseif info.type == 'blob' then
        local obj_map = { INDEX = 'IDX', OURS = 'OUR', THEIRS = 'THE', BASE = 'BASE' }
        return (obj_map[info.obj] or info.obj:sub(1, 4)) .. ' │ ' .. info.file
    elseif info.type == 'diff' then
        return 'DIF │ ' .. info.file
    end
    return 'FUG'
end

local function quickfix_search_query(bufnr, winid)
    -- From loclist data: w:quickfix_title is set too late on lopen splits.
    local title
    local filewinid = vim.fn.getloclist(winid, { filewinid = 0 }).filewinid
    if filewinid and filewinid ~= 0 then
        title = vim.fn.getloclist(filewinid, { title = 0 }).title
    else
        title = vim.w[winid].quickfix_title
    end
    if not title then return end
    local chain = require'nvim_config.qflist.filter'.get_filter_chain(winid)
    if not chain or #chain == 0 then return title end
    local MAX_CHAIN = 25
    local visible = {}
    for i, v in ipairs(chain) do visible[i] = v end
    local hidden = 0
    while #table.concat(visible, ' → ') > MAX_CHAIN and #visible > 1 do
        table.remove(visible, 1)
        hidden = hidden + 1
    end
    local chain_str = ' → ' .. (hidden > 0 and ('(+' .. hidden .. ') ') or '') .. table.concat(visible, ' → ')
    local before, sep_and_after = title:match('^(.-)( │ .+)$')
    if before then
        return before .. chain_str .. sep_and_after
    end
    return title .. chain_str
end


local function quickfix_search_query_compact(bufnr, winid)
    local title
    local filewinid = vim.fn.getloclist(winid, { filewinid = 0 }).filewinid
    if filewinid and filewinid ~= 0 then
        title = vim.fn.getloclist(filewinid, { title = 0 }).title
    else
        title = vim.w[winid].quickfix_title
    end
    return title or ''
end

local function loclist_tag(bufnr, winid)
    local tag = vim.w[winid] and vim.w[winid].loclist_tag
    if not tag then return end
    return ('%#StatuslineTag' .. tag .. '#  ')
end

local function make_statusline_text(bufnr, winid, components, sep, ctx)
    sep = sep or ''
    if components == nil then return '' end

    if type(components) == 'string' then
        return components
    elseif type(components) == 'number' then
        return tostring(components)
    elseif type(components) == 'function' then
        if ctx then
            local cached = ctx.cache[components]
            if not cached then
                cached = { value = components(bufnr, winid), text = {} }
                ctx.cache[components] = cached
            end
            if cached.text[sep] == nil then
                cached.text[sep] = make_statusline_text(bufnr, winid, cached.value, sep, ctx)
            end
            return cached.text[sep]
        end
        local res = components(bufnr, winid)
        if res == nil then return '' end
        return make_statusline_text(bufnr, winid, res, sep, ctx)
    elseif type(components) == 'table' and components.__sh then
        if ctx then
            local cached = ctx.cache[components]
            if not cached then
                ctx.candidates[#ctx.candidates + 1] = {
                    fn       = components.fn,
                    priority = components.priority,
                    order    = #ctx.candidates + 1,
                }
                cached = {
                    full = make_statusline_text(bufnr, winid, components.fn, sep, ctx),
                    compact = make_statusline_text(bufnr, winid, components.compact, sep, ctx),
                }
                ctx.cache[components] = cached
            end
            return ctx.excluded[components.fn] and cached.compact or cached.full
        end
        return make_statusline_text(bufnr, winid, components.fn, sep, ctx)
    elseif type(components) == 'table' then
        sep = components.sep or sep
        local pad = components.pad or ''
        local hl = components.hl and ("%%#%s#"):format(components.hl) or ""
        local t = {}
        for _, c in ipairs(components) do
            -- Only types we support as a statusline component
            if type(c) == 'string' or type(c) == 'number' or type(c) == 'function' or type(c) == 'table' then
                local c_str = make_statusline_text(bufnr, winid, c, sep, ctx)
                if c_str and c_str ~= '' then
                    t[#t+1] = c_str
                end
            end
        end
        if #t == 0 then return '' end
        for i, s in ipairs(t) do
            t[i] = hl .. (i == 1 and pad or '') .. s .. (i == #t and pad or '') .. hl
        end
        return table.concat(t, sep)
    end
    return ''
end


local proj_or_git_branch_memoized          = ut.memoize_ttl(project_or_git_branch_name,  {ttl_ms=1000})
local filename_and_status_memoized         = ut.memoize_ttl(filename_and_status,          {ttl_ms=300})
local filename_and_status_compact_memoized = ut.memoize_ttl(filename_and_status_compact,  {ttl_ms=300})
local encoding_memoized                    = ut.memoize_ttl(encoding,                     {ttl_ms=2000})
local current_function_memoized            = ut.memoize_ttl(current_function,             {ttl_ms=200})

local function general_statusline(activation, mode, winid)
    local hl = function(num)
        return 'StatuslineGeneral' .. (activation and ('Active_%d_%s'):format(num, mode) or 'Inactive')
    end
    return {
        {
            sh(proj_or_git_branch_memoized, 9),
            sh(filename_and_status_memoized, 1, filename_and_status_compact_memoized),
            activation and sh(lsp_status, 2) or false,
            hl = hl(1), sep = ' │ ', pad = ' '
        },
        gap,
        {
            activation and sh(current_function_memoized, 3) or false,
            sh(encoding_memoized, 4),
            hl = hl(1), sep = ' │ ', pad = ' '
        },
        activation and {
            sh(search_count, 5),
            sh(percentage_loc, 10),
            sh(column_loc, 6),
            hl = hl(2), sep = ' ', pad = ' '
        } or false,
        loclist_tag,
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
        { 'ﴴ ', sh(quickfix_search_query, 1, quickfix_search_query_compact), hl = hl1, sep = ' ', pad = ' ' },
        gap,
        { grep_status_icon, activation and sh(search_count, 2) or false, sh('%l/%L', 3, '%l'), hl = hl2, sep = ' ', pad = ' ' },
        loclist_tag,
    }
end

local function help_statusline(activation)
    local active_only = function(st) return activation and st or '' end
    return {
        {' ', filename_only, hl = 'StatuslineGeneralActive_1_n', pad = ' ', sep = ' ' },
        gap,
        active_only{ sh(search_count, 1), sh(percentage_loc, 2), hl = 'StatuslineGeneralActive_2_n', pad = ' ', sep = ' ' },
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
        active_only{ sh(search_count, 1), sh(percentage_loc, 2), sh(column_loc, 3),
                     hl = 'StatuslineGeneralActive_2_n', sep = ' ', pad = ' ' },
    }
end

local function fugitive_statusline(activation)
    local active_only = function(st) return activation and st or '' end
    return {
        { ' ', sh(fugitive_info, 2, fugitive_info_compact), hl = 'StatuslineGeneralActive_1_n', sep = ' ', pad = ' ' },
        gap,
        active_only{ sh(percentage_loc, 1), hl = 'StatuslineGeneralActive_2_n', sep = ' ', pad = ' ' },
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
            launcher_status_icon,
            sh(launcher_folder, 1, launcher_folder_compact),
            '│',
            sh(launcher_command, 2),
            hl = hl(1), sep = ' ', pad = ' '
        },
        gap,
        active_only {
            search_count,
            sh('%l/%L', 10, '%l'),
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

local function get_entry_func(buftype, filetype, protocol)
    local components = statusline_setup.components

    if components[protocol] then
        return components[protocol]
    elseif components[buftype] then
        return components[buftype]
    elseif components[filetype] then
        return components[filetype]
    end

    return components.general
end

function M.statusline_entry()
    local winid = vim.g.statusline_winid or 0
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local protocol = util_buffer.GetBufferProtocol(bufnr)
    local w = vim.api.nvim_win_get_width(winid)
    local activation = winid == vim.api.nvim_get_current_win()
    local entryfunc = get_entry_func(vim.bo[bufnr].buftype, vim.bo[bufnr].filetype, protocol)
    local is_read = require('nvim_config.read_mode').is_active(winid)
    local mode = is_read and 'read' or vim.fn.mode()
    local tree = entryfunc(activation, mode, winid)

    local excluded = {}
    -- Cache full/compact text for this render only, including empty results.
    local ctx = { excluded = excluded, candidates = {}, cache = {} }
    local result = make_statusline_text(bufnr, winid, tree, '', ctx)
    if measure_sl_text(result) > w then
        table.sort(ctx.candidates, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            return a.order < b.order
        end)
        for _, c in ipairs(ctx.candidates) do
            if not excluded[c.fn] then
                excluded[c.fn] = true
                result = make_statusline_text(bufnr, winid, tree, '', ctx)
                if measure_sl_text(result) <= w then break end
            end
        end
    end

    return result
end

function M.setup()
    -- Skip in tests (headless UI errors).
    if vim.g.is_testing then return end

    vim.o.laststatus = 2
    vim.o.statusline = "%!v:lua.require'nvim_config.status'.statusline_entry()"

end

return M
