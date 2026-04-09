-- example_page.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

--[[

Pages are layed out as followed:
/-----------------\
|      TITLE      |
|L1             R1|
|L2             R2|
|L3             R3|
|L4             R4|
|L5             R5|
|L6             R6|
\-----------------/

Each field is a string formatted as follows:

"#identifier#{title}[type](action)|dependant_on_to_show|*command*:placeholder:"

For example:
TITLE = "REF NAV DATA"
L1 = "#runway_ident#{RUNWAY IDENT}[input:runway](none)|airport_ident|*update*:-----:"
L2 = "#airport_ident#{AIRPORT IDENT}[input:ICAO](none)|none|*update*:----:"
L3 = "#latitude#{LATITUDE}[output](none)|airport_ident AND runway_ident|*find_latitude*::"
R3 = "#longitude#{LONGITUDE}[output](none)|airport_ident AND runway_ident|*find_longitude*::"
R4 = "#elevation#{ELEVATION}[output](none)|airport_ident AND runway_ident|*find_elevation*::"
R5 = "#runway_length#{LENGTH}[output](none)|airport_ident AND runway_ident|*find_runway_length*::"
L5 = "#magnetic_variation#{MAG VAR}[output](none)|airport_ident AND NOT runway_ident|*find_magnetic_variation*::"
L6 = "#nil#{nil}[link](nil)|none|*none*:<INDEX:"

local function get_nav_parser()
    if earth_nav_parser then
        return earth_nav_parser
    end
    if custom_module and custom_module.parsers then
        return custom_module.parsers.earth_nav
    end
    return nil
end

local function ensure_nav_ready(nav)
    if not nav then
        return false
    end

    if not nav.ready and type(nav.load) == "function" then
        nav.load()
    end

    if type(nav.update) == "function" then
        nav.update()
    end

    return nav.ready == true
end

local function find_localizer_for_airport(nav, airport_ident, runway_ident)
    if not nav or type(nav.loc) ~= "table" then
        return nil
    end

    local fallback = nil
    for _, entries in pairs(nav.loc) do
        for _, loc in ipairs(entries) do
            if loc.airport == airport_ident then
                if runway_ident and loc.runway == runway_ident then
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

    local nav = get_nav_parser()
    if not ensure_nav_ready(nav) then
        return nil
    end

    if airport_ident then
        local loc = find_localizer_for_airport(nav, airport_ident, runway_ident)
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

    local nav = get_nav_parser()
    if not ensure_nav_ready(nav) then
        return nil
    end

    if airport_ident then
        local loc = find_localizer_for_airport(nav, airport_ident, runway_ident)
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

    local nav = get_nav_parser()
    if not ensure_nav_ready(nav) then
        return nil
    end

    if airport_ident then
        local loc = find_localizer_for_airport(nav, airport_ident, runway_ident)
        if loc and loc.elev then
            return loc.elev
        end
    end

    local navaid = nav.findNavaid and nav.findNavaid(airport_ident)
    return navaid and navaid.elev or nil
end

local function normalize_variation(delta)
    local d = delta
    while d > 180 do
        d = d - 360
    end
    while d < -180 do
        d = d + 360
    end
    return d
end

local function find_magnetic_variation(airport_ident, runway_ident)
    if airport_ident == nil then
        return nil
    end

    local nav = get_nav_parser()
    if not ensure_nav_ready(nav) then
        return nil
    end

    local loc = find_localizer_for_airport(nav, airport_ident, runway_ident)
    if loc and loc.true_brg and loc.mag_front then
        return normalize_variation(loc.true_brg - loc.mag_front)
    end

    return nil
end



NOTE:

this system uses what I like to call a "reverse dependancy tree" and therefore requires compilation.
the "update" command needs to call a update of all things that depend on this

--]]
