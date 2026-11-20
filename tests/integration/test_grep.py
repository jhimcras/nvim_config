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

    def test_dd_honors_count(self):
        self.file("main.txt", "needle alpha\nneedle bravo\nneedle charlie\nneedle delta\n")
        self.command("Grep needle")
        self.wait_lua("return vim.bo.buftype", "quickfix")
        self.wait_lua("return vim.w.grep_status", "done")
        self.wait_lua("return #vim.fn.getloclist(0)", 4)
        self.keys("g", "g", "2", "d", "d")
        self.wait_lua("return #vim.fn.getloclist(0)", 2)
        self.assertEqual([3, 4], self.lua(
            "local l={}; for _, i in ipairs(vim.fn.getloclist(0)) do l[#l+1]=i.lnum end; return l"))

    def test_lfilter_on_100k_results_keeps_owner_and_jump(self):
        for file in range(100):
            self.file(f"f{file:03}.txt", "".join(
                f"needle {'keepmark' if (file * 1000 + line) % 100 == 1 else 'dropmark'} {line}\n"
                for line in range(1000)))
        owner = self.lua("return vim.api.nvim_get_current_win()")
        self.command("Grep needle")
        self.wait_lua("return vim.bo.buftype", "quickfix")
        self.wait_lua("return vim.w.grep_status", "done")
        self.wait_lua("return vim.fn.getloclist(0, {size=0}).size", 100000)
        # rg emits files in no fixed order; sort so the first result is known.
        self.keys("s", "n")
        self.wait_lua("return vim.w.sort_order", "asc")
        self.keys("g", "g")
        self.command("Lfilter /keepmark/")
        self.wait_lua("return vim.fn.getloclist(0, {size=0}).size", 1000)
        self.assertEqual(owner, self.lua("return vim.fn.getloclist(0, {filewinid=0}).filewinid"))
        self.assertEqual(1000, self.lua("return vim.fn.getloclist(" + str(owner) + ", {size=0}).size"))
        self.assertEqual(["keepmark"], self.lua("return require('nvim_config.qflist.filter').get_filter_chain(0)"))
        self.keys("g", "g", "Enter")
        self.wait_lua("return vim.fn.expand('%:t')", "f000.txt")
        self.assertEqual(owner, self.lua("return vim.api.nvim_get_current_win()"))
        self.assertEqual([2, 0], self.lua("return vim.api.nvim_win_get_cursor(0)"))
        self.assert_no_errors()
