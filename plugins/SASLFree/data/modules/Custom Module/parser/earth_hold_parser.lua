-- earth_hold_parser.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

-- General variables

local xp_path = sasl.getXPlanePath()
local xp_version = sasl.getXPVersion()

local xp11_navdata_paths = {
    { "Custom Data/earth_hold.dat",                                         "hold - Navigraph/Aerosoft override" },
    { "Resources/default data/earth_hold.dat",                              "hold - Laminar fallback" },
}

local xp12_navdata_paths = {
    { "Custom Data/earth_hold.dat",                                         "hold - Navigraph/Aerosoft override" },
    { "Resources/default data/earth_hold.dat",                              "hold - Laminar fallback" },
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
