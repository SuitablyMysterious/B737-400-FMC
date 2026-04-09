-- render_page.lua
-- CLI scaffold renderer for compiled FMC pages.

local function dirname(path)
    local normalized = path:gsub("\\", "/")
    return normalized:match("^(.*)/[^/]+$") or "."
end

local scriptPath = debug.getinfo(1, "S").source:sub(2)
local scriptDir = dirname(scriptPath)
local compiledDir = scriptDir .. "/../pages_compiled"

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
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

local function makeMockNavParser()
    local airport = {
        ident = "KSEA",
        lat = 47.4489,
        lon = -122.3094,
        elev = 433,
        slaved_var = 15,
    }

    local runwayLoc = {
        ident = "16L",
        airport = "KSEA",
        runway = "16L",
        lat = 47.4439,
        lon = -122.3088,
        elev = 433,
        true_brg = 164,
        mag_front = 149,
        range = 18,
    }

    local mock = {}
    mock.ready = true

    function mock.load()
        mock.ready = true
    end

    function mock.update()
        mock.ready = true
    end

    function mock.getLOC(ident)
        if ident == runwayLoc.ident then
            return runwayLoc
        end
        return nil
    end

    function mock.findNavaid(ident)
        if ident == airport.ident then
            return airport
        end
        return nil
    end

    function mock.findAll(ident)
        if ident == airport.ident then
            return { airport, runwayLoc }
        end
        return {}
    end

    return mock
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
    local runwayIdent = argv[3] and trim(argv[3]) or "16L"
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

    earth_nav_parser = makeMockNavParser()
    custom_module = {
        parsers = {
            earth_nav = earth_nav_parser,
        },
    }

    local pagePath = compiledDir .. "/" .. pageKey .. ".lua"
    local page = loadPage(pageKey)
    renderPage(page, airportIdent, runwayIdent)

    return pagePath
end

local ok, result = pcall(main, arg or {})
if not ok then
    io.stderr:write("RENDER FAILED: " .. tostring(result) .. "\n")
    os.exit(1)
end
