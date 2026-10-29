local queue = require('nvim_config.coderunner.queue')
describe('coderunner queue', function()
    it('starts FIFO and cancels waiting work without starting it', function()
        local q, order, finishes = queue.new(1), {}, {}
        local function submit(n)
            return q.submit(function(done) order[#order + 1] = n; finishes[n] = done end)
        end
        submit(1); local cancelled = submit(2); submit(3)
        assert.same({ 1 }, order)
        assert.is_true(cancelled.cancel())
        finishes[1](); assert.same({ 1, 3 }, order)
        finishes[3](); finishes[3](); assert.equals(0, q.running)
    end)
    it('changes limits without terminating running jobs', function()
        local q, done = queue.new(2), {}
        for i = 1, 4 do q.submit(function(finish) done[i] = finish end) end
        assert.equals(2, q.running)
        q.set_max_jobs(1); done[1](); assert.is_nil(done[3])
        done[2](); assert.is_function(done[3])
        q.set_max_jobs(3); assert.is_function(done[4])
        done[3](); done[4](); assert.equals(0, q.running)
    end)
end)
