-- Minimal zero-dependency HTTP server built on vim.uv (libuv).
-- Serves the generated notebook directory on localhost. The site is flat
-- (index.html + one page per repo), so only top-level files are served.

local uv = vim.uv or vim.loop

local M = {}

local state = {
	server = nil, ---@type uv_tcp_t|nil
	port = nil, ---@type number|nil
	dir = nil, ---@type string|nil
}

---@param path string
---@return string
local function content_type_for(path)
	if path:match("%.html?$") then
		return "text/html; charset=utf-8"
	elseif path:match("%.css$") then
		return "text/css; charset=utf-8"
	elseif path:match("%.js$") then
		return "text/javascript; charset=utf-8"
	elseif path:match("%.json$") then
		return "application/json"
	end
	return "text/plain; charset=utf-8"
end

---@param status string  e.g. "200 OK"
---@param ctype string
---@param body string
---@return string
local function http_response(status, ctype, body)
	return table.concat({
		"HTTP/1.1 " .. status,
		"Content-Type: " .. ctype,
		"Content-Length: " .. #body,
		"Cache-Control: no-store",
		"Connection: close",
		"",
		body,
	}, "\r\n")
end

---@param path string
---@return string|nil
local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

--- Decode %XX escapes in a URL path.
---@param s string
---@return string
local function url_decode(s)
	return (s:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

--- Build the HTTP response for a raw request.
--- Runs inside a libuv callback, so only plain Lua (no vim.api) is used here.
---@param request string
---@return string
local function handle(request)
	local method, raw_path = request:match("^(%u+)%s+([^%s]+)")
	if method ~= "GET" then
		return http_response("405 Method Not Allowed", "text/plain; charset=utf-8", "method not allowed")
	end

	local path = url_decode(raw_path:gsub("%?.*$", ""))
	if path == "/__stamp" then
		local stamp = read_file(state.dir .. "/.stamp") or "0"
		return http_response("200 OK", "text/plain; charset=utf-8", stamp)
	end
	if path == "/" then
		path = "/index.html"
	end

	-- The site is flat: reject traversal and any nested path outright
	if path:find("..", 1, true) or path:find("/", 2, true) or path:find("\\", 1, true) then
		return http_response("400 Bad Request", "text/plain; charset=utf-8", "bad request")
	end

	local body = read_file(state.dir .. path)
	if not body then
		return http_response("404 Not Found", "text/html; charset=utf-8", "<h1>404</h1><p>Not found.</p>")
	end
	return http_response("200 OK", content_type_for(path), body)
end

---@param client uv_tcp_t
local function close_client(client)
	if not client:is_closing() then
		client:close()
	end
end

---@param srv uv_tcp_t
---@return fun(err: string|nil)
local function on_connect(srv)
	return function(err)
		if err then
			return
		end
		local client = uv.new_tcp()
		srv:accept(client)
		local request = ""
		client:read_start(function(rerr, chunk)
			if rerr or not chunk then
				close_client(client)
				return
			end
			request = request .. chunk
			-- Respond once the request head is complete (GET has no body)
			if request:find("\r\n\r\n", 1, true) then
				client:read_stop()
				local ok, response = pcall(handle, request)
				if not ok then
					response = http_response("500 Internal Server Error", "text/plain; charset=utf-8", "internal error")
				end
				client:write(response, function()
					close_client(client)
				end)
			end
		end)
	end
end

--- Start serving `dir` on 127.0.0.1. Tries `port` first, then a few above it.
--- If the server is already running, just repoints it at `dir`.
---@param dir string
---@param port number
---@return string|nil url, string|nil err
function M.start(dir, port)
	state.dir = dir
	if state.server then
		return string.format("http://127.0.0.1:%d/", state.port)
	end

	local last_err = "could not bind a port"
	for p = port, port + 9 do
		local srv = uv.new_tcp()
		local ok, bind_err = srv:bind("127.0.0.1", p)
		if ok then
			local lok, listen_err = srv:listen(64, on_connect(srv))
			if lok then
				state.server = srv
				state.port = p
				return string.format("http://127.0.0.1:%d/", p)
			end
			last_err = listen_err or last_err
		else
			last_err = bind_err or last_err
		end
		srv:close()
	end
	return nil, last_err
end

--- Stop the server.
---@return boolean stopped  false if it wasn't running.
function M.stop()
	if not state.server then
		return false
	end
	state.server:close()
	state.server = nil
	state.port = nil
	return true
end

---@return boolean
function M.is_running()
	return state.server ~= nil
end

---@return string|nil
function M.url()
	if state.server then
		return string.format("http://127.0.0.1:%d/", state.port)
	end
	return nil
end

return M
