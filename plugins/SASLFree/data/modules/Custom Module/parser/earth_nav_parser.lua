-- earth_nav_parser.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

-- Row type constants:

local ROW_NDB = 2
local ROW_VOR = 3
local ROW_ILS_LOC = 4
local ROW_LOC_ONLY = 5
local ROW_GS = 6
local ROW_OM = 7
local ROW_MM = 8
local ROW_IM = 9
local ROW_DME_PAI = 12
local ROW_DME_STA = 13
local ROW_FPAP = 14
local ROW_GLS = 15
local ROW_LTP = 16
local ROW_EOF = 99

-- General variables

local xp_path = sasl.getXPlanePath()
local aircraft_path = sasl.getAircraftPath()
local xp_version = sasl.getXPVersion()

local xp11_navdata_paths = {
    {"Custom Data/earth_nav.dat"},
    {"Resources/default data/earth_nav.dat"},
}

local xp12_navdata_paths = {
    {"Custom Data/earth_nav.dat"},
    {"Resources/default data/earth_nav.dat"},
}

-- main table

local mainTable = {}

-- storage tables

mainTable.ndb = {} -- keyed by ident, dupes allowed
mainTable.vor = {} -- keyed by ident
mainTable.loc = {} -- keyed by ident
mainTable.gs = {} -- keyed by ident
mainTable.markers = {} -- OM/MM/IM, keyed by assiciated loc ident
mainTable.dme = {} -- keyed by ident
mainTable.fpap = {} -- final approach path alignment points
mainTable.ltp = {} -- landing thresholds points
mainTable.gls = {} -- GBAS ground stations

-- parse state
mainTable.ready = false
mainTable.loading = false
mainTable.linesRead = 0
mainTable.totalNavaids = 0

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

-- safe function for safely inserting navaid

local function insertNavaid(tbl, key, entry)
    if not tbl[key] then
        tbl[key] = {}
    end
    table.insert(tbl[key], entry)
end

local function decodeLocBearing(raw)
    local true_brg = raw % 360
    local mag_front = math.floor(raw / 360 + 0.5)
    return true_brg, mag_front
end

local function decodeGlideslope(raw)
    local true_brg = raw % 100000
    local angle = math.floor(raw / 100000 + 0.5) / 1000.0
    return true_brg, angle
end

