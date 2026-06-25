local M = {}

local list_pat = [[^\s*\%(\d\+[.)]\|[-*+]\)\s\+\%(\[.\]\s\+\)\?]]

function M.dw(s)
    return vim.fn.strdisplaywidth(s)
end

function M.compute_indent(text)
    local marker = vim.fn.matchstr(text, list_pat)
    if marker ~= '' then
        return M.dw(marker)
    end
    local heading = text:match('^%s*#+%s+')
    if heading then
        return M.dw(heading)
    end
    local quote = text:match('^%s*>[%s>]*')
    if quote then
        return M.dw(quote)
    end
    return M.dw(text:match('^%s*') or '')
end

function M.slice_concat(t, a, b)
    local r = {}
    for k = a, b do
        r[#r + 1] = t[k]
    end
    return table.concat(r)
end

function M.flatten_runs(intervals, line_len)
    if not intervals or #intervals == 0 then
        return nil
    end
    local points, seen = {}, {}
    local function add_point(p)
        p = math.max(0, math.min(p, line_len))
        if not seen[p] then
            seen[p] = true
            points[#points + 1] = p
        end
    end
    for _, iv in ipairs(intervals) do
        add_point(iv.s)
        add_point(iv.e)
    end
    table.sort(points)

    local runs = {}
    for k = 1, #points - 1 do
        local s, e = points[k], points[k + 1]
        local active = {}
        for _, iv in ipairs(intervals) do
            if iv.s < e and iv.e > s then
                active[#active + 1] = iv
            end
        end
        if #active > 0 then
            table.sort(active, function(a, b)
                if (a.priority or 100) ~= (b.priority or 100) then
                    return (a.priority or 100) < (b.priority or 100)
                end
                return (a.seq or 0) < (b.seq or 0)
            end)
            local hl, conceal, anchor = {}, nil, nil
            for _, iv in ipairs(active) do
                if iv.hl then
                    hl[#hl + 1] = iv.hl
                end
                if iv.conceal ~= nil then
                    conceal, anchor = iv.conceal, iv.s
                end
            end
            runs[#runs + 1] = {
                s = s,
                e = e,
                hl = #hl > 0 and hl or nil,
                conceal = conceal,
                conceal_anchor = anchor,
            }
        end
    end
    return runs
end

function M.with_base(base_hl, hl)
    if not base_hl then
        return hl
    end
    local stack = { base_hl }
    if hl then
        if type(hl) == 'table' then
            vim.list_extend(stack, hl)
        else
            stack[#stack + 1] = hl
        end
    end
    return stack
end

function M.push_chunk(out, text, hl)
    if text == '' then
        return
    end
    local prev = out[#out]
    if prev and vim.deep_equal(prev[2], hl) then
        prev[1] = prev[1] .. text
    else
        out[#out + 1] = hl ~= nil and { text, hl } or { text }
    end
end

function M.slice_chunks(out, line, runs, sb, eb, base_hl)
    if not runs then
        M.push_chunk(out, line:sub(sb + 1, eb), M.with_base(base_hl, nil))
        return
    end
    local pos = sb
    for _, r in ipairs(runs) do
        if pos >= eb then
            break
        end
        if r.e > pos and r.s < eb then
            if r.s > pos then
                M.push_chunk(out, line:sub(pos + 1, math.min(r.s, eb)), M.with_base(base_hl, nil))
                pos = math.min(r.s, eb)
            end
            local s, e = math.max(r.s, pos), math.min(r.e, eb)
            if r.conceal == '' then
                -- concealed
            elseif r.conceal then
                if r.conceal_anchor >= s and r.conceal_anchor < e then
                    M.push_chunk(out, r.conceal, M.with_base(base_hl, r.hl))
                end
            else
                M.push_chunk(out, line:sub(s + 1, e), M.with_base(base_hl, r.hl))
            end
            pos = e
        end
    end
    if pos < eb then
        M.push_chunk(out, line:sub(pos + 1, eb), M.with_base(base_hl, nil))
    end
end

function M.wrap_indices(items, width1, widthN)
    local ranges = {}
    local line_start = 1
    local cur_w = 0
    local last_space = nil
    local budget = width1

    local function push(stop_exclusive)
        local e = stop_exclusive - 1
        while e >= line_start and items[e].sp do
            e = e - 1
        end
        ranges[#ranges + 1] = { line_start, e }
    end

    local i = 1
    while i <= #items do
        local it = items[i]
        if it.sp then
            last_space = i
        end
        if cur_w + it.w > budget and i > line_start then
            local stop, next_start
            if last_space and last_space >= line_start then
                stop = last_space
                next_start = last_space + 1
                while next_start <= #items and items[next_start].sp do
                    next_start = next_start + 1
                end
            else
                stop = i
                next_start = i
            end
            push(stop)
            budget = widthN
            line_start = next_start
            last_space = nil
            cur_w = 0
            i = next_start
        else
            cur_w = cur_w + it.w
            i = i + 1
        end
    end

    if line_start <= #items then
        push(#items + 1)
    end
    return ranges
end

function M.char_items(chars)
    local items = {}
    for i, c in ipairs(chars) do
        items[i] = { w = M.dw(c), sp = c:match('%s') ~= nil }
    end
    return items
end

function M.wrap_line(text, width1, widthN, indent)
    local chars = vim.fn.split(text, '\\zs')
    if #chars == 0 then
        return { first_end_byte = nil, lines = {}, spans = {} }
    end

    local byte_at = {}
    local acc = 0
    for i, c in ipairs(chars) do
        byte_at[i] = acc
        acc = acc + #c
    end
    byte_at[#chars + 1] = acc

    local ranges = M.wrap_indices(M.char_items(chars), width1, widthN)
    if #ranges < 2 then
        return { first_end_byte = nil, lines = {}, spans = {} }
    end

    local indent_str = string.rep(' ', indent)
    local lines, spans = {}, {}
    for k = 2, #ranges do
        local s, e = ranges[k][1], ranges[k][2]
        lines[#lines + 1] = indent_str .. M.slice_concat(chars, s, e)
        spans[#spans + 1] = { byte_at[s], byte_at[e + 1] }
    end
    return { first_end_byte = byte_at[ranges[1][2] + 1], lines = lines, spans = spans }
end

return M
