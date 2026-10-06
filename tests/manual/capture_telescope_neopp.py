"""Capture Telescope buffers and neopp screenshots while replacing search queries.

Requires a built sibling neopp repository, Xvfb, xdotool, scrot and installed plugins.
Usage: python tests/manual/capture_telescope_neopp.py [--buffer FILE] [--query WORD ...]
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

config = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default=str(config.parent / 'neopp/build/neopp'))
parser.add_argument('--buffer', default=str(config / 'README.md'))
parser.add_argument('--query', nargs='+', default=['tele', 'setting', 'zzzznomatch', 'rendermark'])
args = parser.parse_args()
output = Path(tempfile.mkdtemp(prefix='telescope-neopp-'))
print(f'Captures: {output}', flush=True)
env = os.environ | dict(SDL_VIDEODRIVER='x11', LIBGL_ALWAYS_SOFTWARE='1',
                        MESA_SHADER_CACHE_DISABLE='1', XDG_STATE_HOME=str(output / 'state'))


def run(*argv):
    return subprocess.check_output(argv, env=env, text=True).strip()


def lua(expression):
    return run('nvim', '--server', str(output / 'nvim.sock'), '--remote-expr',
               'luaeval(' + json.dumps(expression) + ')')


gui = None
with open(output / 'display', 'w+') as display, open(output / 'xvfb.log', 'w') as log:
    xvfb = subprocess.Popen(['Xvfb', '-displayfd', str(display.fileno()), '-screen', '0',
                             '1280x900x24', '-nolisten', 'tcp'], pass_fds=(display.fileno(),),
                            stdout=log, stderr=log)
    try:
        for _ in range(100):
            display.seek(0)
            number = display.read().strip()
            if number:
                break
            time.sleep(.1)
        assert number, 'Xvfb did not start; see xvfb.log'
        env['DISPLAY'] = ':' + number
        with open(output / 'neopp.log', 'w') as log:
            gui = subprocess.Popen([args.binary, '-u', str(config / 'init.lua'), '-i', 'NONE',
                                    '--listen', str(output / 'nvim.sock'), args.buffer],
                                   cwd=config, env=env, stdout=log, stderr=log)
        time.sleep(5)
        window = run('xdotool', 'search', '--pid', str(gui.pid)).splitlines()[0]
        run('xdotool', 'windowfocus', window)
        records = []
        for lazy in (True, False):
            lua('(function() vim.o.lazyredraw=' + str(lazy).lower() + '; return true end)()')
            run('xdotool', 'key', 'space', 'f', 'f')
            time.sleep(1)
            for index, query in enumerate(args.query):
                run('xdotool', 'key', 'ctrl+w')
                run('xdotool', 'type', '--delay', '20', '--', query)
                time.sleep(.5)
                record = json.loads(lua("(function() local p=require('telescope.actions.state').get_current_picker(vim.api.nvim_get_current_buf()); return vim.json.encode({prompt=p:_get_prompt(),lines=vim.tbl_filter(function(s) return s~='' end,vim.api.nvim_buf_get_lines(p.results_bufnr,0,-1,false)),stats=p.stats}) end)()"))
                record['lazyredraw'] = lazy
                record['screenshot'] = f'{lazy}-{index}.png'
                records.append(record)
                (output / 'results.json').write_text(json.dumps(records, ensure_ascii=False, indent=2))
                assert record['prompt'] == query, record
                run('scrot', str(output / record['screenshot']))
                print(f'lazyredraw={lazy} query={query}: {len(record["lines"])} results', flush=True)
            run('xdotool', 'key', 'Escape')
            time.sleep(.3)
    finally:
        if gui and gui.poll() is None:
            subprocess.run(['nvim', '--server', str(output / 'nvim.sock'), '--remote-send',
                            '<Esc>:qa!<CR>'], env=env, capture_output=True, timeout=5)
            try:
                gui.wait(timeout=5)
            except subprocess.TimeoutExpired:
                gui.kill()
                gui.wait(timeout=5)
        xvfb.terminate()
        xvfb.wait(timeout=5)
