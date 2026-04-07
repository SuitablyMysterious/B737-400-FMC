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

## `medb_parser.lua`:

Loads takeoff/landing speed table data from `aircraft_dir/EEPROM/<profile>.medb`, where `<profile>` is selected from livery `eng_type` in `livery.fcconfig` read via `sim/aircraft/view/acf_livery_path`.

Supported MEDB profiles:

- `2B2.medb`
- `3C1.medb`

If no livery config value can be resolved, parser falls back to `3C1.medb`.

## integration:

All parser modules above are loaded/updated via `Custom Module/main.lua` using `require("parser.<module>")`, `loadAll()`, and `updateAll()`.