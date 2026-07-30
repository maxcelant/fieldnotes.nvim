local storage = require("fieldnotes.storage")
local ui = require("fieldnotes.ui")
local notebook = require("fieldnotes.notebook")
local server = require("fieldnotes.server")

local M = {}

M.config = {
	storage_dir = nil, -- defaults to ~/.fieldnotes
	keymap = "<leader>fn",
	sign_text = ">>",
	sign_hl = "DiagnosticInfo",
	line_hl = "fieldnotesHighlight",
	notebook_port = 6614, -- port for the local notebook website
}

local ns = vim.api.nvim_create_namespace("fieldnotes_signs")

-- Define a subtle default highlight for annotated ranges
-- Users can override with :hi fieldnotesHighlight ...
vim.api.nvim_set_hl(0, "fieldnotesHighlight", { default = true, bg = "#1e2a35" })

--- Refresh sign indicators for the given buffer (or current buffer).
---@param bufnr number|nil
function M.refresh_signs(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- Only operate on normal listed buffers with a real file
	if vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= "" then
		return
	end

	-- Clear existing signs in this buffer
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local abs_path = vim.api.nvim_buf_get_name(bufnr)
	if abs_path == "" then
		return
	end

	local repo_root = storage.get_repo_root()
	local rel_path = abs_path:sub(#repo_root + 2)

	local notes = storage.read_notes(M.config)
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	for _, note in ipairs(notes) do
		if note.file == rel_path and note.start_line and note.start_line >= 1 and note.start_line <= line_count then
			local end_line = math.min(note.end_line or note.start_line, line_count)

			-- Sign on the first line
			vim.api.nvim_buf_set_extmark(bufnr, ns, note.start_line - 1, 0, {
				sign_text = M.config.sign_text,
				sign_hl_group = M.config.sign_hl,
			})

			-- Highlight the full range
			for line = note.start_line, end_line do
				vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
					line_hl_group = M.config.line_hl,
				})
			end
		end
	end
end

--- Refresh signs across all loaded buffers.
function M.refresh_all_signs()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			M.refresh_signs(bufnr)
		end
	end
end

--- Setup the plugin with optional user configuration.
---@param opts table|nil
function M.setup(opts)
	opts = opts or {}
	M.config = vim.tbl_deep_extend("force", M.config, opts)

	-- Visual-mode keymap to add a note
	vim.keymap.set("x", M.config.keymap, function()
		M.add_note()
	end, { noremap = true, silent = true, desc = "fieldnotes: Add note" })

	-- Normal-mode keymap to show notes
	vim.keymap.set("n", "<leader>fs", function()
		M.show_notes()
	end, { noremap = true, silent = true, desc = "fieldnotes: Show notes" })

	-- Normal-mode keymap to hover preview notes on current line
	vim.keymap.set("n", "<leader>fp", function()
		M.hover_note()
	end, { noremap = true, silent = true, desc = "fieldnotes: Preview note" })

	-- Commands
	vim.api.nvim_create_user_command("FnShow", function(cmd)
		local tag = cmd.args ~= "" and cmd.args or nil
		M.show_notes(tag)
	end, { nargs = "?", desc = "fieldnotes: Show all notes (optionally filter by #tag)" })

	vim.api.nvim_create_user_command("FnAdd", function()
		M.add_note()
	end, { range = true, desc = "fieldnotes: Add a note for the current selection" })

	vim.api.nvim_create_user_command("FnExport", function()
		M.export_notes()
	end, { desc = "fieldnotes: Export notes to markdown" })

	vim.api.nvim_create_user_command("FnShowAll", function()
		M.show_all_notes()
	end, { desc = "fieldnotes: Browse notes across all repos" })

	vim.api.nvim_create_user_command("FnServe", function()
		M.open_notebook()
	end, { desc = "fieldnotes: Serve the notebook website locally" })

	vim.api.nvim_create_user_command("FnStop", function()
		M.stop_notebook()
	end, { desc = "fieldnotes: Stop the notebook server" })

	-- Refresh signs when entering a buffer
	vim.api.nvim_create_autocmd("BufEnter", {
		group = vim.api.nvim_create_augroup("fieldnotesSignRefresh", { clear = true }),
		callback = function(ev)
			M.refresh_signs(ev.buf)
		end,
	})

	-- Initial refresh for current buffer
	M.refresh_signs()
end

