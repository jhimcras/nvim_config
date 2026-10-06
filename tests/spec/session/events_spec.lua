local session = require('nvim_config.session')
local tabline = require('nvim_config.tabline')

tabline.setup()

describe('session events', function()
    local directory, original_stdpath, original_session, original_cwd, original_confirm
    local events, group, file

    before_each(function()
        directory = vim.fn.tempname()
        vim.fn.mkdir(directory, 'p')
        original_stdpath = vim.fn.stdpath
        original_session = vim.v.this_session
        original_cwd = vim.fn.getcwd()
        original_confirm = vim.fn.confirm
        vim.fn.stdpath = function(kind)
            return kind == 'data' and directory or original_stdpath(kind)
        end
        vim.v.this_session = ''
        file = directory .. '/document.txt'
        vim.fn.writefile({ 'first', 'second' }, file)
        vim.cmd.edit(file)
        events = {}
        group = vim.api.nvim_create_augroup('SessionEventSpec', { clear = true })
        vim.api.nvim_create_autocmd('User', {
            group = group,
            pattern = { 'SessionChanged', 'SessionLoaded' },
            callback = function(event)
                events[#events + 1] = {
                    event = event.match,
                    data = event.data,
                    tabline = vim.go.tabline,
                    cmdheight = vim.o.cmdheight,
                    loclist = vim.fn.getloclist(0),
                    quickfix = vim.fn.getqflist(),
                }
            end,
        })
    end)

    after_each(function()
        vim.api.nvim_del_augroup_by_id(group)
        vim.fn.stdpath = original_stdpath
        vim.fn.confirm = original_confirm
        vim.v.this_session = original_session
        vim.cmd.cd(original_cwd)
        pcall(vim.cmd, 'lclose')
        pcall(vim.cmd, 'cclose')
        vim.cmd('enew!')
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_get_name(buf):find(directory, 1, true) == 1 then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
        vim.fn.delete(directory, 'rf')
    end)

    it('updates tabline synchronously after saving and removing the current session', function()
        session.SaveSession('events_save')
        local path = directory .. '/sessions/events_save'
        assert.equals(1, vim.fn.filereadable(path))
        assert.equals(1, #events)
        assert.equals('SessionChanged', events[1].event)
        assert.same({ action = 'save', path = path, session = path }, events[1].data)
        assert.truthy(events[1].tabline:find('events_save', 1, true))

        session.RemoveSession()
        assert.equals(0, vim.fn.filereadable(path))
        assert.equals(2, #events)
        assert.same({ action = 'remove', path = path, session = '' }, events[2].data)
        assert.is_nil(events[2].tabline:find('events_save', 1, true))
    end)

    it('emits SessionLoaded after restoring list contents and cmdheight', function()
        vim.fn.setloclist(0, {}, ' ', {
            title = 'saved location list',
            items = { { filename = file, lnum = 2, col = 1, text = 'saved match' } },
        })
        vim.cmd('lopen')
        session.SaveSession('events_load')
        vim.cmd('lclose')
        vim.o.cmdheight = 5
        session.OpenSession('events_load')
        assert.equals(2, #events)
        local loaded = events[2]
        local path = directory .. '/sessions/events_load'
        assert.equals('SessionLoaded', loaded.event)
        assert.same({ action = 'open', path = path, session = path }, loaded.data)
        assert.equals(1, loaded.cmdheight)
        assert.equals('saved match', loaded.loclist[1].text)
        assert.truthy(loaded.tabline:find('events_load', 1, true))
    end)

    it('emits Close only after clearing session and quickfix state', function()
        session.SaveSession('events_close')
        vim.fn.setqflist({}, ' ', { items = { { filename = file, lnum = 1, text = 'old match' } } })
        session.CloseSession()
        assert.equals(2, #events)
        assert.same({
            action = 'close', path = directory .. '/sessions/events_close', session = '',
        }, events[2].data)
        assert.same({}, events[2].quickfix)
        assert.is_nil(events[2].tabline:find('events_close', 1, true))
    end)

    it('does not emit events for cancelled loads or missing removals', function()
        vim.bo.modified = true
        vim.fn.confirm = function() return 2 end
        session.OpenSession('does_not_exist')
        session.RemoveSession('does_not_exist')
        assert.same({}, events)
        vim.bo.modified = false
    end)
end)
