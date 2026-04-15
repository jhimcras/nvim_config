# Neovim Configuration TODOs

---

## Core / General Settings

- [x] Annoyed by the gray lines between windows; switched to lines and updated the font.
- [x] Enable Neovim on Windows as well.
- [x] Evaluate whether relative line numbers are helpful; sometimes they come in handy.
- [x] Bind F2 to rename; need to build an interactive interface to accept input.
- [x] Explore Neovim's built-in package management to see if I can move away from `vim-plug`. It would be great to create a custom plugin manager, as I haven't found a reliable way to reload plugins. Sticking with `vim-plug` for now.
- [x] Refine configuration reloading. `so%` has limitations.
  - Basic configuration works with `so $MYVIMRC`, but need to prevent redundant execution.
  - Since Lua plugins are already required, can I just set packages to `nil`?
    - `package.loaded` contains global data like `_G`, making batch deletion tricky.
    - Implemented a targeted reset for specific files.
- [x] Clean up configuration files.
- [x] Optimize `init.lua` loading. Unlike the old `init.vim` approach, Lua allows for multiple modular configuration files.
  - Place plugins in designated directories and load them using `require`.
  - Use `luafile` at the end of `init.vim` to load `init.lua`.
- [x] Experiment with `set clipboard=unnamedplus`; it seems quite useful.
- [x] `<leader><leader>` mapping caused delays and conflicted with `visual-multi-cursor`. Dropped `visual-multi-cursor`.
- [x] Need to break the habit of using `:w` and use `:update` instead.
- [x] Remove the 'X' button from the right side of the tabline.
- [x] Learn to use `netrw`. `Vinegar` seems promising, but I've opted for `Dirvish` for now, despite some friction with file creation/deletion.
- [x] Setting `GuiPopupmenu 0` looks cleaner.
- [x] Organize `<leader>` mappings more effectively.
- [x] Visual Mode issue: `vim.api.nvim_eval([[getpos("'>")]])` fails to get the correct position until after exiting Visual mode. Solved this by using `line('v')` and `col('v')`.
- [x] Enable custom naming for tabs in the tabline.
- [x] Add tab-completion for Lua functions when typing `lua ...` in the command line.
  - Review `help :command-completion-customlist`.
  - Since built-in commands can't be modified, I may need to recompile Neovim or create wrapper commands like `Lua`.
- [x] Replace the `-` character for `diff` in `fillchars`.
- [x] Automate Lua plugin resetting (using `autocmd BufWritePost *.lua ...`).
- [x] `gq` operator configuration.
- [x] Fixed `Config` and `ConfigLua` commands to prevent inactive windows from defocusing.
- [x] If `Config` is run in an unrelated buffer, overwrite the current buffer instead of opening a new one.
- [x] Add arguments to `Config` to display search results in Telescope.
- [x] Refactor and clean up `init.lua`.
- [x] Fix errors triggered when reloading `init.lua`, particularly `lsp-status` calls during `CursorHold`.
- [ ] Add a feature to execute Lua code snippets directly and handle errors (check out `rafcamlet/nvim-luapad`).
- [ ] Document reviews of plugins I've tested.
- [x] Create a unit testing suite for plugins.
- [x] Investigate why `colorcolumn` intermittently fails to appear.
- [x] Disable `colorcolumn` and focus distinctions when in diff mode.
- [ ] Automatically handle file saving with UTF/BOM modes on Windows.
- [x] Improve `matchparen` performance in large C++ files.
- [x] Enhance highlighting for folded regions in `init.vim`.
  - Implemented `winhighlight` to dynamically change highlights when entering windows. (Note: Only the second query works, need to debug why).
- [ ] When closing a tab, return to the previously active tab instead of the next one.
- [ ] Implement a "reopen recently closed window" feature.
- [x] Create a floating window to display file info.
    - Shows all components from the status line.
    - Allows adding extra metadata.
    - Provides a keymap/command to view details if the window is too narrow.
- [ ] Feature to spawn a new Neovim process (using the current GUI), accessible via command or Telescope.
    - [ ] Open a specific session.
    - [ ] Open a specific file/buffer.
