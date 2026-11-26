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

    def test_reopen_keeps_window_local_directory(self):
        self.file("target.txt", "ROOT_TARGET\n")
        self.file("sub/editor.txt", "EDITOR\n")
        self.file("sub/target.txt", "SUB_TARGET\n")
        self.command("vsplit sub/editor.txt")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 2)
        self.command("lcd sub")
        before = self.lua("return vim.fn.getcwd()")
        self.command("close")
        self.wait_lua("return require('nvim_config.reopen').depth()", 1)
        self.command("Reopen")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 2)
        self.assertEqual(1, self.lua("return vim.fn.haslocaldir()"))
        self.assertEqual(before, self.lua("return vim.fn.getcwd()"))
        self.command("edit target.txt")
        self.assertEqual("SUB_TARGET", self.lua("return vim.fn.getline(1)"))
        self.assertTrue(self.lua("return vim.api.nvim_buf_get_name(0)").endswith("/sub/target.txt"))
        self.command("wincmd p")
        self.assertEqual(0, self.lua("return vim.fn.haslocaldir()"))

    def test_reopen_restores_full_height_window_beside_nested_split(self):
        for name in ("left.txt", "upper.txt", "lower.txt", "right.txt"):
            self.file(name, name + "\n")
        self.command("edit left.txt")
        self.command("rightbelow vsplit upper.txt")
        self.command("belowright split lower.txt")
        self.command("botright vsplit right.txt")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 4)
        layout = (
            "local function walk(node) if node[1] == 'leaf' then return "
            "vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(node[2])), ':t') "
            "end local kids = {} for _, child in ipairs(node[2]) do kids[#kids + 1] = walk(child) end "
            "return {node[1], kids} end return walk(vim.fn.winlayout())")
        before = self.lua(layout)
        self.assertEqual(["row", ["left.txt", ["col", ["upper.txt", "lower.txt"]], "right.txt"]],
                         before)
        self.command("close")
        self.wait_lua("return require('nvim_config.reopen').depth()", 1)
        self.command("Reopen")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 4)
        self.assertEqual(before, self.lua(layout))
        self.assertEqual("right.txt", self.lua("return vim.fn.expand('%:t')"))

    def test_reopen_tab_without_room_keeps_record_until_resized(self):
        names = [f"part{i}.txt" for i in range(1, 6)]
        for name in names:
            self.file(name, name + "\n")
        self.command("tabnew part1.txt")
        for name in names[1:]:
            self.command("split " + name)
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 5)
        self.command("tabclose")
        self.wait_lua("return require('nvim_config.reopen').depth()", 1)
        self.tmux("resize-window", "-t", "test:0", "-x", "120", "-y", "8")
        self.wait_lua("return vim.o.lines", 8)
        self.command("Reopen")
        self.assertIn("Not enough room", self.lua(
            "return vim.api.nvim_exec2('messages', {output=true}).output"))
        self.assertEqual([1, 1, "main.txt", 1], self.lua(
            "return {vim.fn.tabpagenr('$'), #vim.api.nvim_tabpage_list_wins(0), "
            "vim.fn.expand('%:t'), require('nvim_config.reopen').depth()}"))
        self.assertEqual("", self.lua("return vim.v.errmsg"))
        self.tmux("resize-window", "-t", "test:0", "-x", "120", "-y", "40")
        self.wait_lua("return vim.o.lines", 40)
        self.command("Reopen")
        self.wait_lua("return vim.fn.tabpagenr('$')", 2)
        # :split puts each new window above, so the last split is on top.
        self.assertEqual(list(reversed(names)), self.lua(
            "local names = {} for _, leaf in ipairs(vim.fn.winlayout()[2]) do "
            "names[#names + 1] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name("
            "vim.api.nvim_win_get_buf(leaf[2])), ':t') end return names"))
        self.assertEqual(0, self.lua("return require('nvim_config.reopen').depth()"))

    def test_reopen_window_without_room_keeps_records_until_resized(self):
        names = [f"part{i}.txt" for i in range(1, 5)]
        for name in names:
            self.file(name, name + "\n")
        for name in names:
            self.command("split " + name)
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 5)
        layout = (
            "local names = {} for _, leaf in ipairs(vim.fn.winlayout()[2]) do "
            "names[#names + 1] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name("
            "vim.api.nvim_win_get_buf(leaf[2])), ':t') end return names")
        # An older record below the one that will not fit.
        self.command("execute bufwinnr('part1.txt') .. 'close'")
        self.wait_lua("return require('nvim_config.reopen').depth()", 1)
        self.command("execute bufwinnr('part3.txt') .. 'close'")
        self.wait_lua("return require('nvim_config.reopen').depth()", 2)
        before = ["part4.txt", "part2.txt", "main.txt"]
        self.assertEqual(before, self.lua(layout))
        current = self.lua("return vim.api.nvim_get_current_win()")
        self.tmux("resize-window", "-t", "test:0", "-x", "120", "-y", "8")
        self.wait_lua("return vim.o.lines", 8)
        sizes = self.lua("return vim.fn.winrestcmd()")
        self.command("Reopen")
        self.assertIn("Not enough room to reopen the closed window", self.lua(
            "return vim.api.nvim_exec2('messages', {output=true}).output"))
        self.assertEqual(before, self.lua(layout))
        self.assertEqual(sizes, self.lua("return vim.fn.winrestcmd()"))
        self.assertEqual([1, current, 2], self.lua(
            "return {vim.fn.tabpagenr('$'), vim.api.nvim_get_current_win(), "
            "require('nvim_config.reopen').depth()}"))
        self.assertEqual("", self.lua("return vim.v.errmsg"))
        self.tmux("resize-window", "-t", "test:0", "-x", "120", "-y", "40")
        self.wait_lua("return vim.o.lines", 40)
        self.command("Reopen")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 4)
        self.assertEqual(["part4.txt", "part3.txt", "part2.txt", "main.txt"], self.lua(layout))
        self.assertEqual("part3.txt", self.lua("return vim.fn.expand('%:t')"))
        self.assertEqual(1, self.lua("return require('nvim_config.reopen').depth()"))

    def test_reopen_loclist_without_room_keeps_records_until_resized(self):
        names = [f"part{i}.txt" for i in range(1, 4)]
        for name in names:
            self.file(name, name + "\n")
        for name in names:
            self.command("split " + name)
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 4)
        layout = (
            "local names = {} for _, leaf in ipairs(vim.fn.winlayout()[2]) do "
            "local buf = vim.api.nvim_win_get_buf(leaf[2]) "
            "names[#names + 1] = vim.bo[buf].buftype == 'quickfix' and 'loclist' or "
            "vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t') end return names")
        # An older record below the one that will not fit.
        self.command("execute bufwinnr('part1.txt') .. 'close'")
        self.wait_lua("return require('nvim_config.reopen').depth()", 1)
        self.command("execute bufwinnr('main.txt') .. 'wincmd w'")
        origin = self.lua("return vim.api.nvim_get_current_win()")
        self.lua("return vim.fn.setloclist(0, {}, ' ', {title = 'hits', items = {"
                 "{filename = 'part2.txt', lnum = 1, text = 'part2'},"
                 "{filename = 'part3.txt', lnum = 1, text = 'part3'}}})")
        self.command("lopen")
        self.wait_lua("return vim.bo.buftype", "quickfix")
        self.command("lclose")
        self.wait_lua("return require('nvim_config.reopen').depth()", 2)
        before = ["part3.txt", "part2.txt", "main.txt"]
        self.assertEqual(before, self.lua(layout))
        # Stand somewhere other than the origin so a stray focus change shows.
        self.command("execute bufwinnr('part3.txt') .. 'wincmd w'")
        current = self.lua("return vim.api.nvim_get_current_win()")
        self.tmux("resize-window", "-t", "test:0", "-x", "120", "-y", "8")
        self.wait_lua("return vim.o.lines", 8)
        sizes = self.lua("return vim.fn.winrestcmd()")
        self.command("Reopen")
        self.assertIn("Not enough room to reopen the closed window", self.lua(
            "return vim.api.nvim_exec2('messages', {output=true}).output"))
        self.assertEqual(before, self.lua(layout))
        self.assertEqual(sizes, self.lua("return vim.fn.winrestcmd()"))
        self.assertEqual([1, current, 2], self.lua(
            "return {vim.fn.tabpagenr('$'), vim.api.nvim_get_current_win(), "
            "require('nvim_config.reopen').depth()}"))
        self.assertEqual("", self.lua("return vim.v.errmsg"))
        self.tmux("resize-window", "-t", "test:0", "-x", "120", "-y", "40")
        self.wait_lua("return vim.o.lines", 40)
        self.command("Reopen")
        self.wait_lua("return #vim.api.nvim_tabpage_list_wins(0)", 4)
        self.assertEqual(["part3.txt", "part2.txt", "main.txt", "loclist"], self.lua(layout))
        self.assertEqual(["quickfix", origin, "hits"], self.lua(
            "local info = vim.fn.getloclist(0, {filewinid = 0, title = 0}) "
            "return {vim.bo.buftype, info.filewinid, info.title}"))
        self.assertEqual(1, self.lua("return require('nvim_config.reopen').depth()"))

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

    def test_read_mode_buffer_switch_restores_editing_of_previous_file(self):
        self.file("other.txt", "beta\ncharlie\n")
        self.keys("Space", "r")
        self.wait_lua("return vim.w.read_mode_active == true", True)
        self.command("edit other.txt")
        self.wait_lua("return vim.fn.expand('%:t')", "other.txt")
        self.assertTrue(self.lua("return vim.w.read_mode_active == true"))
        self.assertFalse(self.lua("return vim.bo.modifiable"))
        self.keys("Escape")
        self.wait_lua("return vim.w.read_mode_active == true", False)
        self.command("edit main.txt")
        self.wait_lua("return vim.fn.expand('%:t')", "main.txt")
        self.assertEqual([True, True], self.lua(
            "return {vim.bo[vim.fn.bufnr('main.txt')].modifiable, "
            "vim.bo[vim.fn.bufnr('other.txt')].modifiable}"))
        self.keys("i")
        self.tmux("send-keys", "-t", "test:0.0", "-l", "X")
        self.keys("Escape")
        self.wait_lua("return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]", "Xalpha")
