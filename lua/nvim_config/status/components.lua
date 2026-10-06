local env = require 'nvim_config.env'
local util_buffer = require('nvim_config.util.buffer')
local ut = require('nvim_config.util.cache')

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


local function current_function(bufnr, winid, api)
    local curfunc = api.current_function()
    if curfunc and curfunc ~= '' then
        return 'ℱ ' .. curfunc
    end
end


local function lsp_status(bufnr, winid, api)
    local s = api.lsp(bufnr)
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
                cached = { value = components(bufnr, winid, ctx and ctx.api), text = {} }
                ctx.cache[components] = cached
            end
            if cached.text[sep] == nil then
                cached.text[sep] = make_statusline_text(bufnr, winid, cached.value, sep, ctx)
            end
            return cached.text[sep]
        end
        local res = components(bufnr, winid, ctx and ctx.api)
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

return {
    launcher_status_icon = launcher_status_icon,
    grep_status_icon = grep_status_icon,
    launcher_folder = launcher_folder,
    launcher_folder_compact = launcher_folder_compact,
    launcher_command = launcher_command,
    filename_only = filename_only,
    lsp_status = lsp_status,
    search_count = search_count,
    sh = sh,
    measure_sl_text = measure_sl_text,
    fugitive_info = fugitive_info,
    fugitive_info_compact = fugitive_info_compact,
    quickfix_search_query = quickfix_search_query,
    quickfix_search_query_compact = quickfix_search_query_compact,
    loclist_tag = loclist_tag,
    make_statusline_text = make_statusline_text,
    proj_or_git_branch_memoized = proj_or_git_branch_memoized,
    filename_and_status_memoized = filename_and_status_memoized,
    filename_and_status_compact_memoized = filename_and_status_compact_memoized,
    encoding_memoized = encoding_memoized,
    current_function_memoized = current_function_memoized,
}
