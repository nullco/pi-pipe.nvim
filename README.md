# pi-pipe.nvim

Keep your [pi](https://pi.dev) coding agent aware of what you're looking at in Neovim — in real time via Unix domain sockets.

As you move your cursor or select code, pi receives live updates. On every prompt, the current selection (or buffer) is automatically injected as context.

## How it works

Two pieces communicating over a local Unix domain socket:

1. **Neovim plugin** — starts a Unix socket server at `/tmp/pi-pipe/pipe-<nvim-pid>.sock`, broadcasts cursor/selection as NDJSON on every `CursorMoved` / `ModeChanged`. On connect, sends a handshake with its `cwd`.

2. **Pi extension** — scans `/tmp/pi-pipe/` for `.sock` files from alive processes, connects to each, reads the handshake, and keeps the first one whose `cwd` matches (same project or ancestor/descendant). Caches the latest selection. Shows the current file and selection in pi's footer status line. The `/nvim` command sends a prompt with that selection (or file) attached as context.

```
CursorMoved → selection.lua → Unix Socket → pi extension caches
                                        │
                           updates footer status line
                                        │
                     `/nvim <prompt>`: sent to LLM as context
```

## Installation

### 1. Pi extension

This repo is a pi package. Install with `pi install`:

```bash
# From git (once pushed)
pi install git:github.com/nullco/pi-pipe.nvim

# From local path (for development)
pi install ~/Projects/pi-pipe.nvim
```

Restart pi. You should see `pi-pipe ready (cwd: ...)` on startup.

### 2. Neovim plugin

#### lazy.nvim

```lua
{
    "nullco/pi-pipe.nvim",
    dir = "~/Projects/pi-pipe.nvim", -- or omit for git install
    config = function()
        require("pi-pipe").setup()
    end,
}
```

## Usage

No keymaps, no commands to run. Just open pi in your project, then open Neovim. The plugin starts automatically.

To send a prompt with your current Neovim context attached, use the `/nvim` command in pi. It attaches the active selection, or — if nothing is selected — the current file and cursor position:

```
/nvim explain what this function does
/nvim refactor this to use async/await
```

The args can be multiline (everything after the first space is the prompt). With no args, only the context is sent. You'll also see the current file and selection state in pi's footer:

- **`file.lua:42`** — cursor on line 42, nothing selected
- **`sel: file.lua:10-25`** — text selected on lines 10-25

### Commands

| Command | Action |
|---------|--------|
| `:PiStart` | Start the Unix socket server and selection tracking |
| `:PiStop` | Stop tracking and shut down the server |
| `:PiStatus` | Show socket path and current selection info |
| `:PiTest` | Force a test broadcast to verify connectivity |

## Configuration

```lua
require("pi-pipe").setup({
    -- Debounce time for selection updates (ms)
    debounce_ms = 100,

    -- Start automatically on setup
    auto_start = true,
})
```

## How matching works

Pi scans `/tmp/pi-pipe/` for port files from running Neovim instances. It matches any Neovim that shares a common project tree with pi — same directory, ancestor, or descendant (any depth). Multiple project pairs work independently.

## Troubleshooting

**`No notification on startup`:** Make sure the pi extension is installed. Run `pi` and look for `pi-pipe ready`.

**Selection not showing up:** Ensure Neovim is running (with the plugin loaded) *before* you start pi in the same project. Run `:PiStatus` in Neovim to verify.

**`pi-pipe: Failed to start server`:** Check permissions on `/tmp/pi-pipe/`. Run `:PiStart` manually to see the error.

## License

MIT

## Tests

```bash
# TypeScript helpers (node:test)
npm run test:ts

# Lua selection spec (requires plenary.nvim on your runtimepath)
npm run test:nvim

# Both
npm test
```
