local M = {}


local function map_general(mode, lh, rh, opts)
    if opts then
        local check_validation = function(o)
            assert(o == 'expr' or o == 'buffer' or o == 'noremap' or o == 'silent',
                   string.format('keymap option: %s is not valid option',  tostring(o)))
        end
        local options = {}
        for _, o in ipairs(opts) do
            check_validation(o)
            options[o] = true
        end
        for o, v in pairs(opts) do
            if type(o) ~= 'number' then
                check_validation(o)
                options[o] = v
            end
        end
        vim.keymap.set(mode, lh, rh, options)
    end
end


local modes = { '', 'n', 't', 'x', 'i', 'v', 's', 'o' }
for _, m in ipairs(modes) do
    M[m .. 'map'] = function(lh, rh, opts) map_general(m, lh, rh, vim.tbl_extend('force', opts or {}, {silent=true})) end
    M[m .. 'noremap'] = function(lh, rh, opts) map_general(m, lh, rh, vim.tbl_extend('force', opts or {}, {noremap=true, silent=true})) end
end


return M
