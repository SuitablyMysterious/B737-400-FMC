-- earth_awy_parser.lua

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

"{title}[type](action):placeholder:"

For example:

L1 = "{RUNWAY IDENT}[input](none):-----:"
L2 = "{AIRPORT IDENT}[input:ICAO]:----:"



--]]
