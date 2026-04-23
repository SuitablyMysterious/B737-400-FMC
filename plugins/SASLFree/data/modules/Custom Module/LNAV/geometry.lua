-- geometry.lua

local geometry = {}

local EARTH_RADIUS_NM = 3440.065
local DEG_TO_RAD = math.pi / 180
local RAD_TO_DEG = 180 / math.pi
local KNOT_TO_MPS = 0.514444
local METERS_PER_NM = 1852
local STANDARD_GRAVITY_MPS2 = 9.80665

local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function atan2(y, x)
    if math.atan2 then
        return math.atan2(y, x)
    end

    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 and y >= 0 then
        return math.atan(y / x) + math.pi
    elseif x < 0 and y < 0 then
        return math.atan(y / x) - math.pi
    elseif x == 0 and y > 0 then
        return math.pi / 2
    elseif x == 0 and y < 0 then
        return -math.pi / 2
    end

    return 0
end

local function toRad(deg)
    return deg * DEG_TO_RAD
end

local function toDeg(rad)
    return rad * RAD_TO_DEG
end

function geometry.clamp(v, minV, maxV)
    if not isFiniteNumber(v) then
        return nil
    end
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

function geometry.wrap360(deg)
    if not isFiniteNumber(deg) then
        return nil
    end
    local wrapped = deg % 360
    if wrapped < 0 then
        wrapped = wrapped + 360
    end
    return wrapped
end

function geometry.wrap180(deg)
    if not isFiniteNumber(deg) then
        return nil
    end
    local wrapped = ((deg + 180) % 360) - 180
    return wrapped
end

function geometry.angleDiffDeg(a, b)
    if not isFiniteNumber(a) or not isFiniteNumber(b) then
        return nil
    end
    return geometry.wrap180(a - b)
end

function geometry.absAngleDiffDeg(a, b)
    local d = geometry.angleDiffDeg(a, b)
    if d == nil then
        return nil
    end
    return math.abs(d)
end

function geometry.distanceRad(lat1Deg, lon1Deg, lat2Deg, lon2Deg)
    if not isFiniteNumber(lat1Deg) or not isFiniteNumber(lon1Deg)
        or not isFiniteNumber(lat2Deg) or not isFiniteNumber(lon2Deg) then
        return nil
    end

    local lat1 = toRad(lat1Deg)
    local lon1 = toRad(lon1Deg)
    local lat2 = toRad(lat2Deg)
    local lon2 = toRad(lon2Deg)

    local dLat = lat2 - lat1
    local dLon = lon2 - lon1

    local sinHalfDLat = math.sin(dLat * 0.5)
    local sinHalfDLon = math.sin(dLon * 0.5)

    local a = sinHalfDLat * sinHalfDLat
        + math.cos(lat1) * math.cos(lat2) * sinHalfDLon * sinHalfDLon

    a = geometry.clamp(a, 0, 1)
    if not a then
        return nil
    end

    local c = 2 * atan2(math.sqrt(a), math.sqrt(1 - a))
    return c
end

function geometry.distanceNm(lat1Deg, lon1Deg, lat2Deg, lon2Deg)
    local c = geometry.distanceRad(lat1Deg, lon1Deg, lat2Deg, lon2Deg)
    if c == nil then
        return nil
    end
    return c * EARTH_RADIUS_NM
end

function geometry.initialBearingDeg(lat1Deg, lon1Deg, lat2Deg, lon2Deg)
    if not isFiniteNumber(lat1Deg) or not isFiniteNumber(lon1Deg)
        or not isFiniteNumber(lat2Deg) or not isFiniteNumber(lon2Deg) then
        return nil
    end

    if math.abs(lat1Deg - lat2Deg) < 1e-12 and math.abs(lon1Deg - lon2Deg) < 1e-12 then
        return 0
    end

    local lat1 = toRad(lat1Deg)
    local lon1 = toRad(lon1Deg)
    local lat2 = toRad(lat2Deg)
    local lon2 = toRad(lon2Deg)

    local dLon = lon2 - lon1
    local y = math.sin(dLon) * math.cos(lat2)
    local x = math.cos(lat1) * math.sin(lat2)
        - math.sin(lat1) * math.cos(lat2) * math.cos(dLon)

    local bearing = toDeg(atan2(y, x))
    return geometry.wrap360(bearing)
