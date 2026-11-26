import re
import time

from tmux_case import TmuxCase


class Markdown(TmuxCase):
    def test_markdown_does_not_start_an_lsp_client(self):
        # core excludes external LSP processes even when the host has mdloom.
        self.file('plain.md', '# title\n\ntext\n')
        self.command('edit plain.md')
        self.wait_lua('return vim.bo.filetype', 'markdown')
        self.assertEqual('', self.lua("return table.concat(vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients()), ',')"))

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

    def test_tall_image_offset_survives_edits_on_other_lines(self):
        (self.project / 'tall.png').write_bytes(b'\x89PNG\r\n\x1a\n' + bytes(8)
                                                + (200).to_bytes(4, 'big') + (1500).to_bytes(4, 'big'))
        self.file('image2.md', 'before\n![a](tall.png)\nmid\n![b](tall.png)\nafter\ntail\n')
        self.command("lua vim.g.rendermark_img_stub=true; require('nvim_config.rendermark.image').setup({})")
        self.command('edit image2.md')
        self.keys('2', 'G')
        self.wait_lua("return vim.fn.line('.')", 2)
        self.wait_screen('200x1500px y=0/')
        # Image a's GUI origin and the y= offsets shown by every stub label, by source row.
        state = ("local a for _, e in pairs(_G.__rendermark_image_backend.stub_store) do "
                 "if e.opts.row == 1 then a = e.opts.dest_y_px end end "
                 "local labels = {} for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {details=true})) do "
                 "for _, l in ipairs(m[4].virt_lines or {}) do for _, c in ipairs(l) do "
                 "local y = type(c[1]) == 'string' and c[1]:match('y=(%d+)/') "
                 "if y then labels[#labels+1] = tonumber(y) end end end end "
                 "return {a, labels}")
        height = self.lua('return vim.api.nvim_win_get_height(0)')
        maximum = ((1500 - height * 18 + 17) // 18) * 18
        self.keys(str(maximum // 18), 'j')
        self.wait_screen('y=%d/' % maximum)
        self.assertEqual(2, self.lua("return vim.fn.line('.')"))
        self.keys('j')
        self.wait_lua("return vim.fn.line('.')", 3)
        self.keys('j')
        self.wait_lua("return vim.fn.line('.')", 4)
        before = self.lua(state)
        self.assertIn(maximum, before[1])
        self.keys('A', 'X', 'Escape')
        self.wait_lua("return vim.fn.getline(4)", '![b](tall.png)X')
        self.wait_lua('return vim.fn.mode()', 'n')
        # Trailing text makes b an inline (unscrolled) image; a keeps its offset.
        self.wait_lua(state, [before[0], [maximum]])
        self.keys('u')
        self.wait_lua("return vim.fn.getline(4)", '![b](tall.png)')
        self.wait_lua(state, before)

    def test_tall_image_returns_when_its_fold_opens(self):
        (self.project / 'tall.png').write_bytes(b'\x89PNG\r\n\x1a\n' + bytes(8)
                                                + (548).to_bytes(4, 'big') + (5000).to_bytes(4, 'big'))
        self.file('image.md', 'before\n![image](tall.png)\nafter\n' + ''.join('l%d\n' % i for i in range(1, 6)))
        self.command("lua vim.g.rendermark_img_stub=true; require('nvim_config.rendermark.image').setup({})")
        self.command('edit image.md')
        self.command('setlocal foldmethod=manual')
        self.keys('2', 'G')
        self.wait_lua("return vim.fn.line('.')", 2)
        self.wait_screen('548x5000px y=0/')
        count = "local n=0 for _ in pairs(_G.__rendermark_image_backend.stub_store) do n=n+1 end return n"
        self.keys('z', 'f', 'j')
        self.keys('z', 'c')
        self.wait_lua('return vim.fn.foldclosed(2)', 2)
        self.wait_lua(count, 0)
        self.keys('z', 'o')
        # No further input: the box must come back by itself within 1s.
        self.timeout = 1
        try:
            self.wait_lua(count, 1)
            self.wait_screen('548x5000px y=0/')
        finally:
            del self.timeout
        self.assertEqual(-1, self.lua('return vim.fn.foldclosed(2)'))

    def test_image_scroll_keys_keep_typeahead_order_like_plain_text(self):
        self.command("lua vim.g.rendermark_img_stub=true; require('nvim_config.rendermark.image').setup({})")
        results = {}
        for name in ('m.txt', 'm.md'):
            self.file(name, 'aaa\nbbb\nccc\nddd\n')
            self.command('edit ' + name)
            if name == 'm.md':
                self.wait_lua("return vim.fn.maparg('j', 'n', false, true).buffer", 1)
            self.keys('g', 'g')
            self.wait_lua("return vim.fn.line('.')", 1)
            # Both keys in one send: x is already in typeahead when j's mapping runs.
            self.keys('j', 'x')
            self.wait_lua('return vim.bo.modified', True)
            typed = self.lua("return {vim.api.nvim_buf_get_lines(0,0,-1,false), vim.fn.line('.')}")
            self.command("call setreg('a', 'jx')")
            self.keys('@', 'a')
            self.wait_lua("return #table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false))", 10)
            replayed = self.lua("return {vim.api.nvim_buf_get_lines(0,0,-1,false), vim.fn.line('.')}")
            results[name] = (typed, replayed)
        self.assertEqual([[['aaa', 'bb', 'ccc', 'ddd'], 2], [['aaa', 'bb', 'cc', 'ddd'], 3]],
                         list(map(list, results['m.txt'])))
        self.assertEqual(results['m.txt'], results['m.md'])

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

    def test_table_rewraps_after_vsplit_while_other_window_has_focus(self):
        row = "| alpha beta gamma delta | alpha beta gamma delta | alpha beta gamma delta |\n"
        self.file("table.md", "# Data\n\n| first | second | THIRDTAG |\n| --- | --- | --- |\n" + row * 3)
        self.file("side.txt", "SIDE-PANEL\n")
        self.command("edit table.md")
        self.wait_lua("return vim.b.markdown_visual_wrap == true", True)
        self.wait_screen("THIRDTAG")
        self.command("vsplit side.txt")
        self.wait_lua("return vim.fn.expand('%:t')", "side.txt")
        windows = "local r={} for _,w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do r[#r+1]=vim.api.nvim_win_get_width(w) end return r"
        self.assertIn(59, self.lua(windows))
        self.wait_screen("SIDE-PANEL")
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            screen = self.screen()
            if "THIRDTAG" in screen and re.search(r"THIRDTAG[^\n]*│", screen):
                return
            time.sleep(0.05)
        self.fail("table clipped after split:\n" + self.screen())

    def test_checkbox_bulk_toggle_of_2000_rows_is_fast_and_one_undo(self):
        self.file("c.md", "".join(f"- [ ] task-{i:04d}\n" for i in range(1, 2001)))
        self.command("edit c.md")
        self.wait_lua("return vim.b.markdown_visual_wrap == true", True)
        self.wait_screen("[ ] task-0001")
        count = "local n=0 for _,s in ipairs(vim.api.nvim_buf_get_lines(0,0,-1,false)) do if s:find('- [x]',1,true)==1 then n=n+1 end end return n"
        durations = []
        for _ in range(3):
            self.keys("g", "g", "V", "G")
            self.wait_lua("return vim.fn.mode()", "V")
            start = time.monotonic()
            self.keys("C-Space")
            while "[x] task-0001" not in self.screen():
                self.assertLess(time.monotonic() - start, 5)
                time.sleep(0.01)
            durations.append((time.monotonic() - start) * 1000)
            self.wait_lua(count, 2000)
            self.keys("u")
            self.wait_lua(count, 0)
            self.wait_screen("[ ] task-0001")
        durations.sort()
        self.assertLess(durations[1], 250, durations)

    def test_large_table_cell_edit_shows_first_character_quickly(self):
        rows = ["| Index | Reading | Source | Comment |", "| --- | --- | --- | --- |"]
        rows += [f"| {i:04d} | Value{i:04d} | Sensor A | Reviewed |" for i in range(1, 3001)]
        self.file("big.md", "\n".join(rows) + "\n")
        self.command("edit big.md")
        self.wait_lua("return vim.b.markdown_visual_wrap == true", True)
        self.wait_screen("Value0001")
        durations = []
        for number, row in enumerate((1502, 1700, 2100), 1):
            value = "Value%04d" % (row - 2)
            self.command(f"call cursor({row}, 18)")
            self.wait_screen(value)
            self.keys("a")
            self.wait_lua("return vim.fn.mode()", "i")
            start = time.monotonic()
            self.keys("X")
            while value + "X" not in self.screen():
                self.assertLess(time.monotonic() - start, 5)
                time.sleep(0.005)
            durations.append((time.monotonic() - start) * 1000)
            self.keys("Escape", "j")
            self.wait_lua("return vim.fn.line('.')", row + 1)
            self.assertEqual(f"| {row - 2:04d} | {value}X | Sensor A | Reviewed |",
                             self.lua(f"return vim.api.nvim_buf_get_lines(0, {row - 1}, {row}, false)[1]"))
        durations.sort()
        self.assertLess(durations[1], 100, durations)
