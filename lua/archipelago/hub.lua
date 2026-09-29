-- The hub is a directory that only contains symlinks, one per workspace folder.
local M = {}

local uv = vim.uv or vim.loop

---@class archipelago.Root
---@field name string unique name inside the hub
---@field path string real absolute path
---@field link string hub path of the symlink

--- Rebuild the hub. Only symlinks inside the hub are removed; link targets are never touched.
---@param hub string
---@param folders archipelago.Folder[]
---@param warn fun(msg: string)
---@return archipelago.Root[]
function M.build(hub, folders, warn)
  vim.fn.mkdir(hub, "p")
  for name, kind in vim.fs.dir(hub) do
    if kind == "link" then
      uv.fs_unlink(hub .. "/" .. name)
    end
  end

  local roots, used = {}, {}
  for _, folder in ipairs(folders) do
    local stat = uv.fs_stat(folder.path)
    if not stat or stat.type ~= "directory" then
      warn("archipelago: skip missing folder " .. folder.path)
    else
      local name, n = folder.name, 1
      while used[name] do
        n = n + 1
        name = folder.name .. "-" .. n
      end
      used[name] = true
      local link = hub .. "/" .. name
      if uv.fs_lstat(link) then
        warn("archipelago: " .. link .. " exists and is not a symlink, skipped")
      else
        uv.fs_symlink(folder.path, link)
        table.insert(roots, { name = name, path = folder.path, link = link })
      end
    end
  end
  return roots
end

return M
