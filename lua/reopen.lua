-- Reopen the most recently closed window or tab, restoring its original layout.
--
-- Windows and tabs share a single chronological stack, so <leader>u walks back
-- through whatever was closed last regardless of kind.
--
-- Capture hangs off a single WinClosed autocmd. Two facts drive the design:
--   * WinClosed fires while the window is still valid, so buffer/cursor/size
--     are all readable at that point.
--   * Closing a tab fires WinClosed once per window, and winlayout() degrades
--     as the burst progresses -- the last event in a :tabclose burst reports a
--     different tab's tree entirely. So the whole-tab snapshot is taken on the
--     FIRST WinClosed seen for a tabpage and keyed by its handle.
-- Reconciliation is deferred to vim.schedule, by which point a closed tab's
-- handle is already invalid; that removes any need for a TabClosed autocmd.

local api = vim.api

local M = {}

local MAX_DEPTH = 10
-- A person does not close nine windows in one keystroke. Anything past this in
-- a single burst is programmatic teardown (%bwipeout!, tabonly!, ...) and would
-- otherwise evict the real history, so the whole burst is dropped.
local BURST_LIMIT = 8

local stack = {}      -- oldest .. newest
local pending = {}    -- [tabpage handle] = snapshot taken at first WinClosed
local burst_base = nil -- #stack when the current burst began
local scheduled = false

----------------------------------------------------------------------------------------------------
-- capture

local function is_floating(win)
    return api.nvim_win_get_config(win).relative ~= ''
end

local function skippable(win)
    if not api.nvim_win_is_valid(win) then return true end
    if is_floating(win) then return true end
    return vim.bo[api.nvim_win_get_buf(win)].buftype == 'terminal'
end

local function win_state(win)
    local buf = api.nvim_win_get_buf(win)
    local state = {
        win     = win,
        buf     = buf,
        name    = api.nvim_buf_get_name(buf),
        buftype = vim.bo[buf].buftype,
        cursor  = api.nvim_win_get_cursor(win),
        -- line('w0', winid) reads the topline without switching windows;
        -- nvim_win_call(winsaveview) costs ~5x more for the same information.
        topline = vim.fn.line('w0', win),
        width   = api.nvim_win_get_width(win),
        height  = api.nvim_win_get_height(win),
    }
    if state.buftype == 'quickfix' then
        local info = vim.fn.getloclist(win, { filewinid = 0 })
        -- filewinid ~= 0 marks a location list, which belongs to an origin window.
        if info.filewinid and info.filewinid ~= 0 then state.filewinid = info.filewinid end
    end
    return state
end

