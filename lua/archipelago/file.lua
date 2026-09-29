-- Read and write VSCode `.code-workspace` files.
local M = {}

local uv = vim.uv or vim.loop

--- Decode JSONC as written by VSCode: full-line `//` comments and trailing commas.
---@param file string
---@return table
function M.read(file)
  local lines = {}
  for _, line in ipairs(vim.fn.readfile(file)) do
    if not line:match("^%s*//") then
      table.insert(lines, line)
    end
  end
  local text = table.concat(lines, "\n"):gsub(",(%s*[%]}])", "%1")
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" then
    error("archipelago: invalid workspace file " .. file, 0)
  end
  return data
end

--- Write the workspace back, `folders` first, other top-level fields preserved.
---@param file string
---@param data table
function M.write(file, data)
  local keys = vim.tbl_keys(data)
  table.sort(keys, function(a, b)
    if a == "folders" or b == "folders" then
      return a == "folders"
    end
    return a < b
  end)
  local out = { "{" }
  for i, key in ipairs(keys) do
    local comma = i < #keys and "," or ""
    if key == "folders" then
      table.insert(out, '  "folders": [')
      for j, folder in ipairs(data.folders) do
        table.insert(out, "    " .. vim.json.encode(folder) .. (j < #data.folders and "," or ""))
      end
      table.insert(out, "  ]" .. comma)
    else
      table.insert(out, "  " .. vim.json.encode(key) .. ": " .. vim.json.encode(data[key]) .. comma)
    end
  end
  table.insert(out, "}")
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  vim.fn.writefile(out, file)
end

--- Resolve a folder path the way VSCode does: relative to the workspace file.
---@param path string
---@param base string directory of the workspace file
---@return string
function M.resolve(path, base)
  path = vim.fn.expand(path)
  if path:sub(1, 1) ~= "/" then
    path = base .. "/" .. path
  end
  path = vim.fs.normalize(path)
  return uv.fs_realpath(path) or path
end

---@class archipelago.Folder
---@field name string
---@field path string real absolute path

--- Parse the `folders` list. Entries without `path` (e.g. remote `uri`) are skipped.
---@param file string
---@return archipelago.Folder[]
function M.parse(file)
  return M.folders(M.read(file), vim.fn.fnamemodify(file, ":p:h"))
end

--- `folders` of already decoded workspace data.
---@param data table
---@param base string directory relative paths resolve against
---@return archipelago.Folder[]
function M.folders(data, base)
  local folders = {}
  for _, folder in ipairs(data.folders or {}) do
    if type(folder.path) == "string" then
      local path = M.resolve(folder.path, base)
      table.insert(folders, { name = folder.name or vim.fs.basename(path), path = path })
    end
  end
  return folders
end

return M
