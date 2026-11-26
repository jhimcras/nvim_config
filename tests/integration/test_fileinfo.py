from tmux_case import TmuxCase


class FileInfo(TmuxCase):
    def test_cursor_column_is_one_based(self):
        self.file("abc.txt", "abcdef\n")
        self.command("edit abc.txt")
        for keys, col in ((("g", "g", "0"), 1), (("l",), 2)):
            self.keys(*keys)
            self.wait_lua("return vim.fn.col('.')", col)
            self.command("FileInfo")
            self.wait_screen(f"Line 1, Col {col} ")
            self.keys("q")
            self.wait_lua("return vim.api.nvim_win_get_config(0).relative", "")

    def test_narrow_window_shows_path_end_and_metadata(self):
        rel = "customer-migration-documentation/production-rollout-configuration/report.txt"
        self.file(rel, "sample report\n")
        self.command("edit " + rel)
        self.tmux("resize-window", "-t", "test:0", "-x", "60", "-y", "24")
        self.wait_lua("return vim.o.columns", 60)
        self.command("FileInfo")
        self.wait_screen("Encoding")
        screen = self.screen()
        popup = [line for line in screen.splitlines() if "\u2502" in line]
        for text in ("report.txt", "Encoding", "Size", "Cursor"):
            self.assertTrue(any(text in line for line in popup), text)
        self.keys("q")
        self.tmux("resize-window", "-t", "test:0", "-x", "180", "-y", "24")
        self.wait_lua("return vim.o.columns", 180)
        self.command("FileInfo")
        self.wait_screen("Encoding")
        self.assertIn(rel, self.screen().replace("\n", ""))
        self.assertIn("Size", self.screen())
