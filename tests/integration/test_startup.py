from tmux_case import ROOT, TmuxCase


class Startup(TmuxCase):
    def test_loads_checkout_and_evaluates_statusline_tabline_and_string_commands(self):
        # A worktree must not pass by loading the user's installed copy instead.
        loaded_from = self.lua("return debug.getinfo(require('nvim_config.launcher').Launch, 'S').source:sub(2)")
        self.assertTrue(loaded_from.startswith(str(ROOT / "lua" / "nvim_config") + "/"), loaded_from)
        self.assertEqual(str(self.project), self.lua(
            "return require('nvim_config.prjroot').GetCurrentProjectRoot()"))
        for command in ("Grep", "Lfilter", "ProcessList", "SaveSession", "Reopen",
                        "MoveBufferToInstance", "MoveTabToInstance"):
            self.assertEqual(2, self.lua(f"return vim.fn.exists(':{command}')"), command)
        # Evaluate the configured expressions, catching stale require paths after moves.
        self.assertGreater(self.lua("return vim.api.nvim_eval_statusline(vim.o.statusline, "
                                   "{winid=vim.api.nvim_get_current_win()}).width"), 0)
        self.assertGreater(self.lua("return vim.api.nvim_eval_statusline(vim.o.tabline, "
                                   "{use_tabline=true}).width"), 0)
        self.command("FileInfo")
        self.wait_screen("main.txt")

    def test_tabline_preserves_literal_percent_pairs_in_file_names(self):
        percent_name = "report%%done.txt"
        ordinary_name = "ordinary.txt"
        self.file(percent_name, "report\n")
        self.file(ordinary_name, "ordinary\n")
        self.command(r"edit report\%\%done.txt")
        self.command("tabedit ordinary.txt")

        for index, current_name in enumerate((ordinary_name, percent_name, ordinary_name)):
            if index:
                self.keys("g", "t")
            self.wait_lua("return vim.fn.expand('%:t')", current_name)
            self.command("redraw!")
            tabline = self.tmux("capture-pane", "-p", "-t", "test:0.0").splitlines()[0]
            self.assertIn(percent_name, tabline)
            self.assertIn(ordinary_name, tabline)

    def test_header_detection_and_external_file_reload_use_real_autocmds(self):
        self.file("header.h", "int value;\n")
        self.command("edit header.h")
        self.wait_lua("return vim.bo.filetype", "c")
        self.file("cpp_header.cpp", "int value = 1;\n")
        self.file("cpp_header.h", "int value;\n")
        self.command("edit cpp_header.h")
        self.wait_lua("return vim.bo.filetype", "cpp")
        self.file("cpp_header.h", "int changed_on_disk;\n")
        self.command("doautocmd FocusGained")
        self.wait_lua("return vim.api.nvim_get_current_line()", "int changed_on_disk;")
