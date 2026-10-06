from tmux_case import TmuxCase


class Markdown(TmuxCase):
    def test_table_wrap_checkbox_and_read_mode_render_without_editing_source(self):
        source = ("# Heading\n\n- [ ] task\n\n"
                  "| Name | Value |\n| --- | --- |\n| 한글 | content |\n\n"
                  + "A long paragraph with words for wrapping. " * 8 + "\n")
        self.file("note.md", source)
        self.command("edit note.md")
        self.wait_lua("return vim.bo.filetype", "markdown")
        self.wait_lua("return vim.b.markdown_visual_wrap == true", True)
        self.keys("G")
        self.wait_lua("return vim.fn.line('.')", 9)
        self.keys("Space", "r")
        self.wait_lua("return vim.w.read_mode_active == true", True)
        # Virtual lines show table borders and wrapped text; the source stays intact.
        rendered = self.lua("local lines={}; for _, ns in pairs(vim.api.nvim_get_namespaces()) do "
                            "for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, "
                            "{details=true, type='virt_lines'})) do "
                            "for _, row in ipairs(mark[4].virt_lines or {}) do "
                            "local s=''; for _, chunk in ipairs(row) do s=s..chunk[1] end; "
                            "lines[#lines+1]=s end end end; return lines")
        self.assertTrue(any("┌" in line for line in rendered), rendered)
        self.assertTrue(any("paragraph" in line for line in rendered), rendered)
        self.wait_screen("│ 한글 │ content │")
        self.assertEqual(source.splitlines(), self.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"))
        self.assertFalse(self.lua("return vim.bo.modified"))
        self.keys("Escape")
        self.wait_lua("return vim.w.read_mode_active == true", False)
        self.keys("3", "G", "C-Space")
        self.wait_lua("return vim.api.nvim_get_current_line()", "- [x] task")
        self.assertTrue(self.lua("return vim.bo.modified"))
