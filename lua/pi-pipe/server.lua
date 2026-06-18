---@brief Unix domain socket server for pi-pipe.nvim
--- Listens on a socket file, sends newline-delimited JSON selection updates
--- to connected clients (pi extension).

local M = {}

M.state = {
    server = nil,
    socket_path = nil,
    clients = {},
    cwd = nil, -- captured at start(), safe to use in libuv callbacks
}

M._next_client_id = 0

local PI_PIPE_DIR = "/tmp/pi-pipe"

---Generate a unique socket path for this Neovim instance
---@return string socket_path
local function make_socket_path()
    return PI_PIPE_DIR .. "/pipe-" .. vim.fn.getpid() .. ".sock"
end

---Start the Unix socket server
---@return string|nil socket_path, string|nil error
function M.start()
    if M.state.server then
        return M.state.socket_path -- already running
    end

    vim.fn.mkdir(PI_PIPE_DIR, "p")
    -- Best-effort: restrict the socket directory to the owner. Other local
    -- users should not be able to connect and read selection contents.
    pcall(vim.loop.fs_chmod, PI_PIPE_DIR, 0o700)

    local socket_path = make_socket_path()

    -- Remove stale socket file if it exists
    os.remove(socket_path)

    local server = vim.loop.new_pipe(false)
    if not server then
        return nil, "Failed to create pipe server"
    end

    local ok, err = server:bind(socket_path)
    if not ok then
        server:close()
        return nil, "Failed to bind: " .. (err or "unknown")
    end

    -- Restrict the socket file itself to owner-only (rw).
    pcall(vim.loop.fs_chmod, socket_path, 0o600)

    ok, err = server:listen(128, function(listen_err)
        if listen_err then
            return
        end
        M._accept(server)
    end)

    if not ok then
        server:close()
        return nil, "Failed to listen: " .. (err or "unknown")
    end

    M.state.server = server
    M.state.socket_path = socket_path
    M.state.cwd = vim.fn.getcwd()

    return socket_path
end

---Accept a new client connection
function M._accept(server)
    local client = vim.loop.new_pipe(false)
    if not client then
        return
    end

    local ok, err = server:accept(client)
    if not ok then
        if client and not client:is_closing() then
            client:close()
        end
        return
    end

    local client_id = tostring(M._next_client_id + 1)
    M._next_client_id = M._next_client_id + 1
    M.state.clients[client_id] = client

    -- Send handshake with cwd so pi can match to the right project
    local handshake = vim.json.encode({
        type = "handshake",
        cwd = M.state.cwd,
    }) .. "\n"
    client:write(handshake)

    -- Send latest selection to newly connected client so pi has context immediately
    vim.schedule(function()
        local sel_lib = package.loaded["pi-pipe.selection"]
        if sel_lib and sel_lib.state and sel_lib.state.tracking_enabled then
            sel_lib.update_and_broadcast(true)
        end
    end)

    -- Drain any incoming data; we don't expect clients to send anything,
    -- but read_start is required to get EOF/error notifications.
    client:read_start(function(read_err, data)
        if read_err then
            M._remove_client(client_id)
            return
        end
        if not data then
            -- EOF
            M._remove_client(client_id)
            return
        end
        -- Discard inbound data; protocol is server->client only.
    end)
end

---Remove a client
function M._remove_client(client_id)
    local client = M.state.clients[client_id]
    if client and not client:is_closing() then
        client:close()
    end
    M.state.clients[client_id] = nil
end

---Broadcast a message to all connected clients
---@param data string Raw data to send (should include newline)
function M.broadcast(data)
    for id, client in pairs(M.state.clients) do
        if client and not client:is_closing() then
            client:write(data)
        end
    end
end

---Stop the server
function M.stop()
    -- Close all clients
    for id, client in pairs(M.state.clients) do
        if client and not client:is_closing() then
            client:close()
        end
    end
    M.state.clients = {}

    -- Close server
    if M.state.server and not M.state.server:is_closing() then
        M.state.server:close()
    end
    M.state.server = nil

    -- Remove socket file
    if M.state.socket_path then
        os.remove(M.state.socket_path)
        M.state.socket_path = nil
    end
end

---Get the current socket path
---@return string|nil
function M.get_socket_path()
    return M.state.socket_path
end

return M
