local text = require('nvim_config.rendermark.wrap.text')

describe('rendermark/wrap/text.lua display and byte coordinates', function()
    it('wraps Korean glyphs by display width but reports UTF-8 byte spans', function()
        assert.are.same({ first_end_byte = 6, lines = { '  다라', '  마' },
            spans = { { 6, 12 }, { 12, 15 } } }, text.wrap_line('가나다라마', 4, 4, 2))
    end)

    it('breaks at spaces and applies a separate continuation width', function()
        assert.are.same({ first_end_byte = 3, lines = { '  two', '  three' },
            spans = { { 4, 7 }, { 8, 13 } } }, text.wrap_line('one two three', 5, 5, 2))
    end)

    it('does not add virtual rows for an empty line or a line that fits', function()
        local unwrapped = { lines = {}, spans = {} }
        assert.are.same(unwrapped, text.wrap_line('', 10, 10, 0))
        assert.are.same(unwrapped, text.wrap_line('hello', 5, 5, 0))
    end)

    it('uses rendered checkbox and heading widths for hanging indents', function()
        assert.are.equal(8, text.compute_indent('  - [ ] task'))
        assert.are.equal(5, text.compute_indent('  - [ ] task', { checkbox = 3 }))
        assert.are.equal(6, text.compute_indent('  ### title', { heading = 2 }))
        assert.are.equal(4, text.compute_indent('> > quote'))
    end)

    it('stacks overlapping highlights in priority and sequence order', function()
        local runs = text.flatten_runs({
            { s = 0, e = 4, hl = 'Bold', priority = 100, seq = 2 },
            { s = 1, e = 3, hl = 'Link', priority = 200 },
            { s = -1, e = 9, hl = 'Base', priority = 100, seq = 1 },
        }, 4)
        assert.are.same({
            { s = 0, e = 1, hl = { 'Base', 'Bold' } },
            { s = 1, e = 3, hl = { 'Base', 'Bold', 'Link' } },
            { s = 3, e = 4, hl = { 'Base', 'Bold' } },
        }, runs)
    end)

    it('emits a concealed replacement once even when its range is split by a highlight', function()
        local runs = text.flatten_runs({
            { s = 0, e = 4, conceal = '✓', hl = 'Check' },
            { s = 2, e = 3, hl = 'Overlay', priority = 200 },
        }, 5)
        local out = {}
        text.slice_chunks(out, '[x] !', runs, 0, 5, 'Base')
        assert.are.same({ { '✓', { 'Base', 'Check' } }, { '!', { 'Base' } } }, out)
    end)

    it('keeps character indices while accounting for hidden text and inserted virtual widths', function()
        local runs = text.flatten_runs({ { s = 0, e = 3, conceal = '✓' } }, 4)
        assert.are.same({ { w = 1, sp = false }, { w = 0, sp = false },
            { w = 0, sp = false }, { w = 3, sp = false } },
            text.conceal_items({ '[', 'x', ']', 'a' }, { 0, 1, 2, 3 }, runs, { { b = 3, w = 2 } }))
    end)
end)
