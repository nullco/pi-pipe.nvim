-- pi-pipe.nvim lazy-loading entry point
-- Passively tracks selection/cursor and broadcasts to pi extension.

if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("pi-pipe.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
    return
end

-- Setup with defaults on load (user can override with require("pi-pipe").setup({...}))
vim.schedule(function()
    if not require("pi-pipe").config or next(require("pi-pipe").config) == nil then
        require("pi-pipe").setup()
    end
end)
