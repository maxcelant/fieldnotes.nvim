-- Static site generator for the fieldnotes notebook.
-- Renders every repo's notes into a self-contained HTML page (one file per
-- repository) plus an index page, all written to <storage_dir>/notebook/.

local storage = require("fieldnotes.storage")

local M = {}

-- Per-session counter mixed into the stamp file so served pages can detect
-- regeneration and auto-reload.
local generation = 0

--- Escape a string for HTML text and attribute contexts.
---@param s any
---@return string
local function esc(s)
	s = tostring(s or "")
	s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
	return s
end

--- Turn a repo name into a safe, flat filename slug.
---@param name string
---@return string
local function slugify(name)
	return (name:gsub("[^%w%-_%.]", "-"))
end

--- "1 note" / "3 notes"
---@param n number
---@param word string
---@return string
local function plural(n, word)
	return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

--- Date portion of an ISO timestamp ("2026-07-08T10:00:00" -> "2026-07-08").
---@param iso any
---@return string
local function date_part(iso)
	if type(iso) == "string" and #iso >= 10 then
		return iso:sub(1, 10)
	end
	return ""
end

--- Render note text with #tags wrapped in styled spans.
---@param text string
---@return string
local function render_text(text)
	local html = esc(text):gsub("#(%w+)", '<span class="tag">#%1</span>')
	return html
end

local CSS = [[
* { box-sizing: border-box; margin: 0; padding: 0; }
:root {
	--bg: #f6efe4;
	--panel: #fdf8ef;
	--border: #e4d6c1;
	--fg: #4f4234;
	--muted: #a08d75;
	--accent: #b07d4f;
	--filepath: #87986a;
	--chip-bg: rgba(176, 125, 79, 0.14);
	--chip-fg: #96683f;
	--code-bg: #f3ead9;
	--mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
}
body { background: var(--bg); color: var(--fg); font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif; }
.wrap { max-width: 960px; margin: 0 auto; padding: 2.5rem 1.5rem 4rem; }
header.site { display: flex; align-items: baseline; gap: 0.75rem; margin-bottom: 1.5rem; }
header.site h1 { font-size: 1.6rem; }
.subtitle { color: var(--muted); }
a.back { color: var(--muted); text-decoration: none; font-size: 0.9rem; }
a.back:hover { color: var(--accent); }
h1.repotitle { font-family: var(--mono); font-size: 1.5rem; margin-bottom: 0.25rem; overflow-wrap: anywhere; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 1rem; }
a.card { display: block; background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 1.1rem 1.2rem; text-decoration: none; color: var(--fg); transition: border-color 0.15s ease, transform 0.15s ease; }
a.card:hover { border-color: var(--accent); transform: translateY(-2px); box-shadow: 0 3px 10px rgba(95, 76, 56, 0.1); }
.cardname { font-family: var(--mono); font-weight: 600; color: var(--accent); margin-bottom: 0.35rem; overflow-wrap: anywhere; }
.cardstats { color: var(--muted); font-size: 0.85rem; }
.cardtags { margin-top: 0.6rem; display: flex; flex-wrap: wrap; gap: 0.35rem; }
.cardupdated { margin-top: 0.6rem; color: var(--muted); font-size: 0.75rem; }
.chip { font-family: var(--mono); font-size: 0.75rem; background: var(--chip-bg); color: var(--chip-fg); padding: 0.1rem 0.55rem; border-radius: 999px; white-space: nowrap; }
.tagbar { display: flex; flex-wrap: wrap; gap: 0.4rem; margin: 1.25rem 0 2rem; }
.tagbar .chip { cursor: pointer; border: 1px solid transparent; user-select: none; }
.tagbar .chip.active { border-color: var(--chip-fg); }
.filegroup { margin-bottom: 2.5rem; }
h2.filepath { font-family: var(--mono); font-size: 1rem; font-weight: 600; color: var(--filepath); border-bottom: 1px solid var(--border); padding-bottom: 0.5rem; margin-bottom: 1rem; overflow-wrap: anywhere; }
article.note { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 1rem 1.1rem; margin-bottom: 1rem; }
.notemeta { display: flex; flex-wrap: wrap; align-items: center; gap: 0.6rem; margin-bottom: 0.75rem; }
.loc { font-family: var(--mono); font-size: 0.8rem; color: var(--accent); background: rgba(176, 125, 79, 0.12); padding: 0.1rem 0.5rem; border-radius: 6px; }
.date { color: var(--muted); font-size: 0.8rem; }
.codewrap { display: flex; background: var(--code-bg); border: 1px solid var(--border); border-radius: 8px; max-height: 30rem; overflow-y: auto; }
pre.gutter { padding: 0.75rem 0.6rem 0.75rem 0.9rem; text-align: right; color: var(--muted); user-select: none; border-right: 1px solid var(--border); font: 0.85rem/1.6 var(--mono); }
pre.codeblock { padding: 0.75rem 0.9rem; flex: 1; overflow-x: auto; font: 0.85rem/1.6 var(--mono); }
pre.codeblock code { font: inherit; display: block; }
pre.codeblock code.hljs { padding: 0; background: transparent; }
.notetext { margin-top: 0.8rem; overflow-wrap: anywhere; }
.notetext .tag { color: var(--chip-fg); font-family: var(--mono); font-size: 0.9em; }
.empty { color: var(--muted); text-align: center; padding: 4rem 0; }
footer.site { margin-top: 3rem; color: var(--muted); font-size: 0.8rem; text-align: center; }
]]

