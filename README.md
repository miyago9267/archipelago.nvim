# archipelago.nvim

Multi-root workspaces for Neovim, compatible with VSCode `.code-workspace` files.

Every folder is an island; the workspace is the archipelago. Open several repositories as
one project: a single file tree, one search over every folder, and terminal agents that see
the whole workspace. Every path you copy or that shows up in a buffer is the real path.

```
$ nvim platform.code-workspace

 File Tree                        │ api/src/server.ts
  ~/.local/state/nvim/archipelago/│
    api ➛ ~/code/api              │
      src                         │
        ✗ server.ts               │
    web ➛ ~/code/web              │
    infra ➛ ~/code/infra          │
```

## Why

Neovim has one cwd and most file trees have one root. The usual workaround is a directory of
symlinks, but then paths go wrong: the tree copies symlink paths, "follow current file" jumps
the root to the real repository, and `fd` / `rg` do not follow symlinks by default.

archipelago builds that symlink directory (the *hub*) for you and fixes the edges:

- **Real paths out.** Buffers, `:CopyPath`, and files opened from pickers use real paths, so
  what you paste into an agent or a terminal points at the right file.
- **Stable tree.** The tree root stays on the hub and reveals the file you are editing.
- **Search everything.** `fd` and `rg` follow the hub symlinks inside a workspace only.
- **Same file as VSCode.** Open an existing `.code-workspace`, or create one from Neovim.

## Requirements

