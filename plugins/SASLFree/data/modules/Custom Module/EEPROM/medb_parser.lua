-- medb_parser.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

local aircraft_path = sasl.getAircraftPath()

local mainTable = {}

mainTable.ready = false
mainTable.loading = false
mainTable.profile = nil
mainTable.fcconfigPath = nil
mainTable.medbPath = nil
mainTable.data = nil
mainTable.sections = {}
mainTable.speeds = {} -- speeds[weight][flap] = { v1=, vr=, v2=, vref= }
mainTable.weights = {}
mainTable.meta = {}

local simDR_livery_path = nil
pcall(function()
    simDR_livery_path = globalPropertys("sim/aircraft/view/acf_livery_path")
end)

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fileExists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

local function toNumber(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return nil end
    return tonumber(v)
end

local function normalizeEngineTag(raw)
    local v = trim(raw):upper()
    if v == "" then return nil end

    v = v:gsub("CFM56%-", "")

    if v == "2B2" or v == "3B2" then return "2B2" end
    if v == "3C1" then return "3C1" end

    return nil
end

local function getLiveryPath()
    if not simDR_livery_path or type(get) ~= "function" then
        return nil
    end

    local ok, value = pcall(get, simDR_livery_path)
    if not ok or type(value) ~= "string" or value == "" then
        return nil
    end

    return value
end

local function parseFcconfig(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local engType = nil

    for line in f:lines() do
        local clean = trim((line or ""):gsub("#.*$", ""):gsub(";.*$", ""))
        if clean ~= "" then
            local key, value = clean:match("^([%w_%.%-]+)%s*=%s*(.-)%s*$")
            if key and value and key:lower() == "eng_type" then
                local v = trim((value or ""):gsub("%b()", ""))
                if v:find("/") then
                    logMsg("MEDB PARSER: eng_type in fcconfig is ambiguous (contains '/'): " .. tostring(v))
                else
                    engType = normalizeEngineTag(v)
                    if not engType then
                        logMsg("MEDB PARSER: Unsupported eng_type in fcconfig: " .. tostring(v))
                    end
                end
                break
            end
        end
    end

    f:close()
    return engType
end

local function resolveProfileFromLivery()
    local liveryPath = getLiveryPath()
    if not liveryPath or liveryPath == "" then
        return nil, nil
    end

    local configPath = liveryPath .. "livery.fcconfig"
    local profile = parseFcconfig(configPath)
    return profile, configPath
end

local function addSpeedRow(target, weight, flap, v1, vr, v2, vref)
    local w = toNumber(weight)
    local f = toNumber(flap)
    if not w or not f then return false end

    local iv1 = toNumber(v1)
    local ivr = toNumber(vr)
    local iv2 = toNumber(v2)
    local ivref = toNumber(vref)
    if not iv1 or not iv2 or not ivref then return false end

    if not target[w] then
        target[w] = {}
    end

    target[w][f] = {
        v1 = iv1,
        vr = ivr,
        v2 = iv2,
        vref = ivref,
    }

    return true
end

local function sortedWeights(tbl)
    local weights = {}
    for w, _ in pairs(tbl) do
        weights[#weights + 1] = w
    end
    table.sort(weights)
    return weights
end

local function firstTable(...)
    local candidates = { ... }
    for i = 1, #candidates do
        if type(candidates[i]) == "table" then
            return candidates[i]
        end
    end
    return nil
end

local function getNested(root, ...)
    local node = root
    local keys = { ... }
    for i = 1, #keys do
        if type(node) ~= "table" then
            return nil
        end
        node = node[keys[i]]
    end
    return node
end

local function parseMedbTable(data)
    if type(data) ~= "table" then
        return nil, "MEDB root must be a table"
    end

    local performance = firstTable(data.performance, data.performance_data, data.performanceData)
    local takeoff = firstTable(data.takeoff, getNested(performance, "takeoff")) or {}
    local climb = firstTable(data.climb, getNested(performance, "climb"))
    local cruise = firstTable(data.cruise, getNested(performance, "cruise"))
    local descent = firstTable(data.descent, getNested(performance, "descent"))
    local fuel = firstTable(data.fuel, getNested(performance, "fuel"))
    local altitudeCapability = firstTable(
        data.altitude_capability,
        data.altitudeCapability,
        getNested(performance, "altitude_capability"),
        getNested(performance, "altitudeCapability")
    )

    local out = {}
    local meta = {
        profile = data.profile,
        engine = data.engine,
        thrust_lb = data.thrust_lb,
        mtow_kg = data.mtow_kg,
        mlw_kg = data.mlw_kg,
        units = data.units,
        vref40_diff = firstTable(takeoff.vref40_diff, data.vref40_diff, getNested(performance, "vref40_diff")),
    }
    local loaded = 0

    local takeoffSpeeds = firstTable(
        takeoff.speeds,
        takeoff.rows,
        data.speeds,
        data.rows,
        getNested(performance, "takeoff", "speeds"),
        getNested(performance, "takeoff", "rows")
    )

    if type(takeoffSpeeds) == "table" then
        for weight, flapTable in pairs(takeoffSpeeds) do
            if type(flapTable) == "table" then
                for flap, spd in pairs(flapTable) do
                    if type(spd) == "table" and addSpeedRow(out, weight, flap, spd.v1, spd.vr, spd.v2, spd.vref) then
                        loaded = loaded + 1
                    end
                end
            end
        end
    elseif type(data.rows) == "table" then
        for _, row in ipairs(data.rows) do
            if type(row) == "table" and type(row.flaps) == "table" then
                for flap, spd in pairs(row.flaps) do
                    if type(spd) == "table" and addSpeedRow(out, row.weight, flap, spd.v1, spd.vr, spd.v2, spd.vref) then
                        loaded = loaded + 1
                    end
                end
            end
        end
    end

    if loaded == 0 then
        return nil, "No speed rows found in MEDB"
    end

    return out, meta, {
        takeoff = takeoff,
        climb = climb,
        cruise = cruise,
        descent = descent,
        fuel = fuel,
        altitude_capability = altitudeCapability,
        performance = performance,
    }, data, nil
end

local function loadMedb(path)
    local chunk, loadErr = loadfile(path, "t", {})
    if not chunk then
        return nil, "Cannot load MEDB: " .. tostring(loadErr)
    end

    local ok, result = pcall(chunk)
    if not ok then
        return nil, "MEDB execution failed: " .. tostring(result)
    end

    local parsed, meta, sections, rawData, parseErr = parseMedbTable(result)
    if not parsed then
        return nil, parseErr
    end

    return parsed, meta, sections, rawData, nil
end

local function lerp(a, b, t)
    return a + ((b - a) * t)
end

local function findBoundingWeights(weights, targetWeight, flap)
    local low, high = nil, nil

    for i = 1, #weights do
        local w = weights[i]
        if mainTable.speeds[w] and mainTable.speeds[w][flap] then
            if w <= targetWeight then
                low = w
            end
            if w >= targetWeight then
                high = w
                break
            end
        end
    end

    return low, high
end

function mainTable.load()
    if mainTable.loading or mainTable.ready then return end

    mainTable.loading = true
    mainTable.ready = false
    mainTable.speeds = {}
    mainTable.weights = {}
    mainTable.profile = nil
    mainTable.fcconfigPath = nil
    mainTable.medbPath = nil
    mainTable.data = nil
    mainTable.sections = {}
    mainTable.meta = {}

    local profile, fcconfigPath = resolveProfileFromLivery()
    if not profile then
        profile = "3C1"
        logMsg("MEDB PARSER: Falling back to default profile 3C1")
    end

    local medbPath = aircraft_path .. "EEPROM/" .. profile .. ".medb"
    if not fileExists(medbPath) then
        mainTable.loading = false
        logMsg("MEDB PARSER: Missing MEDB file: " .. tostring(medbPath))
        return
    end

    local parsed, meta, sections, rawData, err = loadMedb(medbPath)
    if not parsed then
        mainTable.loading = false
        logMsg("MEDB PARSER: " .. tostring(err))
        return
    end

    mainTable.profile = profile
    mainTable.fcconfigPath = fcconfigPath
    mainTable.medbPath = medbPath
    mainTable.data = rawData
    mainTable.speeds = parsed
    mainTable.weights = sortedWeights(parsed)
    mainTable.meta = meta or {}
    mainTable.sections = sections or {}
    mainTable.ready = true
    mainTable.loading = false

    logMsg(string.format("MEDB PARSER: Loaded %s (%d weights)", profile, #mainTable.weights))
end

function mainTable.update()
    -- no-op; synchronous parser
end

function mainTable.reload()
    mainTable.ready = false
    mainTable.loading = false
    mainTable.load()
end

function mainTable.getExact(weight, flap)
    local w = toNumber(weight)
    local f = toNumber(flap)
    if not w or not f then return nil end

    local row = mainTable.speeds[w]
    if not row then return nil end
    return row[f]
end

function mainTable.getInterpolated(weight, flap)
    local w = toNumber(weight)
    local f = toNumber(flap)
    if not w or not f then return nil end

    local exact = mainTable.getExact(w, f)
    if exact then return exact, "exact" end

    local low, high = findBoundingWeights(mainTable.weights, w, f)
    if not low and not high then return nil end
    if low and not high then return mainTable.speeds[low][f], "clamped_low" end
    if high and not low then return mainTable.speeds[high][f], "clamped_high" end
    if low == high then return mainTable.speeds[low][f], "exact" end

    local lo = mainTable.speeds[low][f]
    local hi = mainTable.speeds[high][f]
    if not lo or not hi then return nil end

    local t = (w - low) / (high - low)
    return {
        v1 = lerp(lo.v1, hi.v1, t),
        vr = (lo.vr and hi.vr) and lerp(lo.vr, hi.vr, t) or nil,
        v2 = lerp(lo.v2, hi.v2, t),
        vref = lerp(lo.vref, hi.vref, t),
    }, "interpolated"
end

function mainTable.get(weight, flap, interpolate)
    if interpolate == false then
        return mainTable.getExact(weight, flap), "exact"
    end
    return mainTable.getInterpolated(weight, flap)
end

function mainTable.getProfiles()
    return { "2B2", "3C1" }
end

function mainTable.getSection(name)
    if type(name) ~= "string" then return nil end
    return mainTable.sections[name]
end

function mainTable.getTakeoffData()
    return mainTable.sections.takeoff
end

function mainTable.getClimbData()
    return mainTable.sections.climb
end

function mainTable.getCruiseData()
    return mainTable.sections.cruise
end

function mainTable.getDescentData()
    return mainTable.sections.descent
end

function mainTable.getFuelData()
    return mainTable.sections.fuel
end

function mainTable.getAltitudeCapabilityData()
    return mainTable.sections.altitude_capability
end

function mainTable.getVref40(weight, flap, useInterpolation)
    local speeds
    if useInterpolation == false then
        speeds = mainTable.getExact(weight, flap)
    else
        speeds = mainTable.getInterpolated(weight, flap)
    end

    if not speeds or not speeds.vref then
        return nil
    end

    local diffCfg = (mainTable.meta and mainTable.meta.vref40_diff) or nil
    if type(diffCfg) ~= "table" then
        return nil
    end

    local w = toNumber(weight)
    if not w then return nil end

    local diff
    if w < 50000 then
        diff = toNumber(diffCfg.below_50t)
    else
        diff = toNumber(diffCfg.above_50t)
    end

    if not diff then
        return nil
    end

    return speeds.vref - diff
end

return mainTable