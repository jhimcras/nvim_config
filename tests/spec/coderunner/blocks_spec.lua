local B = require('nvim_config.coderunner.blocks')
local H = require('tests.spec.coderunner.helpers')
local function parse(s) return assert(B.parse(s, { path = '/work/notes/a.md', root = '/work' })) end
local function fence(info, code) return '```' .. info .. '\n' .. (code or 'x\n') .. '```\n' end

describe('coderunner blocks', function()
    it('parses Pandoc attributes, first ID and implicit class language', function()
        local b = parse(fence('mermaid {#arch #second .wide width=300 title="두 단어"}'))[1]
        assert.equals('mermaid', b.lang)
        assert.equals('arch', b.id)
        assert.same({ 'wide' }, b.classes)
        assert.same({ width = '300', title = '두 단어' }, b.attrs)
        b = parse(fence('{.dot #g}'))[1]
        assert.equals('dot', b.lang)
        assert.equals('g', b.id)
        for _, info in ipairs({ 'python {broken', 'python {#id bad}', 'python {x="unfinished}',
            'python {x="ok"bad}', 'python {x=}', 'python {#id} junk' }) do
            b = parse(fence(info))[1]
            assert.equals('python', b.lang)
            assert.is_nil(b.id)
            assert.same({}, b.attrs)
        end
    end)

    it('matches original facts code ranges and normalized hashes across containers', function()
        local sources = {
            '> ```py\r\n> x\r\n>   y\r\n> ```\r\n',
            '```py\nx\n  y\n```\n',
            '- a\n\n  ```py\n  x\n    y\n  ```\n',
            '  ```py\n  x\n    y\n  ```\n',
            '> - a\n>\n>   ```py\n>   x\n>     y\n>   ```\n',
        }
        for _, source in ipairs(sources) do
            local b = parse(source)[1]
            assert.equals('x\n  y\n', b.code, source)
            assert.equals(vim.fn.sha256('x\n  y\n'), b.hash)
            assert.is_true(b.closed)
        end
        assert.same({ 1, 0, 3, 0 }, parse(sources[1])[1].content_range)
        assert.is_not.equal(parse(sources[1])[1].hash, parse(fence('py', '  x\n  y\n'))[1].hash)
    end)

    it('keeps output ordinals separate and flags all duplicate IDs', function()
        local b = parse(fence('python') .. fence('output') .. fence('python') .. fence('output')
            .. fence('python') .. fence('js {#calc}') .. fence('js {#calc}') .. fence(''))
        assert.equals('notes/a.md:python:1', b[1].key)
        assert.equals('notes/a.md:output:1', b[2].key)
        assert.equals('notes/a.md:python:2', b[3].key)
        assert.equals('notes/a.md:output:2', b[4].key)
        assert.equals('notes/a.md:python:3', b[5].key)
        assert.equals('notes/a.md#calc', b[6].key)
        assert.is_true(b[6].duplicate)
        assert.is_true(b[7].duplicate)
        assert.is_nil(b[8].key)
    end)

    it('associates output only across zero or one blank lines in the same container', function()
        for n = 0, 2 do
            local b = parse(fence('py') .. string.rep('\n', n) .. fence('output {.error}') .. fence('output'))
            if n < 2 then assert.equals(b[2], b[1].output) else assert.is_nil(b[1].output) end
            assert.is_nil(b[2].output)
        end
        local b = parse(fence('py') .. '> ```output\n> x\n> ```\n')
        assert.is_nil(b[1].output)
        b = parse('> ```py\n> x\n> ```\n>\n> ```output\n> x\n> ```\n')
        assert.equals(b[2], b[1].output)
        b = parse('- ```py\n  x\n  ```\n- ```output\n  x\n  ```\n')
        assert.is_nil(b[1].output)
    end)

    it('finds ordered markdown, wiki and HTML image candidates in the next paragraph', function()
        for n = 0, 2 do
            local b = parse(fence('dot') .. string.rep('\n', n)
                .. '![a](assets/a.svg) ![[b.png|alt]] <img src="assets/c.png">\n')
            if n < 2 then
                assert.equals(3, #b[1].images)
                assert.equals('assets/a.svg', b[1].images[1].target)
                assert.equals('b.png', b[1].images[2].target)
                assert.equals('assets/c.png', b[1].images[3].target)
                assert.equals(3 + n, b[1].images[1].row)
            else assert.same({}, b[1].images) end
        end
    end)

    it('handles HTML blocks, escaped destinations, code spans and containers', function()
        local b = parse(fence('dot') .. '<img src="a&amp;b.svg">\n')[1]
        assert.equals('a&b.svg', b.images[1].target)
        b = parse(fence('dot') .. '`![[fake.png]]` \\![[escaped.png]] ![a](<sp ace.png>) ![b](a\\(b\\).png)\n')[1]
        assert.equals(2, #b.images)
        assert.equals('sp ace.png', b.images[1].target)
        assert.equals('a(b).png', b.images[2].target)
        b = parse('> ```dot\n> x\n> ```\n>\n> ![[a.png]]\n')[1]
        assert.equals('a.png', b.images[1].target)
        assert.equals('> ', b.close_prefix)
        assert.is_false(b.top_level)
        assert.same({}, parse(fence('dot') .. '# ![[heading.png]]\n')[1].images)
        assert.same({}, parse(fence('output') .. '![[a.png]]\n')[1].images)
    end)

    it('preserves fence coordinates and handles empty, long, tilde and unclosed fences', function()
        local b = parse('~~~py\nx\n~~~\n')[1]
        assert.equals('x\n', b.code)
        assert.same({ 0, 0, 0, 3 }, b.open_range)
        assert.same({ 2, 0, 2, 3 }, b.close_range)
        assert.is_true(b.top_level)
        b = parse('````py\n```\n````\n')[1]
        assert.equals('```\n', b.code)
        assert.equals('', parse('```\n```\n')[1].code)
        b = parse('```py\nunclosed')[1]
        assert.equals('unclosed', b.code)
        assert.is_false(b.closed)
        assert.is_nil(b.close_range)
        assert.equals('unclosed\n', parse('```py\nunclosed\n')[1].code)
        assert.equals(0, #parse('```py`bad\nx\n'))
        assert.equals(1, #parse('~~~py`ok\nx\n~~~\n'))
    end)

    it('matches original facts.rs output/image fixture associations', function()
        local f = assert(io.open('tests/fixtures/coderunner/blocks.md', 'rb'))
        local b = parse(f:read('*a')); f:close()
        assert.equals(b[2], b[1].output)
        assert.equals(b[4], b[3].output)
        assert.is_nil(b[5].output)
        assert.is_nil(b[7].output)
        assert.is_nil(b[11].output)
        assert.equals('assets/calc.svg', b[8].images[1].target)
        assert.equals('calc.png', b[8].images[2].target)
        assert.equals('assets/m.svg', b[9].images[1].target)
        assert.same({}, b[10].images)
    end)

    it('recognizes a closing fence at EOF without adding bytes to unclosed code', function()
        for _, source in ipairs({ '```py\nx\n```', '~~~py\nx\n~~~',
            '> ```py\n> x\n> ```', '```py\r\nx\r\n```' }) do
            local b = parse(source)[1]
            assert.is_true(b.closed, source)
            assert.equals('x\n', b.code)
            assert.equals(2, b.close_range[1])
        end
        assert.equals('unfinished', parse('```py\nunfinished')[1].code)
        assert.equals('unfinished\n', parse('```py\nunfinished\n')[1].code)
        assert.is_false(parse('````py\nx\n```')[1].closed)
    end)

    it('invalidates cached unclosed code when only endofline changes', function()
        local root = H.workspace()
        local buf = H.buffer(root, '```py\nunfinished')
        vim.bo[buf].endofline = false
        assert.equals('unfinished', B.get(buf, root)[1].code)
        vim.bo[buf].endofline = true
        assert.equals('unfinished\n', B.get(buf, root)[1].code)
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.fn.delete(root, 'rf')
    end)

    it('handles multiline HTML and ignores comment images', function()
        local b = parse(fence('dot') .. '<img\n src="assets/a.svg">\n')[1]
        assert.equals('assets/a.svg', b.images[1].target)
        b = parse(fence('dot') .. '<!-- <img src="fake.svg"> -->\n')[1]
        assert.same({}, b.images)
    end)

    it('caches buffer parsing by changedtick, root and path', function()
        local root = H.workspace()
        local buf = H.buffer(root, fence('py'))
        local a = B.get(buf, root)
        assert.equals(a, B.get(buf, root))
        vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'changed' })
        local b = B.get(buf, root)
        assert.is_not.equal(a, b)
        assert.equals('changed\n', b[1].code)
        assert.equals('note.md:py:1', b[1].key)
        assert.is_not.equal(b, B.get(buf, root .. '/other'))
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.fn.delete(root, 'rf')
    end)

    it('returns an explicit error when markdown parser is unavailable', function()
        local original = vim.treesitter.get_string_parser
        vim.treesitter.get_string_parser = function() error('missing parser') end
        local blocks, err = B.parse(fence('py'))
        vim.treesitter.get_string_parser = original
        assert.is_nil(blocks)
        assert.is_truthy(err:find('markdown parser unavailable', 1, true))
    end)
end)
