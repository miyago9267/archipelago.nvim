-- Run: nvim --headless -u NONE -l tests/archipelago_test.lua
-- Plain asserts; fixtures and hub live in a temp directory.
local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(config_dir)

local tmp = vim.uv.fs_realpath((vim.fn.tempname():gsub("[^/]+$", ""))) .. "/ws-test-" .. vim.uv.getpid()
vim.fn.mkdir(tmp, "p")
local ws = require("archipelago")
local file = require("archipelago.file")
local hub = require("archipelago.hub")
local fzf = require("archipelago.integrations.fzf-lua")
local tree = require("archipelago.integrations.nvim-tree")
ws.setup({ store_dir = tmp .. "/data", hub_dir = tmp .. "/state", notify_on_copy = false })

local failures, passed = {}, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    table.insert(failures, name .. ": " .. tostring(err))
  end
end
local function eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error((msg or "") .. " expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual), 2)
  end
end
local function write(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(content, "\n"), path)
end

-- fixture: two repos, one with a duplicate name, one missing path
write(tmp .. "/code/api/src/x.ts", "line1\nline2\nline3")
write(tmp .. "/code/web/index.html", "<p>hi</p>")
write(tmp .. "/other/api/readme.md", "dup")
local ws_file = tmp .. "/proj/demo.code-workspace"
write(ws_file, [[
{
  // full-line comment
  "folders": [
    { "path": "../code/api" },
    { "path": "]] .. tmp .. [[/code/web", "name": "frontend" },
    { "path": "../other/api" },
    { "path": "../missing" },
  ],
  "settings": { "editor.tabSize": 2 },
}]])

local warnings = {}
ws.warn = function(msg) table.insert(warnings, msg) end

test("T1 parse relative/absolute/comments/trailing commas", function()
  local folders = file.parse(ws_file)
  eq(#folders, 4)
  eq(folders[1].path, tmp .. "/code/api")
  eq(folders[2].path, tmp .. "/code/web")
  eq(folders[2].name, "frontend")
  eq(folders[3].name, "api")
end)

test("T1 parse ~ expansion", function()
  local f = tmp .. "/tilde.code-workspace"
  write(f, '{"folders":[{"path":"~/x"}]}')
  eq(file.parse(f)[1].path, vim.fn.expand("~") .. "/x")
end)

test("T2 open builds hub symlinks and sets cwd", function()
  ws.open(ws_file)
  local hub_path = ws.state.hub
  eq(vim.fn.getcwd(), hub_path)
  eq(vim.uv.fs_readlink(hub_path .. "/api"), tmp .. "/code/api")
  eq(vim.uv.fs_readlink(hub_path .. "/frontend"), tmp .. "/code/web")
end)

test("T3 duplicate names get suffix", function()
  eq(vim.uv.fs_readlink(ws.state.hub .. "/api-2"), tmp .. "/other/api")
end)

test("T4 missing folder skipped with warning", function()
  eq(vim.uv.fs_lstat(ws.state.hub .. "/missing"), nil)
  assert(#warnings >= 1 and warnings[1]:find("missing"), "no warning for missing folder")
end)

test("T5 rebuild only removes symlinks inside hub", function()
  local hub_path = ws.state.hub
  hub.build(hub_path, { { name = "frontend", path = tmp .. "/code/web" } }, ws.warn)
  eq(vim.uv.fs_lstat(hub_path .. "/api"), nil)
  eq(vim.fn.filereadable(tmp .. "/code/api/src/x.ts"), 1, "target content deleted")
  ws.open(ws_file)
end)

test("T6 buffer name is real path and maps to hub", function()
  vim.cmd("edit api/src/x.ts")
  local real = vim.api.nvim_buf_get_name(0)
  eq(real, tmp .. "/code/api/src/x.ts")
  eq(ws.to_hub(real), ws.state.hub .. "/api/src/x.ts")
  eq(ws.to_hub(tmp .. "/elsewhere.txt"), nil)
end)

test("T7 copy absolute/relative with ranges", function()
  eq(ws.path_for(0, "absolute"), tmp .. "/code/api/src/x.ts")
  eq(ws.path_for(0, "relative"), "api/src/x.ts")
  vim.cmd("CopyPath")
  eq(vim.fn.getreg("+") ~= "" and vim.fn.getreg("+") or vim.fn.getreg('"'), tmp .. "/code/api/src/x.ts")
  vim.cmd("2CopyRelativePath")
  eq(vim.fn.getreg('"'), "api/src/x.ts:2")
  vim.cmd("1,3CopyRelativePath")
  eq(vim.fn.getreg('"'), "api/src/x.ts:1-3")
  vim.cmd("2,3CopyPath")
  eq(vim.fn.getreg('"'), tmp .. "/code/api/src/x.ts:2-3")
end)

test("T8 search opts follow symlinks in workspace", function()
  local files = fzf.opts("files")
  assert(files.fd_opts:find("--follow"), "fd_opts missing --follow")
  eq(files.cwd, ws.state.hub)
  local grep = fzf.opts("grep")
  assert(grep.rg_opts:find("--follow"), "rg_opts missing --follow")
end)

test("T12 agent cwd is hub", function()
  eq(vim.fn.getcwd(), ws.state.hub)
  eq(vim.fn.filereadable(ws.path_for(0, "relative")), 1, "relative path unreadable from hub")
end)

test("T10 close restores cwd and default behavior", function()
  local hub_path = ws.state.hub
  ws.close()
  eq(ws.state, nil)
  assert(vim.fn.getcwd() ~= hub_path, "cwd still hub")
  eq(fzf.opts("files"), {})
  eq(tree.exclude({ buf = 0 }), false)
end)

test("R6 add/remove update the workspace file", function()
  local f = tmp .. "/data/demo2.code-workspace"
  ws.create("demo2", tmp .. "/code/api")
  eq(vim.fn.getcwd(), ws.state.hub)
  ws.add(tmp .. "/code/web")
  eq(#file.parse(f), 2)
  eq(vim.uv.fs_readlink(ws.state.hub .. "/web"), tmp .. "/code/web")
  ws.remove("web")
  eq(#file.parse(f), 1)
  eq(vim.uv.fs_lstat(ws.state.hub .. "/web"), nil)
  ws.close()
end)

test("R6 save keeps unknown fields", function()
  ws.open(ws_file)
  ws.add(tmp .. "/other")
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(ws_file), "\n"))
  eq(decoded.settings["editor.tabSize"], 2)
  ws.close()
end)

test("status and list", function()
  ws.open(ws_file)
  eq(ws.status(), "demo")
  eq(ws.list(), { "demo2" })
  ws.close()
  eq(ws.status(), nil)
end)

test("User events fire", function()
  local seen = {}
  vim.api.nvim_create_autocmd("User", {
    pattern = { "ArchipelagoOpen", "ArchipelagoClose", "ArchipelagoChanged" },
    callback = function(ev) table.insert(seen, ev.match) end,
  })
  ws.open(ws_file)
  ws.remove("api-2")
  ws.close()
  eq(seen, { "ArchipelagoOpen", "ArchipelagoChanged", "ArchipelagoClose" })
end)

test("folders with uri are skipped", function()
  local f = tmp .. "/uri.code-workspace"
  write(f, '{"folders":[{"uri":"vscode-remote://x/y"},{"path":"code/web"}]}')
  eq(#file.parse(f), 1)
end)

test("add refuses the hub itself", function()
  ws.open(ws_file)
  local before = #file.parse(ws_file)
  vim.cmd("enew")
  ws.add() -- no file buffer: default folder would be cwd, which is the hub
  eq(#file.parse(ws_file), before)
  ws.add(ws.state.hub .. "/frontend") -- hub path of an existing folder resolves to a duplicate
  eq(#file.parse(ws_file), before)
  ws.close()
end)

test("add uses the directory from a path source (file tree node)", function()
  ws.open(ws_file)
  local before = #file.parse(ws_file)
  ws.path_sources.TestTree = function() return tmp .. "/proj/demo.code-workspace" end
  vim.cmd("enew")
  vim.bo.filetype = "TestTree"
  ws.add()
  local folders = file.parse(ws_file)
  eq(#folders, before + 1)
  eq(folders[#folders].path, tmp .. "/proj")
  ws.path_sources.TestTree = nil
  ws.close()
end)

test("add without an open workspace starts an untitled one, no prompt", function()
  local orig = vim.ui.input
  vim.ui.input = function() error("must not prompt") end
  vim.cmd("cd " .. tmp .. "/code/api")
  vim.cmd("enew")
  ws.add(tmp .. "/code/web")
  vim.ui.input = orig
  eq(ws.status(), "untitled")
  eq(ws.state.file, nil)
  eq(vim.fn.getcwd(), ws.state.hub)
  eq(vim.tbl_map(function(r) return r.path end, ws.state.roots), { tmp .. "/code/api", tmp .. "/code/web" })
  eq(ws.list(), { "demo2" }, "nothing written to the store")
end)

test("untitled workspace keeps changes in memory", function()
  ws.remove("web")
  eq(vim.tbl_map(function(r) return r.name end, ws.state.roots), { "api" })
  ws.add(tmp .. "/code/web")
  eq(#ws.state.roots, 2)
end)

test("save writes the untitled workspace and switches to it", function()
  local untitled_hub = ws.state.hub
  ws.save("fresh")
  eq(ws.status(), "fresh")
  eq(ws.state.file, tmp .. "/data/fresh.code-workspace")
  eq(vim.fn.getcwd(), ws.state.hub)
  eq(vim.fn.isdirectory(untitled_hub), 0, "untitled hub removed")
  local folders = file.parse(tmp .. "/data/fresh.code-workspace")
  eq(vim.tbl_map(function(f) return f.path end, folders), { tmp .. "/code/api", tmp .. "/code/web" })
  ws.close()
end)

test("save asks for a name only when none is given", function()
  vim.cmd("cd " .. tmp .. "/code/api")
  ws.add(tmp .. "/code/web")
  local asked
  local orig = vim.ui.input
  vim.ui.input = function(o, cb) asked = o.default; cb("fresh2") end
  ws.save()
  vim.ui.input = orig
  eq(asked, "api")
  eq(ws.status(), "fresh2")
  ws.close()
end)

test("closing an untitled workspace discards it without prompting", function()
  vim.cmd("cd " .. tmp .. "/code/api")
  ws.add(tmp .. "/code/web")
  local hub_path = ws.state.hub
  ws.close()
  eq(ws.state, nil)
  eq(vim.fn.isdirectory(hub_path), 0)
  eq(vim.fn.isdirectory(tmp .. "/code/web"), 1, "folder content untouched")
end)

test("new with an existing name opens it instead of failing", function()
  ws.create("fresh")
  eq(ws.status(), "fresh")
  eq(#ws.state.roots, 2)
  ws.close()
end)

test("add accepts a list of folders", function()
  ws.open(ws_file)
  local before = #file.parse(ws_file)
  vim.fn.mkdir(tmp .. "/l1", "p")
  vim.fn.mkdir(tmp .. "/l2", "p")
  ws.add({ tmp .. "/l1", tmp .. "/l2" })
  eq(#file.parse(ws_file), before + 2)
  ws.close()
end)

test("fzf-lua folder source command", function()
  local src = fzf.folder_source("fd", { roots = { "~", tmp }, max_depth = 3 })
  assert(src.cmd:find("fd --type d --max-depth 3 . ", 1, true), src.cmd)
  eq(src.cwd, vim.fn.expand("~"))
  assert(src.cmd:find("3 . . ", 1, true), "home root should be '.' " .. src.cmd)
  eq(src.to_path("Project/x"), vim.fn.expand("~") .. "/Project/x")
  eq(src.to_path("/abs/y"), "/abs/y")
  eq(fzf.folder_source("fd", {}).cmd, "fd --type d --max-depth 4 --strip-cwd-prefix")
  local z = fzf.folder_source("zoxide", {})
  eq(z.cmd, "zoxide query --list")
end)

test("tree is re-synced after a late nvim-tree root change", function()
  -- fake nvim-tree: records calls, and simulates its debounced BufEnter moving the root away
  local calls = {}
  package.loaded["nvim-tree"] = {}
  package.loaded["nvim-tree.api"] = {
    tree = {
      change_root = function(p) table.insert(calls, "root:" .. p) end,
      reload = function() end,
      find_file = function(o) table.insert(calls, "find:" .. o.buf) end,
    },
  }
  vim.cmd("edit " .. tmp .. "/code/api/src/x.ts")
  ws.open(ws_file)
  table.insert(calls, "root:ELSEWHERE") -- the stale debounced update lands after open
  vim.cmd("lcd " .. tmp .. "/code/api/src") -- ...and nvim-tree :lcd's the window there
  vim.wait(500, function() return calls[#calls]:find("^find:") ~= nil end)
  package.loaded["nvim-tree"], package.loaded["nvim-tree.api"] = nil, nil
  local last_root
  for _, c in ipairs(calls) do
    if c:find("^root:") then last_root = c end
  end
  eq(last_root, "root:" .. ws.state.hub)
  eq(calls[#calls], "find:" .. ws.state.hub .. "/api/src/x.ts")
  eq(vim.fn.getcwd(), ws.state.hub)
  ws.close()
end)

test("window and tab local cwd follow open/close", function()
  vim.cmd("tabnew")
  vim.cmd("tcd " .. tmp .. "/code")
  vim.cmd("vsplit")
  vim.cmd("lcd " .. tmp .. "/code/web")
  vim.cmd("wincmd p") -- the window with :lcd is not the current one
  ws.open(ws_file)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    eq(vim.api.nvim_win_call(win, vim.fn.getcwd), ws.state.hub, "window cwd")
  end
  ws.close()
  assert(vim.fn.getcwd() ~= tmp .. "/state/demo", "cwd still on hub after close")
  vim.cmd("tabclose")
end)

vim.fn.delete(tmp, "rf")
if #failures > 0 then
  io.stderr:write(("FAIL %d, pass %d\n  %s\n"):format(#failures, passed, table.concat(failures, "\n  ")))
  vim.cmd("cquit 1")
end
io.stderr:write(("PASS %d\n"):format(passed))
vim.cmd("qall!")
