local M = {}
local pr = require 'prjroot'
local ut = require 'util'

-- Reference: https://github.com/nvim-telescope/telescope.nvim/blob/master/developers.md
local pickers = require 'telescope.pickers'
local finders = require 'telescope.finders'
local conf = require 'telescope.config'.values
local actions = require 'telescope.actions'
local action_state = require 'telescope.actions.state'
local make_entry = require 'telescope.make_entry'


local function Files()
    if pr then
        require 'telescope.builtin'.find_files {
            cwd = pr.GetCurrentProjectRoot() or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':p:h')
        }
    end
end

-- TODO: cannot swipe current diplayed buffer
local function Buffers()
    local default_selection_idx = 1
    local buffer_list = function(opts)
        opts = opts or {}
        local bufnrs = vim.tbl_filter(function(b)
            if 1 ~= vim.fn.buflisted(b) then
                return false
            end
            -- only hide unloaded buffers if opts.show_all_buffers is false, keep them listed if true or nil
            if opts.show_all_buffers == false and not vim.api.nvim_buf_is_loaded(b) then
                return false
            end
            if opts.ignore_current_buffer and b == vim.api.nvim_get_current_buf() then
                return false
            end
            if opts.cwd_only and not string.find(vim.api.nvim_buf_get_name(b), vim.loop.cwd(), 1, true) then
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


local function Sessions()
    local session = require 'session'
    pickers.new({}, {
        prompt_title = 'Sessions',
        finder = finders.new_oneshot_job(session.SessionDir()),
        sorter = conf.generic_sorter({}),
        previewer = false,
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                session.OpenSession(selection[1])
            end)
            return true
        end,
    }):find()
end

local function RunLauncher()
    local opts = {}
    pickers.new(opts, {
        prompt_title = 'Launch',
        finder = finders.new_table { results = require'launcher'.GetLauncherList(), },
        sorter = conf.generic_sorter(opts),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                require'launcher'.LaunchObject(selection[1])
            end)
            return true
        end,
    }):find()
end

local function Notes()
    require 'telescope.builtin'.find_files { cwd = '~/notes/' }
end

function M.setup()
    require 'telescope'.setup {
        defaults = {
            mappings = {
                i = {
                    ["<esc>"] = require('telescope.actions').close,
                },
            },
            preview = false,
        }
    }
    ut.nmap('<Leader>ff', Files)
    ut.nmap('<Leader>fb', Buffers)
    ut.nmap('<Leader>fs', Sessions)
    ut.nmap('<Leader>fu', RunLauncher)
    ut.nmap('<Leader>fn', Notes)
end

return M
