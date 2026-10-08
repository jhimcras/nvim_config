local M = {}
local pr = require 'nvim_config.prjroot'
local ut = require('nvim_config.util.buffer')

-- Reference: https://github.com/nvim-telescope/telescope.nvim/blob/master/developers.md
local pickers, finders, conf, actions, action_state, make_entry

local function load_dependencies()
    pickers = require 'telescope.pickers'
    finders = require 'telescope.finders'
    conf = require 'telescope.config'.values
    actions = require 'telescope.actions'
    action_state = require 'telescope.actions.state'
    make_entry = require 'telescope.make_entry'
end

local function open_in_new_instance()
    local entry = action_state.get_selected_entry()
    local path = entry and (entry.path or entry.filename)
    if path then
        require'nvim_config.instance'.new(path)
    end
end

function M.InstanceTargets(on_select)
    load_dependencies()
    pickers.new({}, {
        prompt_title = 'Move to Nvim instance',
        finder = finders.new_table {
            results = require'nvim_config.instance.move'.targets(),
            entry_maker = function(target)
                return { value = target, display = target.display, ordinal = target.display }
            end,
        },
        sorter = conf.generic_sorter({}),
        previewer = false,
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                -- Let Telescope finish closing before opening a command-line prompt.
                vim.schedule(function() on_select(selection and selection.value) end)
            end)
            return true
        end,
    }):find()
end

function M.Files()
    load_dependencies()
    local cwd = pr.GetCurrentProjectRoot() or ut.GetCurrentBufferDir()
    require 'telescope.builtin'.find_files {
        cwd = cwd,
        attach_mappings = function(_, map)
            map('i', '<C-i>', open_in_new_instance)
            return true
        end,
    }
end

-- TODO: cannot swipe current diplayed buffer
function M.Buffers()
    load_dependencies()
    local default_selection_idx = 1
    local buffer_list = function(opts)
        opts = opts or {}
        local bufnrs = vim.tbl_filter(function(b)
            if 1 ~= vim.fn.buflisted(b) then
                return false
            end
            -- hide unloaded buffers only when show_all_buffers is false
            if opts.show_all_buffers == false and not vim.api.nvim_buf_is_loaded(b) then
                return false
            end
            if opts.ignore_current_buffer and b == vim.api.nvim_get_current_buf() then
                return false
            end
            if opts.cwd_only and not string.find(vim.api.nvim_buf_get_name(b), vim.uv.cwd(), 1, true) then
                return false
            end
            return true
        end, vim.api.nvim_list_bufs())
        if not next(bufnrs) then
            return
        end
        if opts.sort_mru then
            table.sort(bufnrs, function(a, b)
                return vim.fn.getbufinfo(a)[1].lastused > vim.fn.getbufinfo(b)[1].lastused
            end)
        end

        local buffers = {}
        for _, bufnr in ipairs(bufnrs) do
            local flag = bufnr == vim.fn.bufnr "" and "%" or (bufnr == vim.fn.bufnr "#" and "#" or " ")

            if opts.sort_lastused and not opts.ignore_current_buffer and flag == "#" then
                default_selection_idx = 2
            end

            local element = {
                bufnr = bufnr,
                flag = flag,
                info = vim.fn.getbufinfo(bufnr)[1],
            }

            if opts.sort_lastused and (flag == "#" or flag == "%") then
                local idx = ((buffers[1] ~= nil and buffers[1].flag == "%") and 2 or 1)
                table.insert(buffers, idx, element)
            else
                table.insert(buffers, element)
            end
        end

        if not opts.bufnr_width then
            local max_bufnr = math.max(unpack(bufnrs))
            opts.bufnr_width = #tostring(max_bufnr)
        end
        return buffers
    end

    local opts = {}
    pickers.new(opts, {
        prompt_title = "Buffers",
        finder = finders.new_table {
            results = buffer_list(opts),
            entry_maker = opts.entry_maker or make_entry.gen_from_buffer(opts),
        },
        previewer = conf.grep_previewer(opts),
        sorter = conf.generic_sorter(opts),
        default_selection_index = default_selection_idx,
        attach_mappings = function(prompt_bufnr, map)
            map('i', '<C-i>', open_in_new_instance)
            map('i', '<C-s>', function()    -- s as swipe
                local current_picker = action_state.get_current_picker(prompt_bufnr)
                local multi_selection = current_picker:get_multi_selection()
                -- TODO: currently cannot delete last shown buffer
                if #multi_selection > 0 then
                    for _, selection in ipairs(multi_selection) do
                        vim.api.nvim_buf_delete(selection.bufnr, { force=true })
                    end
                else
                    local selection = action_state.get_selected_entry()
                    vim.api.nvim_buf_delete(selection.bufnr, { force=true })
                end
                action_state.get_current_picker(prompt_bufnr):refresh(finders.new_table{
                    results = buffer_list(opts), entry_maker = opts.entry_maker or make_entry.gen_from_buffer(opts) })
            end)
            return true
        end,
    }):find()
