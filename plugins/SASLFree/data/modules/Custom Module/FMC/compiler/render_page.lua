#!/usr/bin/env lua
-- render_page.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

-- CLI scaffold renderer for compiled FMC pages.

local function dirname(path)
    local normalized = path:gsub("\\", "/")
    return normalized:match("^(.*)/[^/]+$") or "."
end

local scriptPath = debug.getinfo(1, "S").source:sub(2)
if scriptPath:sub(1, 1) ~= "/" then
    local cwd = io.popen("pwd"):read("*l")
    scriptPath = cwd .. "/" .. scriptPath
end
local scriptDir = dirname(scriptPath)
local compiledDir = scriptDir .. "/../pages_compiled"

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function pathExists(path)
    local f = io.open(path, "r")
    if not f then
        return false
    end
    f:close()
    return true
end

local function centerText(text, width)
    local value = tostring(text or "")
    if #value >= width then
        return value:sub(1, width)
    end

    local pad = width - #value
    local left = math.floor(pad / 2)
    local right = pad - left
    return string.rep(" ", left) .. value .. string.rep(" ", right)
end

local function truncateText(text, width)
    local value = tostring(text or "")
    if #value <= width then
        return value .. string.rep(" ", width - #value)
    end
    if width <= 1 then
        return value:sub(1, width)
    end
    return value:sub(1, width - 1) .. "~"
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

local function resolveNavdataPaths()
    local env = os.getenv
    local repoRoot = scriptDir
    for _ = 1, 7 do
        repoRoot = dirname(repoRoot)
    end
    local sampleNavdata = repoRoot .. "/plugins/SASLFree/data/modules/Custom Module/EEPROM/examples/earth_nav.dat"
    local tempRoot = os.getenv("TMPDIR") or "/tmp"
    local defaultAircraftPath = tempRoot .. "/fmc_aircraft_render_" .. tostring(os.time()) .. "/"
    os.execute('mkdir -p "' .. defaultAircraftPath .. 'EEPROM"')

    local explicitNavdata = env("NAVDATA_FILE")
    if explicitNavdata and pathExists(explicitNavdata) then
        local navDir = explicitNavdata:match("^(.*)/[^/]+$")
        if navDir then
            return navDir .. "/", env("AIRCRAFT_PATH") or defaultAircraftPath, tonumber(env("XP_VERSION")) or 12000
        end
    end

    local xplanePath = env("XPLANE_PATH") or env("XPLANE_ROOT")
    if xplanePath and xplanePath ~= "" then
        return xplanePath, env("AIRCRAFT_PATH") or defaultAircraftPath, tonumber(env("XP_VERSION")) or 12000
    end

    if repoRoot ~= "" then
        local shimRoot = tempRoot .. "/fmc_navshim"
            os.execute('mkdir -p "' .. shimRoot .. '/Custom Data"')
            os.execute('mkdir -p "' .. shimRoot .. '/Resources/default data"')
            os.execute('ln -sf "' .. sampleNavdata .. '" "' .. shimRoot .. '/Custom Data/earth_nav.dat"')
        return shimRoot .. "/", env("AIRCRAFT_PATH") or defaultAircraftPath, tonumber(env("XP_VERSION")) or 12000
    end

    return nil, nil, nil
end

local function loadRealNavParser()
    local xplanePath, aircraftPath, xpVersion = resolveNavdataPaths()
    if not xplanePath then
        error("No X-Plane navdata source found. Set XPLANE_PATH or NAVDATA_FILE.")
    end


    local previousSasl = rawget(_G, "sasl")
    local previousLogMsg = rawget(_G, "logMsg")
    local previousEarthNav = rawget(_G, "earth_nav_parser")
    local parserLogs = {}

    rawset(_G, "sasl", makeSaslShim(xplanePath, aircraftPath, xpVersion))
    rawset(_G, "logMsg", function(message)
        parserLogs[#parserLogs + 1] = tostring(message)
        if type(previousLogMsg) == "function" then
            pcall(previousLogMsg, message)
        end
    end)
    rawset(_G, "earth_nav_parser", nil)

    local parserPath = scriptDir .. "/../../EEPROM/earth_nav_parser.lua"
    local ok, parser = pcall(dofile, parserPath)

    if not ok then
        rawset(_G, "sasl", previousSasl)
        rawset(_G, "logMsg", previousLogMsg)
        rawset(_G, "earth_nav_parser", previousEarthNav)
        error("Failed to load real earth_nav_parser: " .. tostring(parser))
    end

    return parser, {
        sasl = previousSasl,
        logMsg = previousLogMsg,
        earth_nav_parser = previousEarthNav,
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
end

local function ensureParserReady(parser)
    if not parser then
        return false
    end

    if parser.ready then
        return true
    end

    if type(parser.load) == "function" then
        local ok, err = pcall(parser.load)
        if not ok then
            error("earth_nav_parser.load failed: " .. tostring(err))
        end
    end

    local guard = 0
    while not parser.ready and guard < 10000 do
        guard = guard + 1
        if type(parser.update) ~= "function" then
            break
        end

        local ok, err = pcall(parser.update)
        if not ok then
            error("earth_nav_parser.update failed: " .. tostring(err))
        end
    end

    return parser.ready == true
end

local function loadPage(pageKey)
    local pagePath = compiledDir .. "/" .. pageKey .. ".lua"
    local page = dofile(pagePath)
    if type(page) ~= "table" then
        error("Compiled page did not return a table: " .. tostring(pagePath))
    end
    return page
end

local function parseArgs(argv)
    local pageKey = argv[1] and trim(argv[1]) or "REF_NAV_DATA"
    local airportIdent = argv[2] and trim(argv[2]) or "KSEA"
    local runwayIdent = nil
    if argv[3] then
        local parsed = trim(argv[3])
        if parsed ~= "" then
            runwayIdent = parsed
        end
    end
    return pageKey, airportIdent, runwayIdent
end

local function buildContextValues(airportIdent, runwayIdent)
    return {
        airport_ident = airportIdent,
        runway_ident = runwayIdent,
    }
end

local function fieldValue(page, slot, airportIdent, runwayIdent, values)
    local field = page.fieldsBySlot and page.fieldsBySlot[slot]
    if not field then
        return ""
    end

    if field.fieldType == "input" then
        local current = values[field.identifier]
        return current ~= nil and tostring(current) or (field.placeholder or "")
    end

    if field.command == "none" then
        return ""
    end

    local ok, result = pcall(page.runCommand, slot, airportIdent, runwayIdent)
    if not ok then
        return "<err>"
    end

    if result == nil then
        return "<nil>"
    end

    return tostring(result)
end

local function renderRow(page, leftSlot, rightSlot, airportIdent, runwayIdent, values)
    local leftField = page.fieldsBySlot and page.fieldsBySlot[leftSlot]
    local rightField = page.fieldsBySlot and page.fieldsBySlot[rightSlot]

    local leftVisible = leftField and page.fieldVisible(leftSlot, values)
    local rightVisible = rightField and page.fieldVisible(rightSlot, values)

    local leftLabel = leftVisible and (leftField.label or "") or ""
    local rightLabel = rightVisible and (rightField.label or "") or ""

    local leftValue = leftVisible and fieldValue(page, leftSlot, airportIdent, runwayIdent, values) or ""
    local rightValue = rightVisible and fieldValue(page, rightSlot, airportIdent, runwayIdent, values) or ""

    local leftText = truncateText(leftSlot .. " " .. leftLabel .. " = " .. leftValue, 38)
    local rightText = truncateText(rightSlot .. " " .. rightLabel .. " = " .. rightValue, 38)

    return "| " .. leftText .. " | " .. rightText .. " |"
end

local function renderPage(page, airportIdent, runwayIdent)
    local values = buildContextValues(airportIdent, runwayIdent)
    local width = 83
    local border = "+" .. string.rep("-", width - 2) .. "+"

    print(border)
    print("|" .. centerText(page.title or page.pageKey or "PAGE", width - 2) .. "|")
    print(border)
    print(renderRow(page, "L1", "R1", airportIdent, runwayIdent, values))
    print(renderRow(page, "L2", "R2", airportIdent, runwayIdent, values))
    print(renderRow(page, "L3", "R3", airportIdent, runwayIdent, values))
    print(renderRow(page, "L4", "R4", airportIdent, runwayIdent, values))
    print(renderRow(page, "L5", "R5", airportIdent, runwayIdent, values))
    print(renderRow(page, "L6", "R6", airportIdent, runwayIdent, values))
    print(border)
    print("Context: airport_ident=" .. tostring(airportIdent) .. " runway_ident=" .. tostring(runwayIdent))
end

local function main(argv)
    local pageKey, airportIdent, runwayIdent = parseArgs(argv)

    local parser, parserGlobals = loadRealNavParser()
    if not ensureParserReady(parser) then
        restoreParserGlobals(parserGlobals)
        error("earth_nav_parser did not become ready: " .. table.concat(parserGlobals.logs or {}, " | "))
    end

    earth_nav_parser = parser
    custom_module = {
        parsers = {
            earth_nav = earth_nav_parser,
        },
    }

    local pagePath = compiledDir .. "/" .. pageKey .. ".lua"
    local page = loadPage(pageKey)
    renderPage(page, airportIdent, runwayIdent)

    restoreParserGlobals(parserGlobals)

    return pagePath
end

local ok, result = pcall(main, arg or {})
if not ok then
    io.stderr:write("RENDER FAILED: " .. tostring(result) .. "\n")
    os.exit(1)
end
