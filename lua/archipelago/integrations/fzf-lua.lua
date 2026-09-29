-- fzf-lua integration: the same pickers, but following the hub symlinks inside a workspace.
--
--   vim.keymap.set("n", "<C-p>", require("archipelago.integrations.fzf-lua").files)
--   vim.keymap.set("n", "<leader>fg", require("archipelago.integrations.fzf-lua").live_grep)
--   vim.keymap.set("n", "<leader>WA", require("archipelago.integrations.fzf-lua").add_folder)
local archipelago = require("archipelago")

local M = {}

--- Extra fzf-lua options. Empty outside a workspace, so behaviour is unchanged.
---@param kind "files"|"grep"
---@return table
function M.opts(kind)
  if not archipelago.state then
    return {}
  end
  local ok, defaults = pcall(require, "fzf-lua.defaults")
  local d = ok and defaults.defaults or {}
  if kind == "files" then
    local fd = d.files and d.files.fd_opts or "--color=never --type f --hidden --exclude .git"
    return { cwd = archipelago.state.hub, fd_opts = fd .. " --follow" }
  end
  local rg = d.grep and d.grep.rg_opts or "--column --line-number --no-heading --color=always --smart-case"
  return { cwd = archipelago.state.hub, rg_opts = "--follow " .. rg }
end

local function picker(method, kind)
  return function(opts)
    require("fzf-lua")[method](vim.tbl_extend("force", M.opts(kind), opts or {}))
  end
end

--- Command and path mapping for the folder picker.
---   "zoxide": frecent directories from `zoxide query --list` (instant)
---   "fd":     every directory under `roots` up to `max_depth`
---@param source "zoxide"|"fd"
---@param opts { roots?: string[], max_depth?: integer }
---@return { cmd: string, cwd: string, to_path: fun(entry: string): string }
function M.folder_source(source, opts)
  local home = vim.fn.expand("~")
  local function to_path(entry)
    return entry:sub(1, 1) == "/" and entry or (home .. "/" .. entry)
  end
  if source == "zoxide" then
    return { cmd = "zoxide query --list", cwd = home, to_path = to_path }
  end
  -- run from $HOME so paths under it are shown relative (shorter, easier to fuzzy match)
  local args = {}
  for _, root in ipairs(opts.roots or { "~" }) do
    local path = vim.fn.expand(root)
    if path == home then
      table.insert(args, ".")
    elseif path:sub(1, #home + 1) == home .. "/" then
      table.insert(args, vim.fn.shellescape(path:sub(#home + 2)))
    else
      table.insert(args, vim.fn.shellescape(path))
    end
  end
  local depth = opts.max_depth or 4
  if #args == 1 and args[1] == "." then
    -- only $HOME: no path argument, so fd prints `Music/...` instead of `./Music/...`
    return { cmd = ("fd --type d --max-depth %d --strip-cwd-prefix"):format(depth), cwd = home, to_path = to_path }
  end
  local cmd = ("fd --type d --max-depth %d . %s"):format(depth, table.concat(args, " "))
  return { cmd = cmd, cwd = home, to_path = to_path }
end

--- Pick folders with fzf and add them to the workspace. `<Tab>` selects several.
--- Starts with zoxide when available; `<C-f>` switches to a full `fd` search.
---@param opts? { source?: "zoxide"|"fd", roots?: string[], max_depth?: integer }
function M.add_folder(opts)
  opts = opts or {}
  local source = opts.source or (vim.fn.executable("zoxide") == 1 and "zoxide" or "fd")
  local src = M.folder_source(source, opts)
  require("fzf-lua").fzf_exec(src.cmd, {
    prompt = "Add folder (" .. source .. ")> ",
    cwd = src.cwd,
    fzf_opts = { ["--multi"] = true },
    actions = {
      ["default"] = function(selected)
        if #selected > 0 then
          archipelago.add(vim.tbl_map(src.to_path, selected))
        end
      end,
      ["ctrl-f"] = function()
        M.add_folder(vim.tbl_extend("force", opts, { source = "fd" }))
      end,
    },
  })
end

M.files = picker("files", "files")
M.live_grep = picker("live_grep", "grep")
M.grep_cword = picker("grep_cword", "grep")
M.grep_visual = picker("grep_visual", "grep")

return M
