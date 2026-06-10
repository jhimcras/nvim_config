-- Browser-like soft-wrap for markdown using virtual lines.
--
-- Instead of Neovim's native `wrap` (which looks unnatural with breakindent and
-- concealed prefix icons), this renders long lines with `wrap = false` and draws
-- the wrapped continuation rows as extmark `virt_lines`, applied only to markdown
-- buffers.
--
-- Hard constraint: the cursor can never enter a virtual line, and with
-- `wrap = false` the cursor's own line scrolls horizontally to follow it. So the
-- active (cursor) line is always shown raw on a single row; every other visible
-- line is decorated as soft-wrapped. See docs/known limitations in the plan.

local M = {}

local defaults = {
    markdown = true,
    left_pad = 2,        -- left reading margin (columns), via 'statuscolumn'
    right_pad = 2,       -- right reading margin (columns)
    max_width = nil,     -- cap the text column at this width; the window width is
                         -- used instead when it is narrower (nil = no cap)
    min_text_width = 20, -- don't wrap when the text column is narrower than this
    hl = nil,            -- highlight group for continuation rows (nil = default)
}

local config = vim.deepcopy(defaults)
local ns = vim.api.nvim_create_namespace('markdown_visual_wrap')
local group
local saved_state = {} -- per-window saved options, keyed by window id

-- List marker, including an optional task checkbox: "- ", "* ", "+ ", "1.", "12)",
-- "  - nested", "- [ ] task", etc.
local list_pat = [[^\s*\%(\d\+[.)]\|[-*+]\)\s\+\%(\[.\]\s\+\)\?]]

local function dw(s)
    return vim.fn.strdisplaywidth(s)
end

local code_query -- lazily compiled treesitter query for markdown code blocks
local function get_code_query()
    if code_query == nil then
        local ok, q = pcall(vim.treesitter.query.parse, 'markdown',
            '[(fenced_code_block) (indented_code_block)] @cb')
        code_query = ok and q or false
    end
    return code_query or nil
end

-- Continuation indent (display columns) for a logical line, so wrapped rows hang
-- under the line's text the way a browser renders it.
function M.compute_indent(text)
    local marker = vim.fn.matchstr(text, list_pat)
    if marker ~= '' then
        return dw(marker)
    end
    local quote = text:match('^%s*>[%s>]*')
    if quote then
        return dw(quote)
    end
    return dw(text:match('^%s*') or '')
end

