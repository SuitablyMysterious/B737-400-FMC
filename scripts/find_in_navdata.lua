-- run with: lua - < "scripts/find_in_navdata.lua"
local eeprom = "/workspaces/B737-400-FMC/plugins/SASLFree/data/modules/Custom Module/EEPROM"
local examples = eeprom .. "/examples"
local xp = "/tmp/fmc_xplane_airports_cmd/"
local aircraft = "/tmp/fmc_aircraft_airports_cmd/"

os.execute('mkdir -p "' .. xp .. 'Custom Data" "' .. xp .. 'Resources/default data" "' .. aircraft .. 'EEPROM"')
os.execute('ln -sf "' .. examples .. '/earth_nav.dat" "' .. xp .. 'Custom Data/earth_nav.dat"')
os.execute('ln -sf "' .. examples .. '/earth_hold.dat" "' .. xp .. 'Custom Data/earth_hold.dat"')
os.execute('ln -sf "' .. examples .. '/earth_msa.dat" "' .. xp .. 'Custom Data/earth_msa.dat"')

_G.sasl = {
  getXPlanePath = function() return xp end,
  getAircraftPath = function() return aircraft end,
  getXPVersion = function() return 12000 end,
}
_G.logMsg = function() end

local airports = {}
local function add(k)
  if k and k ~= "" and k ~= "ENRT" then airports[k] = true end
end

local function loadParser(name)
  local ok, p = pcall(dofile, eeprom .. "/" .. name)
  if not ok or type(p) ~= "table" then return nil end
  if type(p.load) == "function" then pcall(p.load) end
  local guard = 0
  while p.ready ~= true and guard < 20000 do
    guard = guard + 1
    if type(p.update) == "function" then pcall(p.update) else break end
  end
  return p
end

for _, file in ipairs({"earth_hold_parser.lua", "earth_msa_parser.lua", "earth_apt_parser.lua"}) do
  local p = loadParser(file)
  if p and type(p.byAirport) == "table" then
    for icao in pairs(p.byAirport) do add(icao) end
  end
end

local nav = loadParser("earth_nav_parser.lua")
if nav and type(nav.loc) == "table" then
  for _, entries in pairs(nav.loc) do
    for _, loc in ipairs(entries) do add(loc.airport) end
  end
end

local out = {}
for icao in pairs(airports) do out[#out + 1] = icao end
table.sort(out)
for i = 1, #out do print(out[i]) end