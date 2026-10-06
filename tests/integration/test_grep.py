from tmux_case import TmuxCase


class Grep(TmuxCase):
    def test_rg_filter_sort_delete_and_jump_preserve_list_owner(self):
        self.file("a.txt", "needle keep\nneedle drop\nother\n")
        self.file("z.txt", "other\nneedle keep\n")
        owner = self.lua("return vim.api.nvim_get_current_win()")
        self.command("Grep needle")
        self.wait_lua("return vim.bo.buftype", "quickfix")
        self.wait_lua("return vim.w.grep_status", "done")
        self.wait_lua("return #vim.fn.getloclist(0)", 3)
        self.assertEqual(owner, self.lua("return vim.fn.getloclist(0, {filewinid=0}).filewinid"))
        self.command("Lfilter /keep/")
        self.wait_lua("return #vim.fn.getloclist(0)", 2)
        self.assertEqual(["keep"], self.lua("return require('nvim_config.qflist.filter').get_filter_chain(0)"))
        self.keys("s", "n")
        self.wait_lua("return vim.w.sort_order", "asc")
        self.assertEqual(["a.txt", "z.txt"], self.lua(
            "local names={}; for _, i in ipairs(vim.fn.getloclist(0)) do "
            "names[#names+1]=vim.fn.fnamemodify(vim.fn.bufname(i.bufnr), ':t') end; return names"))
        self.keys("d", "d")
        self.wait_lua("return #vim.fn.getloclist(0)", 1)
        self.keys("Enter")
        self.wait_lua("return vim.fn.expand('%:t')", "z.txt")
        self.assertEqual(owner, self.lua("return vim.api.nvim_get_current_win()"))
        self.assertEqual([2, 0], self.lua("return vim.api.nvim_win_get_cursor(0)"))
        self.command("lclose")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 1)
        self.command("lopen")
        self.wait_lua("return vim.bo.buftype", "quickfix")
        self.assertEqual(1, self.lua("return #vim.fn.getloclist(0)"))
        self.assertEqual(owner, self.lua("return vim.fn.getloclist(0, {filewinid=0}).filewinid"))
        self.assertEqual(self.lua(f"return vim.w[{owner}].loclist_tag"),
                         self.lua("return vim.w.loclist_tag"))
        self.assertEqual(0, self.lua("return #require('nvim_config.launcher').GetRunningProcesses()"))
