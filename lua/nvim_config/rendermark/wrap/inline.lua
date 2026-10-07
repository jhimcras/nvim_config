local wrap_text = require('nvim_config.rendermark.wrap.text')
local M = {}

-- Inline highlight/conceal runs per row for [first, last), from all language trees'
-- highlight captures plus extra_conceals.
function M.collect_inline(parser, buf, first, last, extra_conceals)
    local row_lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
    local function line_len(row)
        return #(row_lines[row - first + 1] or '')
    end
    local intervals = {} -- row -> interval list for M.flatten_runs
    local seq = 0
    parser:for_each_tree(function(tree, ltree)
        local lang = ltree:lang()
        local ok, q = pcall(vim.treesitter.query.get, lang, 'highlights')
        if not ok or not q then
            return
        end
        for id, node, metadata in q:iter_captures(tree:root(), buf, first, last) do
            local name = q.captures[id]
            if name ~= 'spell' and name ~= 'nospell' and name:sub(1, 1) ~= '_' then
                local m = metadata[id]
                local conceal = metadata.conceal
                if m and m.conceal ~= nil then
                    conceal = m.conceal
                end
                local hl = name ~= 'conceal' and ('@' .. name .. '.' .. lang) or nil
                if hl or conceal then
                    local r1, c1, r2, c2 = node:range()
                    local prio = tonumber(metadata.priority or (m and m.priority)) or 100
                    seq = seq + 1
                    for row = math.max(r1, first), math.min(r2, last - 1) do
                        local s = row == r1 and c1 or 0
                        local e = row == r2 and math.min(c2, line_len(row)) or line_len(row)
                        if e > s then
                            local list = intervals[row] or {}
                            intervals[row] = list
                            list[#list + 1] = {
                                s = s, e = e, hl = hl,
                                conceal = conceal, priority = prio, seq = seq,
                            }
                        end
                    end
                end
            end
        end
    end)
    if extra_conceals then
        for row, list in pairs(extra_conceals) do
            local dst = intervals[row] or {}
            intervals[row] = dst
            for _, iv in ipairs(list) do
                dst[#dst + 1] = iv
            end
        end
    end
    local marks = {}
    for row, list in pairs(intervals) do
        marks[row] = wrap_text.flatten_runs(list, line_len(row))
    end
    return marks
end

-- Display metrics from foreign extmarks over [first, last), keyed by row:
--   conceals[row] = conceal ranges and hl_group highlights
--   inserts[row]  = { b = byte_col, w = width } of inline virt_text
function M.collect_deco(buf, first, last, own_ns, img_ns)
    local conceals, inserts = {}, {}
    local ok, marks = pcall(vim.api.nvim_buf_get_extmarks, buf, -1,
        { first, 0 }, { last, -1 }, { details = true })
    if not ok then
        return conceals, inserts
    end
    local seq = 0
    for _, m in ipairs(marks) do
        local row, col, d = m[2], m[3], m[4]
        local nsid = d.ns_id
        if nsid ~= own_ns and nsid ~= img_ns then
            if d.conceal ~= nil and d.end_col and d.end_col > col
                and (d.end_row == nil or d.end_row == row) then
                seq = seq + 1
                local list = conceals[row] or {}
                conceals[row] = list
                list[#list + 1] = {
                    s = col, e = d.end_col, hl = nil,
                    conceal = d.conceal,
                    priority = tonumber(d.priority) or 200,
                    seq = 1000000 + seq,
                }
            end
            if d.hl_group and d.end_col then
                seq = seq + 1
                local r2 = d.end_row or row
                for rr = math.max(row, first), math.min(r2, last - 1) do
                    local s = rr == row and col or 0
                    local e = rr == r2 and d.end_col or math.huge
                    if e > s then
                        local list = conceals[rr] or {}
                        conceals[rr] = list
                        list[#list + 1] = {
                            s = s, e = e, hl = d.hl_group,
                            conceal = nil,
                            priority = tonumber(d.priority) or 4096,
                            seq = 1000000 + seq,
                        }
                    end
                end
            end
            if d.virt_text and d.virt_text_pos == 'inline' then
                local w = 0
                for _, ch in ipairs(d.virt_text) do
                    w = w + wrap_text.dw(ch[1] or '')
                end
                if w > 0 then
                    local list = inserts[row] or {}
                    inserts[row] = list
                    list[#list + 1] = { b = col, w = w }
                end
            end
        end
    end
    return conceals, inserts
end

return M
