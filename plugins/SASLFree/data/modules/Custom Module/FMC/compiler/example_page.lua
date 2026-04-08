-- page.lua

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
L6 = #null#{null}[link](null)|none|*none*:<INDEX:

local function find_latitude(airport_ident, runway_ident):
    if runway_ident and airport_ident == null do
        return null
    elseif runway_ident == null do    
        -- check nav database for airport elevation
    else do
        -- check nav database for airport and runway elevation
    end
end

-- do the same for lat, mag deviation and long

NOTE:

this system uses what I like to call a "reverse dependancy tree" and therefore requires compilation.
the "update" command needs to call a update of all things that depend on this

--]]
