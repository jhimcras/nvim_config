from tmux_case import TmuxCase


class Launcher(TmuxCase):
    def setUp(self):
        super().setUp()
        self.file(".prjroot", """return { launchers = {
            build = { cmd = 'sh', args = {'build.sh'}, focus = true,
                patterns = {{pattern = '([^:]+):(%d+):(%d+)',
                             extract = {'filename', 'row', 'column'}}} },
            wait = { cmd = 'sleep', args = {'30'}, focus = true },
            term = { cmd = 'sh', args = {'-c', 'printf terminal_ready; sleep 30'},
                     mode = 'terminal', focus = true },
        } }\n""")
        self.file("build.sh", "printf '\\033[31mmain.txt:3:2 error\\033[0m\\n'\n")
        # Force config reload through its public API after writing the fixture.
        self.lua("require('nvim_config.prjroot').ClearCache(); return true")

    def test_general_output_ansi_jump_and_buffer_reuse(self):
        self.command("lua require('nvim_config.launcher').LaunchObject('build')")
        self.wait_lua("return vim.bo.filetype", "launcher")
        buf = self.lua("return vim.api.nvim_get_current_buf()")
        self.wait_lua("return vim.b.launcher_status", "done")
        self.assertIn("main.txt:3:2 error", self.lua(
            "return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')"))
        self.assertNotIn("\x1b", self.lua("return vim.api.nvim_get_current_line()"))
        self.assertGreater(len(self.lua("return require('nvim_config.launcher').GetHighlights(0)")), 0)
        self.keys("]", "e")
        self.wait_lua("return vim.api.nvim_get_current_line()", "main.txt:3:2 error")
        self.keys("Enter")
        self.wait_lua("return vim.fn.expand('%:t')", "main.txt")
        self.assertEqual([3, 1], self.lua("return vim.api.nvim_win_get_cursor(0)"))
        self.assertTrue(self.lua(f"return vim.api.nvim_buf_is_valid({buf})"))
        self.command("lua require('nvim_config.launcher').LaunchObject('build')")
        self.wait_lua("return vim.api.nvim_get_current_buf()", buf)
        self.wait_lua("return vim.b.launcher_status", "done")
        self.assertEqual(1, self.lua("local n=0; for _, b in ipairs(vim.api.nvim_list_bufs()) do "
                                    "if vim.b[b].lc_object == 'build' then n=n+1 end end; return n"))

    def test_process_list_and_ctrl_c_stop_a_real_job(self):
        self.command("lua require('nvim_config.launcher').LaunchObject('wait')")
        self.wait_lua("return vim.b.launcher_status", "running")
        buf = self.lua("return vim.api.nvim_get_current_buf()")
        pid = self.lua("return require('nvim_config.launcher').GetRunningProcesses()[1].pid")
        self.assertGreater(pid, 0)
        self.command("ProcessList")
        self.wait_lua("return vim.bo.filetype", "processlist")
        self.wait_screen("wait")
        self.keys("j", "j", "Enter")
        self.wait_lua("return vim.api.nvim_get_current_buf()", buf)
        self.keys("C-c")
        self.wait_lua("return vim.b.launcher_status", "terminated")
        self.wait_lua("return #require('nvim_config.launcher').GetRunningProcesses()", 0)
        self.wait_lua(f"return vim.uv.kill({pid}, 0) == nil", True)

    def test_terminal_output_escape_mapping_and_process_registration(self):
        # TermOpen enters terminal input mode, so an Ex completion marker would
        # be sent to the child process. Observe its buffer and output instead.
        self.command("lua require('nvim_config.launcher').LaunchObject('term')", wait=False)
        self.wait_lua("return vim.bo.buftype", "terminal")
        self.wait_screen("terminal_ready")
        self.keys("Escape")
        self.wait_lua("return vim.fn.mode()", "n")
        self.assertEqual("running", self.lua("return vim.b.launcher_status"))
        self.assertEqual("terminal", self.lua("return require('nvim_config.launcher').GetRunningProcesses()[1].type"))
        job = self.lua("return require('nvim_config.launcher').GetRunningProcesses()[1].job_id")
        self.keys("C-c")
        self.wait_lua("return #require('nvim_config.launcher').GetRunningProcesses()", 0)
        self.wait_lua(f"return vim.fn.jobwait({{{job}}}, 0)[1] ~= -1", True)
