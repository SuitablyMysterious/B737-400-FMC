-- parser smoke_test.lua
-- Quick integration smoke tests for parser modules and main loader wiring.

local module_root = ...
if not module_root or module_root == "" then
    module_root = debug.getinfo(1, "S").source:sub(2)
    module_root = module_root:gsub("/parser/tests/smoke_test.lua$", "")
end

local parser_examples = module_root .. "/parser/examples"

local function exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

local function mkdir_p(path)
    os.execute('mkdir -p "' .. path .. '"')
end

local function cp(src, dst)
    os.execute('cp "' .. src .. '" "' .. dst .. '"')
end

local function dirname(path)
    return path:match("^(.*)/[^/]+$")
end

local function assertf(cond, fmt, ...)
    if not cond then
        error(string.format(fmt, ...), 2)
    end
end

local tmp_root = os.tmpname():gsub("^@", "")
os.remove(tmp_root)
mkdir_p(tmp_root)

local xp_root = tmp_root .. "/xplane/"
local acf_root = tmp_root .. "/aircraft/"

mkdir_p(xp_root .. "Resources/default data")
mkdir_p(acf_root .. "EEPROM")

-- Provide fallback copies where parsers look for default navdata.
cp(parser_examples .. "/earth_nav.dat", xp_root .. "Resources/default data/earth_nav.dat")
cp(parser_examples .. "/earth_awy.dat", xp_root .. "Resources/default data/earth_awy.dat")
cp(parser_examples .. "/earth_hold.dat", xp_root .. "Resources/default data/earth_hold.dat")
cp(parser_examples .. "/earth_mora.dat", xp_root .. "Resources/default data/earth_mora.dat")
cp(parser_examples .. "/earth_msa.dat", xp_root .. "Resources/default data/earth_msa.dat")

assertf(exists(xp_root .. "Resources/default data/earth_nav.dat"), "Failed to stage earth_nav.dat")
assertf(exists(xp_root .. "Resources/default data/earth_awy.dat"), "Failed to stage earth_awy.dat")
assertf(exists(xp_root .. "Resources/default data/earth_hold.dat"), "Failed to stage earth_hold.dat")
assertf(exists(xp_root .. "Resources/default data/earth_mora.dat"), "Failed to stage earth_mora.dat")
assertf(exists(xp_root .. "Resources/default data/earth_msa.dat"), "Failed to stage earth_msa.dat")

_G.logMsg = function(msg)
    io.stdout:write("[log] " .. tostring(msg) .. "\n")
end

_G.sasl = {
    getXPlanePath = function() return xp_root end,
    getAircraftPath = function() return acf_root end,
    getXPVersion = function() return 12000 end,
}

-- Let require("parser.<name>") work exactly as runtime wiring does.
package.path = module_root .. "/?.lua;" .. module_root .. "/?/?.lua;" .. package.path

local function run_until_ready(parser, name)
    parser.load()
    local guard = 0
    while not parser.ready and guard < 20000 do
        parser.update()
        guard = guard + 1
    end
    assertf(parser.ready, "%s did not finish loading", name)
end

local function reset_parser_state(parser)
    parser.ready = false
    parser.loading = false
    parser.linesRead = 0

    if parser.totalRows ~= nil then
        parser.totalRows = 0
    end
    if parser.totalNavaids ~= nil then
        parser.totalNavaids = 0
    end

    if parser.rows then parser.rows = {} end
    if parser.ndb then parser.ndb = {} end
    if parser.vor then parser.vor = {} end
    if parser.loc then parser.loc = {} end
    if parser.gs then parser.gs = {} end
    if parser.markers then parser.markers = {} end
    if parser.dme then parser.dme = {} end
    if parser.fpap then parser.fpap = {} end
    if parser.ltp then parser.ltp = {} end
    if parser.gls then parser.gls = {} end
    if parser.byAirway then parser.byAirway = {} end
    if parser.byFrom then parser.byFrom = {} end
    if parser.byTo then parser.byTo = {} end
    if parser.byIdent then parser.byIdent = {} end
    if parser.byAirport then parser.byAirport = {} end
    if parser.grid then parser.grid = {} end
end

