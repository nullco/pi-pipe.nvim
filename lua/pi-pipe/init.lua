local M = {}

M.config = {}
M.state = {
    port = nil,
}

---@param opts PiNvimConfig|nil
function M.setup(opts)
    M.config = require("pi-pipe.config").setup(opts)

    local selection = require("pi-pipe.selection")
    local server = require("pi-pipe.server")

    -- Pass config to selection module (avoids circular require)
    selection.set_config(M.config)

    -- Start the TCP server
    if M.config.auto_start then
        local port, err = server.start()
        if not port then
            vim.notify("pi-pipe: Failed to start server: " .. (err or "unknown"), vim.log.levels.ERROR)
            return
        end
        M.state.port = port

        -- Write port to well-known file so pi extension can discover it
        M._write_port_file(port)

        -- Enable selection tracking (passes server reference)
        selection.enable(server)

        vim.notify("pi-pipe: listening on port " .. port, vim.log.levels.INFO)
    end

    -- User commands
    vim.api.nvim_create_user_command("PiStart", function()
        local port, err = server.start()
        if not port then
            vim.notify("pi-pipe: Failed: " .. (err or "unknown"), vim.log.levels.ERROR)
            return
        end
        M.state.port = port
        M._write_port_file(port)
        selection.enable(server)
        vim.notify("pi-pipe: listening on port " .. port, vim.log.levels.INFO)
    end, { desc = "Start pi-pipe server and selection tracking" })

    vim.api.nvim_create_user_command("PiStop", function()
        selection.disable()
        server.stop()
        M._remove_port_file()
        M.state.port = nil
        vim.notify("pi-pipe: stopped", vim.log.levels.INFO)
    end, { desc = "Stop pi-pipe server" })

    vim.api.nvim_create_user_command("PiStatus", function()
        if M.state.port then
            local sel = selection.get_current_selection()
            local info = "pi-pipe: port " .. M.state.port .. " | "
            if sel then
                local filename = vim.fn.fnamemodify(sel.fileUrl:gsub("^file://", ""), ":t")
                info = info .. filename
            else
                info = info .. "no file"
            end
            vim.notify(info, vim.log.levels.INFO)
        else
            vim.notify("pi-pipe: not running", vim.log.levels.INFO)
        end
    end, { desc = "Show pi-pipe status" })

    vim.api.nvim_create_user_command("PiTest", function()
        if not M.state.port then
            vim.notify("pi-pipe: not running (run :PiStart first)", vim.log.levels.WARN)
            return
        end
        selection.update_and_broadcast(true)
        local sel = selection.get_current_selection()
        if sel then
            vim.notify("pi-pipe: test broadcast sent (" .. (sel.fileUrl:gsub("^file://", "") or "?" ) .. ")", vim.log.levels.INFO)
        else
            vim.notify("pi-pipe: no file open to broadcast", vim.log.levels.WARN)
        end
    end, { desc = "Force a test broadcast to pi" })

    -- Cleanup on exit
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("PiPipeShutdown", { clear = true }),
        callback = function()
            selection.disable()
            server.stop()
            M._remove_port_file()
        end,
    })

    vim.notify("pi-pipe: ready", vim.log.levels.INFO)
end

local PI_PIPE_DIR = "/tmp/pi-pipe"

---Write port to a per-instance file for pi extension discovery
function M._write_port_file(port)
    vim.fn.mkdir(PI_PIPE_DIR, "p")
    local file = PI_PIPE_DIR .. "/port-" .. vim.fn.getpid() .. ".json"
    local data = vim.json.encode({
        pid = vim.fn.getpid(),
        port = port,
        cwd = vim.fn.getcwd(),
    })
    local f = io.open(file, "w")
    if f then
        f:write(data)
        f:close()
    end
end

---Remove the port file
function M._remove_port_file()
    local file = PI_PIPE_DIR .. "/port-" .. vim.fn.getpid() .. ".json"
    os.remove(file)
end

return M