- [ ] Implement an Outline feature.
- [ ] Add a Python debugger.
- [ ] Ensure diff windows are fully unfolded by default.
- [x] Refactor `GetBufferName`, `GetBufferDir`, and `GetCurrentBufferDir` in `util.lua`.
    - Return names regardless of buffer type (strip protocols like `fugitive://`).
    - Implement `GetBufferProtocol` to return the protocol as a string (e.g., `'fugitive'`).
    - Clean up 'oil' buffer handling in `GetBufferName`.


## UI: Statusline / Tabline

- [x] Add LSP info (diagnostics, functions) and Treesitter status to the status line.
- [x] Create a dedicated status line for QuickFix.
- [x] Fix tabline not updating after `tabmove`.
- [x] Display Git branch name (or commit ID) in the status line when not at the branch head.
- [x] Close diagnostic float windows when pressing `<ESC>` in normal mode.
- [x] Redraw status line when pressing `<ESC>` in normal mode.
    - Resolved execution order conflict between `feedkey` and `redraw` by scheduling both.
- [x] Adjust padding: setting padding to 1 without a separator results in a gap of 2; need it to be 1.
- [ ] Optimize status line performance; displaying search counts in large files causes significant slowdowns.
- [ ] Add file format icons next to the filename in the status line.
- [x] Implement dynamic truncation based on priority when columns are narrow.
- [x] Fix status line issues in `checkhealth` and other specialized buffers.
- [ ] Customize status line based on buffer/file types.
    - [x] `checkhealth`: Use simple "CHECK HEALTH" text.
    - [x] `man pager`: Display MAN page name, search count, and cursor position.
- [ ] Fix status line column miscalculation when `<tab>` characters are present.
- [x] Prevent floating window info from appearing in the tabline.
- [x] Manage tabline overflow: when full, show "<" on the left and allow scrolling.
    - Scroll via keymap (`<leader>t` for right, `<leader>T` for left).
    - Ensure session name is always visible on the right.
- [x] Highlight the current tab index if it's hidden due to scrolling.
- [x] Scroll tabline to ensure the current tab is visible when using `gt`/`gT`.
- [x] Implement Telescope tab listing to switch to tabs containing specific files.
- [x] Implement dynamic status line truncation based on window width.
    - Concept: Each component has a compact version and a removal priority.
    - If total text width exceeds the window width, truncate/remove low-priority components iteratively.
- [x] Fix truncated 'fugitive' buffer names in GdiffSplit windows.
- [x] Fix incorrect folder name display for Oil on Linux.
- [ ] Improve tab distinction in the tabline.


## Search: Loupe / Grep

- [x] Enhance `loupe` functionality.
  - Implement "highlight identical words" (similar to `*`) without cursor movement.
  - Ensure `n` and `N` searches always move in the same consistent direction.
- [x] Modify `*` search to avoid jumping initially and display match count.
  - Mapped `#` to `nmap # *N` to utilize its backward-search capability for these features.
- [x] Fixed "No range allowed" error caused by accidental number + `<esc>` inputs.
- [x] Fixed screen jumping after `*` followed by `N` when no other matches exist.
- [x] Prevent UI blocking when async commands (like `rg`) overlap.
- [x] Fixed abnormal current-location highlighting in search; switched to `IncSearch`.


## Quickfix / Location List

- [x] Fix QuickFix root directory issues when searching within an already-focused QuickFix window.
- [x] Add search text highlighting to Grep results in QuickFix.
- [x] Configure QuickFix to show line numbers but hide relative numbers.
- [x] Fixed result truncation issues when reading directly from `onread`.
- [x] Implement `<c-c>` to cancel ongoing Grep tasks.
- [x] Display total match count in the status line.
- [x] Fixed Quickfix stack issues by using `items` instead of `line` in `setloclist`.
- [x] Display Grep status (searching, done, terminated) in the status line.
- [x] Improve status line coloring for QuickFix windows.
- [x] Migrated to Location List.
    - [x] Fixed errors when searching in multiple windows simultaneously.
    - [x] Added indicators (e.g., status line color) to identify which window's list is active.
    - [x] Ensure lists close automatically when the originating window is closed.
    - [x] Queue concurrent Grep searches instead of running them simultaneously.
- [x] Implement line deletion (dd, d{motion}, etc.).
- [x] Preserve highlights after `lolder`/`lnewer` list changes.
- [x] Display `Lfilter`/`Cfilter` changes in the status line.
- [x] Fix bug where LocList titles swap when multiple windows are open.
    - Switched from `%!expr` to pre-rendered format strings in window-local status lines.
