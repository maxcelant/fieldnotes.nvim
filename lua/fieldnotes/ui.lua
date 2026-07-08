local storage = require("fieldnotes.storage")

local M = {}

--- Open a small floating window for the user to type a note.
--- Calls `on_confirm(text)` when the user saves.
---@param on_confirm fun(text: string)
---@param prefill string|nil  Optional text to pre-fill the input with (for editing).
function M.open_input_float(on_confirm, prefill)
	local width = math.floor(vim.o.columns * 0.6)
	local height = 5
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local title = prefill and " fieldnotes: Edit Note " or " fieldnotes: Add Note "

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

	-- Pre-fill buffer if editing
	if prefill and prefill ~= "" then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { prefill })
	end

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		border = "rounded",
		title = title,
		title_pos = "center",
	})

	-- Start in insert mode (at end of line if pre-filled)
	if prefill and prefill ~= "" then
		vim.cmd("normal! $")
		vim.cmd("startinsert!")
	else
		vim.cmd("startinsert")
	end

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function confirm()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = vim.fn.trim(table.concat(lines, " "))
		close()
		if text ~= "" then
			on_confirm(text)
		end
	end

	-- Keymaps for the input buffer
	local opts = { noremap = true, silent = true, buffer = buf }
	vim.keymap.set("n", "<CR>", confirm, opts)
	vim.keymap.set("i", "<CR>", function()
		vim.cmd("stopinsert")
		confirm()
	end, opts)
	vim.keymap.set("n", "q", close, opts)
	vim.keymap.set("n", "<Esc>", close, opts)
end

--- Open a small read-only floating popup showing notes for the current line.
---@param notes table[]  Notes that match the current cursor line.
function M.open_hover_float(notes)
	if #notes == 0 then
		vim.notify("fieldnotes: No notes on this line.", vim.log.levels.INFO)
		return
	end

	local max_width = math.floor(vim.o.columns * 0.6)

	--- Word-wrap a string to fit within max_width columns.
	---@param str string
	---@param wrap_at number
	---@return string[]
	local function wrap_text(str, wrap_at)
		local wrapped = {}
		for segment in str:gmatch("[^\n]+") do
			if #segment <= wrap_at then
				table.insert(wrapped, segment)
			else
				local current = ""
				for word in segment:gmatch("%S+") do
					if current == "" then
						current = word
					elseif #current + 1 + #word <= wrap_at then
						current = current .. " " .. word
					else
						table.insert(wrapped, current)
						current = word
					end
				end
				if current ~= "" then
					table.insert(wrapped, current)
				end
			end
		end
		return wrapped
	end

	local lines = {}
	for i, note in ipairs(notes) do
		if #notes > 1 then
			table.insert(lines, string.format("--- Note %d ---", i))
		end
		local wrapped = wrap_text(note.text or "", max_width - 2)
		for _, wl in ipairs(wrapped) do
			table.insert(lines, wl)
		end
		if i < #notes then
			table.insert(lines, "")
		end
	end

	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, #line)
	end
	width = math.min(math.max(width + 2, 20), max_width)
	local height = #lines

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		width = width,
		height = height,
		row = 1,
		col = 0,
		border = "rounded",
		title = " fieldnotes: Note ",
		title_pos = "center",
	})

	-- Close on any movement
	local opts = { noremap = true, silent = true, buffer = buf }
	vim.keymap.set("n", "q", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, opts)
	vim.keymap.set("n", "<Esc>", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, opts)
end

