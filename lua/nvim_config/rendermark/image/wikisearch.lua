-- Name lookup for wiki image embeds (`![[name.png]]` with no folder part).
--
-- The embed is looked for in the document folder first (the caller does that
-- with one stat); this module handles the rest: the images under the project
-- root (`nvim_config.prjroot`, falling back to the document folder). The root
-- is walked once, asynchronously, and every image file found is indexed by
-- name, so any number of embeds costs one walk. Until the walk finishes a
-- lookup answers `nil` (the scan draws nothing) and `on_ready` is called with
-- the waiting buffers afterwards. No file watching: BufWritePost and BufEnter
-- mark an index stale, and the next lookup re-walks while still answering from
-- the old index (no flicker); `on_ready` fires only if the answer changed.
local M = {}

local uv = vim.uv

-- Observed note trees (docs/rendermark_plan.md R2): 251 to 1075 files and 26 to
-- 291 directories. 20000 entries is about 20 times the largest of them and
-- still a few tens of milliseconds of worker-thread readdir; depth 8 is
-- generous for a note tree and stops runaway nesting.
M.limits = { max_entries = 20000, max_depth = 8 }
-- A BufEnter does not re-walk an index younger than this (saving always does).
M.min_age_ms = 2000
M.stats = { started = 0, finished = 0 }
M.on_ready = function(_) end

local IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true, webp = true, svg = true, bmp = true, avif = true }
local SKIPPED_DIRS = { node_modules = true, target = true }

function M.is_image_name(name)
  local ext = name:match('%.([^./\\]+)$')
  return ext ~= nil and IMAGE_EXTENSIONS[ext:lower()] == true
end

-- root -> { index = { by_name, truncated }|nil, stale, scanning, waiters, time }
local entries = {}

local function normalize(path)
  return vim.fs.normalize(path)
end

function M.find_root(dir)
  local ok, prjroot = pcall(require, 'nvim_config.prjroot')
  local root = ok and prjroot.GetProjectRoot(dir .. '/_') or nil
  return normalize(root or dir)
end

-- Asynchronous breadth-first walk (libuv scandir callbacks, one directory at a
-- time) that never blocks the editor. Hidden directories, node_modules and
-- target are skipped, and so are symlinked directories (no loops).
local function walk(root, done)
  local by_name = {}
  local seen, truncated, outstanding = 0, false, 0
  local limits = M.limits
  local function visit(dir, depth)
    outstanding = outstanding + 1
    local started = pcall(uv.fs_scandir, dir, function(err, req)
      if not err and req then
        while true do
          local name, kind = uv.fs_scandir_next(req)
          if not name then break end
          seen = seen + 1
          if seen > limits.max_entries then
            truncated = true
            break
          end
          if kind == 'directory' then
            if depth < limits.max_depth and name:sub(1, 1) ~= '.' and not SKIPPED_DIRS[name] then
              visit(dir .. '/' .. name, depth + 1)
            elseif depth >= limits.max_depth then
              truncated = true
            end
          elseif M.is_image_name(name) then
            local dirs = by_name[name]
            if not dirs then dirs = {}; by_name[name] = dirs end
            dirs[#dirs + 1] = dir
          end
        end
      end
      outstanding = outstanding - 1
      if outstanding == 0 then done({ by_name = by_name, truncated = truncated }) end
    end)
    if not started then
      outstanding = outstanding - 1
      if outstanding == 0 then done({ by_name = by_name, truncated = truncated }) end
    end
  end
  visit(root, 0)
end

local function start_scan(root, entry)
  entry.scanning = true
  entry.stale = false
  M.stats.started = M.stats.started + 1
  walk(root, function(index)
    vim.schedule(function()
      local previous = entry.index
      M.stats.finished = M.stats.finished + 1
      entry.index, entry.scanning, entry.time = index, false, uv.now()
      local waiters = entry.waiters
      entry.waiters = {}
      if previous and vim.deep_equal(previous.by_name, index.by_name) then return end
      if next(waiters) then M.on_ready(waiters) end
    end)
  end)
end

local function components(path)
  local out = {}
  for part in path:gmatch('[^/]+') do out[#out + 1] = part end
  return out
end

-- Number of folder steps between two directories (up from `a`, down to `b`).
local function distance(a, b)
  local ca, cb = components(a), components(b)
  local common = 0
  while common < #ca and common < #cb and ca[common + 1] == cb[common + 1] do common = common + 1 end
  return (#ca - common) + (#cb - common)
end

-- The folder of the closest same-named image: { path = … }, { error = 'not_found' }
-- or { error = 'ambiguous' } when several are equally close.
local function pick(index, doc_dir, name)
  local dirs = index.by_name[name]
  if not dirs then return { error = 'not_found' } end
  local best, best_dist, tie = nil, math.huge, false
  for _, dir in ipairs(dirs) do
    local d = distance(doc_dir, dir)
    if d < best_dist then
      best, best_dist, tie = dir, d, false
    elseif d == best_dist then
      tie = true
    end
  end
  if tie then return { error = 'ambiguous' } end
  return { path = best .. '/' .. name }
end

-- Where the embed `name` lives, as pick() answers; nil while the walk of the
-- project root is unfinished (the buffer is then refreshed through `on_ready`).
function M.lookup(buf, doc_dir, name)
  doc_dir = normalize(doc_dir)
  local root = M.find_root(doc_dir)
  local entry = entries[root]
  if not entry then
    entry = { waiters = {} }
    entries[root] = entry
  end
  if (entry.stale or not entry.index) and not entry.scanning then
    start_scan(root, entry)
  end
  -- A walk in flight (first or re-walk) reports back to every asker.
  if entry.scanning then entry.waiters[buf] = true end
  if entry.index then return pick(entry.index, doc_dir, name) end
  return nil
end

-- A save or a visit may have added or moved image files.
function M.invalidate(buf, reason)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then return end
  local root = M.find_root(normalize(vim.fn.fnamemodify(name, ':p:h')))
  local entry = entries[root]
  if not entry or not entry.index then return end
  if reason == 'enter' and entry.time and uv.now() - entry.time < M.min_age_ms then return end
  entry.stale = true
end

function M.forget_buf(buf)
  for _, entry in pairs(entries) do entry.waiters[buf] = nil end
end

-- For tests: drop every index and waiter.
function M.reset()
  entries = {}
  M.stats.started, M.stats.finished = 0, 0
end

return M
