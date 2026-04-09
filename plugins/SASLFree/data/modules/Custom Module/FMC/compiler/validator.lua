-- validator.lua
-- Normalization and validation helpers for FMC page values.

local validator = {}

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function toNumber(v)
	if type(v) == "number" then
		return v
	end
	local s = trim(v)
	if s == "" then
		return nil
	end
	return tonumber(s)
end

local function formatDms(value, posChar, negChar, degWidth)
	local absVal = math.abs(value)
	local deg = math.floor(absVal)
	local min = (absVal - deg) * 60

	-- Carry if 59.95+ rounds to 60.0.
	local minRounded = tonumber(string.format("%.1f", min))
	if minRounded >= 60.0 then
		deg = deg + 1
		minRounded = 0.0
	end

	local hemi = (value < 0) and negChar or posChar
	local degFmt = "%0" .. tostring(degWidth) .. "d"
	return string.format("%s" .. degFmt .. "° %04.1f", hemi, deg, minRounded)
end

local function normalizeRunway(raw)
	local s = trim(raw):upper()
	if s == "" then
		return nil, false
	end

	local core = s
	if core:sub(1, 2) == "RW" then
		core = core:sub(3)
	end

	if not core:match("^%d%d[CLR]?$") then
		return nil, false
	end

	return "RW" .. core, true
end

local function normalizeAirportIcao(raw)
	local s = trim(raw):upper()
	if s:match("^[A-Z][A-Z0-9][A-Z0-9][A-Z0-9]$") then
		return s, true
	end
	return nil, false
end

local function normalizeLatitude(raw)
	local n = toNumber(raw)
	if not n then
		return nil, false
	end
	if n < -90 or n > 90 then
		return nil, false
	end
	return formatDms(n, "N", "S", 2), true
end

local function normalizeLongitude(raw)
	local n = toNumber(raw)
	if not n then
		return nil, false
	end
	if n < -180 or n > 180 then
		return nil, false
	end
	return formatDms(n, "E", "W", 3), true
end

local function normalizeElevation(raw)
	local n = toNumber(raw)
	if not n then
		return nil, false
	end
	return string.format("%dft", math.floor(n + 0.5)), true
end

local function normalizeRunwayLength(raw)
	local n = toNumber(raw)
	if not n or n < 0 then
		return nil, false
	end
	return string.format("%dft", math.floor(n + 0.5)), true
end

local function normalizeMagVar(raw)
	local n = toNumber(raw)
	if not n then
		return nil, false
	end

	local hemi = (n < 0) and "W" or "E"
	local mag = math.floor(math.abs(n) + 0.5)
	return string.format("%s %d°", hemi, mag), true
end

local IDENT_NORMALIZERS = {
	runway_ident = normalizeRunway,
	airport_ident = normalizeAirportIcao,
	latitude = normalizeLatitude,
	longitude = normalizeLongitude,
	elevation = normalizeElevation,
	runway_length = normalizeRunwayLength,
	magnetic_variation = normalizeMagVar,
}

function validator.normalize(field, value)
	if value == nil then
		return nil
	end
	if type(field) ~= "table" then
		return value
	end

	local normalizer = IDENT_NORMALIZERS[field.identifier]
	if not normalizer then
		return value
	end

	local normalized, ok = normalizer(value)
	if ok then
		return normalized
	end

	return value
end

function validator.validate(field, value)
	if type(field) ~= "table" then
		return true
	end

	local normalizer = IDENT_NORMALIZERS[field.identifier]
	if not normalizer then
		return true
	end

	local _, ok = normalizer(value)
	return ok
end

return validator