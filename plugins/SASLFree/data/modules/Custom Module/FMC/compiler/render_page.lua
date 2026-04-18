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

local validator = nil
do
    local ok, mod = pcall(dofile, scriptDir .. "/validator.lua")
    if ok and type(mod) == "table" then
        validator = mod
    end
end

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
    local sampleAptdata = repoRoot .. "/plugins/SASLFree/data/modules/Custom Module/EEPROM/examples/apt.dat"
    local tempRoot = os.getenv("TMPDIR") or "/tmp"
    local defaultAircraftPath = ensureTrailingSlash(env("AIRCRAFT_PATH")) or (tempRoot .. "/fmc_aircraft_render/")
    os.execute('mkdir -p "' .. defaultAircraftPath .. 'EEPROM"')

    local function linkIfExists(src, dst)
        if src and src ~= "" and pathExists(src) then
            os.execute('ln -sf "' .. src .. '" "' .. dst .. '"')
            return true
        end
        return false
    end

    -- Seed the active aircraft EEPROM with the project's raw NDB cache when
    -- available. This lets the nav parser hit cache fast on first render run.
    local bundledNdbCache = repoRoot .. "/plugins/SASLFree/data/modules/Custom Module/FMC/EEPROM/earth_nav.ndb"
    local activeNdbCache = defaultAircraftPath .. "EEPROM/earth_nav.ndb"
    if not pathExists(activeNdbCache) then
        linkIfExists(bundledNdbCache, activeNdbCache)
    end

    local explicitNavdata = env("NAVDATA_FILE")
    local explicitAptdata = env("APTDATA_FILE")
    if explicitNavdata and pathExists(explicitNavdata) then
        local shimRoot = tempRoot .. "/fmc_navshim_explicit"
        os.execute('mkdir -p "' .. shimRoot .. '/Custom Data"')
        os.execute('mkdir -p "' .. shimRoot .. '/Resources/default data"')
        os.execute('mkdir -p "' .. shimRoot .. '/Resources/default scenery/default apt dat/Earth nav data"')
        linkIfExists(explicitNavdata, shimRoot .. '/Custom Data/earth_nav.dat')
        if not linkIfExists(explicitAptdata, shimRoot .. '/Resources/default scenery/default apt dat/Earth nav data/apt.dat') then
            linkIfExists(sampleAptdata, shimRoot .. '/Resources/default scenery/default apt dat/Earth nav data/apt.dat')
        end
        return shimRoot .. "/", defaultAircraftPath, tonumber(env("XP_VERSION")) or 12000
    end

    local xplanePath = env("XPLANE_PATH") or env("XPLANE_ROOT")
    if xplanePath and xplanePath ~= "" then
        return xplanePath, defaultAircraftPath, tonumber(env("XP_VERSION")) or 12000
    end

    if repoRoot ~= "" then
        local shimRoot = tempRoot .. "/fmc_navshim"
            os.execute('mkdir -p "' .. shimRoot .. '/Custom Data"')
            os.execute('mkdir -p "' .. shimRoot .. '/Resources/default data"')
            os.execute('mkdir -p "' .. shimRoot .. '/Resources/default scenery/default apt dat/Earth nav data"')
            linkIfExists(sampleNavdata, shimRoot .. '/Custom Data/earth_nav.dat')
            linkIfExists(sampleAptdata, shimRoot .. '/Resources/default scenery/default apt dat/Earth nav data/apt.dat')
        return shimRoot .. "/", defaultAircraftPath, tonumber(env("XP_VERSION")) or 12000
    end

    return nil, nil, nil
end