local function slice_concat(t, a, b)
    local r = {}
    for k = a, b do
        r[#r + 1] = t[k]
    end
    return table.concat(r)
end

-- Pure wrap computation. Given a line and the available widths, returns:
--   first_end_byte : 0-based byte offset where the first display row ends, i.e.
--                    where the real line should be concealed (nil if it fits).
--   lines          : continuation rows (strings, already indented) for virt_lines.
-- Breaks at spaces when possible, otherwise per-character (handles CJK / long words).
function M.wrap_line(text, width1, widthN, indent)
    local chars = vim.fn.split(text, '\\zs')
    if #chars == 0 then
        return { first_end_byte = nil, lines = {} }
    end

    -- byte offset (0-based) of the start of each char; byte_at[#chars+1] = #text
    local byte_at = {}
    local acc = 0
    for i, c in ipairs(chars) do
        byte_at[i] = acc
        acc = acc + #c
    end
    byte_at[#chars + 1] = acc

    local indent_str = string.rep(' ', indent)
    local lines = {}
    local first_end_byte = nil

    local line_no = 1
    local line_start = 1   -- char index where the current display row starts
    local cur_w = 0
    local last_space = nil -- char index of the last space seen on the current row

    local function budget()
        return line_no == 1 and width1 or widthN
    end

    local function emit(stop_exclusive)
        if line_no == 1 then
            first_end_byte = byte_at[stop_exclusive]
        else
            local s = slice_concat(chars, line_start, stop_exclusive - 1):gsub('%s+$', '')
            lines[#lines + 1] = indent_str .. s
        end
    end

    local i = 1
    while i <= #chars do
        local c = chars[i]
        local cw = dw(c)
        -- A space is a break opportunity: the content before it already fits, so
        -- record it before the overflow check (handles a space landing exactly at
        -- the budget boundary).
        if c:match('%s') then
            last_space = i
        end
        if cur_w + cw > budget() and i > line_start then
            local stop, next_start
            if last_space and last_space >= line_start then
                stop = last_space        -- end row before the space (space dropped)
                next_start = last_space + 1
                while next_start <= #chars and chars[next_start]:match('%s') do
                    next_start = next_start + 1
                end
            else
                stop = i                 -- hard break (CJK / over-long word)
                next_start = i
            end
            emit(stop)
            line_no = line_no + 1
            line_start = next_start
            last_space = nil
            cur_w = 0
            i = next_start
        else
            cur_w = cur_w + cw
            i = i + 1
        end
    end

    if line_no > 1 then
        local s = slice_concat(chars, line_start, #chars):gsub('%s+$', '')
        lines[#lines + 1] = indent_str .. s
    end

    return { first_end_byte = first_end_byte, lines = lines }
end

local function is_markdown_buffer(buf)
    local ft = vim.bo[buf or 0].filetype
    return ft == 'markdown' or ft == 'markdown.mdx'
end

local function buffer_enabled(buf)
    return vim.g.markdown_visual_wrap_enabled ~= false and vim.b[buf].markdown_visual_wrap == true
end

function M.refresh(win)
    if not win or win == 0 then
        win = vim.api.nvim_get_current_win()
    end
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if not buffer_enabled(buf) then
        return
    end

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    -- Horizontal scroll (leftcol) is window-global, so it slides every line's real
    -- text, which we can't counter-compensate per line. Treat any horizontal scroll
    -- as "show raw text": with the namespace just cleared, bail out so all lines
    -- scroll uniformly. Decorations are restored on the next refresh once leftcol
    -- returns to 0.
    local leftcol = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
    end)
    if leftcol > 0 then
        return
    end

    local info = vim.fn.getwininfo(win)[1]
    local width = vim.api.nvim_win_get_width(win) - info.textoff - config.right_pad
    -- A user-set max_width takes priority, but only as a cap: a narrower window
    -- still wraps at the window width.
    if config.max_width and config.max_width > 0 then
        width = math.min(width, config.max_width)
    end
    if width < config.min_text_width then
        return
    end

    local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
    local first = math.max(info.topline - 1, 0)
    local last = info.botline
    local hl_chunk = function(s)
        return config.hl and { s, config.hl } or { s }
    end

    -- Code blocks are read verbatim, so exempt their lines from wrapping. Detect
    -- them with treesitter over the visible range only (the parser is cached).
    local in_code = {}
    local ts_ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    local query = get_code_query()
    if ts_ok and parser and query then
        local tree = parser:parse({ first, last })[1]
        if tree then
            for _, node in query:iter_captures(tree:root(), buf, first, last) do
                local r1, _, r2, c2 = node:range()
                if c2 == 0 then r2 = r2 - 1 end -- node ends at start of r2: exclude r2
                for l = r1, r2 do
                    in_code[l] = true
                end
            end
        end
    end

    for lnum = first, last - 1 do
        if lnum + 1 ~= cursor_row and not in_code[lnum] then
            local text = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
            if text and #text > 0 then
                local indent = M.compute_indent(text)
                local r = M.wrap_line(text, width, width - indent, indent)
                if r.first_end_byte then
                    vim.api.nvim_buf_set_extmark(buf, ns, lnum, r.first_end_byte, {
                        end_col = #text,
                        conceal = '',
                    })
                    local vlines = {}
                    for _, s in ipairs(r.lines) do
                        vlines[#vlines + 1] = { hl_chunk(s) }
                    end
                    vim.api.nvim_buf_set_extmark(buf, ns, lnum, 0, { virt_lines = vlines })
                end
            end
        end
    end
end

local pending = {}
local function schedule_refresh(win)
    if not win or win == 0 then
        win = vim.api.nvim_get_current_win()
    end
    if pending[win] then
        return
    end
    pending[win] = true
    vim.schedule(function()
        pending[win] = nil
        M.refresh(win)
    end)
end

function M.apply(win)
    win = win or 0
    local w = win == 0 and vim.api.nvim_get_current_win() or win
    local buf = vim.api.nvim_win_get_buf(w)

    if saved_state[w] == nil then
        saved_state[w] = {
            wrap = vim.wo[w].wrap,
            statuscolumn = vim.wo[w].statuscolumn,
            conceallevel = vim.wo[w].conceallevel,
        }
    end

    vim.b[buf].markdown_visual_wrap = true
    vim.wo[w].wrap = false
    vim.wo[w].linebreak = false
    vim.wo[w].breakindent = false
    if config.left_pad > 0 then
        vim.wo[w].statuscolumn = string.rep(' ', config.left_pad)
    end
    if vim.wo[w].conceallevel < 2 then
        vim.wo[w].conceallevel = 2
    end

    schedule_refresh(w)
end

function M.disable(win)
    win = win or 0
    local w = win == 0 and vim.api.nvim_get_current_win() or win
    local buf = vim.api.nvim_win_get_buf(w)

    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.b[buf].markdown_visual_wrap = false

    local saved = saved_state[w]
    if saved then
        vim.wo[w].wrap = saved.wrap
        vim.wo[w].statuscolumn = saved.statuscolumn
        vim.wo[w].conceallevel = saved.conceallevel
        saved_state[w] = nil
    end
end

function M.toggle()
    if vim.b.markdown_visual_wrap then
        M.disable(0)
    else
        M.apply(0)
    end
end

local function apply_current_window()
    if vim.g.markdown_visual_wrap_enabled == false then
        return
    end
    if is_markdown_buffer(0) then
        M.apply(0)
    end
end

function M.setup(opts)
    config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
    vim.g.markdown_visual_wrap_enabled = config.markdown

    group = vim.api.nvim_create_augroup('markdown_visual_wrap', { clear = true })

    vim.api.nvim_create_user_command('MarkdownWrapToggle', function()
        if vim.g.markdown_visual_wrap_enabled == false then
            vim.g.markdown_visual_wrap_enabled = true
            if is_markdown_buffer(0) then
                M.apply(0)
            end
        else
            vim.g.markdown_visual_wrap_enabled = false
            M.disable(0)
        end
    end, {})

    if not config.markdown then
        return
    end

    vim.api.nvim_create_autocmd('FileType', {
        group = group,
        pattern = { 'markdown', 'markdown.mdx' },
        callback = apply_current_window,
    })

    vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
        group = group,
        callback = apply_current_window,
    })

    vim.api.nvim_create_autocmd({
        'WinScrolled', 'WinResized', 'VimResized',
        'TextChanged', 'TextChangedI',
        'CursorMoved', 'CursorMovedI',
        'InsertEnter', 'InsertLeave',
    }, {
        group = group,
        callback = function()
            if buffer_enabled(vim.api.nvim_get_current_buf()) then
                schedule_refresh(0)
            end
        end,
    })
end

return M
