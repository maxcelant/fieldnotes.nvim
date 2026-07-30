# fieldnotes.nvim

A zero-dependency Neovim plugin for keeping sporadic notes about the code you explore.

Highlight lines, jot down what they do, and come back to your notes anytime with `:FnShow` — or browse every project's notes as a rendered local website with `:FnServe`.

## Installation

### lazy.nvim

```lua
{
  "maxcelant/fieldnotes.nvim",
  config = function()
    require("fieldnotes").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "maxcelant/fieldnotes.nvim",
  config = function()
    require("fieldnotes").setup()
  end,
}
```

## Usage

### Add a Note

1. Visually select one or more lines (`V` or `v`).
2. Press `<leader>fn`.
3. Type your note in the floating window that appears.
4. Press `<CR>` to save (in insert or normal mode), or `<Esc>` / `q` to cancel.

You can include tags in your notes like `#bug`, `#question`, `#todo` to categorize them.

### Preview a Note

Place your cursor on any annotated line (marked with `>>` in the sign column) and press `<leader>fp` to see the note text in a hover popup.

- `q` / `<Esc>` - Close the popup.

### Show Notes

Run `:FnShow` (or `<leader>fs`) to open a floating viewer with all notes for the current repository.

- `<CR>` - Jump to the file and line of the selected note.
- `e` - Edit the selected note (opens input float pre-filled with existing text).
- `dd` - Delete the selected note.
- `t` - Filter notes by tag (shows a picker of all tags found in your notes).
- `T` - Clear the tag filter and show all notes.
- `q` / `<Esc>` - Close the viewer.

You can also filter directly from the command line:

```vim
:FnShow #bug
:FnShow todo
```

### Cross-Repo Search

Run `:FnShowAll` to browse notes across every repository in your `~/.fieldnotes/` directory. Each note is prefixed with the repo name so you can tell which project it belongs to. Press `<CR>` to jump to the file.

### Export to Markdown

Run `:FnExport` to generate a markdown file with all notes for the current repo, grouped by file. The file is saved to `~/.fieldnotes/<repo-name>/notes.md` and opened in a buffer. Useful for code review prep or documentation.

### Notebook (Local Website)

Run `:FnServe` to build and serve a central notebook website covering **all** your repositories, rendered in a warm pastel-brown theme:

- An index page lists every project that has notes.
- Click a project to see a rendered page with each highlighted code block (with line numbers and syntax highlighting) and the note you took — one HTML file per repository.
- Notes are grouped by file; click a tag chip to filter, click `all` to reset.
- Each snippet's file-and-line reference links to that exact commit on GitHub or GitLab.
- Open browser tabs auto-refresh whenever you add, edit, or delete a note — even from a different Neovim instance.

The server runs inside Neovim itself (zero dependencies, built on `vim.uv`) at `http://127.0.0.1:6614/` by default, and stops when Neovim exits or with `:FnStop`. The generated site is fully static and self-contained — it lives in `~/.fieldnotes/notebook/`, so you can also open `index.html` straight from disk or serve the directory with any other web server.

New notes snapshot the selected code at creation time, so the notebook shows the code exactly as it was when you annotated it. Notes created before this feature existed are backfilled from the current file contents the first time the notebook is generated from within that repository.

Syntax highlighting is loaded from a CDN (highlight.js) when online and degrades gracefully to plain styled code offline.

## Visual Indicators

- A `>>` sign appears in the sign column on the first line of each annotated block.
- The entire annotated line range is lightly highlighted with a background color.
- Both the sign and highlight refresh automatically when you open a buffer or add/delete a note.

## Storage

Notes are stored as JSON in `~/.fieldnotes/<repo-name>/notes.json`.

- `<repo-name>` is derived from the git root directory name.
- File paths within notes are relative to the repo root, so notes stay valid across machines.
- Each note also stores a snapshot of the selected code (`code`), its language (`lang`), and a commit-pinned GitHub/GitLab source link (`source_url`) for rendering in the notebook.
- The generated notebook website lives in `~/.fieldnotes/notebook/`.

## Configuration

```lua
require("fieldnotes").setup({
  -- Override the default storage directory
  storage_dir = "~/.fieldnotes",

  -- Override the keymap for adding notes (visual mode)
  keymap = "<leader>fn",

  -- Sign column indicator for annotated lines
  sign_text = ">>",
  sign_hl = "DiagnosticInfo",

  -- Highlight group for the annotated line range
  line_hl = "fieldnotesHighlight",

  -- Port for the local notebook website (:FnServe)
  notebook_port = 6614,
})
```

All options are optional. The defaults shown above are used if nothing is provided.

To customize the range highlight color:

```lua
vim.api.nvim_set_hl(0, "fieldnotesHighlight", { bg = "#2a2a3a" })
```

## Keymaps

| Mode   | Key            | Action                      |
|--------|----------------|-----------------------------|
| Visual | `<leader>fn`   | Add a note for selection    |
| Normal | `<leader>fs`   | Show all notes              |
| Normal | `<leader>fp`   | Preview note on cursor line |

## Commands

| Command      | Description                                       |
|--------------|---------------------------------------------------|
| `:FnShow`    | Show notes (accepts optional `#tag` argument)     |
| `:FnAdd`     | Add a note for the current selection              |
| `:FnExport`  | Export notes to markdown, grouped by file         |
| `:FnShowAll` | Browse notes across all repos                     |
| `:FnServe`   | Build + serve the notebook website for all repos  |
| `:FnStop`    | Stop the notebook server                          |

## License

MIT
