-- pi-pipe.nvim lazy-loading entry point
-- Passively tracks selection/cursor and broadcasts to pi extension.

if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("pi-pipe.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
    return
end

-- Setup with defaults on load (user can override with require("pi-pipe").setup({...}))
vim.schedule(function()
    local mod = require("pi-pipe")
    if not mod._configured then
        mod.setup()
    end
end)
