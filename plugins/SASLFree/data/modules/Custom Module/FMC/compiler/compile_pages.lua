-- compile_pages.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

local function dirname(path)
    local p = path:gsub("\\", "/")
    return (p:match("^(.*)/[^/]+$") or ".")
end

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local scriptDir = dirname(scriptPath)
local compiler = dofile(scriptDir .. "/page_compiler.lua")

local inputDir = arg and arg[1] or nil
local outputDir = arg and arg[2] or nil

local result, err = compiler.compileAll({
    inputDir = inputDir,
    outputDir = outputDir,
})

if not result then
    io.stderr:write("FMC COMPILE FAILED: " .. tostring(err) .. "\n")
    os.exit(1)
end

io.write(string.format(
    "FMC COMPILE OK: %d page(s) -> %s (registry: %s)\n",
    result.pagesCompiled,
    result.outputDir,
    result.registryPath
))
