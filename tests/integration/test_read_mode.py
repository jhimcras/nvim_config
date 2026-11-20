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
