TITLE = "REF NAV DATA"
L1 = "#runway_ident#{RUNWAY IDENT}[input:runway](none)|airport_ident|*update*:-----:"
L2 = "#airport_ident#{AIRPORT IDENT}[input:ICAO](none)|none|*update*:----:"
L3 = "#latitude#{LATITUDE}[output](none)|airport_ident AND runway_ident OR airport_ident|*find_latitude*::"
R3 = "#longitude#{LONGITUDE}[output](none)|airport_ident AND runway_ident OR airport_ident|*find_longitude*::"
R4 = "#elevation#{ELEVATION}[output](none)|airport_ident AND runway_ident OR airport_ident|*find_elevation*::"
R5 = "#runway_length#{LENGTH}[output](none)|airport_ident AND runway_ident|*find_runway_length*::"
L5 = "#magnetic_variation#{MAG VAR}[output](none)|airport_ident AND NOT runway_ident|*find_magnetic_variation*::"
L6 = "#index#{INDEX}[link](none)|none|*none*:<INDEX:"

local function a_get_nav_parser()
    if earth_nav_parser then
        return earth_nav_parser
    end
    if custom_module and custom_module.parsers then
        return custom_module.parsers.earth_nav
    end
    return nil
end

local function a_get_apt_parser()
    if earth_apt_parser then
        return earth_apt_parser
    end
    if custom_module and custom_module.parsers then
        return custom_module.parsers.earth_apt
    end
    return nil
end

local function a_ensure_parser_ready(parser)
    if not parser then
        return false
    end

    if not parser.ready and type(parser.load) == "function" then
        parser.load()
    end

    if type(parser.update) == "function" then
        parser.update()
    end

    return parser.ready == true
end

local function a_find_runway_end(apt, airport_ident, runway_ident)
    if not apt or not airport_ident or not runway_ident then
        return nil
    end

    local function normalizeRunway(raw)
        local s = (tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")):upper()
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

    local airport = (tostring(airport_ident or ""):gsub("^%s+", ""):gsub("%s+$", "")):upper()
    local runway = normalizeRunway(runway_ident)
    if airport == "" or not runway then
        return nil
    end

    if type(apt.findRunwayEnd) == "function" then
        return apt.findRunwayEnd(airport, runway)
    end

    local byAirportRunway = apt.byAirportRunway
    if type(byAirportRunway) == "table" then
        local list = byAirportRunway[airport .. "|" .. runway]
        if list and #list > 0 then
            return list[1]
        end
    end

    return nil
end

local function a_find_localizer_for_airport(nav, airport_ident, runway_ident)
    if not nav or type(nav.loc) ~= "table" then
        return nil
    end

    local function normalizeRunway(raw)
        local s = (tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")):upper()
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

    local requestedRunway = normalizeRunway(runway_ident)

    local fallback = nil
    for _, entries in pairs(nav.loc) do
        for _, loc in ipairs(entries) do
            if loc.airport == airport_ident then
                if requestedRunway and normalizeRunway(loc.runway) == requestedRunway then
                    return loc
                end
                if not fallback then
                    fallback = loc
                end
            end
        end
    end

    return fallback
end

local function find_latitude(airport_ident, runway_ident)
    if runway_ident and airport_ident == nil then
        return nil
    end

    local apt = a_get_apt_parser()
    if a_ensure_parser_ready(apt) and airport_ident and runway_ident then
        local runway = a_find_runway_end(apt, airport_ident, runway_ident)
        if runway and runway.lat then
            return runway.lat
        end
    end

    local nav = a_get_nav_parser()
    if not a_ensure_parser_ready(nav) then
        return nil
    end

    if airport_ident then
        local loc = a_find_localizer_for_airport(nav, airport_ident, runway_ident)
        if loc and loc.lat then
            return loc.lat
        end
    end

    local navaid = nav.findNavaid and nav.findNavaid(airport_ident)
    return navaid and navaid.lat or nil
end

local function find_longitude(airport_ident, runway_ident)
    if runway_ident and airport_ident == nil then
        return nil
    end

    local apt = a_get_apt_parser()
    if a_ensure_parser_ready(apt) and airport_ident and runway_ident then
        local runway = a_find_runway_end(apt, airport_ident, runway_ident)
        if runway and runway.lon then
            return runway.lon
        end
    end

    local nav = a_get_nav_parser()
    if not a_ensure_parser_ready(nav) then
        return nil
    end

    if airport_ident then
        local loc = a_find_localizer_for_airport(nav, airport_ident, runway_ident)
        if loc and loc.lon then
            return loc.lon
        end
    end

    local navaid = nav.findNavaid and nav.findNavaid(airport_ident)
    return navaid and navaid.lon or nil
end

local function find_elevation(airport_ident, runway_ident)
    if runway_ident and airport_ident == nil then
        return nil
    end

    local apt = a_get_apt_parser()
    if a_ensure_parser_ready(apt) and airport_ident and runway_ident then
        local runway = a_find_runway_end(apt, airport_ident, runway_ident)
        if runway and runway.elev then
            return runway.elev
        end
    end

    local nav = a_get_nav_parser()
    if not a_ensure_parser_ready(nav) then
        return nil
    end

    if airport_ident then
        local loc = a_find_localizer_for_airport(nav, airport_ident, runway_ident)
        if loc and loc.elev then
            return loc.elev
        end
    end

    local navaid = nav.findNavaid and nav.findNavaid(airport_ident)
    return navaid and navaid.elev or nil
end

local function find_runway_length(airport_ident, runway_ident)
    if airport_ident == nil or runway_ident == nil then
        return nil
    end

    local apt = a_get_apt_parser()
    if not a_ensure_parser_ready(apt) then
        return nil
    end

    local runway = a_find_runway_end(apt, airport_ident, runway_ident)
    if runway and runway.length_m then
        return runway.length_m * 3.28084
    end

    return nil
end

local function find_magnetic_variation(airport_ident)
    if airport_ident == nil then
        return nil
    end

    local nav = a_get_nav_parser()
    if not a_ensure_parser_ready(nav) then
        return nil
    end

    local loc = a_find_localizer_for_airport(nav, airport_ident, nil)
    if loc and loc.mag_front and loc.true_brg then
        local d = loc.true_brg - loc.mag_front
        while d > 180 do d = d - 360 end
        while d < -180 do d = d + 360 end
        return d
    end

    return nil
end
