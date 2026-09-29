-- archipelago.nvim: multi-root workspaces for Neovim.
--
-- Folders are joined into a "hub" directory made of symlinks. The hub is used as cwd,
-- so file trees, pickers and terminal agents see every folder. Every path that leaves
-- the plugin (buffer names, copied paths) is the real path, never the hub path.
local file = require("archipelago.file")
local hub = require("archipelago.hub")

local uv = vim.uv or vim.loop

local M = {}

---@class archipelago.Config
---@field store_dir string where named workspaces (`<name>.code-workspace`) live
---@field hub_dir string parent directory of the per-workspace hubs
---@field auto_open boolean `nvim foo.code-workspace` opens the workspace
---@field popup_menu boolean add Copy Path entries to the right-click menu
---@field notify_on_copy boolean
local defaults = {
  store_dir = vim.fn.stdpath("data") .. "/archipelago",
  hub_dir = vim.fn.stdpath("state") .. "/archipelago",
  auto_open = true,
  popup_menu = true,
  notify_on_copy = true,
}

---@type archipelago.Config
M.config = vim.deepcopy(defaults)

---@class archipelago.State
---@field name string
---@field file string
---@field hub string
---@field prev_cwd string
---@field roots archipelago.Root[]

---@type archipelago.State|nil
M.state = nil

M.warn = function(msg)
  vim.notify(msg, vim.log.levels.WARN)
end

local function realpath(path)
  return uv.fs_realpath(path)
end

