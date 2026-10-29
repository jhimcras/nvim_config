local M = {}
local cache = {}

-- All coordinates are zero-based, end-exclusive except end_row (closing
-- fence row, or last content row for an unclosed fence). Code always uses LF.
local function range(node) return { node:range() } end
local function trim(s) return vim.trim(s) end

function M.parse_info(info)
    info = trim(info)
    local lang = info:match('^([^%s{]+)')
    local tail = trim(info:sub(lang and #lang + 1 or 1))
    local empty = { lang = lang, classes = {}, attrs = {} }
    if tail == '' then return empty end
    if tail:sub(1, 1) ~= '{' or tail:sub(-1) ~= '}' then return empty end
    local body, pos = tail:sub(2, -2), 1
    local result = { lang = lang, classes = {}, attrs = {} }
    while pos <= #body do
        local _, ws = body:find('^%s*', pos)
        pos = (ws or pos - 1) + 1
        if pos > #body then break end
        local token = body:match('^[#.]([^%s{}]+)', pos)
        if token then
            if body:sub(pos, pos) == '#' then result.id = result.id or token
            else result.classes[#result.classes + 1] = token end
            pos = pos + #token + 1
        else
            local key = body:match('^([^%s={}]+)=', pos)
            if not key then return empty end
            pos = pos + #key + 1
            local quote, value = body:sub(pos, pos)
            if quote == '"' or quote == "'" then
                local finish = body:find(quote, pos + 1, true)
                if not finish then return empty end
                value, pos = body:sub(pos + 1, finish - 1), finish + 1
            else
                value = body:match('^([^%s{}]+)', pos)
                if not value then return empty end
                pos = pos + #value
            end
            result.attrs[key] = value
        end
        if pos <= #body and not body:sub(pos, pos):match('%s') then return empty end
    end
    result.lang = result.lang or result.classes[1]
    return result
end

local function parser(text, lang)
    local ok, p = pcall(vim.treesitter.get_string_parser, text, lang)
    if not ok then return nil, 'coderunner: treesitter ' .. lang .. ' parser unavailable: ' .. tostring(p) end
    local parsed, trees = pcall(p.parse, p)
    if not parsed or not trees[1] then return nil, 'coderunner: treesitter ' .. lang .. ' parse failed' end
    return trees[1]:root()
end

local function walk(node, fn)
    fn(node)
    for child in node:iter_children() do walk(child, fn) end
end

local function decode(s)
    return (s:gsub('\\([%p])', '%1'):gsub('&amp;', '&'):gsub('&quot;', '"')
        :gsub('&#39;', "'"):gsub('&lt;', '<'):gsub('&gt;', '>'))
end

local function images(node, text)
    local found = {}
    local function add(target, kind, row, col, finish)
        target = trim(target)
        if target == '' then return end
        found[#found + 1] = { target = decode(target), kind = kind, row = row,
            col = col, range = { row, col, row, finish } }
    end
    walk(node, function(inline)
        if inline:type() ~= 'inline' and inline:type() ~= 'html_block' then return end
        local source = vim.treesitter.get_node_text(inline, text)
        if not source:find('!', 1, true) and not source:find('<[iI][mM][gG]') then return end
        local sr, sc = inline:range()
        local root = inline:type() == 'inline' and parser(source, 'markdown_inline') or nil
        local excluded = {}
        if root then
            walk(root, function(n)
                local typ = n:type()
                if typ == 'code_span' then
                    -- Inline code masks wiki/HTML scanning below, including multiline spans.
                    local r = range(n)
                    excluded[#excluded + 1] = r
                elseif typ == 'image' then
                    for child in n:iter_children() do
                        if child:type() == 'link_destination' then
                            local r = range(n)
                            local dest = vim.treesitter.get_node_text(child, source)
                            dest = dest:gsub('^<', ''):gsub('>$', '')
                            add(dest, 'markdown', sr + r[1], r[2] + (r[1] == 0 and sc or 0),
                                r[4] + (r[3] == 0 and sc or 0))
                        end
                    end
                end
            end)
        end
        local row = 0
        for line in (source .. '\n'):gmatch('(.-)\n') do
            local function allowed(col)
                if col > 0 and line:sub(col, col) == '\\' then return false end
                for _, r in ipairs(excluded) do
                    if row >= r[1] and row <= r[3] and (row > r[1] or col >= r[2])
                        and (row < r[3] or col < r[4]) then return false end
                end
                return true
            end
            for start, target, finish in line:gmatch('()!%[%[([^%]]+)%]%]()') do
                if allowed(start - 1) then
                    add(target:match('^([^|#]+)') or '', 'wiki', sr + row,
                        start - 1 + (row == 0 and sc or 0), finish - 1 + (row == 0 and sc or 0))
                end
            end
            row = row + 1
        end
        -- HTML tags may span lines. Mask comments while retaining byte offsets.
        local html = source:gsub('<!%-%-.-%-%->', function(comment) return comment:gsub('[^\n]', ' ') end)
        for start, tag, finish in html:gmatch('()(<[iI][mM][gG]%s+[^>]*>)()') do
            local before = source:sub(1, start - 1)
            local _, line_count = before:gsub('\n', '')
            local col = #(before:match('[^\n]*$') or '')
            local permitted = source:sub(start - 1, start - 1) ~= '\\'
            for _, r in ipairs(excluded) do
                if line_count >= r[1] and line_count <= r[3]
                    and (line_count > r[1] or col >= r[2])
                    and (line_count < r[3] or col < r[4]) then permitted = false end
            end
            if permitted then
                local target = tag:match('[sS][rR][cC]%s*=%s*"([^"]*)"')
                    or tag:match("[sS][rR][cC]%s*=%s*'([^']*)'")
                    or tag:match('[sS][rR][cC]%s*=%s*([^%s>]+)')
                if target and trim(target) ~= '' then
                    local ending = source:sub(1, finish - 1)
                    local _, end_row = ending:gsub('\n', '')
                    local end_col = #(ending:match('[^\n]*$') or '')
                    add(target, 'html', sr + line_count, col + (line_count == 0 and sc or 0), end_col)
                    found[#found].range[3] = sr + end_row
                    found[#found].range[4] = end_col + (end_row == 0 and sc or 0)
                end
            end
        end
    end)
    table.sort(found, function(a, b) return a.row < b.row or a.row == b.row and a.col < b.col end)
    return found
end

function M.parse(text, opts)
    opts = opts or {}
    text = text:gsub('\r\n', '\n')
    -- The markdown grammar requires a final newline to recognize an EOF
    -- closing fence. Keep source bytes unchanged for unclosed code hashes.
    local root, err = parser(text:sub(-1) == '\n' and text or text .. '\n', 'markdown')
    if not root then return nil, err end
    local lines = vim.split(text, '\n', { plain = true })
    local blocks, nodes, by_node, counts, ids = {}, {}, {}, {}, {}
    local path = (opts.path or ''):gsub('\\', '/')
    local workspace = opts.root and vim.fs.normalize(opts.root):gsub('\\', '/')
    if workspace then path = vim.fs.relpath(workspace, path) or path end
    walk(root, function(node)
        if node:type() ~= 'fenced_code_block' then return end
        local delimiters, info, continuations = {}, '', {}
        walk(node, function(child)
            if child:type() == 'fenced_code_block_delimiter' then delimiters[#delimiters + 1] = child
            elseif child:type() == 'info_string' then info = vim.treesitter.get_node_text(child, text)
            elseif child:type() == 'block_continuation' then
                local r = range(child)
                continuations[r[1]] = math.max(continuations[r[1]] or 0, r[4])
            end
        end)
        local open = range(delimiters[1])
        local close = delimiters[2] and range(delimiters[2]) or nil
        -- Treesitter includes up to three indentation spaces in delimiters.
        open[2] = open[2] + #(vim.treesitter.get_node_text(delimiters[1], text):match('^ *') or '')
        if close then
            close[2] = close[2] + #(vim.treesitter.get_node_text(delimiters[2], text):match('^ *') or '')
        end
        local nr = range(node)
        if nr[3] >= #lines then nr[3], nr[4] = #lines - 1, #lines[#lines] end
        local last = close and close[1] - 1 or nr[3] - (nr[4] == 0 and 1 or 0)
        local body = {}
        -- The continuation column removes list/quote markers. Remaining fence
        -- indentation (up to three spaces) is removed without touching code indent.
        local prefix = lines[open[1] + 1]:sub(1, open[2])
        local indent = #(prefix:match(' *$') or '')
        local parent = node:parent()
        if parent and (parent:type() == 'list_item' or parent:type() == 'block_quote') then
            -- In containers the continuation already includes the container indent.
            local continuation = continuations[open[1] + 1] or 0
            indent = math.max(0, open[2] - continuation)
        end
        for row = open[1] + 1, last do
            local line = lines[row + 1] or ''
            line = line:sub((continuations[row] or 0) + 1)
            local spaces = #(line:match('^ *') or '')
            line = line:sub(math.min(spaces, indent) + 1)
            body[#body + 1] = line
        end
        local code = table.concat(body, '\n')
        if #body > 0 and (close or last < #lines - 1) then code = code .. '\n' end
        local b = M.parse_info(info)
        b.info, b.code, b.text = info, code, code
        b.hash = vim.fn.sha256(code)
        b.content_hash = b.hash
        b.start_row, b.end_row = open[1], close and close[1] or last
        b.open_range, b.close_range = open, close
        b.content_range = { open[1] + 1, 0, close and close[1] or nr[3], close and 0 or nr[4] }
        b.range = { open[1], open[2], b.end_row, close and close[4] or nr[4] }
        b.prefix = prefix
        b.close_prefix = close and lines[close[1] + 1]:sub(1, close[2]) or prefix
        b.top_level = open[2] == 0 and parent and parent:type() == 'section'
        b.closed = close ~= nil
        b.path, b.root = path, opts.root
        b.images = {}
        if b.lang then
            counts[b.lang] = (counts[b.lang] or 0) + 1
            b.ordinal = counts[b.lang]
            b.key = b.id and path .. '#' .. b.id or path .. ':' .. b.lang .. ':' .. b.ordinal
        elseif b.id then b.key = path .. '#' .. b.id end
        if b.id then
            if ids[b.id] then b.duplicate = true; ids[b.id].duplicate = true
            else ids[b.id] = b end
        end
        blocks[#blocks + 1], nodes[#nodes + 1] = b, node
        by_node[node:id()] = b
    end)
    for i, b in ipairs(blocks) do
        if b.lang ~= 'output' and b.closed then
            local next_node = nodes[i]:next_named_sibling()
            while next_node and next_node:type() == 'block_continuation' do next_node = next_node:next_named_sibling() end
            if next_node then
                local start = next_node:start()
                if start - b.end_row <= 2 then
                    local following = by_node[next_node:id()]
                    if following and following.lang == 'output' then b.output = following
                    elseif next_node:type() == 'paragraph' or next_node:type() == 'html_block' then
                        b.images = images(next_node, text)
                    end
                end
            end
        end
    end
    return blocks
end

function M.get(buf, root)
    buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
    local tick, path = vim.api.nvim_buf_get_changedtick(buf), vim.api.nvim_buf_get_name(buf)
    local old = cache[buf]
    local eol = vim.bo[buf].endofline
    if old and old.tick == tick and old.root == root and old.path == path and old.eol == eol then return old.blocks, old.error end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, '\n') .. (eol and '\n' or '')
    local blocks, err = M.parse(text, { path = path, root = root })
    cache[buf] = { tick = tick, path = path, root = root, eol = eol, blocks = blocks, error = err }
    return blocks, err
end

function M.invalidate(buf) cache[buf] = nil end
vim.api.nvim_create_autocmd({ 'BufWipeout' }, { callback = function(ev) M.invalidate(ev.buf) end })
return M
