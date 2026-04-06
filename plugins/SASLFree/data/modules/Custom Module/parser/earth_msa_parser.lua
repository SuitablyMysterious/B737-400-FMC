-- earth_msa_parser.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

-- General variables

local xp_path = sasl.getXPlanePath()
local xp_version = sasl.getXPVersion()

local xp11_navdata_paths = {
    { "Custom Data/earth_msa.dat",                                          "msa - Navigraph/Aerosoft override" },
    { "Resources/default data/earth_msa.dat",                               "msa - Laminar fallback" },
}

local xp12_navdata_paths = {
    { "Custom Data/earth_msa.dat",                                          "msa - Navigraph/Aerosoft override" },
    { "Resources/default data/earth_msa.dat",                               "msa - Laminar fallback" },
}

-- main table

local mainTable = {}

-- storage tables

mainTable.rows = {} -- sequential list of all MSA records
mainTable.byAirport = {} -- keyed by airport ICAO
mainTable.byIdent = {} -- keyed by ident

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

local function parseSectors(tokens)
    local sectors = {}

    -- Sector triplets start at token 6 and end before trailing status token
    local i = 6
    while i <= (#tokens - 2) do
        local bearing = tonumber(tokens[i])
        local altitude = tonumber(tokens[i + 1])
        local radius = tonumber(tokens[i + 2])

        if not bearing or not altitude or not radius then
            break
        end

        -- 000 000 terminates sector list in this format
        if bearing == 0 and altitude == 0 then
            break
        end

        sectors[#sectors + 1] = {
            bearing = bearing, -- sector center bearing
            altitude = altitude, -- hundreds of feet (e.g. 076 = 7600 ft)
            radius = radius, -- nm
        }

        i = i + 3
    end

    return sectors
end

local function parseLine(line)
    -- Tokenise on whitespace
    local t = {}
    for token in line:gmatch("%S+") do
        t[#t + 1] = token
    end

    -- Need fixed header plus at least one sector triplet
    if #t < 9 then return end

    local entry = {
        row_type = tonumber(t[1]), -- record type code from nav schema
        ident = t[2],
        region = t[3],
        airport = t[4],
        reference = t[5], -- usually magnetic/true marker in source data
        sectors = parseSectors(t),
        status = tonumber(t[#t]), -- trailing status/flag value
    }

    mainTable.rows[#mainTable.rows + 1] = entry
    insertRow(mainTable.byAirport, entry.airport, entry)
    insertRow(mainTable.byIdent, entry.ident, entry)
end

local BATCH_SIZE = 1500

local function loaderCoroutine(path)
    local f = io.open(path, "r")
    if not f then
        logMsg("MSA PARSER: Cannot open " .. tostring(path))
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
        "MSA PARSER: Done. %d lines, %d records, %d airports",
        lineNum,
        mainTable.totalRows,
        mainTable.countTable(mainTable.byAirport)
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
        logMsg("MSA PARSER: No earth_msa.dat found")
        return
    end

    mainTable.rows = {}
    mainTable.byAirport = {}
    mainTable.byIdent = {}

    mainTable.loading = true
    mainTable.ready = false
    mainTable.linesRead = 0
    mainTable.totalRows = 0

    logMsg("MSA PARSER: Loading " .. tostring(path))
    _coro = coroutine.create(function() loaderCoroutine(path) end)
end

-- Call every frame from your update() loop
function mainTable.update()
    if _coro and not mainTable.ready then
        local ok, err = coroutine.resume(_coro)
        if not ok then
            logMsg("MSA PARSER ERROR: " .. tostring(err))
            mainTable.loading = false
            _coro = nil
        end
        if _coro and coroutine.status(_coro) == "dead" then
            _coro = nil
        end
    end
end

-- Get all MSA entries for an airport
function mainTable.getByAirport(airport)
    return mainTable.byAirport[airport]
end

-- Get all MSA entries for an ident
function mainTable.getByIdent(ident)
    return mainTable.byIdent[ident]
end

-- Find the first MSA entry by ident + optional airport filter
function mainTable.findMSA(ident, airport)
    local list = mainTable.byIdent[ident]
    if not list then return nil end

    if not airport then
        return list[1]
    end

    for _, msa in ipairs(list) do
        if msa.airport == airport then
            return msa
        end
    end
    return nil
end

return mainTable
