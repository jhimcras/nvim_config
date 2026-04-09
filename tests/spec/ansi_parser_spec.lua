local ansi_parser = require('ansi_parser')

describe('ansi_parser', function()
    it('should parse simple ANSI colors', function()
        local text = "\27[31mRed Text\27[0m"
        local cleaned, highlights = ansi_parser.parse_ansi(text)
        assert.are.equal("Red Text", cleaned)
        assert.are.same({{0, 8, 'AnsiRed'}}, highlights)
    end)

    it('should parse multiple colors', function()
        local text = "\27[31mRed\27[32mGreen"
        local cleaned, highlights = ansi_parser.parse_ansi(text)
        assert.are.equal("RedGreen", cleaned)
        assert.are.same({{0, 3, 'AnsiRed'}, {3, 8, 'AnsiGreen'}}, highlights)
    end)

    it('should handle complex ANSI sequences', function()
        local text = "\27[1;34mBlue Bold\27[0m"
        local cleaned, highlights = ansi_parser.parse_ansi(text)
        assert.are.equal("Blue Bold", cleaned)
        assert.are.same({{0, 9, 'AnsiBlue'}}, highlights)
    end)
end)
