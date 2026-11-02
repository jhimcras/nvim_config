-- Spawn suspended so no descendant can escape before Job Object assignment.
local ffi = require('ffi')
local uv = vim.uv
ffi.cdef [[
typedef void *CR_HANDLE;
typedef unsigned long CR_DWORD;
typedef struct { CR_DWORD length; void *descriptor; int inherit; } CR_SECURITY;
typedef struct {
    CR_DWORD cb; unsigned short *reserved, *desktop, *title;
    CR_DWORD x, y, width, height, chars_x, chars_y, fill, flags;
    unsigned short show, reserved_size; unsigned char *reserved_bytes;
    CR_HANDLE input, output, errors;
} CR_STARTUP;
typedef struct { CR_STARTUP startup; void *attributes; } CR_STARTUP_EX;
typedef struct { CR_HANDLE process, thread; CR_DWORD pid, tid; } CR_PROCESS;
typedef struct {
    int64_t process_time, job_time; CR_DWORD flags;
    uintptr_t minimum, maximum; CR_DWORD active; uintptr_t affinity;
    CR_DWORD priority, scheduling;
} CR_JOB_LIMIT;
typedef struct {
    CR_JOB_LIMIT basic; uint64_t io[6];
    uintptr_t process_memory, job_memory, peak_process_memory, peak_job_memory;
} CR_JOB_EXTENDED;
CR_HANDLE __stdcall CreateJobObjectW(void *, const unsigned short *);
int __stdcall SetInformationJobObject(CR_HANDLE, int, void *, CR_DWORD);
int __stdcall AssignProcessToJobObject(CR_HANDLE, CR_HANDLE);
int __stdcall TerminateJobObject(CR_HANDLE, unsigned int);
int __stdcall CreatePipe(CR_HANDLE *, CR_HANDLE *, CR_SECURITY *, CR_DWORD);
int __stdcall SetHandleInformation(CR_HANDLE, CR_DWORD, CR_DWORD);
int __stdcall CloseHandle(CR_HANDLE);
CR_DWORD __stdcall GetLastError(void);
int __stdcall MultiByteToWideChar(unsigned int, CR_DWORD, const char *, int, unsigned short *, int);
int __stdcall InitializeProcThreadAttributeList(void *, CR_DWORD, CR_DWORD, uintptr_t *);
int __stdcall UpdateProcThreadAttribute(void *, CR_DWORD, uintptr_t, void *, uintptr_t, void *, uintptr_t *);
void __stdcall DeleteProcThreadAttributeList(void *);
int __stdcall CreateProcessW(const unsigned short *, unsigned short *, void *, void *, int,
    CR_DWORD, void *, const unsigned short *, CR_STARTUP_EX *, CR_PROCESS *);
CR_DWORD __stdcall ResumeThread(CR_HANDLE);
int __stdcall TerminateProcess(CR_HANDLE, unsigned int);
int __stdcall GetExitCodeProcess(CR_HANDLE, CR_DWORD *);
CR_DWORD __stdcall WaitForSingleObject(CR_HANDLE, CR_DWORD);
int _open_osfhandle(intptr_t, int);
int _close(int);
]]
local kernel = ffi.load('kernel32')
local crt = ffi.load('ucrtbase')
local M = {}
local function wide(s)
    if not s then return nil end
    local n = kernel.MultiByteToWideChar(65001, 8, s, #s, nil, 0)
    if n == 0 then error('invalid UTF-8 in process arguments') end
    local out = ffi.new('unsigned short[?]', n + 1)
    assert(kernel.MultiByteToWideChar(65001, 8, s, #s, out, n) == n)
    return out
end
local function quote(s)
    -- Windows CRT argv rules (including empty args and trailing backslashes).
    return '"' .. s:gsub('(\\*)"', '%1%1\\"'):gsub('(\\+)$', '%1%1') .. '"'
end

function M.spawn(program, opts, callback)
    local argv = { quote(program) }
    for _, arg in ipairs(opts.args) do argv[#argv + 1] = quote(arg) end
    table.sort(opts.env, function(a, b) return a:lower() < b:lower() end)
    local line, env, cwd = wide(table.concat(argv, ' ')), wide(table.concat(opts.env, '\0') .. '\0'), wide(opts.cwd)
    local owned, fds = {}, {}
    local function own(handle)
        if handle ~= nil then owned[#owned + 1] = handle end
        return handle
    end
    local function cleanup()
        for _, fd in pairs(fds) do crt._close(fd) end
        for _, handle in ipairs(owned) do kernel.CloseHandle(handle) end
    end
    local function failed(label, code)
        code = code or tonumber(kernel.GetLastError())
        cleanup()
        return nil, (code == 2 or code == 3) and 'ENOENT' or label .. ': Windows error ' .. code
    end
    local job = own(kernel.CreateJobObjectW(nil, nil))
    if job == nil then return failed('CreateJobObject') end
    local limits = ffi.new('CR_JOB_EXTENDED')
    limits.basic.flags = 0x2000 -- JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if kernel.SetInformationJobObject(job, 9, limits, ffi.sizeof(limits)) == 0 then
        return failed('SetInformationJobObject')
    end
    local child_handles = ffi.new('CR_HANDLE[3]')
    local security = ffi.new('CR_SECURITY', { length = ffi.sizeof('CR_SECURITY'), inherit = 1 })
    for i = 1, 3 do
        local read, write = ffi.new('CR_HANDLE[1]'), ffi.new('CR_HANDLE[1]')
        if kernel.CreatePipe(read, write, security, 0) == 0 then return failed('CreatePipe') end
        own(read[0]); own(write[0])
        local parent = i == 1 and write[0] or read[0]
        child_handles[i - 1] = i == 1 and read[0] or write[0]
        if kernel.SetHandleInformation(parent, 1, 0) == 0 then return failed('SetHandleInformation') end
        local fd = crt._open_osfhandle(ffi.cast('intptr_t', parent), 0x8000) -- binary
        if fd < 0 then cleanup(); return nil, 'cannot open process pipe descriptor' end
        -- The CRT descriptor now owns the parent handle.
        for k, handle in ipairs(owned) do if handle == parent then table.remove(owned, k); break end end
        fds[#fds + 1] = fd
    end
    -- Restrict inheritance to this step's pipes, including concurrent spawns.
    local size = ffi.new('uintptr_t[1]')
    kernel.InitializeProcThreadAttributeList(nil, 1, 0, size)
    local attributes = ffi.new('unsigned char[?]', tonumber(size[0]))
    if kernel.InitializeProcThreadAttributeList(attributes, 1, 0, size) == 0 then
        return failed('InitializeProcThreadAttributeList')
    end
    if kernel.UpdateProcThreadAttribute(attributes, 0, 0x20002, child_handles,
            ffi.sizeof(child_handles), nil, nil) == 0 then
        kernel.DeleteProcThreadAttributeList(attributes)
        return failed('UpdateProcThreadAttribute')
    end
    local startup, info = ffi.new('CR_STARTUP_EX'), ffi.new('CR_PROCESS')
    startup.startup.cb = ffi.sizeof(startup)
    startup.startup.flags = 0x100 -- STARTF_USESTDHANDLES
    startup.startup.input, startup.startup.output, startup.startup.errors =
        child_handles[0], child_handles[1], child_handles[2]
    startup.attributes = attributes
    local created = kernel.CreateProcessW(nil, line, nil, nil, 1,
        0x08080404, env, cwd, startup, info) -- NO_WINDOW | EXTENDED_STARTUPINFO | UNICODE_ENV | SUSPENDED
    local create_error = tonumber(kernel.GetLastError())
    kernel.DeleteProcThreadAttributeList(attributes)
    if created == 0 then
        cleanup()
        return nil, (create_error == 2 or create_error == 3) and 'ENOENT'
            or 'CreateProcess: Windows error ' .. create_error
    end
    own(info.process); own(info.thread)
    if kernel.AssignProcessToJobObject(job, info.process) == 0 then
        local code = tonumber(kernel.GetLastError())
        kernel.TerminateProcess(info.process, 1)
        return failed('AssignProcessToJobObject', code)
    end
    for i, fd in ipairs(fds) do
        local ok, err = opts.stdio[i]:open(fd)
        if not ok then
            kernel.TerminateJobObject(job, 1); cleanup()
            return nil, tostring(err)
        end
        fds[i] = nil
    end
    -- libuv owns descriptors once opened. Close only child pipe ends here.
    fds = {}
    for i = 0, 2 do kernel.CloseHandle(child_handles[i]) end
    owned = {}
    local process = { closed = false }
    local poll = uv.new_timer()
    function process:is_closing() return self.closed end
    function process:kill() kernel.TerminateJobObject(job, 1) end
    function process:close()
        if self.closed then return end
        self.closed = true
        poll:stop(); poll:close()
        kernel.CloseHandle(job); kernel.CloseHandle(info.process)
    end
    if kernel.ResumeThread(info.thread) == 0xffffffff then
        kernel.CloseHandle(info.thread); process:kill(); process:close()
        return nil, 'ResumeThread failed'
    end
    kernel.CloseHandle(info.thread)
    poll:start(0, 10, function()
        if kernel.WaitForSingleObject(info.process, 0) ~= 0 then return end
        poll:stop()
        local code = ffi.new('CR_DWORD[1]')
        kernel.GetExitCodeProcess(info.process, code)
        -- End surviving descendants even after a normal or failed leader exit.
        process:kill()
        callback(tonumber(code[0]), 0)
    end)
    return process, tonumber(info.pid)
end
return M
