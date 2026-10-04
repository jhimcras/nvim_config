"""Run from the repository root; drain a real Neovim PTY during the benchmark."""
import errno
import os
import pty
import select
import subprocess
import time
from pathlib import Path
master, slave = pty.openpty()
p = subprocess.Popen(['nvim', '-u', 'NONE', '-i', 'NONE', '-n', '--cmd', 'set background=dark', '-c', 'luafile tests/manual/benchmark_statusline_shrink.lua'], stdin=slave, stdout=slave, stderr=slave, env={**os.environ, 'TERM':'xterm-256color', 'NVIM_LOG_FILE':'/tmp/statusline-benchmark-nvim.log'})
os.close(slave)
deadline = time.monotonic() + 45
log = open('/tmp/statusline_bench_pty.log', 'wb')
while True:
    if time.monotonic() > deadline:
        p.kill()
        raise RuntimeError('PTY benchmark timed out; see /tmp/statusline_bench_pty.log')
    ready, _, _ = select.select([master], [], [], 1)
    if ready:
        try:
            data = os.read(master, 65536)
            if b'\x1b]11;' in data:
                os.write(master, b'\x1b]11;rgb:0000/0000/0000\x07')
            if b'Press ENTER' in data:
                os.write(master, b'\r')
            log.write(data)
            log.flush()
            if not data: break
        except OSError as e:
            if e.errno == errno.EIO: break
            raise
    elif p.poll() is not None: break
os.close(master)
returncode = p.wait()
if returncode == 0:
    print(Path(os.environ.get('STATUSLINE_BENCH_OUTPUT', '/tmp/statusline_shrink_benchmark.json')).read_text())
raise SystemExit(returncode)
