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

local function assert_closed_fold(start_row, end_row)
    local start_lnum = start_row + 1
    assert.are.equal(start_lnum, vim.fn.foldclosed(start_lnum))
    assert.are.equal(end_row + 1, vim.fn.foldclosedend(start_lnum))
end

local function assert_no_closed_fold(start_row)
    assert.are.equal(-1, vim.fn.foldclosed(start_row + 1))
end

local function rects_overlap(a_top, a_bottom, a_left, a_right, b_top, b_bottom, b_left, b_right)
    return a_top <= b_bottom and b_top <= a_bottom and a_left <= b_right and b_left <= a_right
end

local function write_png_header(path, width, height)
    local bytes = {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        math.floor(width / 0x1000000) % 0x100,
        math.floor(width / 0x10000) % 0x100,
        math.floor(width / 0x100) % 0x100,
        width % 0x100,
        math.floor(height / 0x1000000) % 0x100,
        math.floor(height / 0x10000) % 0x100,
        math.floor(height / 0x100) % 0x100,
        height % 0x100,
    }
    local chars = {}
    for _, byte in ipairs(bytes) do
        chars[#chars + 1] = string.char(byte)
    end
    local file = assert(io.open(path, 'wb'))
    file:write(table.concat(chars))
    file:close()
end

describe('rendermark.plantuml', function()
    local orig_exepath
    local orig_filereadable
    local orig_get_mode
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
        orig_get_mode = vim.api.nvim_get_mode
        orig_system = vim.system
        orig_notify = vim.notify
        vim.notify = function() end
    end)

    after_each(function()
        plantuml.clean(0)
        vim.fn.exepath = orig_exepath
        vim.fn.filereadable = orig_filereadable
        vim.api.nvim_get_mode = orig_get_mode
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
        assert_closed_fold(1, 5)
        assert.is_truthy(vim.fn.foldtextresult(2):find('!%[plantuml%]%(.*%.png%)'))
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
        assert_no_closed_fold(0)
    end)

    it('places preview floats below a block when there is room', function()
        plantuml.setup({ enabled = false })
        local buf = make_buf({
            'before',
            '    ```plantuml',
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

        assert.are.equal('editor', config.relative)
        assert.is_nil(config.border)
        assert.is_true(config.row > 4)
        assert.are.equal(4, config.col)
    end)

    it('keeps sample preview below cursor line 2 from covering the fenced block', function()
        plantuml.setup({ enabled = false })
        make_buf({
            '# One',
            '  ```plantuml',
            '  @startuml',
            '  Alice -> Bob',
            '  Bob -> Carol',
            '  Carol -> Alice',
            '  Alice -> Dave',
            '  Dave -> Bob',
            '  ```',
            '',
            '  ```plantuml',
            '  @startuml',
            '  Foo -> Bar',
            '  Bar -> Baz',
            '  ```',
        })
        vim.cmd('resize 30')
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        vim.cmd('normal! zt')

        local config = plantuml._test.float_config_for_block(0, {
            start_row = 1,
            end_row = 8,
        }, 24, 6)

        local screenpos = vim.fn.win_screenpos(0)
        local topline = vim.api.nvim_win_call(0, function() return vim.fn.line('w0') end) - 1
        local block_top = (screenpos[1] or 1) - 1 + 1 - topline
        local block_bottom = (screenpos[1] or 1) - 1 + 8 - topline
        local float_top = config.row
        local float_bottom = config.row + config.height - 1
        assert.are.equal(2, config.col)
        assert.is_false(rects_overlap(float_top, float_bottom, config.col, config.col + config.width - 1,
            block_top, block_bottom, 2, 17))
    end)

    it('keeps sample preview from cursor line 3 off the opening fence row', function()
        plantuml.setup({ enabled = false })
        make_buf({
            '# One',
            '  ```plantuml',
            '  @startuml',
            '  Alice -> Bob',
            '  Bob -> Carol',
            '  Carol -> Alice',
            '  Alice -> Dave',
            '  Dave -> Bob',
            '  ```',
            '',
            '  ```plantuml',
            '  @startuml',
            '  Foo -> Bar',
            '  Bar -> Baz',
            '  ```',
        })
        vim.cmd('resize 30')
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        vim.cmd('normal! zt')

        local config = plantuml._test.float_config_for_block(0, {
            start_row = 1,
            end_row = 8,
        }, 24, 6)

        local screenpos = vim.fn.win_screenpos(0)
        local topline = vim.api.nvim_win_call(0, function() return vim.fn.line('w0') end) - 1
        local block_top = (screenpos[1] or 1) - 1 + 1 - topline
        local block_bottom = (screenpos[1] or 1) - 1 + 8 - topline
        local float_top = config.row
        local float_bottom = config.row + config.height - 1
        assert.is_false(rects_overlap(float_top, float_bottom, config.col, config.col + config.width - 1,
            block_top, block_bottom, 2, 17))
    end)

    it('keeps sample preview from cursor line 11 off the second fenced block', function()
        plantuml.setup({ enabled = false })
        make_buf({
            '# One',
            '  ```plantuml',
            '  @startuml',
            '  Alice -> Bob',
            '  Bob -> Carol',
            '  Carol -> Alice',
            '  Alice -> Dave',
            '  Dave -> Bob',
            '  ```',
            '',
            '    ```plantuml',
            '    @startuml',
            '    Foo -> Bar',
            '    Bar -> Baz',
            '    ```',
        })
        vim.cmd('resize 30')
        vim.api.nvim_win_set_cursor(0, { 11, 0 })
        vim.cmd('normal! zt')

        local config = plantuml._test.float_config_for_block(0, {
            start_row = 10,
            end_row = 14,
        }, 24, 6)

        local screenpos = vim.fn.win_screenpos(0)
        local topline = vim.api.nvim_win_call(0, function() return vim.fn.line('w0') end) - 1
        local block_top = (screenpos[1] or 1) - 1 + 10 - topline
        local block_bottom = (screenpos[1] or 1) - 1 + 14 - topline
        local float_top = config.row
        local float_bottom = config.row + config.height - 1
        assert.are.equal(4, config.col)
        assert.is_false(rects_overlap(float_top, float_bottom, config.col, config.col + config.width - 1,
            block_top, block_bottom, 4, 18))
    end)

    it('parses PNG dimensions from the image header', function()
        local path = vim.fn.tempname() .. '.png'
        write_png_header(path, 320, 180)

        local size = plantuml._test.read_png_size(path)

        assert.are.same({ width = 320, height = 180 }, size)
        vim.fn.delete(path)
    end)

    it('sizes preview floats from image dimensions converted to cells', function()
        plantuml.setup({ enabled = false })
        local size = { width = 95, height = 37 }

        local dims = plantuml._test.float_dimensions_for_image(size, {
            cell_width = 10,
            cell_height = 18,
            max_width = 80,
            max_height = 24,
        })

        assert.are.equal(10, dims.width)
        assert.are.equal(3, dims.height)
    end)

    it('caps preview float dimensions to the usable editor screen', function()
        plantuml.setup({ enabled = false })
        local old_columns = vim.o.columns
        local old_lines = vim.o.lines
        local old_cmdheight = vim.o.cmdheight
        vim.o.columns = 32
        vim.o.lines = 12
        vim.o.cmdheight = 1

        local ok, dims = pcall(plantuml._test.float_dimensions_for_image, {
            width = 4000,
            height = 3000,
        }, {
            cell_width = 10,
            cell_height = 10,
        })

        vim.o.columns = old_columns
        vim.o.lines = old_lines
        vim.o.cmdheight = old_cmdheight
        if not ok then error(dims, 2) end

        assert.are.equal(32, dims.width)
        assert.are.equal(11, dims.height)
    end)

    it('places preview floats beside the full fenced block without intersecting it', function()
        plantuml.setup({ enabled = false })
        local lines = {}
        for i = 1, 20 do
            lines[i] = 'line ' .. i
        end
        make_buf(lines)
        vim.cmd('resize 8')
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd('normal! zt')

        local config = plantuml._test.float_config_for_block(0, {
            start_row = 1,
            end_row = 5,
        }, 2, 6)

        local topline = vim.api.nvim_win_call(0, function() return vim.fn.line('w0') end) - 1
        local screenpos = vim.fn.win_screenpos(0)
        local block_top = (screenpos[1] or 1) - 1 + 1 - topline
        local block_bottom = (screenpos[1] or 1) - 1 + 5 - topline
        local float_top = config.row
        local float_bottom = config.row + config.height - 1
        assert.is_true(float_bottom < block_top or float_top > block_bottom or config.col + config.width - 1 < 0 or config.col > 0)
    end)

    it('creates preview floats as a markdown scratch buffer with one image link', function()
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
            '@enduml',
            '```',
        })
        vim.api.nvim_win_set_cursor(0, { 2, 0 })

        plantuml.refresh(buf)
        vim.wait(1000, function()
            local st = plantuml._test.states[buf]
            return st and st.float and st.float.win and vim.api.nvim_win_is_valid(st.float.win)
        end)

        local st = plantuml._test.states[buf]
        assert.is_truthy(st and st.float and st.float.win)
        local float_win = st.float.win
        local float_buf = vim.api.nvim_win_get_buf(float_win)
        assert.are.equal('markdown', vim.bo[float_buf].filetype)
        local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
        assert.are.same({ '![plantuml](' .. st.float.path .. ')' }, lines)
    end)

    it('suppresses active previews and inline image marks in visual modes', function()
        vim.fn.exepath = function(name)
            return name == 'plantuml' and '/bin/plantuml' or ''
        end
        vim.system = function(argv, _, on_exit)
            local png = argv[#argv]:gsub('%.puml$', '.png')
            write_png_header(png, 120, 72)
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
            return st and st.float and st.float.win and vim.api.nvim_win_is_valid(st.float.win)
        end)

        vim.cmd('normal! V')
        plantuml.refresh(buf)

        local st = plantuml._test.states[buf]
        assert.is_truthy(st)
        assert.is_nil(st.float)
        for _, mark in ipairs(plantuml_marks(buf)) do
            local vt = mark[4].virt_text
            assert.is_false(vt and vt[1] and vt[1][1]:find('!%[plantuml%]%(.*%.png%)') ~= nil)
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
    end)

    it('keeps active previews in insert and replace modes', function()
        vim.fn.exepath = function(name)
            return name == 'plantuml' and '/bin/plantuml' or ''
        end
        vim.system = function(argv, _, on_exit)
            local png = argv[#argv]:gsub('%.puml$', '.png')
            write_png_header(png, 120, 72)
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
            return st and st.float and st.float.win and vim.api.nvim_win_is_valid(st.float.win)
        end)

        vim.api.nvim_get_mode = function()
            return { mode = 'i', blocking = false }
        end
        plantuml.refresh(buf)
        local st = plantuml._test.states[buf]
        assert.is_truthy(st and st.float and st.float.win and vim.api.nvim_win_is_valid(st.float.win))

        vim.api.nvim_get_mode = function()
            return { mode = 'R', blocking = false }
        end
        plantuml.refresh(buf)
        st = plantuml._test.states[buf]
        assert.is_truthy(st and st.float and st.float.win and vim.api.nvim_win_is_valid(st.float.win))
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

        assert.is_true(config.row + config.height - 1 < 8)
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
        assert_closed_fold(0, 4)
        assert.is_truthy(vim.fn.foldtextresult(1):find('!%[plantuml%]%(.*%.png%)'))
        assert.are.equal('nvic', vim.wo[0].concealcursor)

        vim.b[buf].markdown_read_mode = false
        plantuml.refresh(buf)
        assert.are.equal('', vim.wo[0].concealcursor)
    end)

    it('removes the collapsed fold when a rendered block becomes active outside READ mode', function()
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
            return vim.fn.foldclosed(2) == 2
        end)
        assert_closed_fold(1, 5)

        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        plantuml.refresh(buf)

        assert_no_closed_fold(1)
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
