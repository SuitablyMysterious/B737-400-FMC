-- earth_apt_parser.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

-- General variables

local xp_path = sasl.getXPlanePath()
local aircraft_path = sasl.getAircraftPath()
-- Ensure xp_path ends with a trailing slash so concatenations are safe
if xp_path and xp_path:sub(-1) ~= "/" then
    xp_path = xp_path .. "/"
end

local navdata_paths = {
    {"Custom Scenery"},
    {"Global Airports"},
}

-- main table

local mainTable = {}

-- storage tables

mainTable.rows = {} -- sequential list of all runway-end records
mainTable.byAirport = {} -- keyed by airport ICAO
mainTable.byAirportRunway = {} -- keyed by "ICAO|RWY"

-- parse state
mainTable.ready = false
mainTable.loading = false
mainTable.linesRead = 0
mainTable.totalRunways = 0

local _coro = nil

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeRunwayIdent(raw)
    local s = trim(raw):upper()
    if s == "" then
        return nil
    end

    if s:sub(1, 2) == "RW" then
        s = s:sub(3)
    end

    local num, suffix = s:match("^(%d%d)([LRC]?)$")
    if not num then
        local single, singleSuffix = s:match("^(%d)([LRC]?)$")
        if single then
            num = "0" .. single
            suffix = singleSuffix
        else
            return nil
        end
    end

    local n = tonumber(num)
    if not n or n < 1 or n > 36 then
        return nil
    end

    return string.format("%02d%s", n, suffix or "")
end

local function insertRow(tbl, key, entry)
    if not key or key == "" then
        return
    end
    if not tbl[key] then
        tbl[key] = {}
    end
    table.insert(tbl[key], entry)
end

local function findAptDatPath()
    -- Prefer the global "Global Scenery/Global Airports" apt.dat if present
    local globalApt = xp_path .. "Global Scenery/Global Airports/Earth nav data/apt.dat"
    local f = io.open(globalApt, "r")
    if f then
        f:close()
        return globalApt
    end

    -- Otherwise, search Custom Scenery for any apt.dat (custom sceneries often ship their own)
    local customSceneryPath = xp_path .. "Custom Scenery"
    local customScenery = io.popen('find "' .. customSceneryPath .. '" -type f -path "*/Earth nav data/apt.dat" 2>/dev/null')
    if customScenery then
        for line in customScenery:lines() do
            if line and line ~= "" then
                customScenery:close()
                return line
            end
        end
        customScenery:close()
    end

    local defaultApt = xp_path .. "Resources/default scenery/default apt dat/Earth nav data/apt.dat"
    f = io.open(defaultApt, "r")
    if f then
        f:close()
        return defaultApt
    end

    return nil
end

local function buildRunwayPair(runwayIdent)
    local normalized = normalizeRunwayIdent(runwayIdent)
    if not normalized then
        return nil, nil
    end

    local n = tonumber(normalized:sub(1, 2))
    local suffix = normalized:sub(3)
    local opp = n + 18
    if opp > 36 then
        opp = opp - 36
    end

    local suffixMap = { L = "R", R = "L", C = "C", [""] = "" }
    local oppSuffix = suffixMap[suffix] or ""

    return normalized, string.format("%02d%s", opp, oppSuffix)
end

local function haversineMeters(lat1, lon1, lat2, lon2)
    if not lat1 or not lon1 or not lat2 or not lon2 then
        return nil
    end

    local rad = math.pi / 180
    local dlat = (lat2 - lat1) * rad
    local dlon = (lon2 - lon1) * rad
    local a = math.sin(dlat / 2)^2 + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.sin(dlon / 2)^2
    -- math.atan2 may not be available in all Lua environments; provide a fallback
    local function atan2(y, x)
        if math.atan2 then return math.atan2(y, x) end
        -- Fallback implementation using math.atan
        if x > 0 then
            return math.atan(y / x)
        elseif x < 0 and y >= 0 then
            return math.atan(y / x) + math.pi
        elseif x < 0 and y < 0 then
            return math.atan(y / x) - math.pi
        elseif x == 0 and y > 0 then
            return math.pi / 2
        elseif x == 0 and y < 0 then
            return -math.pi / 2
        else
            return 0
        end
    end
    local c = 2 * atan2(math.sqrt(a), math.sqrt(1 - a))
    return 6371000 * c
end

local function parseAirportHeader(tokens)
    local rowcode = tonumber(tokens[1])
    if rowcode ~= 1 and rowcode ~= 16 and rowcode ~= 17 then
        return nil
    end

    local airport = trim(tokens[5] or ""):upper()
    if airport == "" then
        return nil
    end

    local elev = tonumber(tokens[2])
    return airport, elev
end

