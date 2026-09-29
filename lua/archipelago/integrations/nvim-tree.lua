-- nvim-tree integration.
--
--   require("nvim-tree").setup({
--     update_focused_file = {
--       enable = true,
--       exclude = require("archipelago.integrations.nvim-tree").exclude,
--     },
--     on_attach = require("archipelago.integrations.nvim-tree").on_attach,
--   })
local archipelago = require("archipelago")

local M = {}

-- nvim-tree's `update_root` re-roots the tree (and `:lcd`s) at the current file's project
-- after every cwd change, not only on BufEnter, so `exclude` alone cannot keep the root on
-- the hub. Turn it off while a workspace is open and restore it afterwards.
local saved_update_root

local function update_root_config()
  local ok, config = pcall(require, "nvim-tree.config")
  local uff = ok and type(config.g) == "table" and config.g.update_focused_file
  return type(uff) == "table" and type(uff.update_root) == "table" and uff.update_root or nil
end

local group = vim.api.nvim_create_augroup("archipelago_nvim_tree", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "ArchipelagoOpenPre",
  callback = function()
    local cfg = update_root_config()
    if cfg and saved_update_root == nil then
      saved_update_root = cfg.enable
      cfg.enable = false
    end
  end,
})
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "ArchipelagoClose",
  callback = function()
    local cfg = update_root_config()
    if cfg and saved_update_root ~= nil then
      cfg.enable = saved_update_root
    end
    saved_update_root = nil
  end,
})

-- Copy commands inside the tree act on the node under the cursor.
archipelago.path_sources.NvimTree = function()
  local ok, api = pcall(require, "nvim-tree.api")
  local node = ok and api.tree.get_node_under_cursor()
  return node and node.absolute_path or nil
end

--- `update_focused_file.exclude`: inside a workspace, take over BufEnter so the tree root
--- stays on the hub (real paths are outside it) and reveal the matching hub node instead.
--- Outside a workspace it returns false and nvim-tree behaves as configured.
---@param event { buf: integer }
---@return boolean
function M.exclude(event)
  if not archipelago.state then
    return false
  end
  local name = vim.api.nvim_buf_get_name(event.buf)
  local hub_path = name ~= "" and archipelago.to_hub(name)
  if hub_path then
    vim.schedule(function()
      pcall(require("nvim-tree.api").tree.find_file, { buf = hub_path })
    end)
  end
  return true
end

--- Default nvim-tree mappings, with `gy` / `Y` copying real absolute / relative paths.
---@param bufnr integer
function M.on_attach(bufnr)
  local api = require("nvim-tree.api")
  api.config.mappings.default_on_attach(bufnr)
  M.map_copy(bufnr)
end

--- Only the copy mappings, for users with their own on_attach.
---@param bufnr integer
function M.map_copy(bufnr)
  local function map(lhs, cmd, desc)
    vim.keymap.set("n", lhs, cmd, { buffer = bufnr, noremap = true, silent = true, nowait = true, desc = desc })
  end
  map("gy", "<cmd>CopyPath<CR>", "Copy Absolute Path")
  map("Y", "<cmd>CopyRelativePath<CR>", "Copy Relative Path")
end

return M
