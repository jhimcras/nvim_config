local H = require('tests.spec.coderunner.helpers')
local api = vim.api
local CODERUNNER, IMAGE = 'nvim_config.coderunner', 'nvim_config.rendermark.image'

local function bytes(arr) return string.char(unpack(arr)) end
-- 100x50 PNG header (the size reader only needs the leading bytes).
local PNG = bytes({ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 100, 0, 0, 0, 50 })

local function fire(data)
    api.nvim_exec_autocmds('User', { pattern = 'CodeRunnerDiagrams', modeline = false, data = data })
end

describe('markdown glue', function()
    local glue, saved, preload, refreshed, fake_image, fake_runner

    local function count_autocmds()
        return #api.nvim_get_autocmds({ group = 'nvim_config_markdown', event = 'User' })
    end

    before_each(function()
        saved = { [CODERUNNER] = package.loaded[CODERUNNER], [IMAGE] = package.loaded[IMAGE] }
        preload = package.preload[CODERUNNER]
        refreshed = {}
        fake_image = {
            sources = {},
            set_diagram_source = function(source) table.insert(fake_image.sources, source) end,
            refresh = function(buf) refreshed[#refreshed + 1] = buf end,
        }
        fake_runner = {
            diagrams = function(buf) return { { start_row = 0, end_row = 1, buf = buf } } end,
            request_live = function() return true end,
        }
        package.loaded[IMAGE] = fake_image
        package.loaded[CODERUNNER] = fake_runner
        package.loaded['nvim_config.markdown'] = nil
        glue = require('nvim_config.markdown')
    end)

    after_each(function()
        pcall(api.nvim_del_augroup_by_name, 'nvim_config_markdown')
        package.loaded[CODERUNNER], package.loaded[IMAGE] = saved[CODERUNNER], saved[IMAGE]
        package.preload[CODERUNNER] = preload
        package.loaded['nvim_config.markdown'] = nil
    end)

    it('registers coderunner as the diagram source and forwards both calls', function()
        local live
        fake_runner.request_live = function(buf, row) live = { buf, row }; return true end
        glue.setup()
        assert.equals(1, #fake_image.sources)
        local source = fake_image.sources[1]
        assert.equals(7, source.items(7)[1].buf)
        assert.is_true(source.request_live(7, 3))
        assert.same({ 7, 3 }, live)
    end)

    it('refreshes the buffer named by CodeRunnerDiagrams', function()
        glue.setup()
        fire({ buf = 5 })
        assert.same({ 5 }, refreshed)
    end)

    it('registers nothing and stays quiet without coderunner', function()
        package.loaded[CODERUNNER] = nil
        package.preload[CODERUNNER] = function() error('coderunner is not installed') end
        assert.has_no.errors(function() glue.setup() end)
        assert.equals(0, #fake_image.sources)
        assert.equals(0, count_autocmds())
        assert.has_no.errors(function() fire({ buf = 5 }) end)
        assert.same({}, refreshed)
    end)

    it('ignores events whose buffer is unloaded, invalid or missing', function()
        -- The real refresh must tolerate whatever buffer the event names.
        package.loaded[IMAGE] = nil
        package.loaded['nvim_config.markdown'] = nil
        local real_glue = require('nvim_config.markdown')
        real_glue.setup()
        local unloaded = vim.fn.bufadd(vim.fn.tempname())
        assert.is_false(api.nvim_buf_is_loaded(unloaded))
        assert.has_no.errors(function()
            fire({ buf = unloaded })
            fire({ buf = 99999 })
            fire({ buf = -1 })
            fire({})
            fire(nil)
            fire({ buf = 'nope' })
            vim.wait(30, function() return false end)
        end)
        api.nvim_buf_delete(unloaded, { force = true })
        package.loaded[IMAGE] = fake_image
    end)

    it('skips events without a numeric buffer', function()
        glue.setup()
        fire({}); fire(nil); fire({ buf = 'x' })
        assert.same({}, refreshed)
    end)

    it('is safe to call setup twice', function()
        glue.setup()
        local first = count_autocmds()
        glue.setup()
        assert.equals(1, first)
        assert.equals(1, count_autocmds())
        fire({ buf = 5 })
        assert.same({ 5 }, refreshed)
    end)

    describe('deco_langs', function()
        it('is the rendermark default list without coderunner', function()
            package.loaded[CODERUNNER] = nil
            package.preload[CODERUNNER] = function() error('coderunner is not installed') end
            assert.same({ 'plantuml', 'puml', 'uml' }, glue.deco_langs())
        end)

        it('adds renderer match languages once, lowercased, skipping invalid entries', function()
            fake_runner.resolve = function()
                return { renderers = {
                    plantuml = { match = { 'plantuml', 'puml' } },
                    graph = { match = { 'Mermaid', 'dot' } },
                    broken = false,
                } }
            end
            assert.same({ 'plantuml', 'puml', 'uml', 'dot', 'mermaid' }, glue.deco_langs())
        end)
    end)
end)

describe('markdown glue with the real modules', function()
    local root, buf, win, png, store, saved_ui, saved_backend, saved_image, saved_glue, img, notify

    before_each(function()
        saved_ui, saved_backend = vim.ui.img, rawget(_G, '__rendermark_image_backend')
        saved_image, saved_glue = package.loaded[IMAGE], package.loaded['nvim_config.markdown']
        rawset(_G, '__rendermark_image_backend', nil)
        store = {}
        -- Only swap vim.ui.img: the default statusline calls vim.ui.progress_status.
        vim.ui.img = {
            set = function(id, path, opts) store[id] = { path = path, opts = opts } end,
            del = function(id) store[id] = nil end,
            get = function(id) return store[id] end,
        }
        package.loaded[IMAGE] = nil
        package.loaded['nvim_config.markdown'] = nil
        img = require(IMAGE)
        root = H.workspace()
        png = H.write(root .. '/fake.png', PNG)
        buf = H.buffer(root, 'intro\n```dot {#one}\na -> b\n```\noutro\n')
        vim.bo[buf].filetype = 'markdown'
        vim.cmd('new')
        win = api.nvim_get_current_win()
        api.nvim_win_set_buf(win, buf)
        api.nvim_win_set_cursor(win, { 1, 0 })
        notify = vim.notify; vim.notify = function() end
        require(CODERUNNER).setup({ auto_render = false, renderers = {
            fake = { match = { 'dot' }, formats = { 'png' }, input = 'stdin', output = 'stdout', cmd = H.tool('echo', png) },
        } })
    end)

    after_each(function()
        vim.wait(30, function() return false end)
        pcall(api.nvim_del_augroup_by_name, 'nvim_config_markdown')
        require('nvim_config.coderunner.render').cancel_buffer(buf)
        pcall(img.diagram_cleanup_buf, buf)
        pcall(api.nvim_win_close, win, true)
        pcall(api.nvim_buf_delete, buf, { force = true })
        vim.fn.delete(require('nvim_config.coderunner.cache').paths(root).dir, 'rf')
        vim.fn.delete(root, 'rf')
        vim.notify = notify
        vim.ui.img = saved_ui
        rawset(_G, '__rendermark_image_backend', saved_backend)
        package.loaded[IMAGE], package.loaded['nvim_config.markdown'] = saved_image, saved_glue
    end)

    local function collect()
        local result, errors = {}, {}
        img.collect_diagram_images(buf, result, errors)
        return result, errors
    end

    it('turns a coderunner render into a drawn diagram item', function()
        require('nvim_config.markdown').setup()
        assert.equals(0, #(collect())) -- nothing rendered yet; caches the empty answer
        assert.is_true(require(CODERUNNER).request_live(buf, 2))
        H.wait(function()
            local items = require(CODERUNNER).diagrams(buf)
            return items[1] and items[1].status == 'ready'
        end)
        -- The buffer text did not change, so only the event's refresh can drop the cached answer.
        local result, errors = collect()
        assert.equals(0, #errors)
        assert.equals(1, #result)
        assert.equals(1, result[1].row)
        assert.equals(1, vim.fn.filereadable(result[1].path))
        assert.equals(100, result[1].source_width)
        assert.equals(50, result[1].source_height)
        assert.equals(3, result[1].source_span_height)
    end)
end)