- [x] Ensure color tags disappear when LocList is closed and reappear upon reopening.


## Project Root

- [x] New `.prjroot` template using `vsnip`.
- [x] Fixed errors when folder names contain spaces.
- [x] Optimized project folder checking frequency.
- [x] Automatically apply `tabstop`/`expandtab` based on `prjroot`.
- [ ] Fix `prjroot` detection for launcher filetypes.
- [ ] Improve `prjroot` discovery logic for newly created folders.


## Launcher / Build

- [x] Allow interruption of launcher tasks.
- [x] Prevent launcher execution if other processes are running.
- [x] Optimize launcher window placement.
- [x] Implement process termination.
- [x] Store `prjroot` in launcher buffers to ensure keymaps persist.
- [x] Add error messaging for command execution failures; allow closing with `q`.
- [x] Reuse existing Launcher buffers if the same `prjroot` exists.
- [x] Automatically vsplit execution results into the current tab if the buffer is hidden.
- [x] Refactor process killing to use handles instead of just `vim.loop.kill`.
- [x] Add terminal color parsing for highlighting.
- [x] Allow output encoding specification.
- [x] Add spin animation to the status line during execution.
- [x] Fix launcher-project option conflicts; ensure launcher reads from top-level keys.
- [x] Implement execution mode (general, terminal, external)
- [x] Implement a list of currently running asynchronous processes.
    - It includes launchers, terminals(with something running), asyncronous tasks(searhcing..)
- [x] Keep cursor to the bottom of lines during the execution. (If I moved toward then stop keeping, when I get back to the bottom during the execution, go keeping)
- [x] Prohibit modifying general mode launcher buffer.
- [x] Add options for window position/size and duplicate handling.
    - positions for vertical, horizontal, bottom, top, left, right, tab, (nvim - new neovim process, defered)
- [x] Creation window height and width option.
- [x] Parse execution results from general mode launcher to navigate.
    - It acts like quickfix. And it's custormizable.
    - Use pattern based parsrser from prjroot file.
    - Example:
    ```lua
    launcher = { build = {
        cmd = 'buildcmd',
        patterns = {
            error = { pattern = '(%d+):(%d+):(%d+): (error):', extract = { 'filename', 'row', 'column', '' }, highlight = {[4]='#DD0000'} },
            warning = { pattern = '(%d+):(%d+):(%d+): (warning):', extract = { 'filename', 'row', 'column', '' }, highlight = {[4]='#00DD00'} },
        },
    } }
- [ ] Check the external launcher works.
- [ ] Focus option. Focus the buffer when the execution stated if the option has set.
- [ ] Fix UI annoyance when creating windows from the left-most edge.
    ```
- [ ] Add keymap to remove launcher buffers from other buffers in the same `prjroot`.
    - This todo need to be more specific.
- [ ] Improve session saving to include launcher state.
- [x] Support direct Lua function execution.
- [x] Replacing already running process conflicts its outputs. It should show the new processing output.
- [x] Re-organize statusline for launcher
    - 'Spinner | folder(can compact) | command with args <<gap>> current and total line (as general is)'

- [ ] count pattern matched on the status line
    - This todo need to be more specific.


## Language Server (LSP)

- [x] Find a performant Lua LSP with Windows support.
- [x] Refine `completion-nvim` usage; test thoroughly with C++ projects.
- [x] Test CMake LSP.
- [x] Bind LSP formatting keys.
- [x] Debug Markdown syntax highlighting in completion popups.
    - Addressed highlighting issues (e.g., pink underscores) in floating windows by ensuring proper Markdown escaping and clangd configuration.
- [x] Enable LSP CodeActions.
- [x] Add mappings for diagnostic navigation (e.g., `]d` for next issue).
- [x] Fix LSP preview highlighting issues (e.g., underscores).
- [x] Exclude `Gdiffsplit` and fugitive temporary files from LSP.
- [x] Fix clangd not applying to headers (previously incorrectly opened as objcpp).
- [x] Add `lsp_dynamic_workspace_symbols` for project-wide symbol navigation.
- [x] Manage excessive log file growth.
- [x] Trigger `redrawstatus` after indexing completes.
- [x] Update language server execution to include environment variable settings.


