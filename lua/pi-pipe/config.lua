---@class PiNvimConfig
---@field debounce_ms number Debounce time in ms for selection updates
---@field auto_start boolean Start tracking automatically on setup

local M = {}

M.defaults = {
    debounce_ms = 100,
    auto_start = true,
}

---@param opts PiNvimConfig|nil
function M.setup(opts)
    opts = opts or {}
    return vim.tbl_deep_extend("force", M.defaults, opts)
end

return M
