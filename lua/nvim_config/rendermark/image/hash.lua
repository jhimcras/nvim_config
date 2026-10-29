-- FNV-1a hash used to build stable image ids from paths.
local bitops = bit or bit32

local M = {}

function M.stable_hash(s)
  local h = 2166136261
  for i = 1, #s do
    h = (bitops.bxor(h, s:byte(i)) * 16777619) % 4294967296
  end
  return string.format('%08x', h)
end

return M
