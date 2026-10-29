vim.loader.enable()

----------------------------------------------------------------------------------------------------
require'nvim_config.setting'.setup()
require'nvim_config.plugins'.setup()
require'nvim_config.prjroot'.setup()
require'nvim_config.launcher'.setup()
require'nvim_config.qflist.tag'.setup()
require'nvim_config.qflist.filter'.setup()
require'nvim_config.qflist.edit'.setup()
require'nvim_config.grep'.setup()
require'nvim_config.json'.setup()
require'nvim_config.session'.setup()
require'nvim_config.status'.setup()
require'nvim_config.tabline'.setup()
require'nvim_config.file_info'.setup()
require'nvim_config.smart_cursorline'.setup()
require'nvim_config.read_mode'.setup()
require'nvim_config.reopen'.setup()
vim.g.mdloom_dir = '~/workspace/markdown_lsp' -- mdloom development checkout (plugin + fallback binary).
require'nvim_config.lsp'.setup()
-- Same lookup rendermark used before diagrams moved to coderunner: an explicit jar
-- run through `java`, else the `plantuml` wrapper on PATH.
local function plantuml_cmd()
    local jar = vim.g.rendermark_plantuml_jar or vim.env.RENDERMARK_PLANTUML_JAR or vim.env.PLANTUML_JAR
    jar = jar and vim.fn.fnamemodify(vim.fn.expand(jar), ':p')
    if jar and vim.fn.filereadable(jar) == 1 and vim.fn.executable('java') == 1 then
        return { 'java', '-jar', jar, '-t{format}', '-pipe' }
    end
    return { 'plantuml', '-t{format}', '-pipe' }
end
require'nvim_config.coderunner'.setup{
    diagnostics = false, -- mdloom coexistence; enable after migration.
    render_on_open = true, -- global renderers only; cache misses in the visible window.
    runners = {
        python = { match = { 'python', 'py' }, ext = 'py', cmd = { 'python3', '{file}' } },
    },
    renderers = {
        plantuml = { match = { 'plantuml', 'puml' }, formats = { 'png', 'svg' },
            input = 'stdin', output = 'stdout', cmd = plantuml_cmd() },
    },
}
require'nvim_config.rendermark'.setup{
    max_width = 120,
    diagram = {
        -- Fence languages drawn as images: rendermark's defaults plus coderunner renderer matches.
        disable_deco_langs = require'nvim_config.markdown'.deco_langs(),
        preview = {
            mode = 'split',            -- 'float' | 'split'
            auto = true,               -- open when the cursor enters a block
            split = {
                -- position follows the window aspect: landscape -> right, portrait -> bottom
                size      = 0.20,         -- 'half' | fraction (<1) | absolute cells (>=1)
                lifecycle = 'cursor',    -- 'cursor' | 'persistent'
            },
        },
    },
}
require'nvim_config.markdown'.setup() -- after rendermark and coderunner: connects them.
require'nvim_config.keymap'.setup()
require'nvim_config.instance.move'.setup()
require'nvim_config.highlight'.setup()
