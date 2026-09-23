-- Small HTML subset used in Markdown. Details visibility is kept in extmarks so
-- an opened block stays opened when lines are inserted above it.
local M = {}

local ns = vim.api.nvim_create_namespace('rendermark_html')
local state_ns = vim.api.nvim_create_namespace('rendermark_html_state')
local buffers = {}
local styles = {
    mark = 'RendermarkHtmlMark',
    u = 'RendermarkHtmlUnderline',
    s = 'RendermarkHtmlStrike',
    del = 'RendermarkHtmlStrike',
}

local function put(buf, row, col, opts)
    vim.api.nvim_buf_set_extmark(buf, ns, row, col, opts)
end

local function source_rows(buf)
    local skip, tables = {}, {}
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
    if ok and parser then
        local ok_query, query = pcall(vim.treesitter.query.parse, 'markdown',
            '[(fenced_code_block) (indented_code_block)] @code (pipe_table) @table')
        local trees = parser:parse()
        if ok_query and trees and trees[1] then
            for id, node in query:iter_captures(trees[1]:root(), buf) do
                local first, _, last, col = node:range()
                if col == 0 then last = last - 1 end
                if query.captures[id] == 'code' then
                    for row = first, last do skip[row] = true end
                else
                    local lines = vim.api.nvim_buf_get_lines(buf, first, last + 1, false)
                    local finish = first + 1
                    for i = 3, #lines do
                        if not lines[i]:find('|', 1, true) then break end
                        finish = first + i - 1
                    end
                    for row = first, finish do tables[row] = true end
                end
            end
        end
    end
    -- The Markdown grammar treats a fenced block inside <details> as raw HTML,
    -- so its code node is absent. Recognize those fences from their source lines.
    local fence
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local run = line:match('^%s*([`~]+)')
        if fence then
            skip[i - 1] = true
            if run and run:sub(1, 1) == fence.char and #run >= fence.len
                and run:match('^' .. fence.char .. '+$')
                and line:match('^%s*' .. fence.char .. '+%s*$') then
                fence = nil
            end
        elseif run and #run >= 3 and run:match('^' .. run:sub(1, 1) .. '+$') then
            fence = { char = run:sub(1, 1), len = #run }
            skip[i - 1] = true
        end
    end
    return skip, tables
end

local function scan(buf, old)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local skip, tables = source_rows(buf)
    local blocks, stack = {}, {}
    for i, line in ipairs(lines) do
        local row = i - 1
        if not skip[row] then
            local open = line:match('^%s*<details%s*([^>]*)>%s*$')
            if open then
                local prior = old[row]
                local block = {
                    first = row, summary = nil, last = nil,
                    expanded = prior,
                }
                if prior == nil then block.expanded = open:match('%f[%a]open%f[%A]') ~= nil end
                blocks[#blocks + 1] = block
                stack[#stack + 1] = block
            elseif line:match('^%s*</details%s*>%s*$') and #stack > 0 then
                local block = table.remove(stack)
                block.last = row
            elseif #stack > 0 and not stack[#stack].summary then
                local summary = line:match('^%s*<summary[^>]*>(.-)</summary%s*>%s*$')
                if summary then stack[#stack].summary = summary end
            end
        end
    end
    local complete = {}
    for _, block in ipairs(blocks) do
        if block.last then complete[#complete + 1] = block end
    end
    return lines, skip, tables, complete
end

local function prior_state(buf, records)
    local old = {}
    for _, block in ipairs(records or {}) do
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, state_ns, block.id, {})
        if #pos > 0 then old[pos[1]] = block.expanded end
    end
    return old
end

local function draw_inline(buf, row, line, in_table)
    local active = {}
    local from = 1
    local first_br, last_br
    local table_breaks = {}
    local code = {}
    local opening
    for pos, ticks in line:gmatch('()(`+)') do
        if opening and #ticks == opening.len then
            code[#code + 1] = { opening.pos, pos + #ticks - 1 }
            opening = nil
        elseif not opening then
            opening = { pos = pos, len = #ticks }
        end
    end
    while true do
        local s, e, slash, tag = line:find('<(/?)([%a]+)[^>]*>', from)
        if not s then break end
        local literal = false
        for _, span in ipairs(code) do
            if s >= span[1] and e <= span[2] then literal = true; break end
        end
        tag = tag:lower()
        if literal then
            -- Inline code is source text, even when it contains a supported tag.
        elseif styles[tag] then
            put(buf, row, s - 1, { end_col = e, conceal = '' })
            if slash == '' then
                active[tag] = e
            elseif active[tag] then
                if s - 1 > active[tag] then
                    put(buf, row, active[tag], {
                        end_col = s - 1, hl_group = styles[tag],
                        hl_mode = 'combine', priority = 210,
                    })
                end
                active[tag] = nil
            end
        elseif tag == 'br' and slash == '' then
            if in_table then
                put(buf, row, s - 1, { end_col = e, conceal = '' })
                table_breaks[s - 1] = true
            elseif not first_br then
                -- The cursor line remains raw for editing.
                first_br, last_br = s, e
            end
        elseif in_table and (tag == 'details' or tag == 'summary') then
            put(buf, row, s - 1, { end_col = e, conceal = '' })
        end
        from = e + 1
    end
    return first_br, last_br, table_breaks
end

local function styled_chunks(text, active)
    local chunks, from = {}, 1
    local function append(s)
        if s == '' then return end
        local group = active[#active] and styles[active[#active]]
        chunks[#chunks + 1] = group and { s, group } or { s }
    end
    while true do
        local s, e, slash, tag = text:find('<(/?)([%a]+)[^>]*>', from)
        if not s then break end
        append(text:sub(from, s - 1))
        tag = tag:lower()
        if styles[tag] then
            if slash == '' then
                active[#active + 1] = tag
            else
                for i = #active, 1, -1 do
                    if active[i] == tag then table.remove(active, i); break end
                end
            end
        elseif tag ~= 'summary' then
            append(text:sub(s, e))
        end
        from = e + 1
    end
    append(text:sub(from))
    if #chunks == 0 then chunks[1] = { '' } end
    return chunks
end

local function draw_br(buf, row, line, first, finish)
    local active = {}
    styled_chunks(line:sub(1, first - 1), active)
    local tail = line:sub(finish + 1)
    local rows = {}
    while true do
        local s, e = tail:find('<[bB][rR]%s*/?>')
        if not s then break end
        rows[#rows + 1] = styled_chunks(tail:sub(1, s - 1), active)
        tail = tail:sub(e + 1)
    end
    rows[#rows + 1] = styled_chunks(tail, active)
    put(buf, row, first - 1, { end_col = #line, conceal = '' })
    put(buf, row, 0, { virt_lines = rows })
end

function M.refresh(buf, cursor_row)
    if buf == 0 then buf = vim.api.nvim_get_current_buf() end
    local cache = buffers[buf]
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if not cache or cache.tick ~= tick then
        local old = prior_state(buf, cache and cache.blocks)
        local lines, skip, tables, blocks = scan(buf, old)
        vim.api.nvim_buf_clear_namespace(buf, state_ns, 0, -1)
        for _, block in ipairs(blocks) do
            block.id = vim.api.nvim_buf_set_extmark(buf, state_ns, block.first, 0, {})
        end
        cache = { tick = tick, lines = lines, skip = skip, tables = tables, blocks = blocks }
        buffers[buf] = cache
    end
    if cache.painted and cursor_row ~= cache.cursor_row
        and not cache.br_rows[cursor_row] and not cache.br_rows[cache.cursor_row] then
        cache.cursor_row = cursor_row
        return
    end
    if cache.painted and cursor_row == cache.cursor_row then return end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local hidden = {}
    for _, block in ipairs(cache.blocks) do
        local title = block.summary or 'Details'
        local label = block.expanded and '▼' or ('▶ ' .. title)
        local opener = cache.lines[block.first + 1]
        local pad = math.max(0, vim.fn.strdisplaywidth(opener) - vim.fn.strdisplaywidth(label))
        put(buf, block.first, 0, {
            virt_text = { { label .. string.rep(' ', pad), 'RendermarkHtmlDetails' } },
            virt_text_pos = 'overlay',
        })
        if not block.expanded then
            for row = block.first + 1, block.last do
                hidden[row] = true
                put(buf, row, 0, { conceal_lines = '' })
            end
        else
            local closing = cache.lines[block.last + 1]
            put(buf, block.last, 0, { end_col = #closing, conceal = '' })
            for row = block.first + 1, block.last - 1 do
                local line = cache.lines[row + 1]
                local from = 1
                while true do
                    local a, b = line:find('</?summary[^>]*>', from)
                    if not a then break end
                    put(buf, row, a - 1, { end_col = b, conceal = '' })
                    from = b + 1
                end
            end
        end
    end
    local br_rows, table_breaks = {}, {}
    for i, line in ipairs(cache.lines) do
        local row = i - 1
        if not hidden[row] and not cache.skip[row] then
            local first, finish, breaks = draw_inline(buf, row, line, cache.tables[row])
            if next(breaks) then table_breaks[row] = breaks end
            if first then br_rows[row] = true end
            if first and row ~= cursor_row then draw_br(buf, row, line, first, finish) end
        end
    end
    cache.hidden = hidden
    cache.br_rows = br_rows
    cache.table_breaks = table_breaks
    cache.cursor_row = cursor_row
    cache.painted = true
end

function M.table_breaks(buf, row)
    if buf == 0 then buf = vim.api.nvim_get_current_buf() end
    local cache = buffers[buf]
    return cache and cache.table_breaks and cache.table_breaks[row] or nil
end

function M.is_hidden(buf, row)
    if buf == 0 then buf = vim.api.nvim_get_current_buf() end
    local cache = buffers[buf]
    return cache and cache.hidden and cache.hidden[row] or false
end

-- conceal_lines hides rows visually but normal motions can still enter them.
-- Keep navigation on the visible opener or the line after the block.
function M.skip_hidden(win, previous)
    local buf = vim.api.nvim_win_get_buf(win)
    local cache = buffers[buf]
    if not cache then return false end
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    if cache.tick ~= vim.api.nvim_buf_get_changedtick(buf) then
        M.refresh(buf, row)
        cache = buffers[buf]
    end
    if not cache.hidden[row] then return false end
    for _, block in ipairs(cache.blocks) do
        if not block.expanded and row > block.first and row <= block.last then
            local target = block.first
            if previous and previous - 1 <= block.first
                and block.last + 1 < #cache.lines then
                target = block.last + 1
            end
            vim.api.nvim_win_set_cursor(win, { target + 1, 0 })
            return true
        end
    end
    return false
end

function M.clear(buf)
    if buf == 0 then buf = vim.api.nvim_get_current_buf() end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if buffers[buf] then buffers[buf].painted = false end
end

function M.toggle()
    local buf = vim.api.nvim_get_current_buf()
    local ft = vim.bo[buf].filetype
    if (ft ~= 'markdown' and ft ~= 'markdown.mdx')
        or vim.b[buf].markdown_visual_wrap == false then return false end
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    M.refresh(buf, row)
    local cache = buffers[buf]
    for i = #cache.blocks, 1, -1 do
        local block = cache.blocks[i]
        if row >= block.first and row <= block.last then
            block.expanded = not block.expanded
            cache.painted = false
            M.refresh(buf, row)
            require('rendermark.wrap').refresh(0)
            return true
        end
    end
    return false
end

function M.setup()
    local function highlights()
        vim.api.nvim_set_hl(0, 'RendermarkHtmlMark', { link = 'Search' })
        vim.api.nvim_set_hl(0, 'RendermarkHtmlUnderline', { underline = true })
        vim.api.nvim_set_hl(0, 'RendermarkHtmlStrike', { strikethrough = true })
        vim.api.nvim_set_hl(0, 'RendermarkHtmlDetails', { link = 'Special' })
    end
    highlights()
    local group = vim.api.nvim_create_augroup('rendermark_html', { clear = true })
    vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = group,
        callback = function(args) buffers[args.buf] = nil end,
    })
    vim.api.nvim_create_user_command('MarkdownDetailsToggle', M.toggle, {})
    vim.api.nvim_create_autocmd('FileType', {
        group = group, pattern = { 'markdown', 'markdown.mdx' },
        callback = function(args)
            vim.keymap.set('n', 'za', function()
                if not M.toggle() then vim.cmd('normal! za') end
            end, { buffer = args.buf, desc = 'Toggle Markdown details or fold' })
        end,
    })
end

return M