-- Auto-reload: poll the server's /__stamp endpoint and reload when the site
-- has been regenerated. No-op when the page is opened via file://.
local RELOAD_JS = [[
<script>
(function () {
	if (location.protocol === "file:") return;
	var current = null;
	setInterval(function () {
		fetch("/__stamp", { cache: "no-store" })
			.then(function (r) { return r.text(); })
			.then(function (t) {
				if (current === null) current = t;
				else if (t !== current) location.reload();
			})
			.catch(function () {});
	}, 2000);
})();
</script>
]]

-- Tag filter: clicking a chip in the tagbar shows only notes carrying that
-- tag and hides file groups left with no visible notes.
local TAGBAR_JS = [[
<script>
(function () {
	var chips = document.querySelectorAll(".tagbar [data-tag]");
	chips.forEach(function (chip) {
		chip.addEventListener("click", function () {
			var tag = chip.dataset.tag;
			chips.forEach(function (c) { c.classList.toggle("active", c === chip); });
			document.querySelectorAll("article.note").forEach(function (n) {
				var tags = (n.dataset.tags || "").split(" ");
				n.style.display = (tag === "" || tags.indexOf(tag) !== -1) ? "" : "none";
			});
			document.querySelectorAll(".filegroup").forEach(function (g) {
				var visible = Array.prototype.some.call(g.querySelectorAll("article.note"), function (n) {
					return n.style.display !== "none";
				});
				g.style.display = visible ? "" : "none";
			});
		});
	});
})();
</script>
]]

-- Syntax highlighting via CDN; degrades gracefully to plain styled code when
-- offline (the <script> simply never loads). Kimbie Light's warm brown/tan
-- token colors match the site's pastel palette.
local HLJS_HEAD = [[
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/kimbie-light.min.css">
<script defer src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js" onload="hljs.highlightAll()"></script>
]]

--- Wrap a body in the shared HTML shell.
---@param title string
---@param body string
---@param extra_head string|nil
---@param extra_scripts string|nil
---@return string
local function page(title, body, extra_head, extra_scripts)
	return table.concat({
		"<!doctype html>",
		'<html lang="en">',
		"<head>",
		'<meta charset="utf-8">',
		'<meta name="viewport" content="width=device-width, initial-scale=1">',
		"<title>" .. esc(title) .. "</title>",
		"<style>",
		CSS,
		"</style>",
		extra_head or "",
		"</head>",
		"<body>",
		body,
		RELOAD_JS,
		extra_scripts or "",
		"</body>",
		"</html>",
	}, "\n")
end

local function footer()
	return '<footer class="site">generated by fieldnotes.nvim &middot; ' .. os.date("!%Y-%m-%d %H:%M UTC") .. "</footer>"
end

