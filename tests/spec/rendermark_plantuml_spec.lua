local plantuml = require('rendermark.plantuml')

local function make_buf(lines)
    vim.cmd('enew')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    return buf
end

local function plantuml_marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, plantuml._test.namespace, 0, -1, { details = true })
end

local function concealed_rows(buf)
    local rows = {}
    for _, mark in ipairs(plantuml_marks(buf)) do
        if mark[4].conceal == '' then
            rows[mark[2]] = true
        end
    end
    return rows
end

describe('rendermark.plantuml', function()
    local orig_exepath
    local orig_filereadable
    local orig_system
    local orig_notify

    before_each(function()
        pcall(vim.api.nvim_del_augroup_by_name, 'rendermark_plantuml')
        pcall(vim.api.nvim_del_user_command, 'RendermarkPlantumlRefresh')
        pcall(vim.api.nvim_del_user_command, 'RendermarkPlantumlClean')
        pcall(vim.api.nvim_del_user_command, 'RendermarkPlantumlDebug')
        vim.g.rendermark_plantuml_jar = nil
        vim.env.RENDERMARK_PLANTUML_JAR = nil
        vim.env.PLANTUML_JAR = nil
        orig_exepath = vim.fn.exepath
        orig_filereadable = vim.fn.filereadable
        orig_system = vim.system
        orig_notify = vim.notify
        vim.notify = function() end
    end)

    after_each(function()
        plantuml.clean(0)
        vim.fn.exepath = orig_exepath
        vim.fn.filereadable = orig_filereadable
        vim.system = orig_system
        vim.notify = orig_notify
        vim.g.rendermark_plantuml_jar = nil
        vim.env.RENDERMARK_PLANTUML_JAR = nil
        vim.env.PLANTUML_JAR = nil
    end)

    it('detects plantuml fenced blocks', function()
        plantuml.setup({ enabled = false })
        local buf = make_buf({
            'before',
            '```plantuml',
            '@startuml',
            'Alice -> Bob',
            '@enduml',
            '```',
            'after',
        })

        local blocks = plantuml.find_blocks(buf)
        assert.are.equal(1, #blocks)
        assert.are.equal(1, blocks[1].start_row)
        assert.are.equal(5, blocks[1].end_row)
        assert.are.equal('plantuml', blocks[1].lang)
        assert.is_truthy(blocks[1].text:find('Alice %-> Bob'))
    end)

    it('prefers java jar command when configured', function()
        vim.fn.exepath = function(name)
            if name == 'java' then return '/bin/java' end
            if name == 'plantuml' then return '/bin/plantuml' end
            return ''
        end
        vim.fn.filereadable = function(path)
            return path == '/tmp/plantuml.jar' and 1 or 0
        end
        plantuml.setup({ enabled = false, jar_path = '/tmp/plantuml.jar' })

        local cmd, args = plantuml.resolve_command()
        assert.are.equal('/bin/java', cmd)
        assert.are.same({ '-jar', '/tmp/plantuml.jar', '-tpng' }, args)
    end)

    it('uses the dedicated jar environment variable', function()
        vim.fn.exepath = function(name)
            return name == 'java' and '/bin/java' or ''
        end
        vim.fn.filereadable = function(path)
            return path == '/private/plantuml.jar' and 1 or 0
        end
        vim.env.RENDERMARK_PLANTUML_JAR = '/private/plantuml.jar'
        plantuml.setup({ enabled = false })

        local cmd, args = plantuml.resolve_command()
        assert.are.equal('/bin/java', cmd)
        assert.are.same({ '-jar', '/private/plantuml.jar', '-tpng' }, args)
    end)

    it('explains invalid executable PlantUML jars', function()
        vim.env.RENDERMARK_PLANTUML_JAR = '/private/bad.jar'
        plantuml.setup({ enabled = false })

        local message = plantuml._test.render_error_text(
            'Error: Could not find or load main class net.sourceforge.plantuml.Run\0' ..
            'Caused by: java.lang.ClassNotFoundException: net.sourceforge.plantuml.Run'
        )

        assert.is_truthy(message:find('Invalid PlantUML jar', 1, true))
        assert.is_truthy(message:find('/private/bad.jar', 1, true))
        assert.is_nil(message:find('%z'))
    end)

    it('falls back to plantuml wrapper', function()
        vim.fn.exepath = function(name)
            if name == 'plantuml' then return 'C:/tools/plantuml.cmd' end
            return ''
        end
        vim.fn.filereadable = function() return 0 end
        plantuml.setup({ enabled = false })

        local cmd, args = plantuml.resolve_command()
        assert.are.equal('C:/tools/plantuml.cmd', cmd)
        assert.are.same({ '-tpng' }, args)
    end)

    it('renders a non-cursor block as a virtual image link', function()
        vim.fn.exepath = function(name)
            return name == 'plantuml' and '/bin/plantuml' or ''
        end
        vim.system = function(argv, _, on_exit)
            local puml = argv[#argv]
            local png = puml:gsub('%.puml$', '.png')
            vim.fn.writefile({ 'png' }, png)
            vim.schedule(function() on_exit({ code = 0, stderr = '' }) end)
            return { kill = function() end }
        end
        plantuml.setup({ debounce_ms = 10 })
        local buf = make_buf({
            'cursor here',
            '```plantuml',
            '@startuml',
            'Alice -> Bob',
            '@enduml',
            '```',
        })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })

        plantuml.refresh(buf)
        vim.wait(1000, function()
            local marks = plantuml_marks(buf)
            for _, mark in ipairs(marks) do
                local vt = mark[4].virt_text
                if vt and vt[1] and vt[1][1]:find('!%[plantuml%]%(.*%.png%)') then
                    return true
                end
            end
            return false
        end)

        local found = false
        local marks = plantuml_marks(buf)
        for _, mark in ipairs(marks) do
            local vt = mark[4].virt_text
            found = found or (vt and vt[1] and vt[1][1]:find('!%[plantuml%]%(.*%.png%)') ~= nil)
        end
        assert.is_true(found)
        local rows = concealed_rows(buf)
        for row = 1, 5 do
            assert.is_true(rows[row])
        end
        assert.is_true(vim.wo[0].conceallevel >= 2)
    end)

    it('reports render status in debug output', function()
        vim.fn.exepath = function(name)
            return name == 'plantuml' and '/bin/plantuml' or ''
        end
        vim.system = function(argv, _, on_exit)
            local png = argv[#argv]:gsub('%.puml$', '.png')
            vim.fn.writefile({ 'png' }, png)
            vim.schedule(function() on_exit({ code = 0, stderr = '' }) end)
            return { kill = function() end }
        end
        plantuml.setup({ debounce_ms = 10 })
        local buf = make_buf({ '```plantuml', '@startuml', '@enduml', '```' })

        plantuml.refresh(buf)
        vim.wait(1000, function()
            local st = plantuml._test.states[buf]
            if not st then return false end
            for _, entry in pairs(st.cache) do
                if entry.status == 'ready' then return true end
            end
            return false
        end)

        local output = table.concat(plantuml._test.debug_lines(buf), '\n')
        assert.is_truthy(output:find('temp dir:', 1, true))
        assert.is_truthy(output:find('command: /bin/plantuml -tpng', 1, true))
        assert.is_truthy(output:find('status: ready', 1, true))
        assert.is_truthy(output:find('png:', 1, true))
        assert.is_truthy(output:find('exists=true', 1, true))
    end)

    it('does not inline-transform the active block outside READ mode', function()
        vim.fn.exepath = function(name)
            return name == 'plantuml' and '/bin/plantuml' or ''
        end
        vim.system = function(argv, _, on_exit)
            local png = argv[#argv]:gsub('%.puml$', '.png')
            vim.fn.writefile({ 'png' }, png)
            vim.schedule(function() on_exit({ code = 0, stderr = '' }) end)
            return { kill = function() end }
        end
        plantuml.setup({ debounce_ms = 10 })
        local buf = make_buf({
            '```plantuml',
            '@startuml',
            'Alice -> Bob',
            '@enduml',
            '```',
        })
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        plantuml.refresh(buf)
        vim.wait(1000, function()
            local st = plantuml._test.states[buf]
            if not st then return false end
            for _, entry in pairs(st.cache) do
                if entry.status == 'ready' then return true end
            end
            return false
        end)
        plantuml.refresh(buf)

        local marks = vim.api.nvim_buf_get_extmarks(buf, plantuml._test.namespace, 0, -1, { details = true })
        for _, mark in ipairs(marks) do
            local vt = mark[4].virt_text
            assert.is_false(vt and vt[1] and vt[1][1]:find('!%[plantuml%]%(.*%.png%)') ~= nil)
        end
    end)

    it('places preview floats below a block when there is room', function()
        plantuml.setup({ enabled = false })
        local buf = make_buf({
            'before',
            '```plantuml',
            '@startuml',
            '@enduml',
            '```',
            'after',
        })
        vim.cmd('normal! gg')

        local config = plantuml._test.float_config_for_block(0, {
            start_row = 1,
            end_row = 4,
        }, 30, 6)

        assert.are.equal('win', config.relative)
        assert.is_true(config.row > 4)
    end)

    it('places preview floats above a block when the block is near the bottom', function()
        plantuml.setup({ enabled = false })
        local lines = {}
        for i = 1, 14 do
            lines[i] = 'line ' .. i
        end
        make_buf(lines)
        vim.cmd('resize 12')
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd('normal! zt')

        local config = plantuml._test.float_config_for_block(0, {
            start_row = 8,
            end_row = 11,
        }, 30, 6)

        assert.is_true(config.row + config.height + 1 < 8)
    end)

    it('inline-transforms the active block in READ mode', function()
        vim.fn.exepath = function(name)
            return name == 'plantuml' and '/bin/plantuml' or ''
        end
        vim.system = function(argv, _, on_exit)
            local png = argv[#argv]:gsub('%.puml$', '.png')
            vim.fn.writefile({ 'png' }, png)
            vim.schedule(function() on_exit({ code = 0, stderr = '' }) end)
            return { kill = function() end }
        end
        plantuml.setup({ debounce_ms = 10 })
        local buf = make_buf({
            '```plantuml',
            '@startuml',
            'Alice -> Bob',
            '@enduml',
            '```',
        })
        vim.b[buf].markdown_read_mode = true
        vim.wo[0].concealcursor = ''
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        plantuml.refresh(buf)
        vim.wait(1000, function()
            local marks = plantuml_marks(buf)
            for _, mark in ipairs(marks) do
                local vt = mark[4].virt_text
                if vt and vt[1] and vt[1][1]:find('!%[plantuml%]%(.*%.png%)') then
                    return true
                end
            end
            return false
        end)

        local found = false
        local marks = plantuml_marks(buf)
        for _, mark in ipairs(marks) do
            local vt = mark[4].virt_text
            found = found or (vt and vt[1] and vt[1][1]:find('!%[plantuml%]%(.*%.png%)') ~= nil)
        end
        assert.is_true(found)
        local rows = concealed_rows(buf)
        for row = 0, 4 do
            assert.is_true(rows[row])
        end
        assert.are.equal('nvic', vim.wo[0].concealcursor)

        vim.b[buf].markdown_read_mode = false
        plantuml.refresh(buf)
        assert.are.equal('', vim.wo[0].concealcursor)
    end)

    it('cleans buffer temp files', function()
        vim.fn.exepath = function(name)
            return name == 'plantuml' and '/bin/plantuml' or ''
        end
        vim.system = function(argv, _, on_exit)
            local png = argv[#argv]:gsub('%.puml$', '.png')
            vim.fn.writefile({ 'png' }, png)
            vim.schedule(function() on_exit({ code = 0, stderr = '' }) end)
            return { kill = function() end }
        end
        plantuml.setup({ debounce_ms = 10 })
        local buf = make_buf({ '```plantuml', '@startuml', '@enduml', '```' })
        plantuml.refresh(buf)
        assert.is_truthy(plantuml._test.states[buf])
        local dir = plantuml._test.states[buf].temp_dir
        assert.are.equal(1, vim.fn.isdirectory(dir))

        plantuml.clean(buf)
        assert.are.equal(0, vim.fn.isdirectory(dir))
    end)
end)
