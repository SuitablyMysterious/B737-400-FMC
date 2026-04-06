-- earth_awy_parser.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

-- General variables

local xp_path = sasl.getXPlanePath()
local aircraft_path = sasl.getAircraftPath()
local xp_version = sasl.getXPVersion()

local xp11_navdata_paths = {
    { "Custom Data/earth_awy.dat",                                          "awy - Navigraph/Aerosoft override" },
    { "Resources/default data/earth_awy.dat",                               "awy - Laminar fallback" },
}

local xp12_navdata_paths = {
    { "Custom Data/earth_awy.dat",                                          "awy - Navigraph/Aerosoft override" },
    { "Resources/default data/earth_awy.dat",                               "awy - Laminar fallback" },
}

-- main table

local mainTable = {}

-- storage tables

mainTable.rows = {} -- sequential list of all airway segments
mainTable.byAirway = {} -- keyed by airway name (e.g. J50, UL613)
mainTable.byFrom = {} -- keyed by from ident
mainTable.byTo = {} -- keyed by to ident

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

-- safe function for safely inserting a row

local function insertRow(tbl, key, entry)
    if not tbl[key] then
        tbl[key] = {}
    end
    table.insert(tbl[key], entry)
end

local function parseLine(line)
    -- Tokenise on whitespace
    local t = {}
    for token in line:gmatch("%S+") do
        t[#t + 1] = token
    end

    -- Skip malformed lines
    if #t < 11 then return end

    local entry = {
        from_ident = t[1],
        from_icao = t[2],
        from_type = tonumber(t[3]),
        to_ident = t[4],
        to_icao = t[5],
        to_type = tonumber(t[6]),
        direction = t[7], -- N=normal bi-dir, F=forward one-way
        level = tonumber(t[8]), -- 1=low, 2=high
        floor_fl = tonumber(t[9]), -- lower usable FL (0 means unrestricted)
        ceiling_fl = tonumber(t[10]), -- upper usable FL (600 usually means unlimited)
        airway = t[11],
    }

    mainTable.rows[#mainTable.rows + 1] = entry
    insertRow(mainTable.byAirway, entry.airway, entry)
    insertRow(mainTable.byFrom, entry.from_ident, entry)
    insertRow(mainTable.byTo, entry.to_ident, entry)
end

-- Cache helpers: write AWY cache to aircraft_dir/EEPROM/earth_awy.ndb
local function getCacheFile()
    return aircraft_path .. "EEPROM/earth_awy.ndb"
end

local function ensureEEPROMDir()
    local dir = aircraft_path .. "EEPROM"
    os.execute('mkdir -p "' .. dir .. '"')
end

local function readTwoHeaderLines(path)
    local f = io.open(path, "r")
    if not f then return nil, nil end
    local l1 = f:read("*l") or ""
    local l2 = f:read("*l") or ""
    f:close()
    return l1, l2
end

local function saveCache(navdataPath)
    ensureEEPROMDir()
    local meta1, meta2 = readTwoHeaderLines(navdataPath or findNavdataPath())
    local f = io.open(getCacheFile(), "w")
    if not f then
        logMsg("AWY PARSER: Cannot open cache for writing: " .. tostring(getCacheFile()))
        return
    end

    f:write((meta1 or "") .. "\n")
    f:write((meta2 or "") .. "\n")

    for _, e in ipairs(mainTable.rows) do
        f:write(string.format("%s\t%s\t%d\t%s\t%s\t%d\t%s\t%d\t%d\t%d\t%s\n",
            e.from_ident or "",
            e.from_icao or "",
            e.from_type or 0,
            e.to_ident or "",
            e.to_icao or "",
            e.to_type or 0,
            e.direction or "N",
            e.level or 0,
            e.floor_fl or 0,
            e.ceiling_fl or 0,
            e.airway or ""
        ))
    end

    f:close()
    logMsg("AWY PARSER: Saved cache to " .. getCacheFile())
end

local function loadCache(navdataPath)
    local cache = io.open(getCacheFile(), "r")
    if not cache then return false end

    local cache_h1 = cache:read("*l") or ""
    local cache_h2 = cache:read("*l") or ""
    local nav_h1, nav_h2 = readTwoHeaderLines(navdataPath or findNavdataPath())

    if not nav_h1 or cache_h1 ~= (nav_h1 or "") or cache_h2 ~= (nav_h2 or "") then
        cache:close()
        return false
    end

    for line in cache:lines() do
        if not line:match("^%s*$") then
            parseLine(line)
        end
    end

    cache:close()
    mainTable.totalRows = #mainTable.rows
    logMsg("AWY PARSER: Loaded cache from " .. getCacheFile())
    return true
end

local BATCH_SIZE = 1500

local function loaderCoroutine(path)
    local f = io.open(path, "r")
    if not f then
        logMsg("AWY PARSER: Cannot open " .. tostring(path))
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

    -- save cache (best-effort)
    pcall(saveCache, path)

    logMsg(string.format(
        "AWY PARSER: Done. %d lines, %d segments, %d airways",
        lineNum,
        mainTable.totalRows,
        mainTable.countTable(mainTable.byAirway)
    ))
end

function mainTable.countTable(tbl)
    local n = 0
    for _, _ in pairs(tbl) do
        n = n + 1
    end
    return n
end

function mainTable.load()
    if mainTable.loading or mainTable.ready then return end

    local path = findNavdataPath()
    if not path then
        logMsg("AWY PARSER: No earth_awy.dat found")
        return
    end

    mainTable.rows = {}
    mainTable.byAirway = {}
    mainTable.byFrom = {}
    mainTable.byTo = {}

    mainTable.loading = true
    mainTable.ready = false
    mainTable.linesRead = 0
    mainTable.totalRows = 0

    logMsg("AWY PARSER: Loading " .. tostring(path))

    -- attempt to load cache if metadata matches current navdata
    local ok, loaded = pcall(loadCache, path)
    if ok and loaded and #mainTable.rows > 0 then
        mainTable.ready = true
        mainTable.loading = false
        logMsg("AWY PARSER: Using cached data from " .. getCacheFile())
        return
    end

    _coro = coroutine.create(function() loaderCoroutine(path) end)
end

-- Call every frame from your update() loop
function mainTable.update()
    if _coro and not mainTable.ready then
        local ok, err = coroutine.resume(_coro)
        if not ok then
            logMsg("AWY PARSER ERROR: " .. tostring(err))
            mainTable.loading = false
            _coro = nil
        end
        if _coro and coroutine.status(_coro) == "dead" then
            _coro = nil
        end
    end
end

-- Get all segments for a given airway name
function mainTable.getAirway(airway)
    return mainTable.byAirway[airway]
end

-- Get all segments starting at ident
function mainTable.getFrom(ident)
    return mainTable.byFrom[ident]
end

-- Get all segments ending at ident
function mainTable.getTo(ident)
    return mainTable.byTo[ident]
end

-- Find the first matching segment by from/to (+ optional airway)
function mainTable.findSegment(from_ident, to_ident, airway)
    local list = mainTable.byFrom[from_ident]
    if not list then return nil end

    for _, seg in ipairs(list) do
        if seg.to_ident == to_ident and (not airway or seg.airway == airway) then
            return seg
        end
    end
    return nil
end

return mainTable
