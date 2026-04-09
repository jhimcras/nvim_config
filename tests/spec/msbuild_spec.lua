local msbuild = require('msbuild')

describe('msbuild', function()
    it('should have a builder function', function()
        assert.is_function(msbuild.builder)
    end)
    
    it('should return a table with cmd "msbuild"', function()
        local builder = msbuild.builder('VS2022', 'project.sln', 'Debug', false, 'x64')
        assert.are.equal('msbuild', builder.cmd)
    end)
end)
