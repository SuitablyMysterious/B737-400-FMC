#!/usr/bin/env lua
-- test_lnav.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

local function dirname(path)
    local normalized = (path or ""):gsub("\\", "/")
    return normalized:match("^(.*)/[^/]+$") or "."
end

local function resolveScriptPath()
    local source = debug.getinfo(1, "S").source
    local path = source and source:sub(2) or "test_lnav.lua"

    if path:sub(1, 1) ~= "/" and io.popen then
        local p = io.popen("pwd")
        if p then
            local cwd = p:read("*l")
            p:close()
            if cwd and cwd ~= "" then
                path = cwd .. "/" .. path
            end
        end
    end

    return path
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function pathExists(path)
    local f = io.open(path, "r")
    if not f then
        return false
    end
    f:close()
    return true
end

local function ensureTrailingSlash(path)
    local p = trim(path)
    if p == "" then
        return nil
    end
    if p:sub(-1) ~= "/" then
        p = p .. "/"
    end
    return p
end

local function shellQuote(path)
    return '"' .. tostring(path or ""):gsub('"', '\\"') .. '"'
end

local function mkdirP(path)
    os.execute("mkdir -p " .. shellQuote(path))
end

local function linkIfExists(src, dst)
    if src and src ~= "" and pathExists(src) then
        os.execute("ln -sf " .. shellQuote(src) .. " " .. shellQuote(dst))
        return true
    end
    return false
end

local function makeSaslShim(xplanePath, aircraftPath, xpVersion)
    return {
        getXPlanePath = function()
            return xplanePath
        end,
        getAircraftPath = function()
            return aircraftPath
        end,
        getXPVersion = function()
            return xpVersion
        end,
    }
end

local function resolveNavdataPaths(scriptDir)
    local env = os.getenv
    local sampleNavdata = scriptDir .. "/../EEPROM/examples/earth_nav.dat"
    local sampleAptdata = scriptDir .. "/../EEPROM/examples/apt.dat"
    local bundledNdbCache = scriptDir .. "/../FMC/EEPROM/earth_nav.ndb"
    local tempRoot = env("TMPDIR") or "/tmp"

    local defaultAircraftPath = ensureTrailingSlash(env("AIRCRAFT_PATH")) or (tempRoot .. "/lnav_aircraft_test/")
    mkdirP(defaultAircraftPath .. "EEPROM")

    local activeNdbCache = defaultAircraftPath .. "EEPROM/earth_nav.ndb"
    if not pathExists(activeNdbCache) then
        linkIfExists(bundledNdbCache, activeNdbCache)
    end

    local explicitNavdata = env("NAVDATA_FILE")
    local explicitAptdata = env("APTDATA_FILE")
    if explicitNavdata and pathExists(explicitNavdata) then
        local shimRoot = tempRoot .. "/lnav_navshim_explicit"
        mkdirP(shimRoot .. "/Custom Data")
        mkdirP(shimRoot .. "/Resources/default data")
        mkdirP(shimRoot .. "/Resources/default scenery/default apt dat/Earth nav data")
        linkIfExists(explicitNavdata, shimRoot .. "/Custom Data/earth_nav.dat")

        if not linkIfExists(explicitAptdata, shimRoot .. "/Resources/default scenery/default apt dat/Earth nav data/apt.dat") then
            linkIfExists(sampleAptdata, shimRoot .. "/Resources/default scenery/default apt dat/Earth nav data/apt.dat")
        end

        return ensureTrailingSlash(shimRoot), defaultAircraftPath, tonumber(env("XP_VERSION")) or 12000
    end

    local xplanePath = ensureTrailingSlash(env("XPLANE_PATH") or env("XPLANE_ROOT"))
    if xplanePath then
        return xplanePath, defaultAircraftPath, tonumber(env("XP_VERSION")) or 12000
    end

    if not pathExists(sampleNavdata) then
        return nil, nil, nil
    end

    local shimRoot = tempRoot .. "/lnav_navshim"
    mkdirP(shimRoot .. "/Custom Data")
    mkdirP(shimRoot .. "/Resources/default data")
    mkdirP(shimRoot .. "/Resources/default scenery/default apt dat/Earth nav data")
    linkIfExists(sampleNavdata, shimRoot .. "/Custom Data/earth_nav.dat")
    linkIfExists(sampleAptdata, shimRoot .. "/Resources/default scenery/default apt dat/Earth nav data/apt.dat")
    return ensureTrailingSlash(shimRoot), defaultAircraftPath, tonumber(env("XP_VERSION")) or 12000