--- Open a floating window that lists all notes for the current repo.
--- Pressing <CR> jumps to the note; pressing dd deletes it; pressing e edits it.
---@param config table|nil
---@param on_change fun()|nil  Called after a note is deleted or edited.
---@param opts_viewer table|nil  { tag = string, repo = string, notes = table[], title = string }
function M.open_viewer_float(config, on_change, opts_viewer)
	opts_viewer = opts_viewer or {}
	local active_tag = opts_viewer.tag or nil
	local custom_title = opts_viewer.title or nil

	-- index_map[display_line] = real note index in storage (or provided list)
	local index_map = {}
	local notes = {}

	local width = math.floor(vim.o.columns * 0.6)
	local height = math.floor(vim.o.lines * 0.6)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

	local function load_notes()
		if opts_viewer.notes then
			-- External notes list (e.g. cross-repo)
			notes = opts_viewer.notes
		else
			local all = storage.read_notes(config)
			if active_tag then
				notes = storage.filter_by_tag(all, active_tag)
			else
				notes = all
			end
		end
	end

	local function render()
		load_notes()
		index_map = {}
		local lines = {}
		for i, note in ipairs(notes) do
			local preview = note.text or ""
			if #preview > (width - 30) then
				preview = preview:sub(1, width - 33) .. "..."
			end
			local file_display = note.file or "?"
			-- For cross-repo notes, prefix with repo name
			if note._repo then
				file_display = "[" .. note._repo .. "] " .. file_display
			end
			local entry =
				string.format("%d. %s:%d-%d  %s", i, file_display, note.start_line or 0, note.end_line or 0, preview)
			table.insert(lines, entry)
			-- Map display line to real storage index
			index_map[i] = note._index or i
		end
		if #lines == 0 then
			table.insert(lines, "  (no notes)")
		end
		vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	end

	render()

	if #notes == 0 then
		vim.api.nvim_buf_delete(buf, { force = true })
		local msg = active_tag and ("fieldnotes: No notes with tag #%s."):format(active_tag)
			or "fieldnotes: No notes found."
		vim.notify(msg, vim.log.levels.INFO)
		return
	end

	local title = custom_title or " fieldnotes: Notes "
	if active_tag then
		title = (" fieldnotes: #%s "):format(active_tag)
	end

	local footer_parts = { "<CR> jump", "e edit", "dd delete", "t filter tag", "T clear filter", "q close" }
	-- Cross-repo viewer doesn't support edit/delete (multi-repo complexity)
	if opts_viewer.notes then
		footer_parts = { "<CR> jump", "q close" }
	end

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		border = "rounded",
		title = title,
		title_pos = "center",
		footer = " " .. table.concat(footer_parts, " | ") .. " ",
		footer_pos = "center",
	})

	vim.api.nvim_set_option_value("cursorline", true, { win = win })

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function get_note_repo_root(note)
		if note._repo_root then
			return note._repo_root
		end
		return storage.get_repo_root()
	end

	local function jump_to_note()
		local cursor = vim.api.nvim_win_get_cursor(win)
		local line_nr = cursor[1]
		local note = notes[line_nr]
		if not note then
			return
		end
		close()
		local repo_root = get_note_repo_root(note)
		local filepath = repo_root .. "/" .. note.file
		vim.cmd("edit " .. vim.fn.fnameescape(filepath))
		vim.api.nvim_win_set_cursor(0, { note.start_line, 0 })
		vim.cmd("normal! zz")
	end

	local function delete_note()
		if opts_viewer.notes then
			return
		end -- disabled for cross-repo
		local cursor = vim.api.nvim_win_get_cursor(win)
		local line_nr = cursor[1]
		local real_idx = index_map[line_nr]
		if real_idx then
			storage.delete_note(real_idx, config)
			if on_change then
				on_change()
			end
			render()
			local line_count = vim.api.nvim_buf_line_count(buf)
			if line_nr > line_count then
				vim.api.nvim_win_set_cursor(win, { math.max(1, line_count), 0 })
			end
			notes = opts_viewer.notes or storage.read_notes(config)
			if #notes == 0 or (active_tag and #storage.filter_by_tag(storage.read_notes(config), active_tag) == 0) then
				close()
				vim.notify("fieldnotes: No more notes.", vim.log.levels.INFO)
			end
		end
	end

	local function edit_note()
		if opts_viewer.notes then
			return
		end -- disabled for cross-repo
		local cursor = vim.api.nvim_win_get_cursor(win)
		local line_nr = cursor[1]
		local real_idx = index_map[line_nr]
		local note = notes[line_nr]
		if not note or not real_idx then
			return
		end
		close()
		M.open_input_float(function(new_text)
			storage.update_note(real_idx, new_text, config)
			vim.notify("fieldnotes: Note updated.", vim.log.levels.INFO)
			if on_change then
				on_change()
			end
		end, note.text)
	end

	local function filter_by_tag()
		if opts_viewer.notes then
			return
		end
		local tags = storage.get_all_tags(config)
		if #tags == 0 then
			vim.notify("fieldnotes: No tags found in notes.", vim.log.levels.INFO)
			return
		end
		close()
		vim.ui.select(tags, { prompt = "Filter by tag:" }, function(choice)
			if choice then
				M.open_viewer_float(config, on_change, { tag = choice })
			else
				-- Reopen unfiltered
				M.open_viewer_float(config, on_change)
			end
		end)
	end

	local function clear_tag_filter()
		if opts_viewer.notes then
			return
		end
		if active_tag then
			close()
			M.open_viewer_float(config, on_change)
		end
	end

	local kopts = { noremap = true, silent = true, buffer = buf }
	vim.keymap.set("n", "<CR>", jump_to_note, kopts)
	vim.keymap.set("n", "e", edit_note, kopts)
	vim.keymap.set("n", "dd", delete_note, kopts)
	vim.keymap.set("n", "t", filter_by_tag, kopts)
	vim.keymap.set("n", "T", clear_tag_filter, kopts)
	vim.keymap.set("n", "q", close, kopts)
	vim.keymap.set("n", "<Esc>", close, kopts)
end

return M
