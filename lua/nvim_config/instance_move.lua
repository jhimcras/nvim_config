-- Move file and Oil buffers, or the visible buffers in a tab, to another Nvim process.
local api = vim.api
local M = {}
local registry = vim.fn.stdpath('state') .. '/nvim-instances'
local own_file

local function warn(message)
    vim.notify('MoveInstance: ' .. message, vim.log.levels.WARN)
end

function M.setup()
    vim.fn.mkdir(registry, 'p')
    local address = vim.v.servername
    if address == '' then
        local ok, result = pcall(vim.fn.serverstart)
        if not ok then
            warn('RPC 서버를 시작하지 못했습니다: ' .. tostring(result))
            return
        end
        address = result
    end
    own_file = registry .. '/' .. vim.uv.os_getpid()
    vim.fn.writefile({ address }, own_file)
    api.nvim_create_autocmd('VimLeavePre', { callback = function()
        if own_file then vim.fn.delete(own_file) end
    end })
end

function M.targets()
    local result = { { display = 'New Instance', new = true } }
    for _, file in ipairs(vim.fn.glob(registry .. '/*', false, true)) do
        local pid = tonumber(vim.fn.fnamemodify(file, ':t'))
        if pid and pid ~= vim.uv.os_getpid() then
            local lines = vim.fn.readfile(file)
            local address = lines[1]
            if address and address ~= '' then
                local ok, chan = pcall(vim.fn.sockconnect, 'pipe', address, { rpc = true })
                if ok and chan > 0 then
                    local alive, info = pcall(vim.rpcrequest, chan, 'nvim_exec_lua',
                        'return { session = vim.v.this_session, cwd = vim.fn.getcwd() }', {})
                    if alive and type(info) == 'table' then
                        local session = info.session
                        local label = session and session ~= ''
                            and ('session: ' .. vim.fn.fnamemodify(session, ':t'))
                            or ('pwd: ' .. tostring(info.cwd))
                        result[#result + 1] = {
                            display = string.format('Nvim %d (%s)', pid, label),
                            address = address,
                        }
                    else
                        vim.fn.delete(file)
                    end
                    vim.fn.chanclose(chan)
                else
                    vim.fn.delete(file)
                end
            end
        end
    end
    return result
end

local function collect(kind)
    local buffers = {}
    if kind == 'buffer' then
        buffers[1] = api.nvim_get_current_buf()
    else
        for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
            if api.nvim_win_get_config(win).relative == '' then
                local buf = api.nvim_win_get_buf(win)
                buffers[#buffers + 1] = buf
            end
        end
    end
    local paths = {}
    for _, buf in ipairs(buffers) do
        local name = api.nvim_buf_get_name(buf)
        local oil = vim.bo[buf].filetype == 'oil'
            and name:match('^oil://')
            and require'oil'.get_current_dir(buf) ~= nil
        if not oil and (vim.bo[buf].buftype ~= '' or name == '' or vim.fn.isdirectory(name) == 1) then
            warn('파일 또는 로컬 Oil 버퍼만 옮길 수 있습니다')
            return nil
        end
        paths[#paths + 1] = name
    end
    if #paths == 0 then warn('옮길 파일이 없습니다'); return nil end
    return buffers, paths
end

local function confirm_changes(buffers, done)
    local changed = {}
    for _, buf in ipairs(buffers) do
        if vim.bo[buf].modified and not vim.tbl_contains(changed, buf) then
            changed[#changed + 1] = buf
        end
    end
    if #changed == 0 then done(true); return end
    local function ask()
        vim.ui.input({
            prompt = string.format('Move %d modified buffer%s (1 Save, 2 Ignore, 3 Cancel): ',
                #changed, #changed == 1 and '' or 's'),
        }, function(choice)
            if choice ~= nil and choice ~= '' and choice ~= '1' and choice ~= '2' and choice ~= '3' then
                vim.schedule(ask)
                return
            end
            if choice == '1' then
                local index = 1
                local function save_next()
                    local buf = changed[index]
                    if not buf then done(true); return end
                    index = index + 1
                    if vim.bo[buf].filetype == 'oil' then
                        require'oil'.save({ confirm = false }, function(err)
                            if err then warn('저장 실패: ' .. tostring(err)); done(false); return end
                            save_next()
                        end)
                    else
                        local ok, err = pcall(api.nvim_buf_call, buf, function() vim.cmd.write() end)
                        if not ok then warn('저장 실패: ' .. tostring(err)); done(false); return end
                        save_next()
                    end
                end
                save_next()
            else
                done(choice == '2')
            end
        end)
    end
    ask()
end

-- Called over RPC in the destination process. A tab is one tab with file splits.
function M.receive(paths, kind)
    if type(paths) ~= 'table' or #paths == 0 then return false end
    if kind == 'tab' then
        vim.cmd.tabnew({ args = { paths[1] } })
        for i = 2, #paths do vim.cmd.vsplit({ args = { paths[i] } }) end
    else
        vim.cmd.tabnew({ args = { paths[1] } })
    end
    return true
end

local function send(target, paths, kind)
    if target.new then
        local args = kind == 'tab' and #paths > 1 and { '-O' } or {}
        vim.list_extend(args, paths)
        return require'nvim_config.instance'.new(args)
    end
    local ok, chan = pcall(vim.fn.sockconnect, 'pipe', target.address, { rpc = true })
    if not ok or chan <= 0 then warn('대상 프로세스에 연결하지 못했습니다'); return false end
    local sent, result = pcall(vim.rpcrequest, chan, 'nvim_exec_lua',
        'return require("nvim_config.instance_move").receive(...)', { paths, kind })
    vim.fn.chanclose(chan)
    if not sent or result ~= true then
        warn('대상 프로세스에서 파일을 열지 못했습니다: ' .. tostring(result))
        return false
    end
    return true
end

function M.move(kind)
    local buffers, paths = collect(kind)
    if not buffers then return end
    require'nvim_config.plugins.tele'.InstanceTargets(function(target)
        if not target then return end
        confirm_changes(buffers, function(proceed)
            if not proceed or not send(target, paths, kind) then return end
            if kind == 'tab' then
                if vim.fn.tabpagenr('$') == 1 then
                    vim.cmd.tabnew()
                    vim.cmd.tabprevious()
                end
                vim.cmd.tabclose({ bang = true })
            end
            for _, buf in ipairs(buffers) do
                if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
            end
        end)
    end)
end

return M
