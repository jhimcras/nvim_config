from tmux_case import TmuxCase


class Windows(TmuxCase):
    def test_reopen_mapping_restores_split_side_file_and_cursor(self):
        self.file("second.txt", "one\ntwo\nthree\nfour\n")
        self.command("vsplit second.txt")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 2)
        self.keys("3", "G", "l")
        self.wait_lua("return vim.api.nvim_win_get_cursor(0)", [3, 1])
        side = self.lua("return vim.fn.winlayout()[2][2][2] == vim.api.nvim_get_current_win()")
        self.command("close")
        self.wait_lua("return require('nvim_config.reopen').depth()", 1)
        self.keys("Space", "u")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 2)
        self.assertEqual("second.txt", self.lua("return vim.fn.expand('%:t')"))
        self.assertEqual([3, 1], self.lua("return vim.api.nvim_win_get_cursor(0)"))
        self.assertEqual(side, self.lua(
            "return vim.fn.winlayout()[2][2][2] == vim.api.nvim_get_current_win()"))

    def test_read_mode_mapping_restores_editing_and_statusline(self):
        cursor = self.lua("return vim.o.guicursor")
        options = self.lua("return {vim.wo.cursorline, vim.wo.relativenumber, vim.wo.scrolloff}")
        self.keys("Space", "r")
        self.wait_lua("return vim.w.read_mode_active == true", True)
        self.assertFalse(self.lua("return vim.bo.modifiable"))
        self.assertIn("StatuslineGeneralActive_1_read", self.statusline())
        self.keys("Escape")
        self.wait_lua("return vim.w.read_mode_active == true", False)
        self.assertTrue(self.lua("return vim.bo.modifiable"))
        self.assertEqual(cursor, self.lua("return vim.o.guicursor"))
        self.assertEqual(options, self.lua(
            "return {vim.wo.cursorline, vim.wo.relativenumber, vim.wo.scrolloff}"))
        self.assertNotIn("StatuslineGeneralActive_1_read", self.statusline())
