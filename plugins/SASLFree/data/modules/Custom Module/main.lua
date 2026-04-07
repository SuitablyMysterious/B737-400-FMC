-- main.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

-- main table

local mainTable = {}

-- parser modules

local function safeRequire(moduleName, fallbackName)
	local ok, mod = pcall(require, moduleName)
	if ok then
		return mod
	end

	if fallbackName then
		local ok2, mod2 = pcall(require, fallbackName)
		if ok2 then
			return mod2
		end
		logMsg("CUSTOM MODULE: Failed to require " .. tostring(moduleName) .. " and " .. tostring(fallbackName) .. ": " .. tostring(mod2))
		return nil
	end

	logMsg("CUSTOM MODULE: Failed to require " .. tostring(moduleName) .. ": " .. tostring(mod))
	return nil
end

mainTable.parsers = {
	earth_nav = safeRequire("parser.earth_nav_parser", "earth_nav_parser"),
	earth_awy = safeRequire("parser.earth_awy_parser", "earth_awy_parser"),
	earth_hold = safeRequire("parser.earth_hold_parser", "earth_hold_parser"),
	earth_mora = safeRequire("parser.earth_mora_parser", "earth_mora_parser"),
	earth_msa = safeRequire("parser.earth_msa_parser", "earth_msa_parser"),
	medb = safeRequire("parser.medb_parser", "medb_parser"),
}

-- lifecycle state

mainTable.autoLoad = true
mainTable.initialized = false

function mainTable.loadAll()
	for name, parser in pairs(mainTable.parsers) do
		if parser and type(parser.load) == "function" then
			local ok, err = pcall(parser.load)
			if not ok then
				logMsg("CUSTOM MODULE: " .. tostring(name) .. " load failed: " .. tostring(err))
			end
		end
	end
end

function mainTable.updateAll()
	for name, parser in pairs(mainTable.parsers) do
		if parser and type(parser.update) == "function" then
			local ok, err = pcall(parser.update)
			if not ok then
				logMsg("CUSTOM MODULE: " .. tostring(name) .. " update failed: " .. tostring(err))
			end
		end
	end
end

function mainTable.allReady()
	for _, parser in pairs(mainTable.parsers) do
		if parser and parser.ready == false then
			return false
		end
	end
	return true
end

-- SASL update hook

function update()
	if not mainTable.initialized then
		mainTable.initialized = true
		if mainTable.autoLoad then
			mainTable.loadAll()
		end
	end

	mainTable.updateAll()
end

return mainTable
