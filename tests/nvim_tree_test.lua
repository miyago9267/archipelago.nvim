-- Run: make test-nvim-tree (clones nvim-tree.lua into .deps/)
-- Real nvim-tree with update_root + sync_root_with_cwd, the setup that used to pull the
-- cwd and tree root off the hub whenever a file buffer was current.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. "/.deps/nvim-tree.lua")

local tmp = vim.uv.fs_realpath((vim.fn.tempname():gsub("[^/]+$", ""))) .. "/ws-tree-" .. vim.uv.getpid()
local function write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(content, "\n"), path)
end
write(tmp .. "/code/api/src/x.ts", "x")
write(tmp .. "/code/web/index.html", "y")
write(tmp .. "/demo.code-workspace", '{"folders":[{"path":"code/api"}]}')

local ws = require("archipelago")
local integ = require("archipelago.integrations.nvim-tree")
ws.setup({ store_dir = tmp .. "/data", hub_dir = tmp .. "/state", notify_on_copy = false })
require("nvim-tree").setup({
  sync_root_with_cwd = true,
  update_focused_file = { enable = true, update_root = true, exclude = integ.exclude },
  on_attach = integ.on_attach,
})

local failures, passed = {}, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else table.insert(failures, name .. ": " .. tostring(err)) end
end
local function eq(a, e, msg)
  if not vim.deep_equal(a, e) then error((msg or "") .. " expected " .. vim.inspect(e) .. " got " .. vim.inspect(a), 2) end
end
local function settle() vim.wait(400, function() return false end) end
local tree_cwd = function() return require("nvim-tree.core").get_cwd() end

vim.cmd("cd " .. tmp .. "/code/api")
vim.cmd("edit src/x.ts")
require("nvim-tree.api").tree.open()
vim.cmd("wincmd p")
settle()

test("opening with a file buffer keeps cwd and tree root on the hub", function()
  ws.open(tmp .. "/demo.code-workspace")
  settle()
  eq(vim.fn.getcwd(), ws.state.hub, "cwd")
  eq(tree_cwd(), ws.state.hub, "tree root")
end)

test("adding a folder keeps the root and shows the new folder", function()
  ws.add(tmp .. "/code/web")
  settle()
  eq(tree_cwd(), ws.state.hub)
  eq(vim.uv.fs_readlink(ws.state.hub .. "/web"), tmp .. "/code/web")
end)

test("entering a buffer inside the workspace does not move the root", function()
  vim.cmd("edit " .. tmp .. "/code/web/index.html")
  settle()
  eq(tree_cwd(), ws.state.hub)
  eq(vim.fn.getcwd(), ws.state.hub)
end)

test("update_root is restored after close", function()
  ws.close()
  settle()
  eq(require("nvim-tree.config").g.update_focused_file.update_root.enable, true)
  vim.cmd("edit " .. tmp .. "/code/api/src/x.ts")
  settle()
  assert(tree_cwd() ~= nil and not tree_cwd():find("/state/"), "tree still on hub: " .. tostring(tree_cwd()))
end)

test("adding a folder without a workspace starts an untitled one on the hub", function()
  vim.cmd("cd " .. tmp .. "/code/api")
  vim.cmd("edit " .. tmp .. "/code/api/src/x.ts")
  settle()
  ws.add(tmp .. "/code/web")
  settle()
  eq(ws.status(), "untitled")
  eq(tree_cwd(), ws.state.hub)
  eq(vim.fn.getcwd(), ws.state.hub)
  ws.close()
end)

vim.fn.delete(tmp, "rf")
if #failures > 0 then
  io.stderr:write(("FAIL %d, pass %d\n  %s\n"):format(#failures, passed, table.concat(failures, "\n  ")))
  vim.cmd("cquit 1")
end
io.stderr:write(("PASS %d\n"):format(passed))
vim.cmd("qall!")