local function parseRunwayLine(tokens, currentAirport, airportElev)
    if tonumber(tokens[1]) ~= 100 then
        return nil
    end

    local rw1 = normalizeRunwayIdent(tokens[9])
    local lat1 = tonumber(tokens[10])
    local lon1 = tonumber(tokens[11])

    local rw2 = normalizeRunwayIdent(tokens[18])
    local lat2 = tonumber(tokens[19])
    local lon2 = tonumber(tokens[20])

    if not currentAirport or not rw1 or not rw2 or not lat1 or not lon1 or not lat2 or not lon2 then
        return nil
    end

    local lengthMeters = haversineMeters(lat1, lon1, lat2, lon2)

    local end1 = {
        airport = currentAirport,
        runway = rw1,
        opposite = rw2,
        lat = lat1,
        lon = lon1,
        elev = airportElev,
        length_m = lengthMeters,
    }

    local end2 = {
        airport = currentAirport,
        runway = rw2,
        opposite = rw1,
        lat = lat2,
        lon = lon2,
        elev = airportElev,
        length_m = lengthMeters,
    }

    return end1, end2
end

local function resetStorageTables()
    mainTable.rows = {}
    mainTable.byAirport = {}
    mainTable.byAirportRunway = {}
end

local RAW_MAGIC = "RAW1"
local FIELD_SEP = string.char(31)
local RECORD_SEP = string.char(30)

local function getCacheFile()
    return aircraft_path .. "EEPROM/earth_apt.ndb"
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
    local meta1, meta2 = readTwoHeaderLines(navdataPath or findAptDatPath())
    local f = io.open(getCacheFile(), "w")
    if not f then
        logMsg("APT PARSER: Cannot open cache for writing: " .. tostring(getCacheFile()))
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
            e.airport or "",
            e.runway or "",
            e.opposite or "",
            tostring(e.lat or 0),
            tostring(e.lon or 0),
            tostring(e.elev or 0),
            tostring(e.length_m or 0),
        }
        push(table.concat(parts, FIELD_SEP) .. RECORD_SEP)
    end

    if #writeBuffer > 0 then
        f:write(table.concat(writeBuffer))
    end

    f:close()
    logMsg("APT PARSER: Saved cache to " .. getCacheFile())
end

