local M = {}

M.config = {}
M.state = {
    socket_path = nil,
}
M._configured = false

---@param opts PiNvimConfig|nil
function M.setup(opts)
    M.config = require("pi-pipe.config").setup(opts)

    local selection = require("pi-pipe.selection")
    local server = require("pi-pipe.server")

    -- Pass config to selection module (avoids circular require)
    selection.set_config(M.config)

    -- Start the Unix socket server
    if M.config.auto_start then
        local socket_path, err = server.start()
        if not socket_path then
            vim.notify("pi-pipe: Failed to start server: " .. (err or "unknown"), vim.log.levels.ERROR)
            return
        end
        M.state.socket_path = socket_path

        -- Enable selection tracking (passes server reference)
        selection.enable(server)

        vim.notify("pi-pipe: listening on " .. socket_path, vim.log.levels.INFO)
    end

    -- User commands
    vim.api.nvim_create_user_command("PiStart", function()
        local socket_path, err = server.start()
        if not socket_path then
            vim.notify("pi-pipe: Failed: " .. (err or "unknown"), vim.log.levels.ERROR)
            return
        end
        M.state.socket_path = socket_path
        selection.enable(server)
        vim.notify("pi-pipe: listening on " .. socket_path, vim.log.levels.INFO)
    end, { desc = "Start pi-pipe server and selection tracking" })

    vim.api.nvim_create_user_command("PiStop", function()
        selection.disable()
        server.stop()
        M.state.socket_path = nil
        vim.notify("pi-pipe: stopped", vim.log.levels.INFO)
    end, { desc = "Stop pi-pipe server" })

    vim.api.nvim_create_user_command("PiStatus", function()
        if M.state.socket_path then
            local sel = selection.get_current_selection()
            local info = "pi-pipe: " .. M.state.socket_path .. " | "
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
        if not M.state.socket_path then
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
        end,
    })

    vim.notify("pi-pipe: ready", vim.log.levels.INFO)
    M._configured = true
end

return M
