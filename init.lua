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
require'nvim_config.coderunner'.setup{
    diagnostics = false, -- mdloom coexistence; enable after migration.
    render_on_open = true, -- global renderers only; cache misses in the visible window.
    runners = {
        python = { match = { 'python', 'py' }, ext = 'py', cmd = { 'python3', '{file}' } },
    },
    renderers = {
        plantuml = { match = { 'plantuml', 'puml' }, formats = { 'png', 'svg' },
            input = 'stdin', output = 'stdout', cmd = { 'plantuml', '-t{format}', '-pipe' } },
    },
}
require'nvim_config.rendermark'.setup{
    max_width = 120,
    plantuml = {
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
require'nvim_config.keymap'.setup()
require'nvim_config.instance.move'.setup()
require'nvim_config.highlight'.setup()