--- Compute summary stats for a repo's notes.
---@param notes table[]
---@return number file_count, string[] tags, string latest_created_at
local function repo_stats(notes)
	local files, tags = {}, {}
	local file_count, latest = 0, ""
	for _, note in ipairs(notes) do
		local f = note.file or "?"
		if not files[f] then
			files[f] = true
			file_count = file_count + 1
		end
		for _, t in ipairs(storage.extract_tags(note.text or "")) do
			tags[t] = true
		end
		if type(note.created_at) == "string" and note.created_at > latest then
			latest = note.created_at
		end
	end
	local tag_list = vim.tbl_keys(tags)
	table.sort(tag_list)
	return file_count, tag_list, latest
end

--- Render a note's code snapshot as a line-numbered block.
---@param note table
---@return string  Empty string when the note has no snapshot.
local function render_code(note)
	if type(note.code) ~= "table" or #note.code == 0 then
		return ""
	end
	local start = note.start_line or 1
	local nums, lines = {}, {}
	for i, line in ipairs(note.code) do
		table.insert(nums, tostring(start + i - 1))
		table.insert(lines, esc(line))
	end
	local lang_class = ""
	if type(note.lang) == "string" and note.lang ~= "" then
		lang_class = ' class="language-' .. esc(note.lang) .. '"'
	end
	return table.concat({
		'<div class="codewrap">',
		'<pre class="gutter">' .. table.concat(nums, "\n") .. "</pre>",
		'<pre class="codeblock"><code' .. lang_class .. ">" .. table.concat(lines, "\n") .. "</code></pre>",
		"</div>",
	}, "\n")
end

--- Render a single note card.
---@param note table
---@return string
local function render_note(note)
	local tags = storage.extract_tags(note.text or "")
	local parts = { '<article class="note" data-tags="' .. esc(table.concat(tags, " ")) .. '">' }

	local s = note.start_line or 0
	local e = note.end_line or s
	local loc = (e > s) and string.format("L%d&ndash;%d", s, e) or string.format("L%d", s)
	local meta = { '<span class="loc">' .. loc .. "</span>" }
	local d = date_part(note.created_at)
	if d ~= "" then
		table.insert(meta, '<span class="date">' .. esc(d) .. "</span>")
	end
	table.insert(parts, '<div class="notemeta">' .. table.concat(meta) .. "</div>")

	local code_html = render_code(note)
	if code_html ~= "" then
		table.insert(parts, code_html)
	end

	table.insert(parts, '<div class="notetext">' .. render_text(note.text or "") .. "</div>")
	table.insert(parts, "</article>")
	return table.concat(parts, "\n")
end