local function parseName(tokens, startIdx)
    -- Name may be multi-word; concat everything from startIdx onward
    local parts = {}
    for i = startIdx, #tokens do
        parts[#parts + 1] = tokens[i]
    end
    return table.concat(parts, " ")
end

local function parseNDB(t)
    local entry = {
        type = ROW_NDB,
        lat = tonumber(t[2]),
        lon = tonumber(t[3]),
        elev = tonumber(t[4]), -- ft MSL
        freq = tonumber(t[5]), -- kHz (integer)
        class = tonumber(t[6]), -- 15/25/50/75
        bfo = tonumber(t[7]) == 1.0, -- BFO required flag
        ident = t[8],
        region = t[9], -- airport ICAO or "ENRT"
        icao = t[10], -- ICAO region code
        name = parseName(t, 11),
    }
    insertNavaid(mainTable.ndb, entry.ident, entry)
end

local function parseVOR(t)
    local entry = {
        type = ROW_VOR,
        lat = tonumber(t[2]),
        lon = tonumber(t[3]),
        elev = tonumber(t[4]), -- ft MSL
        freq = tonumber(t[5]), -- MHz * 100 (e.g. 11680 = 116.80)
        freq_mhz = tonumber(t[5]) / 100, -- convenience
        class = tonumber(t[6]), -- 25=terminal, 40=lo-alt, 130=hi-alt
        slaved_var = tonumber(t[7]), -- true degrees of 0-radial
        ident = t[8],
        -- t[9] is always "ENRT" for VORs per spec
        icao = t[10], -- ICAO region code
        name = parseName(t, 11),
    }
    insertNavaid(mainTable.vor, entry.ident, entry)
end

local function parseLOC(t, rowcode)
    local raw_bearing = tonumber(t[7])
    local true_brg, mag_front = decodeLocBearing(raw_bearing)

    local entry = {
        type = rowcode, -- 4=ILS, 5=LOC-only/LDA/SDF
        is_ils = (rowcode == ROW_ILS_LOC),
        lat = tonumber(t[2]),
        lon = tonumber(t[3]),
        elev = tonumber(t[4]),
        freq = tonumber(t[5]),
        freq_mhz = tonumber(t[5]) / 100,
        range = tonumber(t[6]), -- nm
        true_brg = true_brg, -- true bearing of localizer
        mag_front = mag_front, -- magnetic front course (degrees)
        ident = t[8],
        airport = t[9], -- associated airport ICAO
        icao = t[10], -- ICAO region
        runway = t[11], -- e.g. "16L"
        name = parseName(t, 12), -- "ILS-cat-I", "LOC", "LDA", "SDF" etc.
        -- glideslope will be linked here after file is fully parsed
        gs = nil,
    }
    insertNavaid(mainTable.loc, entry.ident, entry)
end

local function parseGS(t)
    local raw = tonumber(t[7])
    local true_brg, gs_angle = decodeGlideslope(raw)

    local entry = {
        type = ROW_GS,
        lat = tonumber(t[2]),
        lon = tonumber(t[3]),
        elev = tonumber(t[4]),
        freq = tonumber(t[5]),
        freq_mhz = tonumber(t[5]) / 100,
        range = tonumber(t[6]),
        true_brg = true_brg,
        gs_angle = gs_angle, -- glideslope angle in degrees (e.g. 3.0)
        ident = t[8],
        airport = t[9],
        icao = t[10],
        runway = t[11],
    }
    insertNavaid(mainTable.gs, entry.ident, entry)
end

local function parseMarker(t, rowcode)
    local mtype = ({ [7] = "OM", [8] = "MM", [9] = "IM" })[rowcode]
    local entry = {
        type = rowcode,
        marker = mtype,
        lat = tonumber(t[2]),
        lon = tonumber(t[3]),
        elev = tonumber(t[4]),
        loc_brg = tonumber(t[7]), -- associated localizer true bearing
        loc_ident = t[8], -- associated ILS/LOC identifier
        airport = t[9],
        icao = t[10],
        runway = t[11],
    }
    -- Group markers under their localizer ident
    if not mainTable.markers[entry.loc_ident] then
        mainTable.markers[entry.loc_ident] = {}
    end
    mainTable.markers[entry.loc_ident][mtype] = entry
end

local function parseDME(t, rowcode)
    local entry = {
        type = rowcode, -- 12=paired(suppress), 13=standalone(show)
        paired = (rowcode == ROW_DME_PAI),
        lat = tonumber(t[2]),
        lon = tonumber(t[3]),
        elev = tonumber(t[4]),
        freq = tonumber(t[5]),
        freq_mhz = tonumber(t[5]) / 100,
        range = tonumber(t[6]),
        bias = tonumber(t[7]), -- nm bias, usually 0.0
        ident = t[8],
        airport = t[9], -- airport ICAO or "ENRT"
        icao = t[10],
        name = parseName(t, 11),
    }
    insertNavaid(mainTable.dme, entry.ident, entry)
end

local function parseFPAP(t)
    local entry = {
        type = ROW_FPAP,
        lat = tonumber(t[2]),
        lon = tonumber(t[3]),
        height = tonumber(t[4]), -- orthometric height ft
        channel = tonumber(t[5]), -- WAAS or GLS channel
        length_offset = tonumber(t[6]), -- meters from stop end to FPAP
        course = tonumber(t[7]), -- final approach true course
        proc_ident = t[8],
        airport = t[9],
        icao = t[10],
        runway = t[11],
        performance = t[12], -- "LP", "LPV", "APV-II", "GLS"
    }
    insertNavaid(mainTable.fpap, entry.proc_ident, entry)
end

local function parseGLS(t)
    local raw = tonumber(t[7])
    local true_brg, gp_angle = decodeGlideslope(raw)

    local entry = {
        type = ROW_GLS,
        lat = tonumber(t[2]),
        lon = tonumber(t[3]),
        elev = tonumber(t[4]),
        channel = tonumber(t[5]),
        true_brg = true_brg,
        gp_angle = gp_angle,
        proc_ident = t[8],
        airport = t[9],
        icao = t[10],
        runway = t[11],
    }
    insertNavaid(mainTable.gls, entry.proc_ident, entry)
end

local function parseLTP(t)
    local raw = tonumber(t[7])
    local true_brg, gp_angle = decodeGlideslope(raw)

    local entry = {
        type = ROW_LTP,
        lat = tonumber(t[2]),
        lon = tonumber(t[3]),
        height = tonumber(t[4]), -- orthometric height ft
        channel = tonumber(t[5]),
        tch = tonumber(t[6]), -- threshold crossing height ft
        true_brg = true_brg,
        gp_angle = gp_angle,
        proc_ident = t[8],
        airport = t[9],
        icao = t[10],
        runway = t[11],
        ref_path = t[12] or "GP", -- e.g. "W16B", default "GP"
    }
    insertNavaid(mainTable.ltp, entry.proc_ident, entry)
end

local function linkGlideslopes()
    for ident, gs_list in pairs(mainTable.gs) do
        for _, gs in ipairs(gs_list) do
            local loc_list = mainTable.loc[ident]
            if loc_list then
                for _, loc in ipairs(loc_list) do
                    if loc.airport == gs.airport and loc.runway == gs.runway then
                        loc.gs = gs
                        break
                    end
                end
            end
        end
    end
end

local function parseLine(line)
    -- Tokenise on whitespace
    local t = {}
    for token in line:gmatch("%S+") do
        t[#t + 1] = token
    end

    if #t < 2 then return end

    local rowcode = tonumber(t[1])
    if not rowcode then return end

        if rowcode == ROW_EOF then return "EOF"
        elseif rowcode == ROW_NDB then parseNDB(t)
        elseif rowcode == ROW_VOR then parseVOR(t)
        elseif rowcode == ROW_ILS_LOC then parseLOC(t, ROW_ILS_LOC)
        elseif rowcode == ROW_LOC_ONLY then parseLOC(t, ROW_LOC_ONLY)
        elseif rowcode == ROW_GS then parseGS(t)
        elseif rowcode == ROW_OM or
            rowcode == ROW_MM or
            rowcode == ROW_IM then parseMarker(t, rowcode)
        elseif rowcode == ROW_DME_PAI then parseDME(t, ROW_DME_PAI)
        elseif rowcode == ROW_DME_STA then parseDME(t, ROW_DME_STA)
        elseif rowcode == ROW_FPAP then parseFPAP(t)
        elseif rowcode == ROW_GLS then parseGLS(t)
        elseif rowcode == ROW_LTP then parseLTP(t)
        end
end

local function resetStorageTables()
    mainTable.ndb = {}
    mainTable.vor = {}
    mainTable.loc = {}
    mainTable.gs = {}
    mainTable.markers = {}
    mainTable.dme = {}
    mainTable.fpap = {}
    mainTable.ltp = {}
    mainTable.gls = {}
end

-- Cache helpers: write NDB cache to aircraft_dir/EEPROM/earth_nav.ndb
local function getNDBCacheFile()
    return aircraft_path .. "EEPROM/earth_nav.ndb"
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

-- saveNDBCache(navdataPath): writes the current mainTable.ndb to cache
-- and prefixes the cache with the two header lines from navdataPath
local function saveNDBCache(navdataPath)
    ensureEEPROMDir()
    local meta1, meta2 = readTwoHeaderLines(navdataPath or findNavdataPath())
    local f = io.open(getNDBCacheFile(), "w")
    if not f then
        logMsg("NAVDATA PARSER: Cannot open NDB cache for writing: " .. tostring(getNDBCacheFile()))
        return
    end
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

    for ident, list in pairs(mainTable.ndb) do
        for _, e in ipairs(list) do
            local name = (e.name or ""):gsub("\t", " "):gsub("\n", " ")
            push(string.format("%s\t%f\t%f\t%f\t%d\t%d\t%d\t%s\t%s\t%s\n",
                e.ident or "", e.lat or 0, e.lon or 0, e.elev or 0,
                e.freq or 0, e.class or 0, e.bfo and 1 or 0,
                e.region or "", e.icao or "", name))
        end
    end

    if #writeBuffer > 0 then
        f:write(table.concat(writeBuffer))
    end

    f:close()
    logMsg("NAVDATA PARSER: Saved NDB cache to " .. getNDBCacheFile())
end

-- loadNDBCache(navdataPath): loads cache only if its first two header
-- lines match the current navdata file at navdataPath. Returns true on success.
local function loadNDBCache(navdataPath)
    local cache = io.open(getNDBCacheFile(), "r")
    if not cache then return false end
    local cache_h1 = cache:read("*l") or ""
    local cache_h2 = cache:read("*l") or ""
    local nav_h1, nav_h2 = readTwoHeaderLines(navdataPath or findNavdataPath())
    if not nav_h1 or cache_h1 ~= (nav_h1 or "") or cache_h2 ~= (nav_h2 or "") then
        cache:close()
        return false
    end

    -- Parse cached rows: ident lat lon elev freq class bfo region icao name
    for line in cache:lines() do
        local ident, lat, lon, elev, freq, class, bfo, region, icao, name =
            line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")

        if ident and ident ~= "" then
            local entry = {
                type = ROW_NDB,
                lat = tonumber(lat),
                lon = tonumber(lon),
                elev = tonumber(elev),
                freq = tonumber(freq),
                class = tonumber(class),
                bfo = tonumber(bfo) == 1,
                ident = ident,
                region = region,
                icao = icao,
                name = name,
            }
            insertNavaid(mainTable.ndb, entry.ident, entry)
        end
    end

    cache:close()
    logMsg("NAVDATA PARSER: Loaded NDB cache from " .. getNDBCacheFile())
    return true
end

local BATCH_SIZE = 500

local function loaderCoroutine(path)
    local f = io.open(path, "r")
    if not f then
        logMsg("NAVDATA PARSER: Cannot open " .. tostring(path))
        return
    end

    local lineNum = 0
    local batch = 0

    for line in f:lines() do
        lineNum = lineNum + 1
        mainTable.linesRead = lineNum

        -- First two lines are header (byte-order + version string) — skip
        if lineNum <= 2 then goto continue end

        -- Skip blank lines
        if line:match("^%s*$") then goto continue end

        local result = parseLine(line)
        if result == "EOF" then break end

        mainTable.totalNavaids = mainTable.totalNavaids + 1

        batch = batch + 1
        if batch >= BATCH_SIZE then
            batch = 0
            coroutine.yield()
        end

        ::continue::
    end

    f:close()
    linkGlideslopes()
    mainTable.ready = true
    mainTable.loading = false
    -- save NDB cache (best-effort)
    pcall(saveNDBCache, path)

    logMsg(string.format(
        "NAVDATA PARSER: Done. %d lines, %d navaids. VOR=%d NDB=%d LOC=%d",
        lineNum,
        mainTable.totalNavaids,
        mainTable.countTable(mainTable.vor),
        mainTable.countTable(mainTable.ndb),
        mainTable.countTable(mainTable.loc)
    ))
end

function mainTable.countTable(tbl)
    local n = 0
    for _, v in pairs(tbl) do
        if type(v) == "table" then
            n = n + #v
        end
    end
    return n
end

function mainTable.load()
    if mainTable.loading or mainTable.ready then return end
    local path = findNavdataPath()
    if not path then
        logMsg("NAVDATA PARSER: No earth_nav.dat found")
        return
    end

    resetStorageTables()

    mainTable.loading = true
    mainTable.ready = false
    mainTable.linesRead = 0
    mainTable.totalNavaids = 0
    logMsg("NAVDATA PARSER: Loading " .. tostring(path))
    -- attempt to load cached NDB if metadata matches current navdata
    local ok, loaded = pcall(loadNDBCache, path)
    if ok and loaded and mainTable.countTable(mainTable.ndb) > 0 then
        mainTable.ready = true
        mainTable.loading = false
        logMsg("NAVDATA PARSER: Using cached NDB data from " .. getNDBCacheFile())
        return
    end
    -- fallback: parse the navdata file
    _coro = coroutine.create(function() loaderCoroutine(path) end)
end

-- Call every frame from your update() loop
function mainTable.update()
    if _coro and not mainTable.ready then
        local ok, err = coroutine.resume(_coro)
        if not ok then
            logMsg("NAVDATA PARSER ERROR: " .. tostring(err))
            mainTable.loading = false
            _coro = nil
        end
        if coroutine.status(_coro) == "dead" then
            _coro = nil
        end
    end
end

local function distSq(lat1, lon1, lat2, lon2)
    local dlat = lat1 - lat2
    local dlon = lon1 - lon2
    return dlat*dlat + dlon*dlon
end

local function findClosest(tbl, ident, ref_lat, ref_lon)
    local entries = tbl[ident]
    if not entries then return nil end
    if #entries == 1 then return entries[1] end

    -- Multiple entries with same ident — return closest to ref pos
    local best, bestDist = nil, math.huge
    for _, e in ipairs(entries) do
        local d = distSq(e.lat, e.lon, ref_lat or 0, ref_lon or 0)
        if d < bestDist then
            bestDist = d
            best = e
        end
    end
    return best
end

-- Get VOR by ident (closest to ref pos if duplicate)
function mainTable.getVOR(ident, ref_lat, ref_lon)
    return findClosest(mainTable.vor, ident, ref_lat, ref_lon)
end

-- Get NDB by ident
function mainTable.getNDB(ident, ref_lat, ref_lon)
    return findClosest(mainTable.ndb, ident, ref_lat, ref_lon)
end

-- Get ILS/LOC by ident
function mainTable.getLOC(ident, ref_lat, ref_lon)
    return findClosest(mainTable.loc, ident, ref_lat, ref_lon)
end

-- Get DME by ident
function mainTable.getDME(ident, ref_lat, ref_lon)
    return findClosest(mainTable.dme, ident, ref_lat, ref_lon)
end

-- Generic: search VOR first, then NDB, then LOC
-- Useful for FMS ident entry where the user types "LON" or "SEA"
function mainTable.findNavaid(ident, ref_lat, ref_lon)
    return mainTable.getVOR(ident, ref_lat, ref_lon)
        or mainTable.getNDB(ident, ref_lat, ref_lon)
        or mainTable.getLOC(ident, ref_lat, ref_lon)
        or mainTable.getDME(ident, ref_lat, ref_lon)
end

-- Return ALL entries for an ident across all tables (for CDU disambiguation page)
function mainTable.findAll(ident)
    local results = {}
    local function collect(tbl)
        if tbl[ident] then
            for _, e in ipairs(tbl[ident]) do
                results[#results + 1] = e
            end
        end
    end
    collect(mainTable.vor)
    collect(mainTable.ndb)
    collect(mainTable.loc)
    collect(mainTable.dme)
    return results
end

return mainTable