end


function M.Sessions()
    load_dependencies()
    local session = require 'nvim_config.session'
    pickers.new({}, {
        prompt_title = 'Sessions',
        mappings = {
            i = { ['<C-v>'] = false, ['<C-x>'] = false },
            n = { ['<C-v>'] = false, ['<C-x>'] = false },
        },
        finder = finders.new_table { results = session.SessionList(), },
        sorter = conf.generic_sorter({}),
        previewer = false,
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection and #selection > 0 then
                    session.OpenSession(selection[1])
                end
            end)
            map('i', '<C-i>', function()
                local selection = action_state.get_selected_entry()
                if selection and #selection > 0 then
                    actions.close(prompt_bufnr)
                    local path = string.format('%s/sessions/%s', vim.fn.stdpath('data'), selection[1])
                    require'nvim_config.instance'.new({ '-S', path })
                end
            end)
            return true
        end,
    }):find()
end

function M.RunLauncher()
    load_dependencies()
    local opts = {}
    pickers.new(opts, {
        prompt_title = 'Launch',
        finder = finders.new_table { results = require'nvim_config.launcher'.GetLauncherList(), },
        sorter = conf.generic_sorter(opts),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                require'nvim_config.launcher'.LaunchObject(selection[1])
            end)
            return true
        end,
    }):find()
end

function M.Notes()
    load_dependencies()
    require 'telescope.builtin'.find_files {
        cwd = '~/notes/',
        attach_mappings = function(_, map)
            map('i', '<C-i>', open_in_new_instance)
            return true
        end,
    }
end

function M.Tabs()
    load_dependencies()
    local total = vim.fn.tabpagenr('$')
    local cur = vim.fn.tabpagenr()
    local entries = {}
    for i = 1, total do
        local tabtitle = require'nvim_config.tabline'.tabtitle(i)
        -- Buffer file names in this tab, for display and filtering
        local num_wins = vim.fn.tabpagewinnr(i, '$')
        local files = {}
        for w = 1, num_wins do
            local winid = vim.fn.win_getid(w, i)
            if vim.api.nvim_win_get_config(winid).relative == '' then
                local buf = vim.api.nvim_win_get_buf(winid)
                local name = vim.fn.bufname(buf)
                if name ~= '' and vim.bo[buf].buftype ~= 'quickfix' then
                    files[#files + 1] = vim.fn.fnamemodify(name, ':p')
                end
            end
        end
        -- Basenames as the ordinal, so fzy scores stay tight
        local basenames = {}
        for _, f in ipairs(files) do
            basenames[#basenames + 1] = vim.fn.fnamemodify(f, ':t')
        end
        entries[#entries + 1] = {
            tabnr = i,
            title = tabtitle,
            files = files,
            basenames = basenames,
            is_current = (i == cur),
        }
    end

    pickers.new({}, {
        prompt_title = 'Tabs',
        finder = finders.new_table {
            results = entries,
            entry_maker = function(entry)
                local prefix = entry.is_current and '* ' or '  '
                local display = string.format('%s%d: %s', prefix, entry.tabnr, entry.title)
                local ordinal = entry.title .. ' ' .. table.concat(entry.basenames, ' ')
                return {
                    value = entry,
                    display = display,
                    ordinal = ordinal,
                }
            end,
        },
        sorter = conf.generic_sorter({}),
        previewer = false,
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    vim.cmd('tabnext ' .. selection.value.tabnr)
                end
            end)
            return true
        end,
    }):find()
end

function M.ConfigFiles(query)
    load_dependencies()
    require'telescope.builtin'.find_files {
        cwd = vim.fn.stdpath('config'),
        default_text = query or '',
        attach_mappings = function(_, map)
            map('i', '<C-i>', open_in_new_instance)
            return true
        end,
    }
end

function M.LSPWorkspaceSymbols()
    load_dependencies()
   require'telescope.builtin'.lsp_dynamic_workspace_symbols {
       fname_width = 120,
   }
end

function M.LSPDocumentSymbols()
    load_dependencies()
    require'telescope.builtin'.lsp_document_symbols {
       fname_width = 120,
    }
end

return M
