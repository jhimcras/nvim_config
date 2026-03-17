local M = {}
local cache = {}
local quick_cache_ttl = 5 -- seconds

-- normalize path across platforms
local function normpath(path)
    return vim.fn.fnamemodify(path, ":p")
end

-- read a single line from file
local function read_first_line(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    return line
end

-- resolve .git (dir or file for worktree)
local function resolve_git_dir(dir)
    local git_path = vim.fs.joinpath(dir, ".git")
    local stat = vim.loop.fs_stat(git_path)

    if not stat then
        return nil
    end

    if stat.type == "file" then
        -- .git is a file -> points to real gitdir
        local f = io.open(git_path, "r")
        if not f then
            return nil
        end
        local line = f:read("*l")
        f:close()

        if line and line:match("^gitdir:") then
            local gitdir = line:gsub("^gitdir:%s*", "")

            -- if relative path, resolve against repo root
            if not gitdir:match("^/") and not gitdir:match("^%a:[/\\]") then
                gitdir = vim.fs.joinpath(dir, gitdir)
            end

            return vim.fn.fnamemodify(gitdir, ":p") -- make absolute + normalize
        end

        return nil
    else
        -- .git is a directory
        return vim.fn.fnamemodify(git_path, ":p")
    end
end

-- get branch and commit by parsing refs
local function read_branch_commit(gitdir)
    local head = read_first_line(gitdir .. "/HEAD")
    if not head then return nil, nil end

    if head:match("^ref:") then
        -- symbolic ref -> read branch + commit
        local ref = head:gsub("^ref:%s*", "")
        local branch = ref:match("refs/heads/(.+)")
        local commit = read_first_line(gitdir .. "/" .. ref)
        if not commit then
            -- fallback: check packed-refs
            local packed = io.open(gitdir .. "/packed-refs", "r")
            if packed then
                for line in packed:lines() do
                    local hash, refname = line:match("^(%x+)%s+(refs/heads/.+)$")
                    if refname == ref then
                        commit = hash
                        break
                    end
                end
                packed:close()
            end
        end
        return branch, commit
    else
        -- detached HEAD -> commit only
        return nil, head
    end
end

-- public function
function M.git_branch_commit(dir)
    dir = dir or vim.loop.cwd()
    dir = normpath(dir)

    local now = vim.uv.now() / 1000
    local c = cache[dir]
    if c and now - c.time < quick_cache_ttl then
        return c.branch, c.commit
    end

    local gitdir = resolve_git_dir(dir)
    if not gitdir then return nil, nil end

    local branch, commit = read_branch_commit(gitdir)
    cache[dir] = { branch = branch, commit = commit, time = now }
    return branch, commit
end

return M