local function loadRealParsers()
    local xplanePath, aircraftPath, xpVersion = resolveNavdataPaths()
    if not xplanePath then
        error("No X-Plane navdata source found. Set XPLANE_PATH or NAVDATA_FILE.")
    end


    local previousSasl = rawget(_G, "sasl")
    local previousLogMsg = rawget(_G, "logMsg")
    local previousEarthNav = rawget(_G, "earth_nav_parser")
    local previousEarthApt = rawget(_G, "earth_apt_parser")
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

    local navParserPath = scriptDir .. "/../../EEPROM/earth_nav_parser.lua"
    local okNav, navParser = pcall(dofile, navParserPath)

    if not okNav then
        rawset(_G, "sasl", previousSasl)
        rawset(_G, "logMsg", previousLogMsg)
        rawset(_G, "earth_nav_parser", previousEarthNav)
        rawset(_G, "earth_apt_parser", previousEarthApt)
        error("Failed to load real earth_nav_parser: " .. tostring(navParser))
    end

    local aptParserPath = scriptDir .. "/../../EEPROM/earth_apt_parser.lua"
    local okApt, aptParser = pcall(dofile, aptParserPath)

    if not okApt then
        rawset(_G, "sasl", previousSasl)
        rawset(_G, "logMsg", previousLogMsg)
        rawset(_G, "earth_nav_parser", previousEarthNav)
        rawset(_G, "earth_apt_parser", previousEarthApt)
        error("Failed to load real earth_apt_parser: " .. tostring(aptParser))
    end

    return {
        earth_nav = navParser,
        earth_apt = aptParser,
    }, {
        sasl = previousSasl,
        logMsg = previousLogMsg,
        earth_nav_parser = previousEarthNav,
        earth_apt_parser = previousEarthApt,
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
            error(tostring(parserName or "parser") .. ".load failed: " .. tostring(err))
        end
    end

    -- Drive parser.update until the parser reports ready. By default we wait
    -- indefinitely (the CLI caller can set PARSER_UPDATE_LIMIT in the environment
    -- to bound the number of update iterations). This mirrors an interactive
    -- FMC: block until the authoritative data is available.
    local limit = tonumber(os.getenv("PARSER_UPDATE_LIMIT") or "-1")
    local iter = 0
    while not parser.ready do
        iter = iter + 1
        if type(parser.update) ~= "function" then
            break
        end

        local ok, err = pcall(parser.update)
        if not ok then
            error(tostring(parserName or "parser") .. ".update failed: " .. tostring(err))
        end

        -- Log progress infrequently so the user sees we're working on large files
        if (iter % 250) == 0 then
            io.stderr:write(string.format("Waiting for %s to become ready (iter=%d, linesRead=%s)\n", tostring(parserName), iter, tostring(parser.linesRead or "N/A")))
        end

        if limit >= 0 and iter >= limit then
            error(tostring(parserName or "parser") .. ": update loop exceeded PARSER_UPDATE_LIMIT=" .. tostring(limit))
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
    -- Parse CLI into a pageKey and an ordered list of actions.
    -- Supported actions (CLI syntax):
    --   type:TEXT    => replace scratchpad with TEXT
    --   append:TEXT  => append TEXT to scratchpad
    --   key:CHAR     => append single CHAR to scratchpad
    --   press:SLOT   => press CDU SLOT (L1..L6, R1..R6, ENT, CLR, DEL)
    -- Backwards compatible shorthand: pageKey ICAO RWY will be converted to
    -- equivalent type/press actions (ICAO -> L2, RWY -> L1) for REF_NAV_DATA-like pages.
    local function isActionToken(token)
        return token:match("^type:") or token:match("^append:") or token:match("^key:") or token:match("^press:")
    end

    local pageKey = "REF_NAV_DATA"
    local interactive = false
    local actions = {}
    local simpleArgs = {}
    local startAt = 1

    if argv[1] then
        local first = tostring(argv[1])
        if first ~= "" and not isActionToken(first) and first ~= "-i" and first ~= "--interactive" and first ~= "interactive" then
            pageKey = trim(first)
            startAt = 2
        end
    end

    for i = startAt, #argv do
        local a = tostring(argv[i])
        if a == "-i" or a == "--interactive" or a == "interactive" then
            interactive = true
        elseif isActionToken(a) then
            actions[#actions + 1] = a
        else
            simpleArgs[#simpleArgs + 1] = trim(a)
        end
    end

    -- Convert old-style plain args into type/press actions for convenience
    if #simpleArgs == 2 then
        local maybeIcao, maybeRwy = simpleArgs[1]:upper(), simpleArgs[2]:upper()
        if maybeIcao:match("^[A-Z][A-Z0-9][A-Z0-9][A-Z0-9]$") then
            actions[#actions + 1] = "type:" .. maybeIcao
            actions[#actions + 1] = "press:L2"
        end
        if maybeRwy ~= "" then
            actions[#actions + 1] = "type:" .. maybeRwy
            actions[#actions + 1] = "press:L1"
        end
    elseif #simpleArgs == 1 then
        local only = simpleArgs[1]
        local upp = only:upper()
        if upp:match("^[A-Z][A-Z0-9][A-Z0-9][A-Z0-9]$") then
            actions[#actions + 1] = "type:" .. upp
            actions[#actions + 1] = "press:L2"
        else
            actions[#actions + 1] = "type:" .. only
            actions[#actions + 1] = "press:L1"
        end
    end

    return pageKey, actions, interactive
end

local function buildContextValues()
    -- start with empty values; actions will populate this table
    return {}
end

local function fieldValue(page, slot, values, context)
    local field = page.fieldsBySlot and page.fieldsBySlot[slot]
    if not field then
        return ""
    end

    if field.fieldType == "input" then
        local current = values[field.identifier]
        return current ~= nil and tostring(current) or (field.placeholder or "")
    end

    if field.fieldType == "link" then
        return field.placeholder or ""
    end

    if field.command == "none" then
        return ""
    end

    -- Pass canonical context values to the compiled page command functions.
    -- Most pages expect airport_ident and runway_ident as the two positional args.
    local ok, result = pcall(page.runCommand, slot, values and values["airport_ident"], values and values["runway_ident"])
    if not ok then
        return "<err>"
    end

    if result == nil then
        return "<nil>"
    end

    return tostring(result)
end

local function renderRowPair(page, leftSlot, rightSlot, values, context)
    local leftField = page.fieldsBySlot and page.fieldsBySlot[leftSlot]
    local rightField = page.fieldsBySlot and page.fieldsBySlot[rightSlot]

    local leftVisible = leftField and page.fieldVisible(leftSlot, values)
    local rightVisible = rightField and page.fieldVisible(rightSlot, values)

    local leftValue = leftVisible and fieldValue(page, leftSlot, values, context) or ""
    local rightValue = rightVisible and fieldValue(page, rightSlot, values, context) or ""

    local leftIsLink = leftField and leftField.fieldType == "link"
    local rightIsLink = rightField and rightField.fieldType == "link"

    local leftTitle = (leftVisible and (not leftIsLink)) and (leftField.label or "") or ""
    local rightTitle = (rightVisible and (not rightIsLink)) and (rightField.label or "") or ""

    local titleLine = "| " .. truncateText(leftTitle, 38) .. " | " .. truncateText(rightTitle, 38) .. " |"
    local valueLine = "| " .. truncateText(leftValue, 38) .. " | " .. truncateText(rightValue, 38) .. " |"

    return titleLine, valueLine
end

local function renderPage(page, values, context)
    local width = 83
    local border = "+" .. string.rep("-", width - 2) .. "+"

    print(border)
    print("|" .. centerText(page.title or page.pageKey or "PAGE", width - 2) .. "|")
    print(border)
    -- Show scratchpad state just under the title to emulate an FMC scratchpad
    local spText = "SCRATCHPAD: " .. (context and tostring(context.scratchpad or "") or "")
    print("| " .. truncateText(spText, width - 4) .. string.rep(" ", 2) .. "|")
    local msgText = "MESSAGE: " .. (context and tostring(context.message or "") or "")
    print("| " .. truncateText(msgText, width - 4) .. string.rep(" ", 2) .. "|")
    print(border)
    local t1, v1 = renderRowPair(page, "L1", "R1", values, context)
    local t2, v2 = renderRowPair(page, "L2", "R2", values, context)
    local t3, v3 = renderRowPair(page, "L3", "R3", values, context)
    local t4, v4 = renderRowPair(page, "L4", "R4", values, context)
    local t5, v5 = renderRowPair(page, "L5", "R5", values, context)
    local t6, v6 = renderRowPair(page, "L6", "R6", values, context)
    print(t1)
    print(v1)
    print(t2)
    print(v2)
    print(t3)
    print(v3)
    print(t4)
    print(v4)
    print(t5)
    print(v5)
    print(t6)
    print(v6)
    print(border)
    local contextParts = (function()
        local out = {}
        local keys = {}
        for k in pairs(values or {}) do
            keys[#keys + 1] = k
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            out[#out + 1] = k .. "=" .. tostring(values[k])
        end
        return out
    end)()
    print("Context: " .. (#contextParts > 0 and table.concat(contextParts, ", ") or "<empty>"))
end

local function main(argv)
    local pageKey, actions, interactive = parseArgs(argv)

    local parsers, parserGlobals = loadRealParsers()
    if not ensureParserReady(parsers.earth_nav, "earth_nav_parser") then
        restoreParserGlobals(parserGlobals)
        error("earth_nav_parser did not become ready: " .. table.concat(parserGlobals.logs or {}, " | "))
    end

    ensureParserReady(parsers.earth_apt, "earth_apt_parser")

    earth_nav_parser = parsers.earth_nav
    earth_apt_parser = parsers.earth_apt
    custom_module = {
        parsers = {
            earth_nav = earth_nav_parser,
            earth_apt = earth_apt_parser,
        },
    }

    local pagePath = compiledDir .. "/" .. pageKey .. ".lua"
    local page = loadPage(pageKey)

    -- Prepare values (page-local field storage) and scratchpad context
    local values = buildContextValues()
    local context = { scratchpad = "", message = "" }
    local SCRATCHPAD_MAX_LEN = 24

    local function setScratchpad(text)
        local v = tostring(text or "")
        if #v > SCRATCHPAD_MAX_LEN then
            v = v:sub(1, SCRATCHPAD_MAX_LEN)
        end
        context.scratchpad = v
    end

    local function normalizeInputForStorage(field, rawValue)
        local value = tostring(rawValue or "")

        if validator and type(validator.validate) == "function" then
            local ok, isValid = pcall(validator.validate, field, value)
            if ok and not isValid then
                return nil, "INVALID ENTRY"
            end
        end

        if validator and type(validator.normalize) == "function" then
            local ok, normalized = pcall(validator.normalize, field, value)
            if ok and normalized ~= nil then
                value = tostring(normalized)
            end
        end

        if field and field.identifier == "runway_ident" then
            value = value:gsub("^RW", "")
        end

        return value, nil
    end

    -- local helpers
    local function pressSlot(slot)
        if not slot or slot == "" then return end
        slot = (slot or ""):upper()
        -- Handle special scratchpad keys
        if slot == "CLR" then
            if context.scratchpad == "" then
                setScratchpad("DELETE")
            else
                setScratchpad("")
            end
            context.message = ""
            return
        end
        if slot == "DEL" then
            setScratchpad(context.scratchpad:sub(1, -2))
            context.message = ""
            return
        end
        if slot == "ENT" then
            context.message = ""
            return
        end

        -- If the slot matches a field on the page
        local field = page.fieldsBySlot and page.fieldsBySlot[slot]
        if field then
            if field.fieldType == "input" then
                -- Transfer scratchpad into the input field
                local entry = trim(context.scratchpad)
                if entry == "" or entry == "DELETE" then
                    values[field.identifier] = nil
                    setScratchpad("")
                    context.message = ""
                    return
                end

                local normalized, err = normalizeInputForStorage(field, entry)
                if err then
                    context.message = err
                    return
                end

                values[field.identifier] = normalized
                setScratchpad("")
                context.message = ""
                return
            else
                -- For non-input slots execute the compiled command for that slot.
                -- page.runCommand expects (slot, airportIdent, runwayIdent) in compiled form.
                -- We forward current canonical values (airport_ident/runway_ident) from values.
                local ok, res = pcall(page.runCommand, slot, values["airport_ident"], values["runway_ident"])
                if not ok then
                    io.stderr:write("Error running command for " .. tostring(slot) .. ": " .. tostring(res) .. "\n")
                    context.message = "EXEC ERROR"
                else
                    context.message = ""
                end
                return
            end
        end

        -- Unknown slot: no-op
        context.message = "UNKNOWN KEY"
    end

    local function applyAction(a)
        local typ, payload = a:match("^(%w+):(.*)$")
        if typ == "type" then
            setScratchpad(payload or "")
            context.message = ""
        elseif typ == "append" then
            setScratchpad((context.scratchpad or "") .. (payload or ""))
            context.message = ""
        elseif typ == "key" then
            local keyPayload = payload or ""
            local upper = keyPayload:upper()
            if upper == "SP" or upper == "SPACE" then
                keyPayload = " "
            end
            setScratchpad((context.scratchpad or "") .. keyPayload)
            context.message = ""
        elseif typ == "press" then
            pressSlot(payload)
        else
            context.message = "UNKNOWN ACTION"
        end
    end

    local function parseInteractiveLine(line)
        local raw = trim(line or "")
        if raw == "" then
            return nil
        end

        local upper = raw:upper()
        if upper == "Q" or upper == "QUIT" or upper == "EXIT" then
            return "quit"
        end
        if upper == "?" or upper == "HELP" then
            return "help"
        end
        if upper == "SHOW" then
            return "show"
        end
        if upper == "CLR" or upper == "DEL" or upper == "ENT" or upper:match("^[LR][1-6]$") then
            return "press:" .. upper
        end

        local cmd, payload = raw:match("^(%S+)%s+(.+)$")
        if cmd then
            local c = cmd:lower()
            if c == "type" or c == "append" or c == "key" or c == "press" then
                return c .. ":" .. payload
            end
        end

        if #raw == 1 then
            return "key:" .. raw
        end

        return "type:" .. raw
    end

    local function runInteractiveLoop()
        print("INTERACTIVE FMC MODE")
        print("Commands: type TEXT | append TEXT | key X | press L1..R6/CLR/DEL | show | help | quit")
        while true do
            io.write("FMC> ")
            local line = io.read("*l")
            if not line then
                break
            end

            local parsed = parseInteractiveLine(line)
            if parsed == "quit" then
                break
            elseif parsed == "help" then
                print("Shortcuts: L1..R6, CLR, DEL, single-char input, free text means TYPE")
            elseif parsed == "show" then
                -- no state change
            elseif parsed then
                applyAction(parsed)
            end

            renderPage(page, values, context)
        end
    end

    -- Apply scripted actions
    for _, a in ipairs(actions or {}) do
        applyAction(a)
    end

    renderPage(page, values, context)

    if interactive then
        runInteractiveLoop()
    end

    restoreParserGlobals(parserGlobals)

    return pagePath
end

local ok, result = pcall(main, arg or {})
if not ok then
    io.stderr:write("RENDER FAILED: " .. tostring(result) .. "\n")
    os.exit(1)
end
