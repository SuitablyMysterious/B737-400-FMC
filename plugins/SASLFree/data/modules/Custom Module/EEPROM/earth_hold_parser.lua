-- earth_hold_parser.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

-- General variables

local xp_path = sasl.getXPlanePath()
local aircraft_path = sasl.getAircraftPath()
local xp_version = sasl.getXPVersion()

local xp11_navdata_paths = {
    {"Custom Data/earth_hold.dat"},
    {"Resources/default data/earth_hold.dat"},
}

local xp12_navdata_paths = {
    {"Custom Data/earth_hold.dat"},
    {"Resources/default data/earth_hold.dat"},
}

-- main table

local mainTable = {}

-- storage tables

mainTable.rows = {} -- sequential list of all hold entries
mainTable.byIdent = {} -- keyed by hold fix ident
mainTable.byAirport = {} -- keyed by airport ICAO or ENRT

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
        ident = t[1],
        region = t[2],
        airport = t[3], -- airport ICAO or ENRT
        fix_type = tonumber(t[4]), -- navaid/fix type code from nav schema
        inbound_course = tonumber(t[5]), -- degrees
        leg_time_min = tonumber(t[6]), -- minutes for timed hold; may be 0
        leg_dist_nm = tonumber(t[7]), -- DME leg distance nm; may be 0
        turn_dir = t[8], -- L or R
        min_alt = tonumber(t[9]), -- feet
        max_alt = tonumber(t[10]), -- feet (0 means no upper limit)
        max_ias = tonumber(t[11]), -- knots (0 means unspecified)
    }

    mainTable.rows[#mainTable.rows + 1] = entry
    insertRow(mainTable.byIdent, entry.ident, entry)
    insertRow(mainTable.byAirport, entry.airport, entry)
end

-- Cache helpers: write HOLD cache to aircraft_dir/EEPROM/earth_hold.ndb
local RAW_MAGIC = "RAW1"
local FIELD_SEP = string.char(31)
local RECORD_SEP = string.char(30)

local function getCacheFile()
    return aircraft_path .. "EEPROM/earth_hold.ndb"
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
        logMsg("HOLD PARSER: Cannot open cache for writing: " .. tostring(getCacheFile()))
        return
    end

    f:write(RAW_MAGIC .. "\n")
    f:write((meta1 or "") .. "\n")
    f:write((meta2 or "") .. "\n")

    local writeBuffer = {}
    local bufferedLines = 0
    local FLUSH_EVERY = 512

    local function push(line)
        writeBuffer[#writeBuffer + 1] = line
        bufferedLines = bufferedLines + 1
        if bufferedLines >= FLUSH_EVERY then
            f:write(table.concat(writeBuffer))
            writeBuffer = {}
            bufferedLines = 0
        end
    end

    for _, e in ipairs(mainTable.rows) do
        local parts = {
            e.ident or "",
            e.region or "",
            e.airport or "",
            tostring(e.fix_type or 0),
            tostring(e.inbound_course or 0),
            tostring(e.leg_time_min or 0),
            tostring(e.leg_dist_nm or 0),
            e.turn_dir or "R",
            tostring(e.min_alt or 0),
            tostring(e.max_alt or 0),
            tostring(e.max_ias or 0),
        }
        push(table.concat(parts, FIELD_SEP) .. RECORD_SEP)
    end

    if #writeBuffer > 0 then
        f:write(table.concat(writeBuffer))
    end

    f:close()
    logMsg("HOLD PARSER: Saved cache to " .. getCacheFile())
end

local function loadCache(navdataPath)
    local cache = io.open(getCacheFile(), "r")
    if not cache then return false end

    local first = cache:read("*l") or ""
    local raw = (first == RAW_MAGIC)
    local cache_h1 = raw and (cache:read("*l") or "") or first
    local cache_h2 = cache:read("*l") or ""
    local nav_h1, nav_h2 = readTwoHeaderLines(navdataPath or findNavdataPath())

    if not nav_h1 or cache_h1 ~= (nav_h1 or "") or cache_h2 ~= (nav_h2 or "") then
        cache:close()
        return false
    end

    if raw then
        local body = cache:read("*a") or ""
        for rec in body:gmatch("([^" .. RECORD_SEP .. "]+)") do
            local line = rec:gsub(FIELD_SEP, " ")
            if not line:match("^%s*$") then
                parseLine(line)
            end
        end
    else
        for line in cache:lines() do
            if not line:match("^%s*$") then
                parseLine(line)
            end
        end
    end

    cache:close()
    mainTable.totalRows = #mainTable.rows
    logMsg("HOLD PARSER: Loaded cache from " .. getCacheFile())
    return true
end

local BATCH_SIZE = 1500

local function loaderCoroutine(path)
    local f = io.open(path, "r")
    if not f then
        logMsg("HOLD PARSER: Cannot open " .. tostring(path))
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
        "HOLD PARSER: Done. %d lines, %d hold entries, %d idents",
        lineNum,
        mainTable.totalRows,
        mainTable.countTable(mainTable.byIdent)
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
        logMsg("HOLD PARSER: No earth_hold.dat found")
        return
    end

    mainTable.rows = {}
    mainTable.byIdent = {}
    mainTable.byAirport = {}

    mainTable.loading = true
    mainTable.ready = false
    mainTable.linesRead = 0
    mainTable.totalRows = 0

    logMsg("HOLD PARSER: Loading " .. tostring(path))

    -- attempt to load cache if metadata matches current navdata
    local ok, loaded = pcall(loadCache, path)
    if ok and loaded and #mainTable.rows > 0 then
        mainTable.ready = true
        mainTable.loading = false
        logMsg("HOLD PARSER: Using cached data from " .. getCacheFile())
        return
    end

    _coro = coroutine.create(function() loaderCoroutine(path) end)
end

-- Call every frame from your update() loop
function mainTable.update()
    if _coro and not mainTable.ready then
        local ok, err = coroutine.resume(_coro)
        if not ok then
            logMsg("HOLD PARSER ERROR: " .. tostring(err))
            mainTable.loading = false
            _coro = nil
        end
        if _coro and coroutine.status(_coro) == "dead" then
            _coro = nil
        end
    end
end

-- Get all hold entries by fix ident
function mainTable.getByIdent(ident)
    return mainTable.byIdent[ident]
end

-- Get all hold entries by airport/ENRT bucket
function mainTable.getByAirport(airport)
    return mainTable.byAirport[airport]
end

-- Find a hold by ident, optionally restricted to airport
function mainTable.findHold(ident, airport)
    local list = mainTable.byIdent[ident]
    if not list then return nil end

    if not airport then
        return list[1]
    end

    for _, hold in ipairs(list) do
        if hold.airport == airport then
            return hold
        end
    end
    return nil
end

return mainTable