end

function geometry.crossTrackErrorNm(curLatDeg, curLonDeg, fromLatDeg, fromLonDeg, toLatDeg, toLonDeg)
    local d13 = geometry.distanceRad(fromLatDeg, fromLonDeg, curLatDeg, curLonDeg)
    local brg13 = geometry.initialBearingDeg(fromLatDeg, fromLonDeg, curLatDeg, curLonDeg)
    local brg12 = geometry.initialBearingDeg(fromLatDeg, fromLonDeg, toLatDeg, toLonDeg)

    if d13 == nil or brg13 == nil or brg12 == nil then
        return nil
    end

    local theta13 = toRad(brg13)
    local theta12 = toRad(brg12)
    local sinXtk = math.sin(d13) * math.sin(theta13 - theta12)
    sinXtk = geometry.clamp(sinXtk, -1, 1)
    if sinXtk == nil then
        return nil
    end

    local xtkRad = math.asin(sinXtk)
    return -xtkRad * EARTH_RADIUS_NM
end

function geometry.alongTrackDistanceNm(curLatDeg, curLonDeg, fromLatDeg, fromLonDeg, toLatDeg, toLonDeg)
    local d13 = geometry.distanceRad(fromLatDeg, fromLonDeg, curLatDeg, curLonDeg)
    local brg13 = geometry.initialBearingDeg(fromLatDeg, fromLonDeg, curLatDeg, curLonDeg)
    local brg12 = geometry.initialBearingDeg(fromLatDeg, fromLonDeg, toLatDeg, toLonDeg)

    if d13 == nil or brg13 == nil or brg12 == nil then
        return nil
    end

    local theta13 = toRad(brg13)
    local theta12 = toRad(brg12)
    local atRad = atan2(math.sin(d13) * math.cos(theta13 - theta12), math.cos(d13))
    return atRad * EARTH_RADIUS_NM
end

function geometry.turnAngleDeg(inboundTrackDeg, outboundTrackDeg)
    local delta = geometry.angleDiffDeg(outboundTrackDeg, inboundTrackDeg)
    if delta == nil then
        return nil
    end
    return math.abs(delta)
end

function geometry.turnRadiusNm(groundSpeedKt, bankAngleDeg)
    if not isFiniteNumber(groundSpeedKt) then
        return nil
    end

    local gs = math.max(0, groundSpeedKt)
    if gs <= 0 then
        return 0
    end

    local bank = bankAngleDeg
    if not isFiniteNumber(bank) then
        bank = 25
    end

    local tanBank = math.tan(toRad(bank))
    if not isFiniteNumber(tanBank) or math.abs(tanBank) < 1e-8 then
        return 0
    end

    local speedMps = gs * KNOT_TO_MPS
    local radiusMeters = (speedMps * speedMps) / (STANDARD_GRAVITY_MPS2 * tanBank)
    if not isFiniteNumber(radiusMeters) or radiusMeters < 0 then
        return 0
    end

    return radiusMeters / METERS_PER_NM
end

function geometry.leadDistanceNm(turnRadiusNm, turnAngleDeg)
    if not isFiniteNumber(turnRadiusNm) or turnRadiusNm <= 0 then
        return 0
    end

    local turnAngle = math.abs(turnAngleDeg or 0)
    if turnAngle < 1e-6 then
        return 0
    end

    if turnAngle > 170 then
        turnAngle = 170
    end

    local lead = turnRadiusNm * math.tan(toRad(turnAngle) * 0.5)
    if not isFiniteNumber(lead) or lead < 0 then
        return 0
    end
    return lead
end

function geometry.isFiniteNumber(v)
    return isFiniteNumber(v)
end

return geometry
