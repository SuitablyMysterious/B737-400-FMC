## `earth_nav_parser.md`:

Parses `earth_nav.dat` into readable/parsable formats stored on the EEPROM memory card (which is located at `aircraft_dir/EEPROM/`).

## `earth_awy_parser.lua`:

Parses `earth_awy.dat` airway segments into indexed lookup tables (`rows`, `byAirway`, `byFrom`, `byTo`).

## `earth_hold_parser.lua`:

Parses `earth_hold.dat` hold entries into indexed lookup tables (`rows`, `byIdent`, `byAirport`).

## `earth_mora_parser.lua`:

Parses `earth_mora.dat` grid rows into both sequential rows and lat/lon-band indexed cells (`rows`, `grid`).

## `earth_msa_parser.lua`:

Parses `earth_msa.dat` MSA records and sector triplets into indexed lookup tables (`rows`, `byAirport`, `byIdent`).

## integration:

All parser modules above are loaded/updated via `Custom Module/main.lua` using `require("parser.<module>")`, `loadAll()`, and `updateAll()`.