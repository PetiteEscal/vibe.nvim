# vibe.nvim

Run [Mistral Vibe](https://docs.mistral.ai/vibe/code/overview) inside Neovim, with commands and keymaps to send files/selections as `@`-mentions, start sessions, and navigate resumes.

A lightweight, terminal-wrapper Neovim plugin inspired by [claudecode.nvim](https://github.com/coder/claudecode.nvim). Instead of re-implementing an IDE protocol, it launches the `vibe` CLI in a Neovim terminal split (or float) and drives Vibe's own TUI — sending context by typing `@path` mentions and slash commands into the running session.

## How it differs from claudecode.nvim

claudecode.nvim runs a WebSocket server and speaks Claude Code's proprietary IDE protocol so Claude can call editor tools. **Vibe uses a different protocol (ACP)**, where the editor would be an ACP client and Vibe a headless agent. That is a large, separate undertaking.

vibe.nvim takes the pragmatic path: Vibe already has an excellent interactive TUI (rich rendering, `/resume` picker, `@`-mentions, `/model`, `/config`). This plugin just runs that TUI inside Neovim and wires up convenient keymaps. The tradeoff is **no native Neovim diff view** — Vibe edits files on disk and you reload buffers. Everything else you'd want (send file, send selection, start session, resume, model picker) works by driving Vibe's own UI.

## Requirements

- Neovim >= 0.8.0
- [Mistral Vibe CLI](https://docs.mistral.ai/vibe/code/cli/install-setup) installed and on `PATH` (or set `terminal_cmd`)
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) (optional, for a nicer terminal; the native fallback needs nothing)

## Installation

### lazy.nvim

```lua
{
  "your-org/vibe.nvim",
  dependencies = { "folke/snacks.nvim" },
  config = true,
  -- `cmd` lets lazy.nvim create command stubs that load the plugin on first use,
  -- so `:Vibe` and friends work on a fresh start.
  cmd = {
    "Vibe",
    "VibeFocus",
    "VibeAdd",
    "VibeSend",
    "VibeSendText",
    "VibeTreeAdd",
    "VibeNew",
    "VibeResume",
    "VibeContinue",
    "VibeModel",
    "VibeCompact",
    "VibeStatus",
    "VibeRestart",
    "VibeQuit",
    "VibeDiagnostic",
    "VibePlans",
  },
  -- Letters aligned with claudecode.nvim (`<leader>a*` -> `<leader>v*`):
  -- b=buffer, s=send, q=kill, r=resume, C=continue, e=diagnostic.
  -- vv=toggle (c is taken by continue). vk=compact (C taken by continue).
  keys = {
    { "<leader>v", nil, desc = "Vibe" },
    { "<leader>vv", "<cmd>Vibe<cr>", desc = "Toggle Vibe" },
    { "<leader>vf", "<cmd>VibeFocus<cr>", desc = "Focus Vibe" },
    { "<leader>vq", "<cmd>VibeQuit<cr>", desc = "Kill Vibe (force)" },
    { "<leader>vb", "<cmd>VibeAdd %<cr>", desc = "Add current buffer to Vibe" },
    { "<leader>vs", "<cmd>VibeSend<cr>", mode = "v", desc = "Send selection to Vibe" },
    {
      "<leader>vs",
      "<cmd>VibeTreeAdd<cr>",
      desc = "Add file",
      ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw", "snacks_picker_list" },
    },
    { "<leader>ve", "<cmd>VibeDiagnostic<cr>", desc = "Send line diagnostic to Vibe" },
    { "<leader>vn", "<cmd>VibeNew<cr>", desc = "New Vibe session (/clear)" },
    { "<leader>vr", "<cmd>VibeResume<cr>", desc = "Resume Vibe (vibe --resume)" },
    { "<leader>vC", "<cmd>VibeContinue<cr>", desc = "Continue last session (vibe -c)" },
    { "<leader>vm", "<cmd>VibeModel<cr>", desc = "Select model (/model)" },
    { "<leader>vk", "<cmd>VibeCompact<cr>", desc = "Compact context (/compact)" },
    { "<leader>vp", "<cmd>VibePlans<cr>", desc = "Open a Vibe plan" },
  },
}
```

That's it — the plugin auto-configures everything else. With this spec the plugin loads on first use (a listed `cmd` is run or a mapped key is pressed), not at startup.

### Local install / custom path

If `vibe` is not on your `PATH`, point the plugin at it:

```lua
{
  "your-org/vibe.nvim",
  opts = {
    terminal_cmd = "~/.local/bin/vibe",
  },
  config = true,
  -- ... cmd / keys as above
}
```

## Commands

| Command | Description |
| --- | --- |
| `:Vibe [args]` | Toggle the Vibe terminal (launches `vibe` on first open; `args` apply on a fresh launch) |
| `:VibeFocus` | Smart focus/toggle the Vibe terminal |
| `:VibeAdd <file> [start] [end]` | Add a file (or the current buffer with `%`) to Vibe context as an `@`-mention |
| `:VibeSend` | In visual mode: send the selection as text. In a tree buffer: add the selected file(s) |
| `:VibeSendText {text}` | Type text into the Vibe prompt and submit (`!` inserts without submitting) |
| `:VibeTreeAdd` | Add the file under the cursor / selection in a tree explorer to Vibe |
| `:VibeNew` | Start a fresh session (`/clear`) |
| `:VibeResume` | Relaunch Vibe with the resume session picker (`vibe --resume`) |
| `:VibeContinue` | Relaunch Vibe resuming the last session (`vibe -c`) |
| `:VibeModel` | Open Vibe's model picker (`/model`) |
| `:VibeCompact` | Compact the session context (`/compact`) |
| `:VibeStatus` | Show vibe.nvim status (terminal running? provider) |
| `:VibeRestart [args]` | Restart the Vibe terminal (optionally with extra args) |
| `:VibeQuit` | Kill the Vibe terminal process (force) — use before `:VibeContinue`/`:VibeResume` so `-c` actually relaunches |
| `:VibeDiagnostic` | Send the current line's diagnostics to Vibe's prompt (submitted) |
| `:VibePlans` | List and open a Vibe plan file (`~/.vibe/plans/*.md`, most recent first) |
| `:checkhealth vibe` | Verify Neovim version, the `vibe` CLI, terminal provider, and running state |

## Usage

1. **Launch Vibe**: `:Vibe` opens Vibe in a split terminal. The first `:VibeAdd`/`:VibeSend` you trigger also auto-launches it.
2. **Send context**:
   - Select text in visual mode and press `<leader>vs` to paste it into Vibe's prompt and submit.
   - `<leader>vb` adds the current buffer to Vibe as `@relative/path` (inserted into the prompt so you can follow it with a question).
   - In `nvim-tree`/`neo-tree`/`oil.nvim`/`mini.files`/`netrw`/a snacks picker list, press `<leader>vs` (or `:VibeTreeAdd`) on a file to add it.
   - `<leader>ve` sends the diagnostics on the current line to Vibe's prompt (mirrors claudecode.nvim's `<leader>ae`).
3. **Sessions**: `<leader>vr` relaunches Vibe with `--resume`; `<leader>vn` starts fresh; `<leader>vC` relaunches with `-c`.
4. **Model / compact**: `<leader>vm` and `<leader>vk` drive Vibe's own pickers.

`@`-mentions are sent as a bracketed paste so Vibe inserts the path literally (it does not open its interactive `@`-mention picker) and reads the file into context on submit.

### Sending text programmatically

```lua
local vibe = require("vibe")
vibe.send_text("explain this function")            -- types + submits
vibe.send_text("draft prompt", { submit = false }) -- insert only
vibe.send_file("lua/vibe/init.lua")                -- add a file as @mention (insert only)
vibe.send_diagnostic()                             -- send current line's diagnostics (submitted)
```

This writes directly to the terminal's job channel, so it only works with the in-editor providers (`native`/`snacks`). The `external`/`none` providers run Vibe outside Neovim and expose no pane to write to.

## Events

The plugin fires `User` autocmds you can hook with `nvim_create_autocmd`.

### `VibeSendComplete`

Fired once per file, synchronously, when a send (`:VibeSend`, `:VibeAdd`, tree add, `send_file`) is dispatched while a Vibe terminal is running. Useful to focus a Vibe session running outside Neovim (`provider = "none"`/`"external"`).

| field | type | notes |
| --- | --- | --- |
| `file_path` | `string` | The formatted/cwd-relative path Vibe received |
| `start_line` | `integer\|nil` | 1-indexed; `nil` for whole files |
| `end_line` | `integer\|nil` | 1-indexed; `nil` for whole-file/directory sends |
| `context` | `string\|nil` | Internal trigger tag (e.g. `"VibeSend"`); best-effort, may change |

Note: fires at **dispatch** time, not delivery — sending retries until Vibe's terminal channel is ready, so a later failure is logged, not reported here. Fires only when text was actually written to a channel (or queued with a launch).

## Advanced configuration

```lua
{
  "your-org/vibe.nvim",
  opts = {
    terminal_cmd = nil,        -- nil => "vibe" from PATH; or absolute path
    env = {},                   -- custom env vars for the Vibe process
    log_level = "info",         -- "trace"|"debug"|"info"|"warn"|"error"
    focus_after_send = false,   -- focus the in-editor terminal after a successful send
    startup_send_timeout = 15000, -- ms to retry a send while Vibe boots (no channel yet)
    send_retry_interval = 300,   -- ms between retries

    terminal = {
      split_side = "right",            -- "left" or "right"
      split_width_percentage = 0.30,
      provider = "auto",               -- "auto"|"snacks"|"native"|"external"|"none"|table
      auto_close = true,
      auto_insert = true,              -- enter insert mode when the terminal gains focus
      snacks_win_opts = {},            -- opts forwarded to Snacks.terminal.open()
      provider_opts = {
        external_terminal_cmd = nil,   -- e.g. "alacritty -e %s"
      },
      -- Working directory control (precedence: cwd_provider > cwd > git_repo_cwd)
      cwd = nil,
      git_repo_cwd = false,
      cwd_provider = nil,              -- function(ctx) -> path string
    },
  },
}
```

### Floating window (snacks)

```lua
local toggle = "<C-,>"
return {
  {
    "your-org/vibe.nvim",
    dependencies = { "folke/snacks.nvim" },
    keys = { { toggle, "<cmd>VibeFocus<cr>", desc = "Vibe", mode = { "n", "x" } } },
    opts = {
      terminal = {
        snacks_win_opts = {
          position = "float",
          width = 0.9,
          height = 0.9,
          keys = {
            vibe_hide = { toggle, function(self) self:hide() end, mode = "t", desc = "Hide" },
          },
        },
      },
    },
  },
}
```

### Terminal providers

- `"auto"` (default): Snacks.nvim if available, else native.
- `"native"`: a plain Neovim `vsplit` terminal (no dependencies).
- `"external"`: launch Vibe in a separate terminal app via `provider_opts.external_terminal_cmd` (`"alacritty -e %s"`, or a `function(cmd, env)`). No in-editor pane, so send commands can't write to it.
- `"none"`: no terminal management at all — you run Vibe yourself (tmux, etc.) and the plugin only provides commands/keymaps. Send commands warn; hook `User VibeSendComplete` to focus your external session.
- Custom: pass a table implementing `setup`, `open`, `close`, `simple_toggle`, `focus_toggle`, `get_active_bufnr`, `is_available` (see claudecode.nvim's custom provider docs for the shape).

## Troubleshooting

- **First stop:** `:checkhealth vibe` — verifies the `vibe` CLI is installed, the terminal provider, and whether a Vibe terminal is running.
- **`vibe` not found?** Set `terminal_cmd` to the full path (`which vibe`).
- **Need debug logs?** Set `log_level = "debug"` in opts.
- **Terminal issues?** Try `provider = "native"`.
- **Send seems lost on first use?** Vibe's TUI takes a moment to boot; the plugin retries sends up to `startup_send_timeout` (15s default). Increase it if your machine is slow.

## Architecture

This plugin reuses the terminal-management layer from claudecode.nvim (Snacks/native/external/none providers, window toggle, anchor-preserving hide/show) but **removes** the WebSocket server, lock file, MCP tools, and diff integration — none of which apply to Vibe's ACP-based model. Instead, context sharing is done by typing `@`-mentions and slash commands into Vibe's own TUI.

## License

MIT