end

local function loadParsers(scriptDir)
    local xplanePath, aircraftPath, xpVersion = resolveNavdataPaths(scriptDir)
    if not xplanePath then
        error("No X-Plane navdata source found. Set XPLANE_PATH or NAVDATA_FILE.")
    end

    local previousSasl = rawget(_G, "sasl")
    local previousLogMsg = rawget(_G, "logMsg")
    local previousEarthNav = rawget(_G, "earth_nav_parser")
    local previousEarthApt = rawget(_G, "earth_apt_parser")
    local previousCustomModule = rawget(_G, "custom_module")
    local parserLogs = {}

    rawset(_G, "sasl", makeSaslShim(xplanePath, aircraftPath, xpVersion))
    rawset(_G, "logMsg", function(message)
        parserLogs[#parserLogs + 1] = tostring(message)
        if type(previousLogMsg) == "function" then
            pcall(previousLogMsg, message)
        end
    end)
    rawset(_G, "earth_nav_parser", nil)
    rawset(_G, "earth_apt_parser", nil)

    local navParserPath = scriptDir .. "/../EEPROM/earth_nav_parser.lua"
    local okNav, navParser = pcall(dofile, navParserPath)
    if not okNav then
        rawset(_G, "sasl", previousSasl)
        rawset(_G, "logMsg", previousLogMsg)
        rawset(_G, "earth_nav_parser", previousEarthNav)
        rawset(_G, "earth_apt_parser", previousEarthApt)
        rawset(_G, "custom_module", previousCustomModule)
        error("Failed to load earth_nav_parser: " .. tostring(navParser))
    end

    local aptParserPath = scriptDir .. "/../EEPROM/earth_apt_parser.lua"
    local okApt, aptParser = pcall(dofile, aptParserPath)
    if not okApt then
        rawset(_G, "sasl", previousSasl)
        rawset(_G, "logMsg", previousLogMsg)
        rawset(_G, "earth_nav_parser", previousEarthNav)
        rawset(_G, "earth_apt_parser", previousEarthApt)
        rawset(_G, "custom_module", previousCustomModule)
        error("Failed to load earth_apt_parser: " .. tostring(aptParser))
    end

    return {
        earth_nav = navParser,
        earth_apt = aptParser,
    }, {
        sasl = previousSasl,
        logMsg = previousLogMsg,
        earth_nav_parser = previousEarthNav,
        earth_apt_parser = previousEarthApt,
        custom_module = previousCustomModule,
        logs = parserLogs,
    }
end

local function restoreParserGlobals(state)
    if not state then
        return
    end
    rawset(_G, "sasl", state.sasl)
    rawset(_G, "logMsg", state.logMsg)
    rawset(_G, "earth_nav_parser", state.earth_nav_parser)
    rawset(_G, "earth_apt_parser", state.earth_apt_parser)
    rawset(_G, "custom_module", state.custom_module)
end

local function ensureParserReady(parser, parserName)
    if not parser then
        return false
    end

    if parser.ready then
        return true
    end

    if type(parser.load) == "function" then
        local ok, err = pcall(parser.load)
        if not ok then
            error(tostring(parserName) .. ".load failed: " .. tostring(err))
        end
    end

    if not parser.ready and parser.loading == false then
        error(tostring(parserName) .. " did not start loading. Check navdata path configuration.")
    end

    local limit = tonumber(os.getenv("PARSER_UPDATE_LIMIT") or "-1")
    local iter = 0
    while not parser.ready do
        if type(parser.update) ~= "function" then
            break
        end

        iter = iter + 1
        local ok, err = pcall(parser.update)
        if not ok then
            error(tostring(parserName) .. ".update failed: " .. tostring(err))
        end

        if not parser.ready and parser.loading == false then
            error(tostring(parserName) .. " stopped before ready state")
        end

        if (iter % 250) == 0 then
            io.stderr:write(string.format(
                "Waiting for %s to become ready (iter=%d, linesRead=%s)\n",
                tostring(parserName),
                iter,
                tostring(parser.linesRead or "N/A")
            ))
        end

        if limit >= 0 and iter >= limit then
            error(tostring(parserName) .. " update loop exceeded PARSER_UPDATE_LIMIT=" .. tostring(limit))
        end
    end

    return parser.ready == true
end

local function sourceFromNavEntry(entry)
    local t = tonumber(entry and entry.type)
    if t == 3 then
        return "VOR"
    elseif t == 2 then
        return "NDB"
    elseif t == 4 or t == 5 then
        return "LOC"
    elseif t == 12 or t == 13 then
        return "DME"
    end
    return "NAV"
end

local function navPriority(entry)
    local t = tonumber(entry and entry.type)
    if t == 3 then
        return 1
    elseif t == 2 then
        return 2
    elseif t == 4 or t == 5 then
        return 3
    elseif t == 12 or t == 13 then
        return 4
    end
    return 9
end

local function distanceScoreSq(lat1, lon1, lat2, lon2)
    if not isFiniteNumber(lat1) or not isFiniteNumber(lon1) or not isFiniteNumber(lat2) or not isFiniteNumber(lon2) then
        return math.huge
    end
    local dlat = lat1 - lat2
    local dlon = lon1 - lon2
    return dlat * dlat + dlon * dlon
end

local function chooseBestNavCandidate(candidates, refLat, refLon)
    if not candidates or #candidates == 0 then
        return nil, nil
    end

    if isFiniteNumber(refLat) and isFiniteNumber(refLon) then
        local best = nil
        local bestDist = math.huge
        for _, entry in ipairs(candidates) do
            local d = distanceScoreSq(refLat, refLon, entry and entry.lat, entry and entry.lon)
            if d < bestDist then
                bestDist = d
                best = entry
            end
        end

        if best and bestDist < math.huge then
            return best, "closest"
        end
    end

    local best = candidates[1]
    local bestPriority = navPriority(best)
    for i = 2, #candidates do
        local current = candidates[i]
        local p = navPriority(current)
        if p < bestPriority then
            best = current
            bestPriority = p
        end
    end
    return best, "priority"
end

local function resolveAirportWaypoint(aptParser, ident, refLat, refLon)
    if not aptParser or type(aptParser.byAirport) ~= "table" then
        return nil
    end

    local rows = aptParser.byAirport[ident]
    if type(rows) ~= "table" or #rows == 0 then
        return nil
    end

    local best = nil
    local bestDist = math.huge
    for _, row in ipairs(rows) do
        if isFiniteNumber(row.lat) and isFiniteNumber(row.lon) then
            local d = distanceScoreSq(refLat, refLon, row.lat, row.lon)
            if not isFiniteNumber(refLat) or not isFiniteNumber(refLon) then
                d = 0
            end
            if d < bestDist then
                bestDist = d
                best = row
            end
        end
    end

    if not best then
        return nil
    end

    return {
        ident = ident,
        lat = best.lat,
        lon = best.lon,
        type = "TF",
        fly_over = false,
        _source = "APT",
        _selection = isFiniteNumber(refLat) and isFiniteNumber(refLon) and "closest" or "first",
        _candidate_count = #rows,
    }
end

local function resolveWaypoint(parsers, identRaw, refLat, refLon)
    local ident = trim(identRaw):upper()
    if ident == "" then
        return nil, "empty ident"
    end

    local nav = parsers and parsers.earth_nav or nil
    if nav and type(nav.findAll) == "function" then
        local ok, candidates = pcall(nav.findAll, ident)
        if ok and type(candidates) == "table" and #candidates > 0 then
            local best, selection = chooseBestNavCandidate(candidates, refLat, refLon)
            if best and isFiniteNumber(best.lat) and isFiniteNumber(best.lon) then
                return {
                    ident = ident,
                    lat = best.lat,
                    lon = best.lon,
                    type = "TF",
                    fly_over = false,
                    _source = sourceFromNavEntry(best),
                    _selection = selection,
                    _candidate_count = #candidates,
                }, nil
            end
        end
    end

    if parsers and parsers.earth_apt and not parsers._apt_ready and not parsers._apt_failed then
        io.stderr:write("Loading airport parser for ICAO waypoint lookup...\n")
        local ok, readyOrErr = pcall(ensureParserReady, parsers.earth_apt, "earth_apt_parser")
        if ok and readyOrErr then
            parsers._apt_ready = true
        else
            parsers._apt_failed = tostring(readyOrErr)
        end
    end

    local airportWp = resolveAirportWaypoint(
        (parsers and parsers._apt_ready) and parsers.earth_apt or nil,
        ident,
        refLat,
        refLon
    )
    if airportWp then
        return airportWp, nil
    end

    return nil, "ident not found"
end

local function printHelp()
    print("Enter waypoint IDENT only (pilot-style input).")
    print("Examples: OLM, BTG, SEA, KSEA")
    print("Type 'd' when done, or '?' for help")
end

local function printWaypoints(title, waypoints)
    print("")
    print(title)
    if not waypoints or #waypoints == 0 then
        print("  <none>")
        return
    end

    for i, wp in ipairs(waypoints) do
        print(string.format(
            "  %02d  %-8s lat=%9.5f lon=%10.5f src=%-3s",
            i,
            tostring(wp.ident or ""),
            tonumber(wp.lat) or 0,
            tonumber(wp.lon) or 0,
            tostring(wp._source or "LNAV")
        ))
    end
end

local function printSelectionHint(wp)
    if not wp or not wp._candidate_count or wp._candidate_count <= 1 then
        return
    end

    if wp._selection == "closest" then
        print(string.format("  matched %d entries; selected closest to previous waypoint", wp._candidate_count))
    elseif wp._selection == "priority" then
        print(string.format("  matched %d entries; selected by NAV priority (VOR>NDB>LOC>DME)", wp._candidate_count))
    elseif wp._selection == "first" then
        print(string.format("  matched %d airport runway ends; selected first", wp._candidate_count))
    end
end

local function toFlightPlan(waypoints)
    local flightPlan = {}
    for _, wp in ipairs(waypoints or {}) do
        flightPlan[#flightPlan + 1] = {
            ident = wp.ident,
            lat = wp.lat,
            lon = wp.lon,
            type = "TF",
            fly_over = wp.fly_over == true,
        }
    end
    return flightPlan
end

local function runInteractiveLookup(parsers)
    print("INTERACTIVE LNAV WAYPOINT TEST")
    printHelp()

    local enteredWaypoints = {}

    while true do
        io.write(string.format("WP %02d> ", #enteredWaypoints + 1))
        local line = io.read("*l")
        if not line then
            break
        end

        local raw = trim(line)
        if raw == "" then
        else
            local upper = raw:upper()
            if upper == "D" or upper == "DONE" then
                break
            elseif upper == "?" or upper == "HELP" then
                printHelp()
            elseif upper:find("%s") then
                io.stderr:write("Enter one waypoint ident at a time.\n")
            else
                local refLat = nil
                local refLon = nil
                if #enteredWaypoints > 0 then
                    local previous = enteredWaypoints[#enteredWaypoints]
                    refLat = previous and previous.lat or nil
                    refLon = previous and previous.lon or nil
                end

                local wp, err = resolveWaypoint(parsers, upper, refLat, refLon)
                if not wp then
                    io.stderr:write("Waypoint '" .. tostring(upper) .. "' not found (" .. tostring(err) .. ")\n")
                else
                    enteredWaypoints[#enteredWaypoints + 1] = wp
                    print(string.format(
                        "Added %-8s lat=%9.5f lon=%10.5f src=%s",
                        tostring(wp.ident),
                        tonumber(wp.lat) or 0,
                        tonumber(wp.lon) or 0,
                        tostring(wp._source or "NAV")
                    ))
                    printSelectionHint(wp)
                end
            end
        end
    end

    return enteredWaypoints
end

local function main()
    local scriptDir = dirname(resolveScriptPath())
    local lnav = dofile(scriptDir .. "/lnav_core.lua")

    local parsers, parserState = loadParsers(scriptDir)
    local ok, result = pcall(function()
        if not ensureParserReady(parsers.earth_nav, "earth_nav_parser") then
            error("earth_nav_parser did not become ready")
        end

        earth_nav_parser = parsers.earth_nav
        earth_apt_parser = parsers.earth_apt
        custom_module = {
            parsers = {
                earth_nav = earth_nav_parser,
                earth_apt = earth_apt_parser,
            },
        }

        local enteredWaypoints = runInteractiveLookup(parsers)
        printWaypoints("Entered waypoints:", enteredWaypoints)

        lnav.setFlightPlan(toFlightPlan(enteredWaypoints))
        printWaypoints("LNAV accepted waypoints:", lnav.flightplan)

        if #lnav.flightplan >= 2 then
            local fromWp = lnav.flightplan[lnav.active_leg]
            local toWp = lnav.flightplan[lnav.active_leg + 1]
            print("")
            print(string.format("Active leg preview: %s -> %s", tostring(fromWp.ident), tostring(toWp.ident)))
        else
            print("")
            print("Need at least 2 waypoints for an LNAV leg preview.")
        end
    end)

    restoreParserGlobals(parserState)

    if not ok then
        if parserState and parserState.logs and #parserState.logs > 0 then
            io.stderr:write("PARSER LOGS: " .. table.concat(parserState.logs, " | ") .. "\n")
        end
        error(result)
    end
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("LNAV TEST FAILED: " .. tostring(err) .. "\n")
    os.exit(1)
end