local function is_under(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function emit(event)
  vim.api.nvim_exec_autocmds("User", { pattern = event, modeline = false })
end

local function workspace_name(path)
  return (vim.fs.basename(path):gsub("%.code%-workspace$", ""))
end

--- `:cd` everywhere. `:cd` alone leaves other windows' `:lcd` / tabs' `:tcd` in place,
--- and file trees (nvim-tree with `change_dir.global = false`) set those when following files.
---@param path string
local function set_cwd(path)
  local escaped = vim.fn.fnameescape(path)
  vim.cmd.cd(escaped)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local tabnr = vim.api.nvim_tabpage_get_number(tab)
    if vim.fn.haslocaldir(-1, tabnr) == 1 then
      vim.api.nvim_win_call(vim.api.nvim_tabpage_get_win(tab), function() vim.cmd.tcd(escaped) end)
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.fn.haslocaldir(vim.api.nvim_win_get_number(win), tabnr) == 1 then
        vim.api.nvim_win_call(win, function() vim.cmd.lcd(escaped) end)
      end
    end
  end
end

local function sync_tree()
  if M.state and vim.fn.getcwd() ~= M.state.hub then
    set_cwd(M.state.hub)
  end
  if not package.loaded["nvim-tree"] then
    return
  end
  local ok, api = pcall(require, "nvim-tree.api")
  if not ok then
    return
  end
  pcall(api.tree.change_root, M.state and M.state.hub or vim.fn.getcwd())
  pcall(api.tree.reload)
  local name = M.state and vim.api.nvim_buf_get_name(0)
  local hub_path = name and name ~= "" and M.to_hub(name)
  if hub_path then
    pcall(api.tree.find_file, { buf = hub_path })
  end
end

-- nvim-tree follows the current file on a debounced BufEnter. One scheduled before the
-- workspace opened (e.g. when a picker closes) can land afterwards and move the root off
-- the hub, so sync again once it has fired.
local function refresh_tree()
  sync_tree()
  vim.defer_fn(sync_tree, 150)
end

-- Saved workspaces are read from their file; an untitled one lives in `state.data`.
local function workspace_data()
  if M.state.file then
    return file.read(M.state.file), vim.fn.fnamemodify(M.state.file, ":h")
  end
  return M.state.data, "/"
end

local function rebuild()
  local data, base = workspace_data()
  M.state.roots = hub.build(M.state.hub, file.folders(data, base), M.warn)
  refresh_tree()
  emit("ArchipelagoChanged")
end

-- Pluggable resolvers for special buffers (e.g. a file tree node under the cursor).
M.path_sources = {}

--- Folder to add by default: the file tree node (its directory), else the current
--- file's git root, else cwd.
local function default_folder()
  local source = M.path_sources[vim.bo.filetype]
  if source then
    local path = source(vim.api.nvim_get_current_buf())
    if path then
      return vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
    end
  end
  local buf = vim.api.nvim_buf_get_name(0)
  if buf ~= "" and vim.bo.buftype == "" then
    return vim.fs.root(buf, ".git") or vim.fs.dirname(buf)
  end
  return vim.fn.getcwd()
end

--- Names of workspaces in `store_dir`.
---@return string[]
function M.list()
  local names = {}
  if vim.fn.isdirectory(M.config.store_dir) == 1 then
    for name in vim.fs.dir(M.config.store_dir) do
      if name:match("%.code%-workspace$") then
        table.insert(names, workspace_name(name))
      end
    end
  end
  table.sort(names)
  return names
end

local function activate(name, target, data, hub_path)
  local prev_cwd = M.state and M.state.prev_cwd or vim.fn.getcwd()
  local base = target and vim.fn.fnamemodify(target, ":h") or "/"
  M.state = { name = name, file = target, data = data, hub = hub_path, prev_cwd = prev_cwd, roots = {} }
  M.state.roots = hub.build(hub_path, file.folders(data, base), M.warn)
  M.state.hub = realpath(hub_path) or hub_path
  if package.loaded["nvim-tree"] then
    -- the integration must see OpenPre even if the tree was never opened yet
    pcall(require, "archipelago.integrations.nvim-tree")
  end
  emit("ArchipelagoOpenPre") -- lets integrations adjust before the cwd changes
  set_cwd(M.state.hub)
  refresh_tree()
  emit("ArchipelagoOpen")
end

local function remove_hub(hub_path)
  hub.build(hub_path, {}, M.warn) -- unlinks the symlinks only
  uv.fs_rmdir(hub_path)
end

local function store_path(name)
  return M.config.store_dir .. "/" .. name .. ".code-workspace"
end

--- Open a workspace by name (from `store_dir`) or by path to a `.code-workspace` file.
---@param target string
function M.open(target)
  if not target:find("/") and not target:find("%.code%-workspace$") then
    target = store_path(target)
  end
  target = vim.fn.fnamemodify(vim.fn.expand(target), ":p")
  if vim.fn.filereadable(target) == 0 then
    M.warn("archipelago: file not found " .. target)
    return
  end
  local previous = M.state
  local name = workspace_name(target)
  activate(name, target, file.read(target), M.config.hub_dir .. "/" .. name)
  M.state.data = nil -- saved workspaces are always re-read from their file
  if previous and not previous.file and previous.hub ~= M.state.hub then
    remove_hub(previous.hub)
  end
end

--- Close the workspace and return to the previous cwd. An untitled workspace is discarded.
function M.close()
  if not M.state then
    return
  end
  local closing = M.state
  M.state = nil
  set_cwd(closing.prev_cwd)
  if not closing.file then
    remove_hub(closing.hub)
  end
  refresh_tree()
  emit("ArchipelagoClose")
end

local function edit_folders(fn)
  if not M.state then
    M.warn("archipelago: no workspace open")
    return
  end
  local data = workspace_data()
  data.folders = data.folders or {}
  fn(data.folders)
  if M.state.file then
    file.write(M.state.file, data)
  else
    M.state.data = data
  end
  rebuild()
end

--- The project the user is in: the current file's git root, else cwd's git root, else cwd
--- (unless cwd is $HOME, which is never a useful workspace folder).
local function current_project()
  local buf = vim.api.nvim_buf_get_name(0)
  local root = buf ~= "" and vim.bo.buftype == "" and vim.fs.root(buf, ".git") or nil
  local cwd = vim.fn.getcwd()
  root = root or vim.fs.root(cwd, ".git")
  if not root and cwd ~= vim.fn.expand("~") then
    root = cwd
  end
  return root and realpath(root)
end

--- Start an untitled (unsaved) workspace, like VSCode does when a folder is added to a
--- single-folder window. `:Workspace save` writes it to `store_dir`.
---@param paths string[]
local function start_untitled(paths)
  local folders, seen = {}, {}
  for _, path in ipairs(paths) do
    if not seen[path] then
      seen[path] = true
      table.insert(folders, { path = path })
    end
  end
  activate("untitled", nil, { folders = folders }, M.config.hub_dir .. "/untitled-" .. uv.os_getpid())
end

--- Add folders to the open workspace. Default: the file tree node, the current file's
--- git root, or cwd. Without an open workspace, starts an untitled one with the current
--- project plus the new folders (like VSCode's "Add Folder to Workspace"); nothing is asked.
---@param dirs? string|string[]
function M.add(dirs)
  if type(dirs) ~= "table" then
    dirs = { dirs or default_folder() }
  end
  local paths = {}
  for _, dir in ipairs(dirs) do
    local path = realpath(vim.fn.expand(dir))
    if path then
      table.insert(paths, path)
    else
      M.warn("archipelago: folder not found " .. dir)
    end
  end
  if #paths == 0 then
    return
  end

  if not M.state then
    local project = current_project()
    start_untitled(project and vim.list_extend({ project }, paths) or paths)
    return
  end

  local hub_root = realpath(M.state.hub) or M.state.hub
  local existing = {}
  for _, root in ipairs(M.state.roots) do
    existing[root.path] = true
  end
  local added = {}
  for _, path in ipairs(paths) do
    if path == hub_root or path:sub(1, #hub_root + 1) == hub_root .. "/" then
      M.warn("archipelago: cannot add the workspace hub to itself")
    elseif existing[path] then
      M.warn("archipelago: " .. path .. " is already in the workspace")
    else
      existing[path] = true
      table.insert(added, path)
    end
  end
  if #added == 0 then
    return
  end
  edit_folders(function(folders)
    for _, path in ipairs(added) do
      table.insert(folders, { path = path })
    end
  end)
end

--- Remove a folder from the open workspace by its hub name.
---@param name string
function M.remove(name)
  local target
  for _, root in ipairs(M.state and M.state.roots or {}) do
    if root.name == name then
      target = root.path
    end
  end
  if not target then
    M.warn("archipelago: no folder named " .. tostring(name))
    return
  end
  local _, base = workspace_data()
  edit_folders(function(folders)
    for i = #folders, 1, -1 do
      if file.resolve(folders[i].path, base) == target then
        table.remove(folders, i)
      end
    end
  end)
end

--- Create a named workspace in `store_dir` and open it. An existing one is just opened.
---@param name string
---@param dir? string first folder, defaults to the current file's git root
function M.create(name, dir)
  local target = store_path(name)
  if vim.fn.filereadable(target) == 1 then
    vim.notify("archipelago: opening existing workspace " .. name)
    M.open(target)
    return
  end
  local path = realpath(vim.fn.expand(dir or default_folder()))
  file.write(target, { folders = { { path = path } } })
  M.open(target)
end

--- Save the open workspace to `store_dir` (asks for a name when none is given) and switch
--- to the saved file. Saving an untitled workspace is the only time a name is needed.
---@param name? string
function M.save(name)
  if not M.state then
    M.warn("archipelago: no workspace open")
    return
  end
  if not name or name == "" then
    local suggestion = M.state.file and M.state.name or (M.state.roots[1] and M.state.roots[1].name) or "workspace"
    vim.ui.input({ prompt = "Save workspace as: ", default = suggestion }, function(input)
      if input and input ~= "" then
        M.save(input)
      end
    end)
    return
  end
  local target = store_path(name)
  if target == M.state.file then
    return
  end
  if vim.fn.filereadable(target) == 1
    and vim.fn.confirm("Workspace " .. name .. " exists. Overwrite?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  local data = vim.deepcopy((workspace_data()))
  data.folders = vim.tbl_map(function(root) return { path = root.path } end, M.state.roots)
  file.write(target, data)
  M.open(target)
  vim.notify("archipelago: saved " .. target)
end

--- Map a real path to its hub path, or nil when it is outside the workspace.
---@param path string
---@return string|nil
function M.to_hub(path)
  if not M.state then
    return nil
  end
  path = realpath(path) or path
  for _, root in ipairs(M.state.roots) do
    if is_under(path, root.path) then
      return root.link .. path:sub(#root.path + 1)
    end
  end
end

local function source_path(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local source = M.path_sources[vim.bo[buf].filetype]
  if source then
    return source(buf)
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and name or nil
end

--- Path of a buffer. `absolute` is the real path; `relative` is relative to cwd,
--- which inside a workspace is `<folder>/<relpath>`.
---@param buf integer
---@param kind "absolute"|"relative"
---@return string|nil
function M.path_for(buf, kind)
  local path = source_path(buf)
  if not path then
    return nil
  end
  local real = realpath(path) or path
  if kind == "absolute" then
    return real
  end
  local hub_path = M.to_hub(real)
  if hub_path then
    return hub_path:sub(#M.state.hub + 2)
  end
  local cwd = realpath(vim.fn.getcwd()) or vim.fn.getcwd()
  if is_under(real, cwd) and real ~= cwd then
    return real:sub(#cwd + 2)
  end
  return real
end

--- Copy a path to the unnamed and `+` registers. A line range appends `:l` or `:l1-l2`.
---@param kind "absolute"|"relative"
---@param range? { line1: integer, line2: integer }
function M.copy_path(kind, range)
  local path = M.path_for(0, kind)
  if not path then
    M.warn("archipelago: no file to copy")
    return
  end
  if range and not M.path_sources[vim.bo.filetype] then
    path = path .. ":" .. (range.line1 == range.line2 and range.line1 or (range.line1 .. "-" .. range.line2))
  end
  vim.fn.setreg('"', path)
  pcall(vim.fn.setreg, "+", path)
  if M.config.notify_on_copy then
    vim.notify("Copied: " .. path)
  end
  return path
end

--- Name of the open workspace, for statuslines.
---@return string|nil
function M.status()
  return M.state and M.state.name or nil
end

local function pick(items, prompt, cb)
  if #items == 0 then
    M.warn("archipelago: nothing to pick")
    return
  end
  vim.ui.select(items, { prompt = prompt }, function(item)
    if item then
      cb(item)
    end
  end)
end

local function root_names()
  return vim.tbl_map(function(r) return r.name end, M.state and M.state.roots or {})
end

local subcommands = {
  open = function(arg)
    if arg then
      M.open(arg)
    else
      pick(M.list(), "Open workspace", M.open)
    end
  end,
  close = function() M.close() end,
  new = function(arg)
    if not arg then
      M.warn("usage: :Workspace new <name>")
      return
    end
    M.create(arg)
  end,
  add = function(arg) M.add(arg) end,
  save = function(arg) M.save(arg) end,
  remove = function(arg)
    if arg then
      M.remove(arg)
    else
      pick(root_names(), "Remove folder", M.remove)
    end
  end,
  list = function()
    if not M.state then
      print("archipelago: no workspace open")
      return
    end
    local lines = { M.state.name .. " (" .. (M.state.file or "unsaved, :Workspace save to keep it") .. ")" }
    for _, root in ipairs(M.state.roots) do
      table.insert(lines, "  " .. root.name .. " -> " .. root.path)
    end
    print(table.concat(lines, "\n"))
  end,
}

local function complete(lead, line)
  local args = vim.split(line, "%s+")
  local function filter(items)
    return vim.tbl_filter(function(s) return s:find(lead, 1, true) == 1 end, items)
  end
  if #args <= 2 then
    local names = vim.tbl_keys(subcommands)
    table.sort(names)
    return filter(names)
  end
  if args[2] == "open" then
    return filter(M.list())
  elseif args[2] == "remove" then
    return filter(root_names())
  elseif args[2] == "add" then
    return vim.fn.getcompletion(lead, "dir")
  end
  return {}
end

---@param opts? archipelago.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.api.nvim_create_user_command("Workspace", function(cmd)
    local sub, arg = cmd.fargs[1] or "open", cmd.fargs[2]
    local fn = subcommands[sub]
    if not fn then
      M.warn("archipelago: unknown subcommand " .. sub)
      return
    end
    local ok, err = pcall(fn, arg)
    if not ok then
      M.warn(tostring(err))
    end
  end, { nargs = "*", complete = complete, desc = "Multi-root workspace" })

  local function range_of(cmd)
    return cmd.range > 0 and { line1 = cmd.line1, line2 = cmd.line2 } or nil
  end
  vim.api.nvim_create_user_command("CopyPath", function(cmd) M.copy_path("absolute", range_of(cmd)) end,
    { range = true, desc = "Copy the real absolute path (with :line for a range)" })
  vim.api.nvim_create_user_command("CopyRelativePath", function(cmd) M.copy_path("relative", range_of(cmd)) end,
    { range = true, desc = "Copy the path relative to cwd / workspace (with :line for a range)" })

  if M.config.popup_menu then
    vim.cmd([[
      nnoremenu PopUp.Copy\ Path <Cmd>CopyPath<CR>
      nnoremenu PopUp.Copy\ Relative\ Path <Cmd>CopyRelativePath<CR>
      vnoremenu PopUp.Copy\ Path :CopyPath<CR>
      vnoremenu PopUp.Copy\ Relative\ Path :CopyRelativePath<CR>
    ]])
  end

  local group = vim.api.nvim_create_augroup("archipelago", { clear = true })
  if M.config.auto_open then
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      nested = true,
      callback = function()
        local arg = vim.fn.argc() == 1 and vim.fn.argv(0) or nil
        if not (arg and arg:match("%.code%-workspace$")) then
          return
        end
        local buf = vim.api.nvim_get_current_buf()
        M.open(arg)
        vim.cmd.enew()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        if package.loaded["nvim-tree"] or pcall(require, "nvim-tree") then
          pcall(require("nvim-tree.api").tree.open)
        end
      end,
    })
  end
end

return M
