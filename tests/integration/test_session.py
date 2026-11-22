import os
import time

from tmux_case import TmuxCase


class Session(TmuxCase):
    def test_round_trip_restores_file_cursor_loclist_and_launcher_output(self):
        self.file("build.sh", "printf '\\033[31msaved output\\033[0m\\n'\n")
        self.command("lua require('nvim_config.launcher').Launch('sh', {'build.sh'}, vim.fn.getcwd(), "
                     "nil, nil, nil, 'use', nil, nil, 'saved-build')")
        self.wait_lua("return vim.bo.filetype", "launcher")
        self.wait_lua("return vim.b.launcher_status", "done")
        output = self.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
        highlights = self.lua("return require('nvim_config.launcher').GetHighlights(0)")
        self.command("wincmd p")
        self.wait_lua("return vim.fn.expand('%:t')", "main.txt")
        self.keys("3", "G", "l")
        self.wait_lua("return vim.api.nvim_win_get_cursor(0)", [3, 1])
        self.command("lua vim.fn.setloclist(0, {}, ' ', {title='saved-search', "
                     "items={{filename='main.txt', lnum=2, col=1, text='saved hit'}}})")
        self.wait_lua("return #vim.fn.getloclist(0)", 1)
        self.command("lopen")
        self.wait_lua("return vim.bo.buftype", "quickfix")
        self.command("SaveSession regression")
        session_path = self.directory / "data/nvim/sessions/regression"
        self.wait_lua("return vim.fn.filereadable(vim.fn.stdpath('data') "
                      ".. '/sessions/regression')", 1)
        self.assertTrue(session_path.exists())
        self.command("lua require('nvim_config.session').OpenSession('regression')")
        # Loading launcher buffers may leave focus there; locate the restored list.
        self.command("lua for _, w in ipairs(vim.api.nvim_list_wins()) do "
                     "if vim.fn.getwininfo(w)[1].loclist == 1 then "
                     "vim.api.nvim_set_current_win(w); break end end")
        self.wait_lua("return vim.fn.getloclist(0, {title=0}).title", "saved-search")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 3)
        self.assertEqual(1, self.lua("return vim.o.cmdheight"))
        self.assertEqual("saved hit", self.lua("return vim.fn.getloclist(0)[1].text"))
        restored = self.lua("for _, b in ipairs(vim.api.nvim_list_bufs()) do "
                            "if vim.b[b].lc_object == 'saved-build' then return b end end")
        self.assertIsInstance(restored, int)
        self.assertEqual(output, self.lua(f"return vim.api.nvim_buf_get_lines({restored}, 0, -1, false)"))
        self.assertEqual(highlights, self.lua(f"return require('nvim_config.launcher').GetHighlights({restored})"))
        self.assertEqual("done", self.lua(f"return vim.b[{restored}].launcher_status"))
        self.assertEqual(0, self.lua("return #require('nvim_config.launcher').GetRunningProcesses()"))
        owner = self.lua("return vim.fn.getloclist(0, {filewinid=0}).filewinid")
        self.assertEqual([3, 1], self.lua(f"return vim.api.nvim_win_get_cursor({owner})"))

    def _assert_loclist_round_trip(self, session_name):
        self.file("hits.txt", "first HIT\nbetween\nlast HIT\n")
        self.command("edit hits.txt")
        self.command("lvimgrep /HIT/ %")
        self.command("lopen")
        self.wait_lua("return vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].loclist", 1)
        self.command(f"SaveSession {session_name}")
        self.command("CloseSession")
        self.wait_lua("return vim.v.this_session", "")
        self.command(f"lua require('nvim_config.session').OpenSession('{session_name}')")
        self.assertEqual(session_name, self.lua("return vim.fn.fnamemodify(vim.v.this_session, ':t')"))
        self.assertEqual(["hits.txt", 1, 3], self.lua(
            "for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do "
            "if vim.fn.getwininfo(w)[1].loclist == 1 then "
            "local owner = vim.fn.getloclist(w, {filewinid=0}).filewinid "
            "local file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(owner)) "
            "local result = {vim.fn.fnamemodify(file, ':t')} "
            "for _, item in ipairs(vim.fn.getloclist(w)) do table.insert(result, item.lnum) end "
            "return result end end return {}"))

    def test_round_trip_restores_loclist_with_brackets_in_session_name(self):
        self._assert_loclist_round_trip("draft[1]")

    def test_round_trip_restores_loclist_with_plain_session_name(self):
        self._assert_loclist_round_trip("draft1")

    def test_round_trip_keeps_unnamed_blank_split(self):
        self.assertEqual(1, self.lua("return vim.tbl_contains(vim.opt.sessionoptions:get(), 'blank') and 1 or 0"))
        self.command("vnew")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 2)
        self.command("SaveSession draft")
        self.wait_lua("return vim.fn.filereadable(vim.fn.stdpath('data') .. '/sessions/draft')", 1)
        self.command("CloseSession")
        self.wait_lua("return vim.v.this_session", "")
        self.command("lua require('nvim_config.session').OpenSession('draft')")
        self.wait_lua("return vim.fn.fnamemodify(vim.v.this_session, ':t')", "draft")
        wins = self.lua("local out = {} for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do "
                        "local b = vim.api.nvim_win_get_buf(w) table.insert(out, "
                        "{vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ':t'), vim.bo[b].buftype}) end "
                        "return out")
        self.assertEqual(2, len(wins))
        self.assertIn(["main.txt", ""], wins)
        self.assertIn(["", ""], wins)
        self.assertEqual("", self.lua("return vim.api.nvim_buf_get_name(0)"))
        self.assertEqual("", self.lua("return vim.bo.buftype"))

    def test_typed_quit_all_cancel_preserves_hidden_running_job(self):
        self.command("lua require('nvim_config.launcher').Launch('sleep', {'30'}, vim.fn.getcwd(), "
                     "nil, nil, nil, 'use', nil, nil, 'guard-build')")
        self.wait_lua("return vim.b.launcher_status", "running")
        buf = self.lua("return vim.api.nvim_get_current_buf()")
        pid = self.lua("return require('nvim_config.launcher').GetRunningProcesses()[1].pid")
        self.command("close")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 1)
        self.command("qa", wait=False)
        # Exercise the actual confirm dialog and command-line abbreviation, not a stub.
        self.wait_screen("Stop and Continue?")
        self.keys("c")
        self.wait_lua("return vim.fn.mode()", "n")
        self.assertEqual("running", self.lua(f"return vim.b[{buf}].launcher_status"))
        self.assertEqual(1, self.lua("return #require('nvim_config.launcher').GetRunningProcesses()"))
        self.assertEqual([], self.lua(f"return vim.fn.win_findbuf({buf})"))
        self.assertEqual("main.txt", self.lua("return vim.fn.expand('%:t')"))
        # A second attempt must prompt again; accepting Stop must actually exit.
        self.command("qa", wait=False)
        self.wait_screen("Stop and Continue?")
        self.keys("s")
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                if not self.socket.exists():
                    return
            time.sleep(0.05)
        self.fail("Accepting Stop did not exit Neovim and terminate its job")

    def tearDown(self):
        # The quit-guard feature intentionally exits its Neovim instance.
        if self.socket.exists():
            super().tearDown()