## Diagnostics

- [x] Display Diagnostic list using Quickfix.
- [x] Test `clang-tidy` integration via `clangd`.
- [x] Fix `lsp-status` bug in `statusline_lsp` function.


## Completion / Snippet

- [x] Implement snippet support via `vim-vsnip` (compatible with built-in LSP).
- [x] Remap completion keys to avoid conflicts with snippet navigation (`<Tab>`).

### Completion via Snippets
While snippets are great for statements and function templates, function snippets are redundant with signature previews, other than auto-completing parentheses. The main downside is snippet navigation conflicts with other completion menus.


## Treesitter / Syntax Highlighting

- [x] Integrate `Util.PrintTreesitter` for scratch buffer inspection.
- [x] Fix Markdown syntax highlighting using Treesitter.
- [x] Treesitter feature audit.
  - [x] Disabled "Current Scope Highlighting" as it was distracting.
  - [x] Cataloging useful Treesitter queries.
- [x] Address Treesitter update failures (often during Undo).
- [x] Investigate inaccurate node type reporting (e.g., non-functions labeled as functions).
- [x] Set up `TSPlayground` for tree structure inspection.
- [x] Fix argument/function object issues by installing `nvim-treesitter-textobjects`.
- [x] Fix highlight errors during substitution.
- [x] Mitigate performance degradation in large files.
- [x] Utilize `highlights.scm` for custom Markdown rules.
- [x] Normalize Markdown list-item indentation/codeblock highlighting using Treesitter.


## Markdown

- [x] Adopt a custom Markdown plugin approach instead of `vimwiki`. Use `note/index.md` with custom keymaps.
- [x] Drop custom Treesitter-based plugin in favor of `plasticboy/vim-markdown`.
- [x] Develop a custom Markdown plugin to handle link navigation, auto-indent, list items, and checkboxes.
- [ ] Display `---` as a horizontal rule using virtual text.
- [ ] Fix bug where task list toggling incorrectly triggers nested tasks.
- [ ] Implement auto-indentation.
- [ ] Implement auto-list-item generation.
- [ ] Finalize checkbox toggle functionality.

### `render-markdown`
- [ ] Fix plugin color rendering.
- [x] Disable numbers in headers; add virtual indentation.
- [ ] Use dimming for checked tasks instead of strikethrough.
- [x] Fix LSP floating window rendering (using `override-buftype-nofile`).


## Session

- [x] Implement session management via `mksession`/`source`.
- [x] Fix LSP diagnostic issues when loading sessions (usually resolves with `:e`).
- [x] Create a session management system integrated with Telescope.
- [x] Display active session name (`v:this_session`) in the tabline.
- [x] Fix Telescope fuzzy finding for sessions.
- [x] Fix `RemoveSession` functionality.
- [x] Handle errors for non-existent sessions in Telescope.
- [x] Improve command-line autocompletion for `RemoveSession`/`SaveSession`.
- [x] Implement saving/loading for Quickfix/Location lists in sessions.
- [x] Fix session saving failure when the directory is missing.
- [x] Implement auto-saving for sessions.
- [x] Warn about unsaved buffers before changing/closing sessions.
- [ ] Warn if terminal processes are running before session changes.
- [ ] Handle large/duplicate Quickfix lists in sessions.
- [ ] Fix `cmdheight` saving issues.
- [ ] Fix auto-save failure on `:qa` exit.


## File Manager

- [x] Implement `gx` for Unix-based file execution in `dirvish`.
- [x] Fix `prjroot` detection in `oil` buffers.
- [x] Add border styling to `oil` save confirmation dialogs.


## Buffer Management

- [x] Implement "wipeout all hidden buffers" command.


## Telescope

- [x] Fix performance hang when searching empty strings.


## IME / Korean Input

- [x] Display IME status (Korean/English) in the status line.
  - Resolved performance issues by using `io.popen` instead of repeatedly calling `fcitx-remote`.
- [ ] Display IME status on the right of the tabline (only when not English).
- [ ] Fix status line refresh delay in Markdown buffers during Insert mode.
- [ ] Support IME status display in command/search modes.


## Git / Fugitive

- [x] Add feature to return to current code from `Gclog` history.
- [ ] Fix `Gclog` return-to-original-code functionality.
