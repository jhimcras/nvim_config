"""Real TUI input via tmux; RPC observes state without changing input mode.

Each test owns a tmux server, project, XDG directories and Neovim socket. Poll
observable conditions instead of sleeping for presumed process completion.
Failures retain screen, messages, input transcript and logs under /tmp.
"""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]


class TmuxCase(unittest.TestCase):
    timeout = 8

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="nvim-regression-"))
        self.addCleanup(self.cleanup)
        self.project = self.directory / "project with spaces"
        self.project.mkdir()
        self.file(".prjroot", "return {}\n")
        self.file("main.txt", "alpha\nbravo\ncharlie\ndelta\n")
        self.socket = self.directory / "nvim.sock"
        self.tmux_socket = self.directory / "tmux.sock"
        self.env = os.environ.copy()
        # Do not inherit a running tmux server or load ~/.config/nvim in worktrees.
        self.env.pop("TMUX", None)
        self.env.pop("NVIM", None)
        for kind in ("CONFIG", "DATA", "STATE", "CACHE"):
            self.env[f"XDG_{kind}_HOME"] = str(self.directory / kind.lower())
        self.env.update(NVIM_TEST_ROOT=str(ROOT),
                        NVIM_LOG_FILE=str(self.directory / "nvim.log"),
                        NVIM_APPNAME="nvim")
        self.command_sequence = 0
        command = shlex.join(["nvim", "--listen", str(self.socket), "-i", "NONE",
                              "-u", str(ROOT / "tests/integration/init.lua"),
                              str(self.project / "main.txt")])
        self.tmux("new-session", "-d", "-s", "test", "-x", "120", "-y", "40",
                  "-c", str(self.project), command)
        self.wait_lua("return vim.g.integration_ready == true", True)
        self.assert_no_errors()

    def file(self, name, content):
        path = self.project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def tmux(self, *args, check=True):
        return subprocess.run(["tmux", "-S", str(self.tmux_socket), "-f", "/dev/null", *args],
                              env=self.env, text=True, capture_output=True,
                              timeout=self.timeout, check=check).stdout

    def lua(self, body):
        expression = "luaeval(" + json.dumps(
            "vim.json.encode((function() " + body + " end)())") + ")"
        result = subprocess.run(["nvim", "--server", str(self.socket), "--remote-expr", expression],
                                env=self.env, text=True, capture_output=True,
                                timeout=2, check=True)
        return json.loads(result.stdout)

    def wait_lua(self, body, expected):
        deadline = time.monotonic() + self.timeout
        last = None
        while time.monotonic() < deadline:
            try:
                last = self.lua(body)
                if last == expected:
                    return last
            except (subprocess.SubprocessError, ValueError) as error:
                last = str(error)
            time.sleep(0.05)
        self.fail(f"Timed out: {body}\nExpected: {expected!r}\nLast: {last!r}")

    def keys(self, *keys):
        self.tmux("send-keys", "-t", "test:0.0", *keys)
        with (self.directory / "input.log").open("a") as log:
            log.write(repr(keys) + "\n")

    def command(self, command, wait=True):
        self.tmux("send-keys", "-t", "test:0.0", "-l", ":" + command)
        self.keys("Enter")
        with (self.directory / "input.log").open("a") as log:
            log.write(":" + command + "\n")
        if wait:
            # A separate Ex command also works after :lua, which consumes '|'.
            # The marker prevents a pre-existing matching state from passing early.
            self.command_sequence += 1
            self.tmux("send-keys", "-t", "test:0.0", "-l",
                      f":let g:integration_command = {self.command_sequence}")
            self.keys("Enter")
            self.wait_lua("return vim.g.integration_command", self.command_sequence)

    def statusline(self):
        return self.lua("local previous=vim.g.statusline_winid; "
                        "vim.g.statusline_winid=vim.api.nvim_get_current_win(); "
                        "local text=require('nvim_config.status').statusline_entry(); "
                        "vim.g.statusline_winid=previous; return text")

    def screen(self):
        return self.tmux("capture-pane", "-p", "-t", "test:0.0", "-S", "-200")

    def wait_screen(self, text):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if text in self.screen():
                return
            time.sleep(0.05)
        self.fail(f"Screen never contained {text!r}")

    def assert_no_errors(self):
        self.assertEqual([], self.lua("return vim.g.integration_errors"))
        self.assertEqual("", self.lua("return vim.v.errmsg"))

    def tearDown(self):
        self.assert_no_errors()

    def cleanup(self):
        # unittest records failures before cleanups, including setUp/tearDown errors.
        failed = any(case is self for case, _ in self._outcome.result.failures
                     + self._outcome.result.errors)
        if failed:
            try:
                (self.directory / "screen.txt").write_text(self.screen(), encoding="utf-8")
                messages = self.lua("return vim.api.nvim_exec2('messages', {output=true}).output")
                (self.directory / "messages.txt").write_text(messages, encoding="utf-8")
            except (subprocess.SubprocessError, ValueError):
                pass
            print(f"\nFailure artifacts: {self.directory}", flush=True)
        try:
            self.lua("for _, p in ipairs(require('nvim_config.session').get_running_processes()) do "
                     "if p.terminate then p.terminate(15) "
                     "elseif p.job_id then vim.fn.jobstop(p.job_id) end end; return true")
        except (subprocess.SubprocessError, ValueError):
            pass
        self.tmux("kill-server", check=False)
        if not failed:
            shutil.rmtree(self.directory)
