from tmux_case import TmuxCase


MARKS = ("local ns = vim.api.nvim_get_namespaces().read_mode_search "
         "return ns and #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) or 0")


class ReadMode(TmuxCase):
    def setUp(self):
        super().setUp()
        self.file("note.txt", "heading\none prefix NEEDLE suffix\nending\n")
        self.command("edit note.txt")
        self.command("vsplit")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 2)
        self.keys("Space", "r")
        self.wait_lua("return vim.w.read_mode_active == true", True)
        self.keys("/")
        self.wait_lua("return vim.fn.getcmdtype()", "/")
        self.tmux("send-keys", "-t", "test:0.0", "-l", "NEEDLE")
        self.keys("Enter")
        self.wait_lua(MARKS, 1)

    def assert_plain_needle_after_nohlsearch(self):
        self.command("close")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 1)
        self.assertFalse(self.lua("return vim.w.read_mode_active == true"))
        self.assertEqual(0, self.lua(MARKS))
        self.command("nohlsearch")
        self.wait_lua("return vim.v.hlsearch", 0)
        # capture-pane -e emits SGR only on attribute changes, so an unbroken
        # run means NEEDLE shares its neighbours' colours.
        self.wait_screen("one prefix NEEDLE suffix")
        ansi = self.tmux("capture-pane", "-p", "-e", "-t", "test:0.0")
        line = next(row for row in ansi.splitlines() if "NEEDLE" in row)
        self.assertIn("one prefix NEEDLE suffix", line)

    def test_closing_searched_read_window_clears_its_highlight(self):
        self.assert_plain_needle_after_nohlsearch()

    def test_escape_before_close_clears_its_highlight(self):
        self.keys("Escape")
        self.wait_lua("return vim.w.read_mode_active == true", False)
        self.assertEqual(0, self.lua(MARKS))
        self.assert_plain_needle_after_nohlsearch()


class ReadModeExit(TmuxCase):
    def test_j_after_exit_moves_by_display_line(self):
        self.file("wrap.txt", "0123456789" * 26 + "\nNEXT LINE\n")
        self.command("edit wrap.txt")
        self.command("setlocal wrap")
        self.keys("g", "g", "0")
        self.keys("j")
        self.wait_lua("return vim.api.nvim_win_get_cursor(0)[2] > 0", True)
        self.assertEqual(1, self.lua("return vim.api.nvim_win_get_cursor(0)[1]"))
        self.keys("g", "g", "0")
        self.wait_lua("return vim.api.nvim_win_get_cursor(0)[2]", 0)
        self.keys("Space", "r")
        self.wait_lua("return vim.w.read_mode_active == true", True)
        self.keys("Escape")
        self.wait_lua("return vim.w.read_mode_active == true", False)
        self.assertTrue(self.lua("return vim.bo.modifiable"))
        self.keys("j")
        self.wait_lua("return vim.api.nvim_win_get_cursor(0)[2] > 0", True)
        self.assertEqual(1, self.lua("return vim.api.nvim_win_get_cursor(0)[1]"))


class ReadModeSearchEnd(TmuxCase):
    def test_n_past_last_match_reports_and_keeps_view(self):
        lines = ["x"] * 40
        lines[9] = lines[29] = "NEEDLE"
        self.file("note.txt", "\n".join(lines) + "\n")
        self.command("edit note.txt")
        self.command("set nowrapscan")
        self.keys("Space", "r")
        self.wait_lua("return vim.w.read_mode_active == true", True)
        self.keys("/")
        self.wait_lua("return vim.fn.getcmdtype()", "/")
        self.tmux("send-keys", "-t", "test:0.0", "-l", "NEEDLE")
        self.keys("Enter")
        self.wait_lua("return vim.api.nvim_win_get_cursor(0)[1]", 10)
        self.keys("n")
        self.wait_lua("return vim.api.nvim_win_get_cursor(0)[1]", 30)
        self.wait_lua("return #vim.api.nvim_buf_get_extmarks(0, "
                      "vim.api.nvim_get_namespaces().read_mode_search, 0, -1, {})", 1)
        top = self.lua("return vim.fn.winsaveview().topline")
        self.keys("n")
        self.wait_screen("E385")
        self.assertIn("E385", self.lua("return vim.fn.execute('messages')"))
        self.assertEqual(30, self.lua("return vim.api.nvim_win_get_cursor(0)[1]"))
        self.assertEqual(0, self.lua("return vim.api.nvim_win_get_cursor(0)[2]"))
        self.assertEqual(top, self.lua("return vim.fn.winsaveview().topline"))
        self.assertTrue(self.lua("return vim.w.read_mode_active == true"))
        # E385 is the expected error; keep teardown's v:errmsg check clean.
        self.lua("vim.v.errmsg = '' return true")
