local M = {}

function M.new(max_jobs)
    local q = { max_jobs = max_jobs or 4, running = 0, waiting = {} }
    local function drain()
        while q.running < q.max_jobs and #q.waiting > 0 do
            local job = table.remove(q.waiting, 1)
            job.state = 'running'
            q.running = q.running + 1
            job.start(function()
                if job.state ~= 'running' then return end
                job.state = 'done'
                q.running = q.running - 1
                drain()
            end)
        end
    end
    function q.submit(start, on_cancel)
        local job = { state = 'queued', start = start }
        function job.cancel()
            if job.state ~= 'queued' then return false end
            for i, pending in ipairs(q.waiting) do
                if pending == job then table.remove(q.waiting, i); break end
            end
            job.state = 'cancelled'
            if on_cancel then on_cancel() end
            return true
        end
        q.waiting[#q.waiting + 1] = job
        drain()
        return job
    end
    function q.set_max_jobs(n)
        assert(type(n) == 'number' and n >= 1 and n % 1 == 0, 'max_jobs must be a positive integer')
        q.max_jobs = n
        drain()
    end
    return q
end

local shared = M.new(4)
M.submit = shared.submit
M.set_max_jobs = shared.set_max_jobs
return M