- Neovim >= 0.10
- Optional: [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua),
  [fzf-lua](https://github.com/ibhagwan/fzf-lua) (with `fd` and `rg`)

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "miyago9267/archipelago.nvim",
  lazy = false, -- needed for `nvim foo.code-workspace`
  opts = {},
}
```

## Usage

| Command | Description |
| --- | --- |
| `nvim foo.code-workspace` | Start Neovim inside the workspace |
| `:Workspace open [name\|path]` | Open a workspace; without an argument pick one with `vim.ui.select` |
| `:Workspace new <name>` | Create a workspace from the current file's git root (or cwd); opens it if the name exists |
| `:Workspace add [dir]` | Add a folder. Default: the directory under the cursor in the file tree, else the current file's git root. Without an open workspace, starts an **untitled** one with the current project plus the new folder, no questions asked |
| `:Workspace remove [name]` | Remove a folder |
| `:Workspace save [name]` | Save to `store_dir` (asks for a name only if none is given); switches to the saved file |
| `:Workspace list` | Show the folders |
| `:Workspace close` | Close and return to the previous cwd; an untitled workspace is discarded |
| `:CopyPath` | Copy the real absolute path |
| `:CopyRelativePath` | Copy the path relative to cwd; inside a workspace this is `<folder>/<path>` |

Both copy commands accept a range: `:'<,'>CopyPath` copies `/real/path/file.ts:12-18`.
With `popup_menu = true` they also appear in the right-click menu.

Like VSCode, adding a folder never asks anything: without a workspace you get an untitled one,
kept in memory until you `:Workspace save` it. Changes to a saved workspace are written to its
file right away.

Named workspaces live in `store_dir`. Any `.code-workspace` file can be opened by path.

Inside a workspace the cwd is the hub, so relative paths given to `:Workspace add` resolve from
there; use absolute or `~` paths.

Suggested mappings (the plugin sets none):

```lua
vim.keymap.set("n", "<leader>Wa", function() require("archipelago").add() end, { desc = "Add folder" })
vim.keymap.set("n", "<leader>Wr", "<cmd>Workspace remove<CR>", { desc = "Remove folder" })
vim.keymap.set("n", "<leader>Wo", "<cmd>Workspace open<CR>", { desc = "Open workspace" })
vim.keymap.set("n", "<leader>Ws", "<cmd>Workspace save<CR>", { desc = "Save workspace" })
vim.keymap.set("n", "<leader>yp", "<cmd>CopyPath<CR>", { desc = "Copy absolute path" })
vim.keymap.set("n", "<leader>yr", "<cmd>CopyRelativePath<CR>", { desc = "Copy relative path" })
vim.keymap.set("v", "<leader>yp", ":CopyPath<CR>", { desc = "Copy absolute path:lines" })
vim.keymap.set("v", "<leader>yr", ":CopyRelativePath<CR>", { desc = "Copy relative path:lines" })
```

## Configuration

Defaults:

```lua
require("archipelago").setup({
  store_dir = vim.fn.stdpath("data") .. "/archipelago", -- named workspaces
  hub_dir = vim.fn.stdpath("state") .. "/archipelago",  -- generated symlink hubs
  auto_open = true,      -- `nvim foo.code-workspace` opens the workspace
  popup_menu = true,     -- Copy Path entries in the right-click menu
  notify_on_copy = true,
})
```

## Integrations

### nvim-tree

```lua
require("nvim-tree").setup({
  sync_root_with_cwd = true,
  update_focused_file = {
    enable = true,
    update_root = true, -- still applies outside a workspace
    exclude = require("archipelago.integrations.nvim-tree").exclude,
  },
  -- default mappings, with gy / Y copying real absolute / relative paths
  on_attach = require("archipelago.integrations.nvim-tree").on_attach,
})
```

While a workspace is open, `update_root` is switched off (nvim-tree would otherwise re-root at
the current file's repository after every cwd change) and restored on `:Workspace close`.

If you already have an `on_attach`, call `require("archipelago.integrations.nvim-tree").map_copy(bufnr)` in it.

### fzf-lua

Drop-in pickers that follow the hub inside a workspace and behave as usual outside:

```lua
local pick = require("archipelago.integrations.fzf-lua")
vim.keymap.set("n", "<C-p>", pick.files)
vim.keymap.set("n", "<leader>fg", pick.live_grep)
vim.keymap.set("n", "<leader>fw", pick.grep_cword)
vim.keymap.set("v", "<leader>fw", pick.grep_visual)
```

Pick folders to add with fzf: `pick.add_folder()` starts with frecent directories from
[zoxide](https://github.com/ajeetdsouza/zoxide) when installed, `<C-f>` switches to `fd` over
`$HOME` (depth 4), and `<Tab>` selects several. Pass `{ source = "fd", roots = { "~/code" }, max_depth = 3 }`
to change the search.

```lua
vim.keymap.set("n", "<leader>WA", pick.add_folder, { desc = "Add folder (fzf)" })
```

For other pickers, `require("archipelago.integrations.fzf-lua").opts("files" | "grep")` shows
what is needed: cwd set to the hub, `fd --follow`, `rg --follow`.

### Statusline and events

`require("archipelago").status()` returns the open workspace name or `nil`.
`User` autocommands fire on `ArchipelagoOpenPre` (before the cwd changes), `ArchipelagoOpen`,
`ArchipelagoChanged`, and `ArchipelagoClose`.

### Terminal agents

Inside a workspace the cwd is the hub, so agents started from Neovim (Claude Code, Codex, ...)
see every folder, and `:CopyRelativePath` output resolves from their cwd. Git commands need to
run inside a folder, since the hub itself is not a repository.

## VSCode compatibility

- Reads `folders[].path` and `folders[].name`. Relative paths resolve against the workspace
  file, as in VSCode. Full-line `//` comments and trailing commas are accepted.
- Folders given by `uri` (remote folders) are skipped.
- Other fields (`settings`, `extensions`, ...) are preserved but not interpreted.
- `:Workspace add` / `remove` rewrite the file: comments are dropped and new folders are
  written as absolute paths.
- `~` in paths is expanded by archipelago; VSCode does not expand it, so avoid it in shared files.

## How it works

Opening a workspace creates `hub_dir/<name>/` with one symlink per folder (duplicate names get
`-2`, `-3`, ...), then `:cd`s into it. Rebuilding the hub only unlinks symlinks inside it;
link targets are never touched. Neovim already resolves symlinks in buffer names, which keeps
LSP roots, git signs and agent integrations on real paths.

## Development

```sh
make test   # unit tests + integration tests against a real nvim-tree (cloned into .deps/)
```

## License

MIT
