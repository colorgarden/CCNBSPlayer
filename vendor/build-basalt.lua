-- A Windows-compatible driver that reproduces Basalt2's own tools/bundler.lua.
--
-- WHY THIS EXISTS: the upstream bundler enumerates files with
-- io.popen('find ...'), which does not exist on Windows. Everything else below
-- is deliberately identical to upstream bundler.lua -- the require override,
-- the minified_elementDirectory / minified_pluginDirectory stubs, the
-- project["<path>"] wrapper and the final return. The file list is supplied
-- instead of discovered.
--
-- Run from the Basalt2 repository root:
--   lua <this file> <filelist.txt> <output.lua> [core|full]

local listPath = arg[1]
local outPath = arg[2]
local mode = arg[3] or "full"

local minify = loadfile("tools/minify.lua")()
local config = dofile("config.lua")

-- isDefaultFile: same predicate as upstream, used for the Core selection.
local function isDefaultFile(path)
  for _, category in pairs(config.categories) do
    for _, fileInfo in pairs(category.files) do
      if fileInfo.path == path and fileInfo.default == true then
        return true
      end
    end
  end
  return false
end

local files = {}
local handle = assert(io.open(listPath, "r"), "cannot open file list: " .. tostring(listPath))
for line in handle:lines() do
  local rel = line:gsub("\r", "")
  if rel ~= "" then
    files[#files + 1] = { path = rel, fullPath = "src/" .. rel }
  end
end
handle:close()

local coreOnly = (mode == "core")

local output = {
  'local minified = true\n',
  'local minified_elementDirectory = {}\n',
  'local minified_pluginDirectory = {}\n',
  'local project = {}\n',
  'local loadedProject = {}\n',
  'local baseRequire = require\n',
  'require = function(path) if(project[path..".lua"])then if(loadedProject[path]==nil)then loadedProject[path] = project[path..".lua"]() end return loadedProject[path] end return baseRequire(path) end\n'
}

for _, file in ipairs(files) do
  if not coreOnly or isDefaultFile(file.path) then
    local elementName = file.path:match("^elements/(.+)%.lua$")
    if elementName then
      output[#output + 1] = string.format('minified_elementDirectory["%s"] = {}\n', elementName)
    end
    local pluginName = file.path:match("^plugins/(.+)%.lua$")
    if pluginName then
      output[#output + 1] = string.format('minified_pluginDirectory["%s"] = {}\n', pluginName)
    end
  end
end

local included = {}
for _, file in ipairs(files) do
  if not coreOnly or isDefaultFile(file.path) then
    local f = assert(io.open(file.fullPath, "r"))
    local content = f:read("*all")
    f:close()

    local ok, minified = minify(content)
    if not ok then
      io.stderr:write("FAILED to minify " .. file.path .. "\n")
      os.exit(1)
    end

    included[#included + 1] = file.path
    output[#output + 1] = string.format('project["%s"] = function(...) %s end\n',
      file.path, minified)
  end
end

output[#output + 1] = 'return project["main.lua"]()'

local out = assert(io.open(outPath, "w"))
out:write(table.concat(output))
out:close()

print(string.format("bundled %d files -> %s", #included, outPath))