-- Keep only the leaves `keep` accepts, collapsing any container left with a
-- single child. Returns nil if nothing survives.
local function filter_tree(node, keep)
    if node[1] == 'leaf' then
        return keep(node[2]) and node or nil
    end
    local kids = {}
    for _, child in ipairs(node[2]) do
        local kept = filter_tree(child, keep)
        if kept then kids[#kids + 1] = kept end
    end
    if #kids == 0 then return nil end
    if #kids == 1 then return kids[1] end
    return { node[1], kids }
end

local function collect_leaves(node, acc)
    if node[1] == 'leaf' then
        acc[#acc + 1] = node[2]
    else
        for _, child in ipairs(node[2]) do collect_leaves(child, acc) end
    end
    return acc
end

local function snapshot(tab)
    local tree = vim.fn.winlayout(api.nvim_tabpage_get_number(tab))
    tree = filter_tree(tree, function(win) return not skippable(win) end)
    if not tree then return nil end
    local states = {}
    for _, win in ipairs(collect_leaves(tree, {})) do
        states[win] = win_state(win)
    end
    return {
        tree   = tree,
        states = states,
        index  = api.nvim_tabpage_get_number(tab),
        cur    = api.nvim_tabpage_get_win(tab),
    }
end

-- Strip quickfix and location-list windows from a snapshot destined for a tab
-- entry. A location list dies with the origin window, which the tab close took
-- with it, and a global quickfix list drifts out from under the closed tab --
-- either way the window comes back empty or stale, which is worse than absent.
-- Only tab entries need this: a lone quickfix/loclist window closing leaves its
-- origin alive, and restoring that still works.
local function without_lists(snap)
    local tree = filter_tree(snap.tree, function(win)
        local state = snap.states[win]
        return state ~= nil and state.buftype ~= 'quickfix'
    end)
    if not tree then return nil end

    local leaves = collect_leaves(tree, {})
    local states = {}
    for _, win in ipairs(leaves) do states[win] = snap.states[win] end
    return {
        tree   = tree,
        states = states,
        index  = snap.index,
        cur    = states[snap.cur] and snap.cur or leaves[1],
    }
end

-- Locate `target`'s container: returns the container kind ('row'/'col'), the
-- target's index among its siblings, the sibling list, and whether the
-- container is the tree root.
local function find_container(node, target, is_root)
    if node[1] == 'leaf' then return nil end
    local kids = node[2]
    for i, child in ipairs(kids) do
        if child[1] == 'leaf' and child[2] == target then
            return node[1], i, kids, is_root
        end
    end
    for _, child in ipairs(kids) do
        local kind, idx, siblings, root = find_container(child, target, false)
        if kind then return kind, idx, siblings, root end
    end
    return nil
end

-- Where to re-create `target` relative to whatever survives around it.
local function placement(tree, target)
    local kind, idx, siblings, is_root = find_container(tree, target, true)
    if not kind then return nil end

    local sib_idx = idx > 1 and idx - 1 or idx + 1
    local sibling = siblings[sib_idx]
    if not sibling then return nil end

    local before = idx < sib_idx
    -- Anchor on the sibling leaf nearest the closed window, so the re-split
    -- lands on the correct side when the sibling is a nested container.
    local leaves = collect_leaves(sibling, {})
    if not before then
        local reversed = {}
        for i = #leaves, 1, -1 do reversed[#reversed + 1] = leaves[i] end
        leaves = reversed
    end
    return { dir = kind, before = before, root = is_root, anchors = leaves }
end

local function push(entry)
    if burst_base == nil then burst_base = #stack end
    stack[#stack + 1] = entry
end

local function truncate()
    while #stack > MAX_DEPTH do table.remove(stack, 1) end
end

-- Runs once per close burst, after every WinClosed/TabClosed has fired.
local function reconcile()
    scheduled = false
    local base = burst_base or #stack
    burst_base = nil

    local dead = {}
    local dead_count = 0
    for tab in pairs(pending) do
        if not api.nvim_tabpage_is_valid(tab) then
            dead[tab] = true
            dead_count = dead_count + 1
        end
    end

    -- A single tab closing legitimately produces one WinClosed per window; that
    -- is not a runaway burst even when the tab held many windows.
    local added = #stack - base
    local single_tab_close = dead_count == 1
    if single_tab_close then
        for i = base + 1, #stack do
            if not dead[stack[i].tab] then single_tab_close = false break end
        end
    end

    if added > BURST_LIMIT and not single_tab_close then
        for i = #stack, base + 1, -1 do table.remove(stack, i) end
        pending = {}
        return
    end

    for tab, snap in pairs(pending) do
        if dead[tab] then
            local kept = {}
            for _, entry in ipairs(stack) do
                if entry.tab ~= tab then kept[#kept + 1] = entry end
            end
            -- A tab of nothing but quickfix/loclist windows leaves nothing worth
            -- restoring, so no entry is recorded at all.
            local restorable = without_lists(snap)
            if restorable then
                kept[#kept + 1] = { kind = 'tab', tab = tab, snap = restorable }
            end
            stack = kept
        end
    end

    pending = {}
    truncate()
end

local function on_win_closed(ev)
    -- mksession-generated files set this while they tear down and rebuild the
    -- layout; none of that is a user closing a window.
    if vim.g.SessionLoad == 1 then return end

    local win = tonumber(ev.match)
    if not win or skippable(win) then return end

    local tab = api.nvim_win_get_tabpage(win)
    if not api.nvim_tabpage_is_valid(tab) then return end

    if pending[tab] == nil then
        pending[tab] = snapshot(tab) or false
    end
    local snap = pending[tab]
    if not snap then return end

    local state = snap.states[win] or win_state(win)
    push({
        kind  = 'win',
        tab   = tab,
        state = state,
        place = placement(snap.tree, win),
    })

    if not scheduled then
        scheduled = true
        vim.schedule(reconcile)
    end
end

----------------------------------------------------------------------------------------------------
-- restore

local function fill_buffer(win, state)
    if state.buf and api.nvim_buf_is_valid(state.buf) then
        if pcall(api.nvim_win_set_buf, win, state.buf) then return true end
    end
    -- The buffer is gone (:bd), so fall back to the path for real files.
    if state.buftype == '' and state.name ~= '' and vim.fn.filereadable(state.name) == 1 then
        local ok = pcall(api.nvim_win_call, win, function()
            vim.cmd('edit ' .. vim.fn.fnameescape(state.name))
        end)
        if ok then return true end
    end
    return false
end

-- True when `win` has a neighbour along the given axis, i.e. when there is
-- somewhere for the rows or columns it gives up to actually go.
local function has_neighbour(win, a, b)
    local ok, res = pcall(api.nvim_win_call, win, function()
        local self = vim.fn.winnr()
        return vim.fn.winnr(a) ~= self or vim.fn.winnr(b) ~= self
    end)
    return ok and res
end

local function apply_view(win, state)
    -- Resizing a window with no neighbour on that axis leaves rows unaccounted
    -- for, and Neovim absorbs them by growing cmdheight. Dropping a quickfix
    -- window from a restored tab is exactly how a lone window arises here.
    if has_neighbour(win, 'h', 'l') then
        pcall(api.nvim_win_set_width, win, state.width)
    end
    if has_neighbour(win, 'j', 'k') then
        pcall(api.nvim_win_set_height, win, state.height)
    end
    local lines = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
    local row = math.min(state.cursor[1], math.max(lines, 1))
    pcall(api.nvim_win_set_cursor, win, { row, state.cursor[2] })
    pcall(api.nvim_win_call, win, function()
        vim.fn.winrestview { topline = state.topline, lnum = row, col = state.cursor[2] }
    end)
end

-- A restored location list keeps its contents but loses filewinid, which is what
-- grep.lua keys its origin tagging on. Re-running :lopen from the origin window
-- rebuilds that association and lets grep.lua's BufWinEnter hook repaint the tag.
local function restore_loclist(state)
    if not api.nvim_win_is_valid(state.filewinid) then return false end
    api.nvim_set_current_win(state.filewinid)
    if not pcall(vim.cmd, 'lopen') then return false end
    apply_view(api.nvim_get_current_win(), state)
    return true
end

local function pick_anchor(place, tab)
    if place then
        for _, win in ipairs(place.anchors) do
            if api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) == tab then
                return win
            end
        end
    end
    local cur = api.nvim_tabpage_get_win(tab)
    return api.nvim_win_is_valid(cur) and cur or nil
end

local function restore_win(entry)
    -- Without its original tab there is no layout left to slot the window back into.
    if not api.nvim_tabpage_is_valid(entry.tab) then return false end
    api.nvim_set_current_tabpage(entry.tab)

    local state = entry.state
    if state.buftype == 'quickfix' and state.filewinid then
        return restore_loclist(state)
    end

    local anchor = pick_anchor(entry.place, entry.tab)
    if not anchor then return false end

    local place = entry.place
    local split = (place and place.dir == 'col') and 'split' or 'vsplit'
    local modifier
    if place and place.root then
        -- The sibling spans the rest of the tab, so split against the tab edge.
        modifier = place.before and 'topleft' or 'botright'
    else
        modifier = (place and place.before) and 'aboveleft' or 'belowright'
    end

    api.nvim_set_current_win(anchor)
    if not pcall(vim.cmd, modifier .. ' ' .. split) then return false end

    local win = api.nvim_get_current_win()
    if not fill_buffer(win, state) then
        pcall(vim.cmd, 'close')
        return false
    end
    apply_view(win, state)
    api.nvim_set_current_win(win)
    return true
end

-- Rebuild a layout tree under `win`, mapping each original winid to its new window.
local function build(node, win, mapping)
    if node[1] == 'leaf' then
        mapping[node[2]] = win
        return
    end
    local kids = node[2]
    local split = (node[1] == 'row') and 'vsplit' or 'split'
    local wins = { win }
    api.nvim_set_current_win(win)
    for i = 2, #kids do
        vim.cmd('belowright ' .. split)
        wins[i] = api.nvim_get_current_win()
    end
    for i, child in ipairs(kids) do build(child, wins[i], mapping) end
end

local function restore_tab(entry)
    local snap = entry.snap
    vim.cmd('$tabnew')
    local tab = api.nvim_get_current_tabpage()

    local target = math.max(1, math.min(snap.index, vim.fn.tabpagenr('$')))
    pcall(vim.cmd, 'tabmove ' .. (target - 1))

    local mapping = {}
    build(snap.tree, api.nvim_get_current_win(), mapping)

    local restored = 0
    for old, win in pairs(mapping) do
        local state = snap.states[old]
        if state and fill_buffer(win, state) then restored = restored + 1 end
    end
    if restored == 0 then
        pcall(vim.cmd, 'tabclose')
        return false
    end

    -- Sizes only settle once every window exists, so apply them in a second pass.
    for old, win in pairs(mapping) do
        local state = snap.states[old]
        if state then apply_view(win, state) end
    end

    local focus = mapping[snap.cur]
    if focus and api.nvim_win_is_valid(focus) then api.nvim_set_current_win(focus) end
    if api.nvim_tabpage_is_valid(tab) then api.nvim_set_current_tabpage(tab) end
    return true
end

function M.restore()
    while #stack > 0 do
        local entry = table.remove(stack)
        local ok, done = pcall(entry.kind == 'tab' and restore_tab or restore_win, entry)
        if ok and done then return true end
    end
    vim.notify('No recently closed window or tab', vim.log.levels.INFO)
    return false
end

----------------------------------------------------------------------------------------------------

function M.depth()
    return #stack
end

function M.peek()
    return stack[#stack]
end

function M.clear()
    stack, pending, burst_base = {}, {}, nil
end

function M.setup()
    local group = api.nvim_create_augroup('reopen', { clear = true })
    api.nvim_create_autocmd('WinClosed', { group = group, callback = on_win_closed })
    api.nvim_create_user_command('Reopen', function() M.restore() end,
        { desc = 'Reopen the most recently closed window or tab' })
end

return M
