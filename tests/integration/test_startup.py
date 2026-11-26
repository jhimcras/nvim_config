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

    def test_tabline_shows_truncated_title_when_active_title_exceeds_width(self):
        long_name = "customer_invoice_reconciliation_report_for_november_with_manual_adjustments_and_audit_notes.txt"
        self.file(long_name, "long\n")
        self.command("tabedit " + long_name)
        self.tmux("resize-window", "-t", "test:0", "-x", "72", "-y", "40")
        self.wait_lua("return vim.o.columns", 72)
        self.keys("g", "t")
        self.wait_lua("return vim.fn.expand('%:t')", "main.txt")
        self.keys("g", "t")
        self.wait_lua("return vim.fn.expand('%:t')", long_name)
        self.command("redraw!")
        tabline = self.tmux("capture-pane", "-p", "-t", "test:0.0").splitlines()[0]
        self.assertIn("audit_notes.txt", tabline)
        self.tmux("resize-window", "-t", "test:0", "-x", "120", "-y", "40")
        self.wait_lua("return vim.o.columns", 120)
        self.command("redraw!")
        tabline = self.tmux("capture-pane", "-p", "-t", "test:0.0").splitlines()[0]
        self.assertIn(long_name, tabline)

    def test_wipe_hidden_buffers_keeps_modified_and_wipes_clean(self):
        self.file("clean.txt", "clean\n")
        self.file("other.txt", "other\n")
        self.command("edit clean.txt")
        self.command("edit main.txt")
        self.keys("o")
        self.tmux("send-keys", "-t", "test:0.0", "-l", "UNSAVED_NOTE")
        self.keys("Escape")
        self.command("edit other.txt")
        self.wait_lua("return vim.fn.getbufinfo({bufloaded=1})[1] ~= nil", True)
        self.command("WipeHiddenBuffers")
        names = self.lua("local r = {} for _, b in ipairs(vim.api.nvim_list_bufs()) do "
                         "if vim.fn.buflisted(b) == 1 then r[#r+1] = vim.fn.fnamemodify("
                         "vim.api.nvim_buf_get_name(b), ':t') end end return r")
        self.assertIn("main.txt", names)
        self.assertNotIn("clean.txt", names)
        self.command("edit main.txt")
        self.assertEqual(True, self.lua("return vim.bo.modified"))
        self.assertIn("UNSAVED_NOTE", self.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"))

    def test_json_pretty_reports_duplicate_key_and_keeps_buffer(self):
        dup = '{"policy":"deny","nested":{"a":1},"policy":"allow","keep":true}'
        self.file("dup.json", dup + "\n")
        self.command("edit dup.json")
        self.command("JsonPretty")
        self.assertEqual([dup], self.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"))
        self.assertFalse(self.lua("return vim.bo.modified"))
        self.assertIn("Duplicate JSON key", self.lua(
            "return vim.api.nvim_exec2('messages', {output=true}).output"))
        self.file("uniq.json", '{"policy":"deny","nested":{"a":1},"b":{"a":2},"keep":true}\n')
        self.command("edit uniq.json")
        self.command("JsonPretty")
        self.assertEqual('{', self.lua("return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]"))
        lines = self.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
        self.assertIn('  "policy": "deny",', lines)
        self.assertIn('  "keep": true', lines)

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
