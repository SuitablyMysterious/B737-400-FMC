TITLE = "REF NAV DATA"
L1 = "#runway_ident#{RUNWAY IDENT}[input:runway](none)|airport_ident|*update*:-----:"
L2 = "#airport_ident#{AIRPORT IDENT}[input:ICAO](none)|none|*update*:----:"
L3 = "#latitude#{LATITUDE}[output](none)|airport_ident AND runway_ident|*find_latitude*::"
R3 = "#longitude#{LONGITUDE}[output](none)|airport_ident AND runway_ident|*find_longitude*::"
R4 = "#elevation#{ELEVATION}[output](none)|airport_ident AND runway_ident|*find_elevation*::"
R5 = "#runway_length#{LENGTH}[output](none)|airport_ident AND runway_ident|*find_runway_length*::"
L5 = "#magnetic_variation#{MAG VAR}[output](none)|airport_ident AND NOT runway_ident|*find_magnetic_variation*::"
L6 = "#index#{INDEX}[link](none)|none|*none*:<INDEX:"

local function find_latitude(airport_ident, runway_ident)
    if runway_ident and airport_ident == nil then
        return nil
    end

    local nav = earth_nav_parser
    if (not nav) and custom_module and custom_module.parsers then
        nav = custom_module.parsers.earth_nav
    end
    if not nav then
        return nil
    end

    if not nav.ready and type(nav.load) == "function" then
        nav.load()
    end
    if type(nav.update) == "function" then
        nav.update()
    end
    if not nav.ready then
        return nil
    end

    if runway_ident and type(nav.getLOC) == "function" then
        local loc = nav.getLOC(runway_ident)
        if loc and loc.airport == airport_ident and loc.lat then
            return loc.lat
        end
    end

    if type(nav.findNavaid) == "function" and airport_ident then
        local navaid = nav.findNavaid(airport_ident)
        if navaid then
            return navaid.lat
        end
    end

    return nil
end

local function find_longitude(airport_ident, runway_ident)
    if runway_ident and airport_ident == nil then
        return nil
    end

    local nav = earth_nav_parser
    if (not nav) and custom_module and custom_module.parsers then
        nav = custom_module.parsers.earth_nav
    end
    if not nav then
        return nil
    end

    if not nav.ready and type(nav.load) == "function" then
        nav.load()
    end
    if type(nav.update) == "function" then
        nav.update()
    end
    if not nav.ready then
        return nil
    end

    if runway_ident and type(nav.getLOC) == "function" then
        local loc = nav.getLOC(runway_ident)
        if loc and loc.airport == airport_ident and loc.lon then
            return loc.lon
        end
    end

    if type(nav.findNavaid) == "function" and airport_ident then
        local navaid = nav.findNavaid(airport_ident)
        if navaid then
            return navaid.lon
        end
    end

    return nil
end

local function find_elevation(airport_ident, runway_ident)
    if runway_ident and airport_ident == nil then
        return nil
    end

    local nav = earth_nav_parser
    if (not nav) and custom_module and custom_module.parsers then
        nav = custom_module.parsers.earth_nav
    end
    if not nav then
        return nil
    end

    if not nav.ready and type(nav.load) == "function" then
        nav.load()
    end
    if type(nav.update) == "function" then
        nav.update()
    end
    if not nav.ready then
        return nil
    end

    if runway_ident and type(nav.getLOC) == "function" then
        local loc = nav.getLOC(runway_ident)
        if loc and loc.airport == airport_ident and loc.elev then
            return loc.elev
        end
    end

    if type(nav.findNavaid) == "function" and airport_ident then
        local navaid = nav.findNavaid(airport_ident)
        if navaid then
            return navaid.elev
        end
    end

    return nil
end

local function find_runway_length(airport_ident, runway_ident)
    if airport_ident == nil or runway_ident == nil then
        return nil
    end

    local nav = earth_nav_parser
    if (not nav) and custom_module and custom_module.parsers then
        nav = custom_module.parsers.earth_nav
    end
    if not nav then
        return nil
    end

    if not nav.ready and type(nav.load) == "function" then
        nav.load()
    end
    if type(nav.update) == "function" then
        nav.update()
    end
    if not nav.ready then
        return nil
    end

    if type(nav.getLOC) == "function" then
        local loc = nav.getLOC(runway_ident)
        if loc and loc.airport == airport_ident and loc.range then
            -- earth_nav_parser has localizer range, not physical runway length.
            return nil
        end
    end

    return nil
end

local function find_magnetic_variation(airport_ident)
    if airport_ident == nil then
        return nil
    end

    local nav = earth_nav_parser
    if (not nav) and custom_module and custom_module.parsers then
        nav = custom_module.parsers.earth_nav
    end
    if not nav then
        return nil
    end

    if not nav.ready and type(nav.load) == "function" then
        nav.load()
    end
    if type(nav.update) == "function" then
        nav.update()
    end
    if not nav.ready then
        return nil
    end

    if type(nav.findAll) == "function" then
        local entries = nav.findAll(airport_ident)
        if entries then
            for _, e in ipairs(entries) do
                if e.mag_front and e.true_brg then
                    local d = e.true_brg - e.mag_front
                    while d > 180 do d = d - 360 end
                    while d < -180 do d = d + 360 end
                    return d
                end
            end
        end
    end

    return nil
end
