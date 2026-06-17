---@brief Passive selection tracking for pi-pipe.nvim
--- Tracks cursor/selection and broadcasts via TCP to the pi extension.
--- Patterned after amp.nvim's selection tracking.

local M = {}

-- State
M.state = {
    latest_selection = nil,
    tracking_enabled = false,
    debounce_timer = nil,
    debounce_ms = 100,
    server = nil, -- reference to the tcp server module
}

-- Config (set by init.lua to avoid circular require)
local _config = {}

---Set config from parent module
---@param cfg table
function M.set_config(cfg)
    _config = cfg or {}
    M.state.debounce_ms = _config.debounce_ms or 100
end

---Get the visual selection if in visual mode
---@return table|nil { text, fileUrl, start_line, start_char, end_line, end_char }
function M.get_visual_selection()
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
        return nil
    end

    local buf = vim.api.nvim_get_current_buf()
    local file_path = vim.api.nvim_buf_get_name(buf)
    if file_path == "" then
        return nil
    end

    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")

    if start_pos[2] == 0 or end_pos[2] == 0 then
        return nil
    end

    -- 0-indexed
    local start_line = start_pos[2] - 1
    local start_char = start_pos[3] - 1
    local end_line = end_pos[2] - 1
    local end_char = end_pos[3] - 1

    -- Ensure start comes before end
    if start_line > end_line or (start_line == end_line and start_char > end_char) then
        start_line, end_line = end_line, start_line
        start_char, end_char = end_char, start_char
    end

    local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line + 1, false)
    local text = ""

    if #lines > 0 then
        if mode == "V" then
            start_char = 0
            end_char = #lines[#lines]
            text = table.concat(lines, "\n")
        elseif #lines == 1 then
            text = string.sub(lines[1], start_char + 1, end_char + 1)
        else
            local parts = {}
            parts[#parts + 1] = string.sub(lines[1], start_char + 1)
            for i = 2, #lines - 1 do
                parts[#parts + 1] = lines[i]
            end
            parts[#parts + 1] = string.sub(lines[#lines], 1, end_char + 1)
            text = table.concat(parts, "\n")
        end
    end

    return {
        text = text,
        fileUrl = "file://" .. file_path,
        start_line = start_line,
        start_char = start_char,
        end_line = end_line,
        end_char = end_char,
    }
end

---Get cursor position as a zero-width selection
---@return table|nil { text, fileUrl, start_line, start_char, end_line, end_char }
function M.get_cursor_position()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local buf = vim.api.nvim_get_current_buf()
    local file_path = vim.api.nvim_buf_get_name(buf)

    if file_path == "" then
        return nil
    end

    return {
        text = "",
        fileUrl = "file://" .. file_path,
        start_line = cursor[1] - 1,
        start_char = cursor[2],
        end_line = cursor[1] - 1,
        end_char = cursor[2],
    }
end

---Get current selection (visual or cursor)
---@return table|nil
function M.get_current_selection()
    local vis = M.get_visual_selection()
    if vis then
        return vis
    end
    return M.get_cursor_position()
end

---Get relative file path
---@return string|nil
function M.get_relative_path()
    local path = vim.fn.expand("%:p")
    if path == "" then
        return nil
    end
    local cwd = vim.fn.getcwd()
    if vim.startswith(path, cwd) then
        return path:sub(#cwd + 2)
    end
    return path
end

---Check if selection has changed since last broadcast
---@param new_sel table
---@return boolean
function M.has_selection_changed(new_sel)
    local old = M.state.latest_selection
    if not old then
        return true
    end
    if not new_sel then
        return old ~= nil
    end
    if old.fileUrl ~= new_sel.fileUrl then
        return true
    end
    if old.text ~= new_sel.text then
        return true
    end
    if old.start_line ~= new_sel.start_line
        or old.start_char ~= new_sel.start_char
        or old.end_line ~= new_sel.end_line
        or old.end_char ~= new_sel.end_char
    then
        return true
    end
    return false
end

---Build the payload and broadcast via TCP
---@param force boolean Force send even if unchanged
function M.update_and_broadcast(force)
    if not M.state.tracking_enabled then
        return
    end
    if not M.state.server then
        return
    end

    local sel = M.get_current_selection()
    if not sel then
        return
    end

    if not force and not M.has_selection_changed(sel) then
        return
    end

    M.state.latest_selection = sel

    local payload = {
        type = "selection",
        pid = vim.fn.getpid(),
        cwd = vim.fn.getcwd(),
        fileUrl = sel.fileUrl,
        relativePath = M.get_relative_path(),
        fileName = vim.fn.fnamemodify(sel.fileUrl:gsub("^file://", ""), ":t"),
        selection = {
            startLine = sel.start_line + 1,
            startChar = sel.start_char,
            endLine = sel.end_line + 1,
            endChar = sel.end_char,
            text = sel.text,
        },
        mode = vim.api.nvim_get_mode().mode,
    }

    -- Broadcast via TCP (NDJSON: one line per message)
    local json = vim.json.encode(payload)
    M.state.server.broadcast(json .. "\n")
end

---Debounced update
function M.debounced_update()
    if M.state.debounce_timer then
        M.state.debounce_timer:stop()
        M.state.debounce_timer:close()
    end

    M.state.debounce_timer = vim.defer_fn(function()
        M.update_and_broadcast()
        M.state.debounce_timer = nil
    end, M.state.debounce_ms)
end

---Enable selection tracking
---@param server table The TCP server module
function M.enable(server)
    if M.state.tracking_enabled then
        return
    end

    M.state.server = server
    M.state.tracking_enabled = true
    M.state.debounce_ms = _config.debounce_ms or 100

    M._create_autocommands()

    -- Initial broadcast after a short delay
    vim.defer_fn(function()
        M.update_and_broadcast(true)
    end, 200)
end

---Disable selection tracking
function M.disable()
    if not M.state.tracking_enabled then
        return
    end

    M.state.tracking_enabled = false
    M.state.server = nil
    M._clear_autocommands()

    if M.state.debounce_timer then
        M.state.debounce_timer:stop()
        M.state.debounce_timer:close()
        M.state.debounce_timer = nil
    end
end

---Create autocommands for selection tracking
function M._create_autocommands()
    local group = vim.api.nvim_create_augroup("PiPipeSelection", { clear = true })

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = function()
            M.debounced_update()
        end,
    })

    vim.api.nvim_create_autocmd("ModeChanged", {
        group = group,
        callback = function()
            M.update_and_broadcast(true)
        end,
    })

    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
        group = group,
        callback = function()
            M.debounced_update()
        end,
    })
end

---Clear autocommands
function M._clear_autocommands()
    vim.api.nvim_clear_autocmds({ group = "PiPipeSelection" })
end

return M