local function loadCache(navdataPath)
    local cache = io.open(getCacheFile(), "r")
    if not cache then return false end

    local first = cache:read("*l") or ""
    local raw = (first == RAW_MAGIC)
    local cache_h1 = raw and (cache:read("*l") or "") or first
    local cache_h2 = cache:read("*l") or ""
    local nav_h1, nav_h2 = readTwoHeaderLines(navdataPath or findAptDatPath())

    if not nav_h1 or cache_h1 ~= (nav_h1 or "") or cache_h2 ~= (nav_h2 or "") then
        cache:close()
        return false
    end

    local function insertEntry(entry)
        mainTable.rows[#mainTable.rows + 1] = entry
        insertRow(mainTable.byAirport, entry.airport, entry)
        insertRow(mainTable.byAirportRunway, entry.airport .. "|" .. entry.runway, entry)
    end

    if raw then
        local body = cache:read("*a") or ""
        for rec in body:gmatch("([^" .. RECORD_SEP .. "]+)") do
            local line = rec:gsub(FIELD_SEP, "\t")
            local airport, runway, opposite, lat, lon, elev, length_m =
                line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")

            if airport and airport ~= "" and runway and runway ~= "" then
                local entry = {
                    airport = airport,
                    runway = runway,
                    opposite = opposite,
                    lat = tonumber(lat),
                    lon = tonumber(lon),
                    elev = tonumber(elev),
                    length_m = tonumber(length_m),
                }
                insertEntry(entry)
            end
        end
    else
        for line in cache:lines() do
            local airport, runway, opposite, lat, lon, elev, length_m =
                line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")

            if airport and airport ~= "" and runway and runway ~= "" then
                local entry = {
                    airport = airport,
                    runway = runway,
                    opposite = opposite,
                    lat = tonumber(lat),
                    lon = tonumber(lon),
                    elev = tonumber(elev),
                    length_m = tonumber(length_m),
                }
                insertEntry(entry)
            end
        end
    end

    cache:close()
    logMsg("APT PARSER: Loaded cache from " .. getCacheFile())
    return #mainTable.rows > 0
end

local BATCH_SIZE = 500

local function loaderCoroutine(path)
    local f = io.open(path, "r")
    if not f then
        logMsg("APT PARSER: Cannot open " .. tostring(path))
        return
    end

    local lineNum = 0
    local batch = 0
    local currentAirport = nil
    local currentAirportElev = nil

    for line in f:lines() do
        lineNum = lineNum + 1
        mainTable.linesRead = lineNum

        if lineNum <= 2 then goto continue end
        if line:match("^%s*$") then goto continue end

        local tokens = {}
        for token in line:gmatch("%S+") do
            tokens[#tokens + 1] = token
        end

        if #tokens == 0 then goto continue end

        local rowcode = tonumber(tokens[1])
        if rowcode == 99 then
            break
        end

        local airport, elev = parseAirportHeader(tokens)
        if airport then
            currentAirport = airport
            currentAirportElev = elev
            goto continue
        end

        local end1, end2 = parseRunwayLine(tokens, currentAirport, currentAirportElev)
        if end1 and end2 then
            mainTable.rows[#mainTable.rows + 1] = end1
            mainTable.rows[#mainTable.rows + 1] = end2

            insertRow(mainTable.byAirport, end1.airport, end1)
            insertRow(mainTable.byAirport, end2.airport, end2)
            insertRow(mainTable.byAirportRunway, end1.airport .. "|" .. end1.runway, end1)
            insertRow(mainTable.byAirportRunway, end2.airport .. "|" .. end2.runway, end2)

            mainTable.totalRunways = mainTable.totalRunways + 1
        end

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
    pcall(saveCache, path)

    logMsg(string.format(
        "APT PARSER: Done. %d lines, %d runway pairs.",
        lineNum,
        mainTable.totalRunways
    ))
end

function mainTable.load()
    if mainTable.loading or mainTable.ready then return end

    local path = findAptDatPath()
    if not path then
        logMsg("APT PARSER: No apt.dat found")
        mainTable.ready = true
        mainTable.loading = false
        return
    end

    resetStorageTables()

    mainTable.loading = true
    mainTable.ready = false
    mainTable.linesRead = 0
    mainTable.totalRunways = 0
    logMsg("APT PARSER: Loading " .. tostring(path))

    local ok, loaded = pcall(loadCache, path)
    if ok and loaded then
        mainTable.ready = true
        mainTable.loading = false
        return
    end

    _coro = coroutine.create(function() loaderCoroutine(path) end)
end

function mainTable.update()
    if _coro and not mainTable.ready then
        local ok, err = coroutine.resume(_coro)
        if not ok then
            logMsg("APT PARSER ERROR: " .. tostring(err))
            mainTable.loading = false
            _coro = nil
        end
        if _coro and coroutine.status(_coro) == "dead" then
            _coro = nil
        end
    end
end

function mainTable.findRunwayEnd(airportIdent, runwayIdent)
    local airport = trim(airportIdent):upper()
    local runway = normalizeRunwayIdent(runwayIdent)
    if airport == "" or not runway then
        return nil
    end

    local key = airport .. "|" .. runway
    local list = mainTable.byAirportRunway[key]
    if list and #list > 0 then
        return list[1]
    end

    local target, opposite = buildRunwayPair(runway)
    if not target then
        return nil
    end

    list = mainTable.byAirportRunway[airport .. "|" .. target]
    if list and #list > 0 then
        return list[1]
    end

    if opposite then
        list = mainTable.byAirportRunway[airport .. "|" .. opposite]
        if list and #list > 0 then
            return list[1]
        end
    end

    return nil
end

-- findRunwayLength(airportIdent, runwayIdent)
-- Returns: length_m (number) or nil, and a source string describing where the
-- length came from: "apt_exact", "apt_numeric_match", "nav_loc", etc.
function mainTable.findRunwayLength(airportIdent, runwayIdent)
    local airport = (tostring(airportIdent or ""):gsub("^%s+", ""):gsub("%s+$", "")):upper()
    if airport == "" or not runwayIdent then
        return nil, nil
    end

    -- Primary: exact apt lookup
    local exact = mainTable.findRunwayEnd(airport, runwayIdent)
    if exact and exact.length_m and exact.length_m > 0 then
        if logMsg then logMsg(string.format("APT PARSER: runway length for %s %s -> %.1fm (source=apt_exact)", airport, tostring(runwayIdent), exact.length_m)) end
        return exact.length_m, "apt_exact"
    end

    -- Fallback 1: permissive numeric-match against apt data (ignore L/R/C)
    local numeric = tonumber(tostring(runwayIdent):sub(1,2))
    if numeric then
        local best = 0
        local keyPrefix = airport .. "|"
        for k, list in pairs(mainTable.byAirportRunway) do
            if k:sub(1, #keyPrefix) == keyPrefix then
                for _, e in ipairs(list) do
                    if e and e.runway and tonumber(e.runway:sub(1,2)) == numeric and e.length_m and e.length_m > best then
                        best = e.length_m
                    end
                end
            end
        end
        if best > 0 then
            if logMsg then logMsg(string.format("APT PARSER: runway length for %s %s -> %.1fm (source=apt_numeric_match)", airport, tostring(runwayIdent), best)) end
            return best, "apt_numeric_match"
        end
    end

    -- Fallback 2: ask earth_nav_parser for an approximation
    local nav = rawget(_G, "earth_nav_parser")
    if not nav and rawget(_G, "custom_module") and custom_module.parsers then
        nav = custom_module.parsers.earth_nav
    end

    if nav and type(nav.findRunwayLength) == "function" then
        local ok, val = pcall(nav.findRunwayLength, airport, runwayIdent)
        if ok and val and type(val) == "number" and val > 0 then
            if logMsg then logMsg(string.format("APT PARSER: runway length for %s %s -> %.1fm (source=nav_loc)", airport, tostring(runwayIdent), val)) end
            return val, "nav_loc"
        end
    end

    return nil, nil
end

function mainTable.normalizeRunwayIdent(raw)
    return normalizeRunwayIdent(raw)
end

return mainTable
