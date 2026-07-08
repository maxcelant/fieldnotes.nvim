-- Prevent double-loading
if vim.g.loaded_fieldnotes then
	return
end
vim.g.loaded_fieldnotes = true

-- The plugin auto-registers commands and keymaps when setup() is called.
-- Users should call: require("fieldnotes").setup({})
--
-- For users who want zero-config, we provide default commands that
-- call setup() lazily on first use.

local function ensure_setup()
	if not vim.g.fieldnotes_setup_done then
		require("fieldnotes").setup({})
		vim.g.fieldnotes_setup_done = true
	end
end

vim.api.nvim_create_user_command("FnShow", function(cmd)
	ensure_setup()
	local tag = cmd.args ~= "" and cmd.args or nil
	require("fieldnotes").show_notes(tag)
end, { nargs = "?", desc = "fieldnotes: Show all notes (optionally filter by #tag)" })

vim.api.nvim_create_user_command("FnAdd", function()
	ensure_setup()
	require("fieldnotes").add_note()
end, { range = true, desc = "fieldnotes: Add a note for the current selection" })

vim.api.nvim_create_user_command("FnShowAll", function()
	ensure_setup()
	require("fieldnotes").show_all_notes()
end, { desc = "fieldnotes: Browse notes across all repos" })

vim.api.nvim_create_user_command("FnServe", function()
	ensure_setup()
	require("fieldnotes").open_notebook()
end, { desc = "fieldnotes: Serve the notebook website locally" })

vim.api.nvim_create_user_command("FnStop", function()
	ensure_setup()
	require("fieldnotes").stop_notebook()
end, { desc = "fieldnotes: Stop the notebook server" })