local function assert_cache_hit_load(parser, name, count_field, custom_count_fn)
    reset_parser_state(parser)
    parser.load()

    -- Cache hit path should complete load immediately without coroutine updates.
    assertf(parser.ready == true, "%s cache-hit load did not complete immediately", name)
    assertf(parser.loading == false, "%s cache-hit load left parser in loading state", name)

    local count = 0
    if type(custom_count_fn) == "function" then
        count = custom_count_fn(parser) or 0
    else
        count = parser[count_field] or 0
    end
    assertf(count > 0, "%s cache-hit load produced zero count in %s", name, tostring(count_field))
end

local nav = require("parser.earth_nav_parser")
run_until_ready(nav, "earth_nav_parser")
assertf(nav.totalNavaids > 0, "earth_nav_parser produced zero navaids")
assertf(nav.countTable(nav.ndb) > 0, "earth_nav_parser produced zero NDB rows")

local awy = require("parser.earth_awy_parser")
run_until_ready(awy, "earth_awy_parser")
assertf(awy.totalRows > 0, "earth_awy_parser produced zero rows")
assertf(awy.rows[1] and awy.getAirway(awy.rows[1].airway), "earth_awy_parser airway index lookup failed")

local hold = require("parser.earth_hold_parser")
run_until_ready(hold, "earth_hold_parser")
assertf(hold.totalRows > 0, "earth_hold_parser produced zero rows")
assertf(hold.rows[1] and hold.findHold(hold.rows[1].ident), "earth_hold_parser hold lookup failed")

local mora = require("parser.earth_mora_parser")
run_until_ready(mora, "earth_mora_parser")
assertf(mora.totalRows > 0, "earth_mora_parser produced zero rows")
assertf(mora.rows[1], "earth_mora_parser missing first row")
assertf(type(mora.getRow(mora.rows[1].lat_band, mora.rows[1].lon_band)) == "table", "earth_mora_parser row lookup failed")

local msa = require("parser.earth_msa_parser")
run_until_ready(msa, "earth_msa_parser")
assertf(msa.totalRows > 0, "earth_msa_parser produced zero rows")
assertf(msa.rows[1] and msa.findMSA(msa.rows[1].ident), "earth_msa_parser MSA lookup failed")

local main_module = require("main")

-- Force a fresh bootstrap pass.
main_module.initialized = false
main_module.autoLoad = true

local guard = 0
while not main_module.allReady() and guard < 20000 do
    update()
    guard = guard + 1
end
assertf(main_module.allReady(), "main.lua bootstrap did not reach allReady()")

-- Verify cache files were created by first pass.
assertf(exists(acf_root .. "EEPROM/earth_nav.ndb"), "earth_nav.ndb was not created")
assertf(exists(acf_root .. "EEPROM/earth_awy.ndb"), "earth_awy.ndb was not created")
assertf(exists(acf_root .. "EEPROM/earth_hold.ndb"), "earth_hold.ndb was not created")
assertf(exists(acf_root .. "EEPROM/earth_mora.ndb"), "earth_mora.ndb was not created")
assertf(exists(acf_root .. "EEPROM/earth_msa.ndb"), "earth_msa.ndb was not created")

-- Export generated cache files to a stable workspace folder.
local output_dir = module_root .. "/parser/tests/output"
mkdir_p(output_dir)

local generated_files = {
    "earth_nav.ndb",
    "earth_awy.ndb",
    "earth_hold.ndb",
    "earth_mora.ndb",
    "earth_msa.ndb",
}

for _, fname in ipairs(generated_files) do
    local src = acf_root .. "EEPROM/" .. fname
    local dst = output_dir .. "/" .. fname
    cp(src, dst)
    assertf(exists(dst), "Failed to export %s to output directory", fname)
    io.stdout:write("[output] " .. dst .. "\n")
end

-- Second pass: verify each parser uses cache-hit path successfully.
assert_cache_hit_load(nav, "earth_nav_parser", "ndb", function(p)
    return p.countTable(p.ndb)
end)
assert_cache_hit_load(awy, "earth_awy_parser", "totalRows")
assert_cache_hit_load(hold, "earth_hold_parser", "totalRows")
assert_cache_hit_load(mora, "earth_mora_parser", "totalRows")
assert_cache_hit_load(msa, "earth_msa_parser", "totalRows")

io.stdout:write("\n[PASS] Parser smoke tests passed for nav/awy/hold/mora/msa + main bootstrap + cache-hit reload\n")
