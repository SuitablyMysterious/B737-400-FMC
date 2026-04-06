-- earth_mora_parser.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

-- General variables

local xp_path = sasl.getXPlanePath()
local xp_version = sasl.getXPVersion()

local xp11_navdata_paths = {
    { "Custom Data/earth_mora.dat",                                         "mora - Navigraph/Aerosoft override" },
    { "Resources/default data/earth_mora.dat",                              "mora - Laminar fallback" },
}

local xp12_navdata_paths = {
    { "Custom Data/earth_mora.dat",                                         "mora - Navigraph/Aerosoft override" },
    { "Resources/default data/earth_mora.dat",                              "mora - Laminar fallback" },
}

-- main table

local mainTable = {}

-- storage tables

mainTable.rows = {} -- sequential list of all MORA grid rows
mainTable.grid = {} -- grid[lat_band][lon_band] = { 30 cells }

-- parse state
mainTable.ready = false
mainTable.loading = false
mainTable.linesRead = 0
mainTable.totalRows = 0

local _coro = nil

-- function for getting the correct navdata path

local function findNavdataPath()
    local paths = (xp_version >= 12000) and xp12_navdata_paths or xp11_navdata_paths
    for _, path in ipairs(paths) do
        local f = io.open(xp_path .. path[1], "r")
        if f then
            f:close()
            return xp_path .. path[1]
        end
    end
end

local function parseSignedBand(value)
    -- Bands are encoded like +00, -120
    if not value then return nil end
    return tonumber(value)
end

local function parseLine(line)
    -- Tokenise on whitespace
    local t = {}
    for token in line:gmatch("%S+") do
        t[#t + 1] = token
    end

    -- Expected: lat band + lon band + 30 MORA values
    if #t < 32 then return end

    local entry = {
        lat_band = t[1],
        lon_band = t[2],
        lat_deg = parseSignedBand(t[1]),
        lon_deg = parseSignedBand(t[2]),
        cells = {},
    }

    for i = 3, #t do
        entry.cells[#entry.cells + 1] = tonumber(t[i])
    end

    mainTable.rows[#mainTable.rows + 1] = entry

    if not mainTable.grid[entry.lat_band] then
        mainTable.grid[entry.lat_band] = {}
    end
    mainTable.grid[entry.lat_band][entry.lon_band] = entry.cells
end

local BATCH_SIZE = 1500

local function loaderCoroutine(path)
    local f = io.open(path, "r")
    if not f then
        logMsg("MORA PARSER: Cannot open " .. tostring(path))
        return
    end

    local lineNum = 0
    local batch = 0

    for line in f:lines() do
        lineNum = lineNum + 1
        mainTable.linesRead = lineNum

        -- First two lines are header (byte-order + version string) - skip
        if lineNum <= 2 then goto continue end

        -- Skip blank lines
        if line:match("^%s*$") then goto continue end

        parseLine(line)
        mainTable.totalRows = mainTable.totalRows + 1

        batch = batch + 1
        if batch >= BATCH_SIZE then
            batch = 0
            coroutine.yield()
        end

        ::continue::
    end

    f:close()
    mainTable.ready = true
    mainTable.loading = false

    logMsg(string.format(
        "MORA PARSER: Done. %d lines, %d grid rows",
        lineNum,
        mainTable.totalRows
    ))
end

function mainTable.load()
    if mainTable.loading or mainTable.ready then return end

    local path = findNavdataPath()
    if not path then
        logMsg("MORA PARSER: No earth_mora.dat found")
        return
    end

    mainTable.rows = {}
    mainTable.grid = {}

    mainTable.loading = true
    mainTable.ready = false
    mainTable.linesRead = 0
    mainTable.totalRows = 0

    logMsg("MORA PARSER: Loading " .. tostring(path))
    _coro = coroutine.create(function() loaderCoroutine(path) end)
end

-- Call every frame from your update() loop
function mainTable.update()
    if _coro and not mainTable.ready then
        local ok, err = coroutine.resume(_coro)
        if not ok then
            logMsg("MORA PARSER ERROR: " .. tostring(err))
            mainTable.loading = false
            _coro = nil
        end
        if _coro and coroutine.status(_coro) == "dead" then
            _coro = nil
        end
    end
end

-- Get full 30-cell grid row for a lat/lon band pair
function mainTable.getRow(lat_band, lon_band)
    local latRows = mainTable.grid[lat_band]
    if not latRows then return nil end
    return latRows[lon_band]
end

-- Get a single MORA cell index (1..30) from a row
function mainTable.getCell(lat_band, lon_band, idx)
    local row = mainTable.getRow(lat_band, lon_band)
    if not row then return nil end
    return row[idx]
end

return mainTable
