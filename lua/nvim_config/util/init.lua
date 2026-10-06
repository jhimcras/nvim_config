local M = {}
local env = require 'nvim_config.env'

local buffer = require('nvim_config.util.buffer')
local text = require('nvim_config.util.text')
local map = require('nvim_config.util.map')
local hl = require('nvim_config.util.hl')
local job = require('nvim_config.util.job')
local cache = require('nvim_config.util.cache')
local serialize = require('nvim_config.util.serialize')

for _, module in ipairs({ buffer, text, map, hl, job, cache, serialize }) do
    for name, value in pairs(module) do
        M[name] = value
    end
end

function M.normalize_path_separator(path)
    return serialize.normalize_path_separator(path, env.os.win)
end

return M