--- Render the page for a single repository.
---@param repo table  { name, slug, notes }
---@return string
local function render_repo_page(repo)
	-- Group notes by file, preserving first-seen order
	local by_file, file_order = {}, {}
	for _, note in ipairs(repo.notes) do
		local f = note.file or "unknown"
		if not by_file[f] then
			by_file[f] = {}
			table.insert(file_order, f)
		end
		table.insert(by_file[f], note)
	end

	local file_count, tag_list = repo_stats(repo.notes)

	local b = {}
	table.insert(b, '<div class="wrap">')
	table.insert(b, '<header class="site"><a class="back" href="index.html">&larr; all projects</a></header>')
	table.insert(b, '<h1 class="repotitle">' .. esc(repo.name) .. "</h1>")
	table.insert(
		b,
		'<p class="subtitle">' .. plural(#repo.notes, "note") .. " across " .. plural(file_count, "file") .. "</p>"
	)

	if #tag_list > 0 then
		local chips = { '<div class="tagbar"><span class="chip active" data-tag="">all</span>' }
		for _, t in ipairs(tag_list) do
			table.insert(chips, '<span class="chip" data-tag="' .. esc(t) .. '">#' .. esc(t) .. "</span>")
		end
		table.insert(chips, "</div>")
		table.insert(b, table.concat(chips))
	end

	for _, file in ipairs(file_order) do
		table.insert(b, '<section class="filegroup">')
		table.insert(b, '<h2 class="filepath">' .. esc(file) .. "</h2>")
		for _, note in ipairs(by_file[file]) do
			table.insert(b, render_note(note))
		end
		table.insert(b, "</section>")
	end

	table.insert(b, footer())
	table.insert(b, "</div>")
	return page("fieldnotes — " .. repo.name, table.concat(b, "\n"), HLJS_HEAD, TAGBAR_JS)
end

--- Render the index page listing all repositories.
---@param repos table[]
---@return string
local function render_index(repos)
	local b = {}
	table.insert(b, '<div class="wrap">')
	table.insert(b, '<header class="site"><h1>&#128211; fieldnotes</h1><span class="subtitle">notebook</span></header>')

	if #repos == 0 then
		table.insert(b, '<p class="empty">No notes yet. Highlight some code and take a note to get started.</p>')
	else
		table.insert(b, '<div class="grid">')
		for _, repo in ipairs(repos) do
			local file_count, tag_list, latest = repo_stats(repo.notes)
			local chips = {}
			for i = 1, math.min(#tag_list, 6) do
				table.insert(chips, '<span class="chip">#' .. esc(tag_list[i]) .. "</span>")
			end
			if #tag_list > 6 then
				table.insert(chips, '<span class="chip">+' .. (#tag_list - 6) .. "</span>")
			end
			local card = {
				'<a class="card" href="' .. esc(repo.slug) .. '.html">',
				'<div class="cardname">' .. esc(repo.name) .. "</div>",
				'<div class="cardstats">'
					.. plural(#repo.notes, "note")
					.. " &middot; "
					.. plural(file_count, "file")
					.. "</div>",
			}
			if #chips > 0 then
				table.insert(card, '<div class="cardtags">' .. table.concat(chips) .. "</div>")
			end
			if latest ~= "" then
				table.insert(card, '<div class="cardupdated">updated ' .. esc(date_part(latest)) .. "</div>")
			end
			table.insert(card, "</a>")
			table.insert(b, table.concat(card, "\n"))
		end
		table.insert(b, "</div>")
	end

	table.insert(b, footer())
	table.insert(b, "</div>")
	return page("fieldnotes — notebook", table.concat(b, "\n"))
end

--- Load every repo (with at least one note) from the storage directory.
---@param config table|nil
---@return table[]  { name, slug, notes }
local function load_repos(config)
	local base = storage.get_base_dir(config)
	local repos = {}
	if vim.fn.isdirectory(base) == 0 then
		return repos
	end
	local used_slugs = { index = true } -- never let a repo page clobber index.html
	for _, name in ipairs(vim.fn.readdir(base)) do
		local notes_path = base .. "/" .. name .. "/notes.json"
		if name ~= "notebook" and vim.fn.filereadable(notes_path) == 1 then
			local content = table.concat(vim.fn.readfile(notes_path), "\n")
			local ok, notes = pcall(vim.fn.json_decode, content)
			if ok and type(notes) == "table" and #notes > 0 then
				local slug = slugify(name)
				if used_slugs[slug] then
					local n = 2
					while used_slugs[slug .. "-" .. n] do
						n = n + 1
					end
					slug = slug .. "-" .. n
				end
				used_slugs[slug] = true
				table.insert(repos, { name = name, slug = slug, notes = notes })
			end
		end
	end
	table.sort(repos, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return repos
end

--- Directory the generated site lives in.
---@param config table|nil
---@return string
function M.get_dir(config)
	return storage.get_base_dir(config) .. "/notebook"
end

--- Generate the static notebook site: index.html plus one HTML file per repo.
---@param config table|nil
---@return string dir  The directory the site was written to.
function M.generate(config)
	local out_dir = M.get_dir(config)
	vim.fn.mkdir(out_dir, "p")
	local repos = load_repos(config)

	local expected = { ["index.html"] = true }
	for _, repo in ipairs(repos) do
		local filename = repo.slug .. ".html"
		expected[filename] = true
		vim.fn.writefile(vim.split(render_repo_page(repo), "\n"), out_dir .. "/" .. filename)
	end
	vim.fn.writefile(vim.split(render_index(repos), "\n"), out_dir .. "/index.html")

	-- Remove pages for repos that no longer have notes
	for _, name in ipairs(vim.fn.readdir(out_dir)) do
		if name:match("%.html$") and not expected[name] then
			vim.fn.delete(out_dir .. "/" .. name)
		end
	end

	-- Bump the stamp so served pages auto-reload
	generation = generation + 1
	vim.fn.writefile({ os.time() .. "-" .. generation }, out_dir .. "/.stamp")

	return out_dir
end

return M
