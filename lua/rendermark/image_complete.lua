-- nvim-cmp source: typing "![" offers image files under the buffer's directory
-- and completes to "![stem](rel/path.ext)" with the cursor after ")".
local M = {}

local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, gif = true, webp = true, svg = true, bmp = true }
local MAX_DEPTH = 3
local MAX_ITEMS = 500

function M.new()
  return setmetatable({}, { __index = M })
end

function M:is_available()
  local ft = vim.bo.filetype
  return ft == 'markdown' or ft == 'markdown.mdx'
end

function M:get_trigger_characters()
  return { '[' }
end

function M:get_keyword_pattern()
  return [==[[^[\]()]*]==]
end

-- relative paths ("img/cat.png") of image files under dir, hidden entries skipped
function M.list_images(dir)
  local paths = {}
  for name, type in vim.fs.dir(dir, {
    depth = MAX_DEPTH,
    skip = function(d) return not vim.fs.basename(d):match('^%.') end,
  }) do
    if type == 'file' and not vim.fs.basename(name):match('^%.') then
      local ext = name:match('%.([^./]+)$')
      if ext and IMAGE_EXTS[ext:lower()] then
        paths[#paths + 1] = name
        if #paths >= MAX_ITEMS then break end
      end
    end
  end
  table.sort(paths)
  return paths
end

function M:complete(params, callback)
  local ctx = params.context
  local start = ctx.cursor_before_line:find('!%[[^%[%]]*$')
  if not start then
    return callback({ items = {}, isIncomplete = false })
  end

  local name = vim.api.nvim_buf_get_name(ctx.bufnr)
  local dir = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  local row = ctx.cursor.row - 1
  local range = {
    start = { line = row, character = ctx.cursor.character - vim.str_utfindex(ctx.cursor_before_line:sub(start), 'utf-16') },
    ['end'] = { line = row, character = ctx.cursor.character },
  }

  local kind = require('cmp').lsp.CompletionItemKind.File
  local items = {}
  for _, path in ipairs(M.list_images(dir)) do
    local stem = vim.fn.fnamemodify(path, ':t:r')
    items[#items + 1] = {
      label = path,
      filterText = '![' .. path,
      kind = kind,
      textEdit = { range = range, newText = '![' .. stem .. '](' .. path:gsub(' ', '%%20') .. ')' },
    }
  end
  callback({ items = items, isIncomplete = false })
end

return M
