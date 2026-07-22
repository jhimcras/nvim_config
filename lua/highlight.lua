local ut = require 'util'

local M = {}

local statusline_highlights = {
    StatuslineGeneralActive = {
        [1] = {
            n = { bg = '#1F2937', fg = '#9CA3AF' },
            i = { bg = '#1F2937', fg = '#98BC99' },
            v = { bg = '#1F2937', fg = '#FBC19D' },
            c = { bg = '#1F2937', fg = '#99BBBD' },
            r = { bg = '#1F2937', fg = '#E8D4B0' },
        },
        [2] = {
            n = { bg = '#334155', fg = '#D1D5DB' },
            i = { bg = '#98BC99', fg = '#111827' },
            v = { bg = '#FBC19D', fg = '#111827' },
            c = { bg = '#99BBBD', fg = '#111827' },
            r = { bg = '#E8D4B0', fg = '#111827' },
        },
    },
    StatuslineGeneralInactive = { bg = '#1F2937', fg = '#6B7280' },
    StatuslineQuickfix = {
        [1] = { link = 'StatuslineGeneralActive_1' },
        [2] = { link = 'StatuslineGeneralActive_2' },
    },
    StatuslineTermActive = {
        [1] = {
            n = { link = 'StatuslineGeneralActive_1_n' },
            t = { link = 'StatuslineGeneralActive_1_i' },
        }
    },
    StatuslineTermInactive = { link = 'StatuslineGeneralInactive' },
    StatuslineTag1 = { fg = '#1e1e2e', bg = '#89b4fa' },
    StatuslineTag2 = { fg = '#1e1e2e', bg = '#a6e3a1' },
    StatuslineTag3 = { fg = '#1e1e2e', bg = '#fab387' },
    StatuslineTag4 = { fg = '#1e1e2e', bg = '#cba6f7' },
    StatuslineTag5 = { fg = '#1e1e2e', bg = '#f38ba8' },
    StatuslineSearch_1 = { bg = '#1F2937', fg = '#0284c7' },
    StatuslineSearch_2 = { bg = '#0c4a6e', fg = '#7dd3fc' },
}

function M.setup()
    ut.set_highlight('QuickFixLine', { gui='underline' })

    ut.set_highlight('RenderMarkdownH1Bg', { guibg='#3B2C3C' })
    ut.set_highlight('RenderMarkdownH2Bg', { guibg='#3A352C' })
    ut.set_highlight('RenderMarkdownH3Bg', { guibg='#1F343D' })
    ut.set_highlight('RenderMarkdownH4Bg', { guibg='#28304D' })
    ut.set_highlight('RenderMarkdownH5Bg', { guibg='#32313A' })
    ut.set_highlight('@markup.heading.1.markdown', { guifg='#FECDD3' })
    ut.set_highlight('@markup.heading.2.markdown', { guifg='#E8D4B0' })
    ut.set_highlight('@markup.heading.3.markdown', { guifg='#B5E8B0' })
    ut.set_highlight('@markup.heading.4.markdown', { guifg='#A5B4FC' })
    ut.set_highlight('@markup.heading.5.markdown', { guifg='#DDD6FE' })

    ut.set_highlight('TabLineSel', {gui = 'bold,italic'})
    ut.set_highlight('TabLineImeHangul', { guibg = '#a6e3a1', guifg = '#1e1e2e', gui = 'bold' })
    ut.set_highlight('TabLineImeEng',    { guibg = '#45475a', guifg = '#cdd6f4' })

    vim.api.nvim_set_hl(0, 'AnsiBlack',   { fg = '#000000', bold = true })
    vim.api.nvim_set_hl(0, 'AnsiRed',     { fg = '#ff5555' })
    vim.api.nvim_set_hl(0, 'AnsiGreen',   { fg = '#50fa7b' })
    vim.api.nvim_set_hl(0, 'AnsiYellow',  { fg = '#f1fa8c' })
    vim.api.nvim_set_hl(0, 'AnsiBlue',    { fg = '#8be9fd' })
    vim.api.nvim_set_hl(0, 'AnsiMagenta', { fg = '#ff79c6' })
    vim.api.nvim_set_hl(0, 'AnsiCyan',    { fg = '#8be9fd' })
    vim.api.nvim_set_hl(0, 'AnsiWhite',   { fg = '#f8f8f2' })

    ut.set_highlights(statusline_highlights)
end

return M
