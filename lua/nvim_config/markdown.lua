-- Glue between rendermark.image (draws) and coderunner (renders). Neither
-- module requires the other; this file is the only place they meet. Without
-- coderunner no diagram source is registered and rendermark draws only
-- Markdown images.
local M = {}

-- rendermark's own default (deco.lua); a user list replaces it, so it is merged here.
local default_deco_langs = { 'plantuml', 'puml', 'uml' }

-- Fence languages rendermark must not decorate as code blocks: its defaults plus
-- every renderer `match` coderunner currently knows (global config and a loaded
-- workspace config for the cwd). Pass the result as `diagram.disable_deco_langs`
-- to rendermark.setup; deco reads the list once, at setup.
function M.deco_langs()
    local langs, seen = {}, {}
    local function add(lang)
        lang = lang:lower()
        if not seen[lang] then seen[lang] = true; langs[#langs + 1] = lang end
    end
    for _, lang in ipairs(default_deco_langs) do add(lang) end
    local ok, runner = pcall(require, 'nvim_config.coderunner')
    if ok and type(runner.resolve) == 'function' then
        local extra = {}
        for _, entry in pairs(runner.resolve(vim.fn.getcwd(), false).renderers) do
            for _, lang in ipairs(entry and entry.match or {}) do extra[#extra + 1] = lang:lower() end
        end
        table.sort(extra)
        for _, lang in ipairs(extra) do add(lang) end
    end
    return langs
end

function M.setup()
    local group = vim.api.nvim_create_augroup('nvim_config_markdown', { clear = true })
    local ok, runner = pcall(require, 'nvim_config.coderunner')
    if not ok then return end
    local image = require('nvim_config.rendermark.image')
    image.set_diagram_source({
        items = function(buf) return runner.diagrams(buf) end,
        request_live = function(buf, row) return runner.request_live(buf, row) end,
    })
    vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'CodeRunnerDiagrams',
        callback = function(args)
            local buf = args.data and args.data.buf
            if type(buf) == 'number' then image.refresh(buf) end
        end,
    })
end

return M
