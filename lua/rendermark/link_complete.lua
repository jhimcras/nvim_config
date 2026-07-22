local scan = require 'rendermark.image.scan'

local M = {}

local function is_url(raw)
  return raw:match('^%a[%w+.-]*://') ~= nil
end

local function parse_destination(raw)
  if is_url(raw) then
    return { kind = 'url', raw = raw }
  end
  local path, anchor = raw:match('^([^#]*)#?(.*)$')
  if path == '' then
    return { kind = 'anchor', anchor = anchor }
  end
  return { kind = 'file', path = path, anchor = anchor }
end

local function slugify(text)
  text = text:gsub('^%s+', ''):gsub('%s+$', ''):lower()
  text = text:gsub('%s+', '-')
  text = text:gsub('[^%w%-_]', '')
  return text
end

function M.new()
  return setmetatable({}, { __index = M })
end

function M:is_available()
  local ft = vim.bo.filetype
  return ft == 'markdown' or ft == 'markdown.mdx'
end

function M:get_trigger_characters()
  return { '/', '.', '#', '\\' }
end

function M:get_keyword_pattern()
  return [==[[^/\\#()[:space:]]*]==]
end

local function destination_prefix(cursor_before_line)
  return cursor_before_line:match('%[.-%]%(([^%)]*)$')
end

-- split "dir/partial" (or "dir\partial") at the last separator. bare "."
-- or ".." (no separator yet) resolve as the dir itself, with
-- needs_slash=true so insertText can reconstruct the full replaced range
-- (cmp's keyword pattern doesn't stop at "." like it does at "/"/"\\").
local function split_path(prefix)
  local last = nil
  for i = #prefix, 1, -1 do
    local c = prefix:sub(i, i)
    if c == '/' or c == '\\' then last = i; break end
  end
  if last then
    return prefix:sub(1, last), prefix:sub(last + 1), false
  end
  if prefix == '.' or prefix == '..' then
    return prefix, '', true
  end
  return nil, nil, false
end

local function looks_like_path_trigger(prefix)
  return prefix:match('^/') or prefix:match('^%a:\\') or prefix:match('^%.')
end

local function path_items(buf, prefix)
  if not looks_like_path_trigger(prefix) then return {} end
  local dir_part, partial, needs_slash = split_path(prefix)
  if not dir_part then return {} end
  local resolved = scan.resolve_image_path(buf, dir_part)
  if not resolved or vim.fn.isdirectory(resolved) ~= 1 then return {} end
  local ok, entries = pcall(vim.fn.readdir, resolved)
  if not ok then return {} end

  local cmp_kind = require('cmp').lsp.CompletionItemKind
  local items = {}
  for _, entry in ipairs(entries) do
    local is_dir = vim.fn.isdirectory(resolved .. '/' .. entry) == 1
    if entry:sub(1, #partial) == partial and (is_dir or entry:lower():match('%.md$')) then
      local label = entry .. (is_dir and '/' or '')
      items[#items + 1] = {
        label = label,
        insertText = needs_slash and (dir_part .. '/' .. label) or label,
        kind = is_dir and cmp_kind.Folder or cmp_kind.File,
      }
    end
  end
  return items
end

local function list_headings(path)
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local headings = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local heading = line:match('^#+%s+(.+)')
    if heading then headings[#headings + 1] = heading end
  end
  return headings
end

local function heading_items(buf, dest)
  local resolved
  if dest.kind == 'anchor' then
    resolved = vim.api.nvim_buf_get_name(buf)
  else
    resolved = scan.resolve_image_path(buf, dest.path)
  end
  if not resolved then return {} end

  local cmp_kind = require('cmp').lsp.CompletionItemKind
  local items = {}
  for _, heading in ipairs(list_headings(resolved)) do
    local slug = slugify(heading)
    if slug:sub(1, #dest.anchor) == dest.anchor then
      items[#items + 1] = {
        label = slug,
        insertText = slug,
        detail = heading,
        kind = cmp_kind.Reference,
      }
    end
  end
  return items
end

function M:complete(params, callback)
  local prefix = destination_prefix(params.context.cursor_before_line)
  if not prefix or is_url(prefix) then
    return callback({ items = {}, isIncomplete = false })
  end

  local buf = params.context.bufnr
  if prefix:find('#', 1, true) then
    local dest = parse_destination(prefix)
    return callback({ items = heading_items(buf, dest), isIncomplete = true })
  end

  return callback({ items = path_items(buf, prefix), isIncomplete = true })
end

return M
