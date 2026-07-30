local M = {}

--- Get the repository name from the current working directory.
--- Uses the git top-level directory if available, otherwise falls back to cwd basename.
---@return string
function M.get_repo_name()
	local git_dir = vim.fn.finddir(".git", ".;")
	if git_dir ~= "" then
		-- Resolve to absolute path first, then get the parent's tail
		local abs_git = vim.fn.fnamemodify(git_dir, ":p:h") -- absolute path to .git
		local repo_root = vim.fn.fnamemodify(abs_git, ":h") -- parent of .git
		return vim.fn.fnamemodify(repo_root, ":t")
	end
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
end

--- Get the root directory of the current git repo (or cwd as fallback).
---@return string
function M.get_repo_root()
	local git_dir = vim.fn.finddir(".git", ".;")
	if git_dir ~= "" then
		local abs_git = vim.fn.fnamemodify(git_dir, ":p:h")
		return vim.fn.fnamemodify(abs_git, ":h:s?/$??")
	end
	return vim.fn.getcwd()
end

--- Build a browser URL for a source range at the current commit.
--- Supports GitHub and GitLab HTTPS/SSH remotes.
---@param filepath string
---@param start_line number
---@param end_line number
---@return string|nil
function M.get_source_url(filepath, start_line, end_line)
	local root = M.get_repo_root()
	local remote_lines = vim.fn.systemlist({ "git", "-C", root, "remote", "get-url", "origin" })
	if vim.v.shell_error ~= 0 or not remote_lines[1] then
		return nil
	end
	local ref_lines = vim.fn.systemlist({ "git", "-C", root, "rev-parse", "HEAD" })
	if vim.v.shell_error ~= 0 or not ref_lines[1] then
		return nil
	end

	local remote = remote_lines[1]
	local base
	if remote:match("^https?://") then
		base = remote:gsub("^(https?://)[^/@]+@", "%1"):gsub("%.git/?$", ""):gsub("/$", "")
	else
		local host, path = remote:match("^[^@]+@([^:]+):(.+)$")
		if not host then
			host, path = remote:match("^ssh://[^@]+@([^/]+)/(.+)$")
		end
		if host and path then
			base = "https://" .. host .. "/" .. path:gsub("%.git/?$", ""):gsub("/$", "")
		end
	end
	if not base then
		return nil
	end

	local encoded_path = filepath:gsub("[^%w%-%._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	local s = math.max(1, start_line or 1)
	local e = math.max(s, end_line or s)
	local is_gitlab = base:lower():find("gitlab", 1, true) ~= nil
	local route = is_gitlab and "/-/blob/" or "/blob/"
	local anchor = is_gitlab and string.format("#L%d-%d", s, e) or string.format("#L%d-L%d", s, e)
	return base .. route .. ref_lines[1] .. "/" .. encoded_path .. anchor
end

--- Get the notes directory for the current repository.
---@param config table|nil  Optional config with `storage_dir` override.
---@return string
function M.get_notes_dir(config)
	local base = (config and config.storage_dir) or (vim.fn.expand("~") .. "/.fieldnotes")
	return base .. "/" .. M.get_repo_name()
end

--- Get the full path to the notes JSON file.
---@param config table|nil
---@return string
function M.get_notes_path(config)
	return M.get_notes_dir(config) .. "/notes.json"
end

--- Read all notes for the current repo.
---@param config table|nil
---@return table[]
function M.read_notes(config)
	local path = M.get_notes_path(config)
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local content = table.concat(vim.fn.readfile(path), "\n")
	if content == "" then
		return {}
	end
	local ok, notes = pcall(vim.fn.json_decode, content)
	if not ok or type(notes) ~= "table" then
		return {}
	end
	return notes
end

--- Write the full notes list to disk.
---@param notes table[]
---@param config table|nil
function M.write_notes(notes, config)
	local dir = M.get_notes_dir(config)
	vim.fn.mkdir(dir, "p")
	local path = M.get_notes_path(config)
	local json = vim.fn.json_encode(notes)
	vim.fn.writefile({ json }, path)
end

--- Add a single note and persist.
---@param note table  { file, start_line, end_line, text, code, lang }
---@param config table|nil
function M.add_note(note, config)
	local notes = M.read_notes(config)
	note.created_at = os.date("!%Y-%m-%dT%H:%M:%S")
	table.insert(notes, note)
	M.write_notes(notes, config)
end

--- Update the text of a note by index (1-based) and persist.
---@param index number
---@param new_text string
---@param config table|nil
function M.update_note(index, new_text, config)
	local notes = M.read_notes(config)
	if index >= 1 and index <= #notes then
		notes[index].text = new_text
		M.write_notes(notes, config)
	end
end

--- Extract all #tags from a note's text.
---@param text string
---@return string[]
function M.extract_tags(text)
	local tags = {}
	for tag in text:gmatch("#(%w+)") do
		table.insert(tags, tag:lower())
	end
	return tags
end

--- Filter notes that contain a given tag.
---@param notes table[]
---@param tag string  Tag name without the # prefix.
---@return table[]  Filtered notes with original indices preserved as `._index`.
function M.filter_by_tag(notes, tag)
	tag = tag:lower()
	local filtered = {}
	for i, note in ipairs(notes) do
		local tags = M.extract_tags(note.text or "")
		for _, t in ipairs(tags) do
			if t == tag then
				local copy = vim.tbl_extend("force", {}, note)
				copy._index = i
				table.insert(filtered, copy)
				break
			end
		end
	end
	return filtered
end

--- Get all unique tags across all notes.
---@param config table|nil
---@return string[]
function M.get_all_tags(config)
	local notes = M.read_notes(config)
	local seen = {}
	local tags = {}
	for _, note in ipairs(notes) do
		for _, tag in ipairs(M.extract_tags(note.text or "")) do
			if not seen[tag] then
				seen[tag] = true
				table.insert(tags, tag)
			end
		end
	end
	table.sort(tags)
	return tags
end

--- Delete a note by index (1-based) and persist.
---@param index number
---@param config table|nil
function M.delete_note(index, config)
	local notes = M.read_notes(config)
	if index >= 1 and index <= #notes then
		table.remove(notes, index)
		M.write_notes(notes, config)
	end
end

--- Get the base storage directory.
---@param config table|nil
---@return string
function M.get_base_dir(config)
	return (config and config.storage_dir) or (vim.fn.expand("~") .. "/.fieldnotes")
end

--- Read notes from all repos in the base storage directory.
---@param config table|nil
---@return table[]  Notes with `_repo` and `_repo_root` fields added.
function M.read_all_repos(config)
	local base = M.get_base_dir(config)
	if vim.fn.isdirectory(base) == 0 then
		return {}
	end
	local all_notes = {}
	local repos = vim.fn.readdir(base)
	for _, repo_name in ipairs(repos) do
		local repo_dir = base .. "/" .. repo_name
		local notes_path = repo_dir .. "/notes.json"
		if vim.fn.filereadable(notes_path) == 1 then
			local content = table.concat(vim.fn.readfile(notes_path), "\n")
			if content ~= "" then
				local ok, notes = pcall(vim.fn.json_decode, content)
				if ok and type(notes) == "table" then
					for _, note in ipairs(notes) do
						note._repo = repo_name
						note._repo_root = repo_dir
						table.insert(all_notes, note)
					end
				end
			end
		end
	end
	return all_notes
end

--- Infer a markdown language identifier from a file path's extension.
---@param filepath string
---@return string
function M.lang_from_file(filepath)
	local ext = filepath:match("%.(%w+)$")
	if not ext then
		return ""
	end
	local map = {
		lua = "lua",
		py = "python",
		rb = "ruby",
		js = "javascript",
		ts = "typescript",
		tsx = "tsx",
		jsx = "jsx",
		rs = "rust",
		go = "go",
		java = "java",
		c = "c",
		cpp = "cpp",
		h = "c",
		hpp = "cpp",
		cs = "csharp",
		sh = "bash",
		bash = "bash",
		zsh = "bash",
		fish = "fish",
		vim = "vim",
		el = "elisp",
		ex = "elixir",
		exs = "elixir",
		erl = "erlang",
		hs = "haskell",
		ml = "ocaml",
		scala = "scala",
		kt = "kotlin",
		swift = "swift",
		r = "r",
		sql = "sql",
		html = "html",
		css = "css",
		scss = "scss",
		json = "json",
		yaml = "yaml",
		yml = "yaml",
		toml = "toml",
		xml = "xml",
		md = "markdown",
		txt = "",
		zig = "zig",
		nix = "nix",
		tf = "hcl",
		proto = "protobuf",
		dart = "dart",
	}
	return map[ext:lower()] or ext:lower()
end

--- Read source lines from a file on disk.
---@param filepath string  Absolute path to the file.
---@param start_line number
---@param end_line number
---@return string[]|nil
local function read_source_lines(filepath, start_line, end_line)
	if vim.fn.filereadable(filepath) == 0 then
		return nil
	end
	local all_lines = vim.fn.readfile(filepath)
	if #all_lines == 0 then
		return nil
	end
	local s = math.max(1, start_line)
	local e = math.min(#all_lines, end_line)
	local result = {}
	for i = s, e do
		table.insert(result, all_lines[i])
	end
	return result
end

--- Fill in missing code snapshots and source links for the current repo's notes.
--- Older notes are enriched from the current checkout when possible.
---@param config table|nil
---@return boolean changed  Whether any note was updated.
function M.backfill_code(config)
	local notes = M.read_notes(config)
	if #notes == 0 then
		return false
	end
	local repo_root = M.get_repo_root()
	local changed = false
	for _, note in ipairs(notes) do
		if type(note.code) ~= "table" and note.file then
			local src = read_source_lines(repo_root .. "/" .. note.file, note.start_line or 0, note.end_line or 0)
			if src and #src > 0 then
				note.code = src
				if type(note.lang) ~= "string" or note.lang == "" then
					note.lang = M.lang_from_file(note.file)
				end
				changed = true
			end
		end
		if note.file and (type(note.source_url) ~= "string" or note.source_url == "") then
			local source_url = M.get_source_url(note.file, note.start_line or 1, note.end_line or note.start_line or 1)
			if source_url then
				note.source_url = source_url
				changed = true
			end
		end
	end
	if changed then
		M.write_notes(notes, config)
	end
	return changed
end

--- Export all notes to a markdown string, grouped by file.
--- Includes the referenced source code in fenced code blocks.
---@param config table|nil
---@return string
function M.export_markdown(config)
	local notes = M.read_notes(config)
	if #notes == 0 then
		return "# fieldnotes Notes\n\nNo notes found.\n"
	end

	local repo_root = M.get_repo_root()

	-- Group by file
	local by_file = {}
	local file_order = {}
	for _, note in ipairs(notes) do
		local f = note.file or "unknown"
		if not by_file[f] then
			by_file[f] = {}
			table.insert(file_order, f)
		end
		table.insert(by_file[f], note)
	end

	local lines = { "# fieldnotes Notes", "", "**Repository:** " .. M.get_repo_name(), "" }

	for _, file in ipairs(file_order) do
		table.insert(lines, "## " .. file)
		table.insert(lines, "")
		local lang = M.lang_from_file(file)
		local abs_file = repo_root .. "/" .. file

		for _, note in ipairs(by_file[file]) do
			local loc = string.format("L%d-%d", note.start_line or 0, note.end_line or 0)
			local tags = M.extract_tags(note.text or "")
			local tag_str = ""
			if #tags > 0 then
				local prefixed = {}
				for _, t in ipairs(tags) do
					table.insert(prefixed, "`#" .. t .. "`")
				end
				tag_str = " " .. table.concat(prefixed, " ")
			end
			table.insert(lines, string.format("- **%s**: %s%s", loc, note.text or "", tag_str))
			if note.created_at then
				table.insert(lines, string.format("  - _Created: %s_", note.created_at))
			end

			-- Include the referenced source code (prefer the snapshot captured
			-- at note creation; fall back to reading the file from disk)
			local src = note.code
			if type(src) ~= "table" or #src == 0 then
				src = read_source_lines(abs_file, note.start_line or 0, note.end_line or 0)
			end
			local note_lang = (type(note.lang) == "string" and note.lang ~= "") and note.lang or lang
			if src and #src > 0 then
				table.insert(lines, "")
				table.insert(lines, "  ```" .. note_lang)
				for _, sl in ipairs(src) do
					table.insert(lines, "  " .. sl)
				end
				table.insert(lines, "  ```")
			end

			table.insert(lines, "")
		end
	end

	return table.concat(lines, "\n")
end

return M
