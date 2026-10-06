local M = {}

local bitops = bit or bit32

local function u32be(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u16be(s, i)
  local a, b = s:byte(i, i + 1)
  if not b then return nil end
  return a * 256 + b
end

local function u16le(s, i)
  local a, b = s:byte(i, i + 1)
  if not b then return nil end
  return a + b * 256
end

local function u24le(s, i)
  local a, b, c = s:byte(i, i + 2)
  if not c then return nil end
  return a + b * 256 + c * 65536
end

function M.parse_image_size(data)
  if type(data) ~= 'string' then return nil end

  if data:sub(1, 8) == '\137PNG\r\n\026\n' and #data >= 24 then
    return { width = u32be(data, 17), height = u32be(data, 21), format = 'png' }
  end

  if data:sub(1, 2) == '\255\216' then
    local i = 3
    while i + 8 <= #data do
      if data:byte(i) ~= 0xFF then return nil end
      local marker = data:byte(i + 1)
      i = i + 2
      while marker == 0xFF and i <= #data do
        marker = data:byte(i)
        i = i + 1
      end
      if marker == 0xD9 or marker == 0xDA then return nil end
      local len = u16be(data, i)
      if not len or len < 2 or i + len - 1 > #data then return nil end
      if (marker >= 0xC0 and marker <= 0xC3) or
         (marker >= 0xC5 and marker <= 0xC7) or
         (marker >= 0xC9 and marker <= 0xCB) or
         (marker >= 0xCD and marker <= 0xCF) then
        return { width = u16be(data, i + 5), height = u16be(data, i + 3), format = 'jpeg' }
      end
      i = i + len
    end
  end

  if data:sub(1, 4) == 'RIFF' and data:sub(9, 12) == 'WEBP' then
    local chunk = data:sub(13, 16)
    if chunk == 'VP8X' and #data >= 30 then
      return { width = u24le(data, 25) + 1, height = u24le(data, 28) + 1, format = 'webp' }
    elseif chunk == 'VP8 ' and #data >= 30 then
      return { width = bitops.band(u16le(data, 27) or 0, 0x3FFF), height = bitops.band(u16le(data, 29) or 0, 0x3FFF), format = 'webp' }
    elseif chunk == 'VP8L' and #data >= 25 then
      local b1, b2, b3, b4 = data:byte(22, 25)
      if b1 then
        local width = 1 + (bitops.band(b2 or 0, 0x3F) * 256 + b1)
        local height = 1 + (bitops.band(b4 or 0, 0x0F) * 1024 + (b3 or 0) * 4 + bitops.rshift(bitops.band(b2 or 0, 0xC0), 6))
        return { width = width, height = height, format = 'webp' }
      end
    end
  end
  return nil
end

function M.new_reader()
  local cache = {}

  return function(path)
    local st = vim.uv.fs_stat(path)
    if not st then
      cache[path] = nil
      return nil
    end

    local mtime = st.mtime and (st.mtime.sec * 1000000000 + (st.mtime.nsec or 0)) or 0
    local cached = cache[path]
    if cached and cached.mtime == mtime and cached.size == st.size then
      return cached.dim or nil
    end

    local f = io.open(path, 'rb')
    if not f then
      cache[path] = nil
      return nil
    end
    local data = f:read(512 * 1024) or ''
    f:close()

    local dim = M.parse_image_size(data)
    cache[path] = { mtime = mtime, size = st.size, dim = dim or false }
    return dim
  end
end

return M
