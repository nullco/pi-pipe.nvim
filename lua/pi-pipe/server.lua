---@brief TCP server for pi-pipe.nvim
--- Listens on a random port, sends newline-delimited JSON selection updates
--- to connected clients (pi extension).

local M = {}

M.state = {
    server = nil,
    port = nil,
    clients = {},
}

---Find a random available port
---@return number|nil port
local function find_port()
    local server = vim.loop.new_tcp()
    if not server then
        return nil
    end
    local ok = server:bind("127.0.0.1", 0)
    if not ok then
        server:close()
        return nil
    end
    local sockname = server:getsockname()
    local port = sockname and sockname.port
    server:close()
    return port
end

---Start the TCP server
---@return number|nil port, string|nil error
function M.start()
    if M.state.server then
        return M.state.port -- already running
    end

    local port = find_port()
    if not port then
        return nil, "Could not find available port"
    end

    local server = vim.loop.new_tcp()
    if not server then
        return nil, "Failed to create TCP server"
    end

    local ok, err = server:bind("127.0.0.1", port)
    if not ok then
        server:close()
        return nil, "Failed to bind: " .. (err or "unknown")
    end

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
    M.state.port = port

    return port
end

---Accept a new client connection
function M._accept(server)
    local client = vim.loop.new_tcp()
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

    local client_id = tostring(client):gsub(".*: ", "")
    M.state.clients[client_id] = client

    -- Send latest selection to newly connected client so pi has context immediately
    vim.schedule(function()
        local sel_lib = package.loaded["pi-pipe.selection"]
        if sel_lib and sel_lib.state and sel_lib.state.tracking_enabled then
            sel_lib.update_and_broadcast(true)
        end
    end)

    -- Accumulate data until newline
    local buffer = ""

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

        buffer = buffer .. data

        -- We don't expect clients to send data, but drain any received lines
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
    M.state.port = nil
end

---Get the current port
---@return number|nil
function M.get_port()
    return M.state.port
end

return M
