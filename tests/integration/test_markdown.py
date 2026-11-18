from tmux_case import TmuxCase


class Markdown(TmuxCase):
    def test_tall_image_scrolls_inside_a_bounded_viewport(self):
        image = self.project / 'tall.png'
        image.write_bytes(b'\x89PNG\r\n\x1a\n' + bytes(8)
                          + (548).to_bytes(4, 'big') + (5000).to_bytes(4, 'big'))
        source = 'before\n![image](tall.png)\nafter\n'
        self.file('image.md', source)
        self.command("lua vim.g.rendermark_img_stub=true; require('nvim_config.rendermark.image').setup({})")
        self.command('edit image.md')
        self.keys('2', 'G')
        self.wait_lua("return vim.fn.line('.')", 2)
        self.wait_screen('548x5000px y=0/')
        geometry = self.lua("for _, e in pairs(_G.__rendermark_image_backend.stub_store) do "
                            "if e.opts.buf == vim.api.nvim_get_current_buf() then return e.opts end end")
        height = self.lua('return vim.api.nvim_win_get_height(0)')
        self.assertEqual(height, geometry['virt_height'])
        self.assertEqual(548, geometry['display_width_px'])
        maximum = ((5000 - height * 18 + 17) // 18) * 18

        offset = ("for _, e in pairs(_G.__rendermark_image_backend.stub_store) do "
                  "if e.opts.buf == vim.api.nvim_get_current_buf() then "
                  "return e.opts.text_grid_row*18-e.opts.dest_y_px end end")
        self.keys('10', 'j')
        self.wait_lua(offset, 180)
        self.assertEqual(2, self.lua("return vim.fn.line('.')"))
        self.wait_screen('y=180/')
        self.keys(str((maximum - 180) // 18), 'j')
        self.wait_lua(offset, maximum)
        self.assertEqual(2, self.lua("return vim.fn.line('.')"))
        self.keys('j')
        self.wait_lua("return vim.fn.line('.')", 3)
        self.keys('k')
        self.wait_lua("return vim.fn.line('.')", 2)
        self.wait_lua(offset, maximum)

        self.keys('Space', 'r')
        self.wait_lua('return vim.w.read_mode_active == true', True)
        self.keys('k')
        self.wait_lua(offset, maximum - 18)
        self.keys('Escape')
        self.wait_lua('return vim.w.read_mode_active == true', False)
        self.assertEqual(source.splitlines(), self.lua('return vim.api.nvim_buf_get_lines(0,0,-1,false)'))
        self.assertFalse(self.lua('return vim.bo.modified'))

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
