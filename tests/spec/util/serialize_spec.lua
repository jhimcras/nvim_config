local serialize = require('nvim_config.util.serialize')

describe('util/serialize.lua persisted Lua data', function()
    it('round-trips nested session data with quotes, newlines, UTF-8 and sparse numeric keys', function()
        local data = {
            title = '한글 "quoted" \\ path\nnext line',
            items = { [1] = { lnum = 3, col = 2, valid = true }, [4] = false },
            empty = {}, status = 'terminated',
        }
        local chunk = assert(loadstring('return ' .. serialize.serialize(data)))
        assert.are.same(data, chunk())
    end)

    it('keeps the existing element when equality matches only its identity field', function()
        local original = { id = 1, text = 'original' }
        local items = { original }
        local eq = function(a, b) return a.id == b.id end
        assert.is_false(serialize.insert_unique_by(items, { id = 1, text = 'replacement' }, eq))
        assert.is_true(serialize.insert_unique_by(items, { id = 2, text = 'new' }, eq))
        assert.are.equal(original, items[1])
        assert.are.equal(2, #items)
    end)

    it('normalizes Windows paths without losing drives, UNC prefixes or Unicode', function()
        assert.are.equal('C:/한글/file.md', serialize.normalize_path_separator('C:\\한글\\file.md', true))
        assert.are.equal('//server/share/file', serialize.normalize_path_separator('\\\\server\\share\\file', false))
    end)
end)
