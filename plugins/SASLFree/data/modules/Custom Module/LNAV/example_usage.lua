-- example_usage.lua

local function dirname(path)
    local normalized = (path or ""):gsub("\\", "/")
    return normalized:match("^(.*)/[^/]+$") or "."
end

local scriptPath = debug.getinfo(1, "S").source:sub(2)
if scriptPath:sub(1, 1) ~= "/" and io.popen then
    local p = io.popen("pwd")
    if p then
        local cwd = p:read("*l")
        p:close()
        if cwd and cwd ~= "" then
            scriptPath = cwd .. "/" .. scriptPath
        end
    end
end

local scriptDir = dirname(scriptPath)
local lnav = dofile(scriptDir .. "/lnav_core.lua")

local flightPlan = {
    { ident = "KSEA", lat = 47.4489, lon = -122.3094, type = "TF" },
    { ident = "OLM", lat = 46.9694, lon = -122.9033, type = "TF" },
    { ident = "BTG", lat = 45.7475, lon = -122.5989, type = "TF" },
}

lnav.setFlightPlan(flightPlan)
lnav.setPosition(47.20, -122.55)
lnav.setMotion(190.0, 240.0)
lnav.update(1 / 60)

local guidance = lnav.getGuidance()

return {
    lnav = lnav,
    guidance = guidance,
}