--- Add a note for the current visual selection.
function M.add_note()
	-- Get visual selection range
	local start_line = vim.fn.line("'<")
	local end_line = vim.fn.line("'>")

	-- If called from visual mode, the marks might not be set yet.
	-- Use the current mode to grab them.
	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "\22" then
		vim.cmd('normal! "')
		start_line = vim.fn.line("v")
		end_line = vim.fn.line(".")
		if start_line > end_line then
			start_line, end_line = end_line, start_line
		end
		-- Exit visual mode so the float works cleanly
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
	end

	-- File path relative to repo root
	local abs_path = vim.fn.expand("%:p")
	local repo_root = storage.get_repo_root()
	local rel_path = abs_path:sub(#repo_root + 2) -- +2 to skip the trailing "/"

	-- Snapshot the selected code now, so the notebook can render it later
	-- even if the file changes or notes are viewed from another repo
	local code = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	local lang = storage.lang_from_file(rel_path)
	if lang == "" then
		lang = vim.bo.filetype or ""
	end
	local source_url = storage.get_source_url(rel_path, start_line, end_line)

	ui.open_input_float(function(text)
		storage.add_note({
			file = rel_path,
			start_line = start_line,
			end_line = end_line,
			text = text,
			code = code,
			lang = lang,
			source_url = source_url,
		}, M.config)
		vim.notify("fieldnotes: Note saved.", vim.log.levels.INFO)
		M.refresh_all_signs()
		M.sync_notebook()
	end)
end

--- Show all notes in a floating viewer.
---@param tag string|nil  Optional tag to filter by (without #).
function M.show_notes(tag)
	local viewer_opts = {}
	if tag and tag ~= "" then
		viewer_opts.tag = tag:gsub("^#", "")
	end
	ui.open_viewer_float(M.config, function()
		-- Refresh signs and the notebook after any note change (edit or delete)
		M.refresh_all_signs()
		M.sync_notebook()
	end, viewer_opts)
end

--- Export notes for the current repo to a markdown file.
function M.export_notes()
	local md = storage.export_markdown(M.config)
	local export_path = storage.get_notes_dir(M.config) .. "/notes.md"
	vim.fn.writefile(vim.split(md, "\n"), export_path)
	vim.cmd("edit " .. vim.fn.fnameescape(export_path))
	vim.notify("fieldnotes: Exported to " .. export_path, vim.log.levels.INFO)
end

--- Show notes from all repos in ~/.fieldnotes/.
function M.show_all_notes()
	local all_notes = storage.read_all_repos(M.config)
	if #all_notes == 0 then
		vim.notify("fieldnotes: No notes found in any repo.", vim.log.levels.INFO)
		return
	end
	ui.open_viewer_float(M.config, nil, {
		notes = all_notes,
		title = " fieldnotes: All Repos ",
	})
end

--- Show a hover popup with notes on the current cursor line.
function M.hover_note()
	local abs_path = vim.fn.expand("%:p")
	local repo_root = storage.get_repo_root()
	local rel_path = abs_path:sub(#repo_root + 2)
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

	local all_notes = storage.read_notes(M.config)
	local matching = {}
	for _, note in ipairs(all_notes) do
		if note.file == rel_path and cursor_line >= (note.start_line or 0) and cursor_line <= (note.end_line or 0) then
			table.insert(matching, note)
		end
	end

	ui.open_hover_float(matching)
end

--- Regenerate the notebook site if it has been generated before or is
--- currently being served. Called after any note change so the website
--- (and any open browser tab, via auto-reload) stays in sync.
function M.sync_notebook()
	pcall(storage.backfill_code, M.config)
	if server.is_running() or vim.fn.isdirectory(notebook.get_dir(M.config)) == 1 then
		pcall(notebook.generate, M.config)
	end
end

--- Generate the notebook website and serve it on a local port.
function M.open_notebook()
	pcall(storage.backfill_code, M.config)
	local dir = notebook.generate(M.config)
	local url, err = server.start(dir, M.config.notebook_port)
	if not url then
		vim.notify("fieldnotes: Could not start notebook server: " .. (err or "unknown error"), vim.log.levels.ERROR)
		return
	end
	vim.notify("fieldnotes: Notebook served at " .. url, vim.log.levels.INFO)
	-- Open in the default browser (nvim 0.10+); older versions get the URL notification
	pcall(function()
		vim.ui.open(url)
	end)
end

--- Stop the notebook server.
function M.stop_notebook()
	if server.stop() then
		vim.notify("fieldnotes: Notebook server stopped.", vim.log.levels.INFO)
	else
		vim.notify("fieldnotes: Notebook server is not running.", vim.log.levels.INFO)
	end
end

return M
