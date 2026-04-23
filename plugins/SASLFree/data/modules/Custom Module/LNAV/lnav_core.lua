-- lnav_core.lua

local function dirname(path)
    local normalized = (path or ""):gsub("\\", "/")
    return normalized:match("^(.*)/[^/]+$") or "."
end

local function resolveScriptPath()
    local source = debug.getinfo(1, "S").source
    local path = source and source:sub(2) or "lnav_core.lua"

    if path:sub(1, 1) ~= "/" and io.popen then
        local p = io.popen("pwd")
        if p then
            local cwd = p:read("*l")
            p:close()
            if cwd and cwd ~= "" then
                path = cwd .. "/" .. path
            end
        end
    end

    return path
end

local function loadGeometryModule()
    local scriptDir = dirname(resolveScriptPath())
    local geomPath = scriptDir .. "/geometry.lua"
    local ok, mod = pcall(dofile, geomPath)
    if not ok then
        error("LNAV CORE: Failed to load geometry.lua: " .. tostring(mod))
    end
    if type(mod) ~= "table" then
        error("LNAV CORE: geometry.lua must return a table")
    end
    return mod
end

local geometry = loadGeometryModule()

local lnav = {
    state = "OFF",
    active_leg = 1,
    flightplan = {},
}

lnav._plans = {
    sid = nil,
    enroute = {},
    star = nil,
}

lnav._position = {
    lat = nil,
    lon = nil,
}

lnav._motion = {
    track_deg = nil,
    ground_speed_kt = nil,
}

lnav._config = {
    intercept_gain = 8.0,
    max_intercept_angle_deg = 30.0,
    activation_xtk_nm = 2.5,
    activation_track_diff_deg = 90.0,
    default_bank_angle_deg = 25.0,
    fallback_sequence_nm = 1.0,
    flyover_sequence_nm = 0.2,
    max_lead_distance_nm = 10.0,
    max_sequence_per_update = 4,
    parser_update_limit = 25000,
}

lnav._guidance = {
    desired_track_deg = nil,
    commanded_track_deg = nil,
    cross_track_error_nm = nil,
    distance_to_waypoint_nm = nil,
    active_waypoint_ident = nil,
    next_waypoint_ident = nil,
    active_waypoint_segment = nil,
    next_waypoint_segment = nil,
    active_procedure_name = nil,
    lnav_state = "OFF",
}

local function isFinite(v)
    return geometry.isFiniteNumber(v)
end

local function copyGuidance(g)
    return {
        desired_track_deg = g.desired_track_deg,
        commanded_track_deg = g.commanded_track_deg,
        cross_track_error_nm = g.cross_track_error_nm,
        distance_to_waypoint_nm = g.distance_to_waypoint_nm,
        active_waypoint_ident = g.active_waypoint_ident,
        next_waypoint_ident = g.next_waypoint_ident,
        active_waypoint_segment = g.active_waypoint_segment,
        next_waypoint_segment = g.next_waypoint_segment,
        active_procedure_name = g.active_procedure_name,
        lnav_state = g.lnav_state,
    }
end

local SEGMENT_SID = "SID"
local SEGMENT_ENROUTE = "ENROUTE"
local SEGMENT_STAR = "STAR"

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function safeLog(message)
    local logger = rawget(_G, "logMsg")
    if type(logger) == "function" then
        pcall(logger, tostring(message))
    end
end

local function normalizeSegment(segment, fallback)
    local s = trim(segment):upper()
    if s == SEGMENT_SID or s == SEGMENT_ENROUTE or s == SEGMENT_STAR then
        return s
    end

    local f = trim(fallback):upper()
    if f == SEGMENT_SID or f == SEGMENT_ENROUTE or f == SEGMENT_STAR then
        return f
    end

    return SEGMENT_ENROUTE
end

local function normalizeProcedureName(name)
    local n = trim(name)
    if n == "" then
        return nil
    end
    return n:upper()
end

local function getParsers()
    local nav = rawget(_G, "earth_nav_parser")
    local apt = rawget(_G, "earth_apt_parser")
    local moduleRoot = rawget(_G, "custom_module")

    if type(moduleRoot) == "table" and type(moduleRoot.parsers) == "table" then
        if nav == nil then
            nav = moduleRoot.parsers.earth_nav
        end
        if apt == nil then
            apt = moduleRoot.parsers.earth_apt
        end
    end

    return nav, apt
end

local function ensureParserReady(parser, parserName)
    if type(parser) ~= "table" then
        return false
    end

    if parser.ready == true then
        return true
    end

    if type(parser.load) == "function" then
        local ok, err = pcall(parser.load)
        if not ok then
            safeLog("LNAV CORE: " .. tostring(parserName) .. ".load failed: " .. tostring(err))
            return false
        end
    end

    local updateLimit = tonumber(lnav._config.parser_update_limit) or 0
    local iter = 0
    while parser.ready ~= true and type(parser.update) == "function" do
        iter = iter + 1

        local ok, err = pcall(parser.update)
        if not ok then
            safeLog("LNAV CORE: " .. tostring(parserName) .. ".update failed: " .. tostring(err))
            return false
        end

        if parser.ready == true then
            break
        end

        if parser.loading == false then
            break
        end

        if updateLimit > 0 and iter >= updateLimit then
            safeLog("LNAV CORE: " .. tostring(parserName) .. " update limit reached")
            return false
        end
    end

    return parser.ready == true
end

local function navaidPriority(entry)
    local t = tonumber(entry and entry.type)
    if t == 3 then
        return 1
    elseif t == 2 then
        return 2
    elseif t == 4 or t == 5 then
        return 3
    elseif t == 12 or t == 13 then
        return 4
    end
    return 9
end

local function distanceScoreSq(refLat, refLon, lat, lon)
    if not isFinite(refLat) or not isFinite(refLon) or not isFinite(lat) or not isFinite(lon) then
        return math.huge
    end
    local dlat = refLat - lat
    local dlon = refLon - lon
    return dlat * dlat + dlon * dlon
end

local function chooseBestNavaid(candidates, refWp)
    if type(candidates) ~= "table" or #candidates == 0 then
        return nil
    end

    local refLat = refWp and refWp.lat or nil
    local refLon = refWp and refWp.lon or nil

    if isFinite(refLat) and isFinite(refLon) then
        local best = nil
        local bestDist = math.huge
        for _, e in ipairs(candidates) do
            local d = distanceScoreSq(refLat, refLon, e and e.lat, e and e.lon)
            if d < bestDist then
                bestDist = d
                best = e
            end
        end
        if best and bestDist < math.huge then
            return best
        end
    end

    local best = nil
    local bestPri = math.huge
    for _, e in ipairs(candidates) do
        if isFinite(e and e.lat) and isFinite(e and e.lon) then
            local pri = navaidPriority(e)
            if pri < bestPri then
                bestPri = pri
                best = e
            end
        end
    end

    return best
end

local function chooseBestAirportRunway(rows, refWp)
    if type(rows) ~= "table" or #rows == 0 then
        return nil
    end

    local refLat = refWp and refWp.lat or nil
    local refLon = refWp and refWp.lon or nil

    if not isFinite(refLat) or not isFinite(refLon) then
        return rows[1]
    end

    local best = nil
    local bestDist = math.huge
    for _, row in ipairs(rows) do
        local d = distanceScoreSq(refLat, refLon, row and row.lat, row and row.lon)
        if d < bestDist then
            bestDist = d
            best = row
        end
    end

    return best
end

local function sanitizeWaypoint(rawWp, index, defaultSegment, defaultProcedureName)
    if type(rawWp) ~= "table" then
        return nil
    end

    if not isFinite(rawWp.lat) or not isFinite(rawWp.lon) then
        return nil
    end

    local wpType = rawWp.type or "TF"
    if wpType ~= "TF" then
        return nil
    end

    local ident = rawWp.ident
    if ident == nil then
        ident = "WP" .. tostring(index)
    else
        ident = tostring(ident)
    end

    local segment = normalizeSegment(rawWp.segment or rawWp._segment, defaultSegment)
    local procedureName = normalizeProcedureName(rawWp.procedure_name or rawWp._procedure_name or defaultProcedureName)

    return {
        ident = ident,
        lat = rawWp.lat,
        lon = rawWp.lon,
        type = "TF",
        fly_over = rawWp.fly_over == true,
        segment = segment,
        procedure_name = procedureName,
    }
end

local function resolveIdentWaypoint(identRaw, refWp, defaultSegment, defaultProcedureName)
    local ident = trim(identRaw):upper()
    if ident == "" then
        return nil
    end

    local nav, apt = getParsers()
    local selected = nil

    if nav and ensureParserReady(nav, "earth_nav_parser") then
        if type(nav.findAll) == "function" then
            local ok, candidates = pcall(nav.findAll, ident)
            if ok and type(candidates) == "table" and #candidates > 0 then
                selected = chooseBestNavaid(candidates, refWp)
            end
        end

        if not selected and type(nav.findNavaid) == "function" then
            local refLat = refWp and refWp.lat or nil
            local refLon = refWp and refWp.lon or nil
            local ok, candidate = pcall(nav.findNavaid, ident, refLat, refLon)
            if ok and type(candidate) == "table" then
                selected = candidate
            end
        end
    end

    if type(selected) == "table" and isFinite(selected.lat) and isFinite(selected.lon) then
        return {
            ident = ident,
            lat = selected.lat,
            lon = selected.lon,
            type = "TF",
            fly_over = false,
            segment = normalizeSegment(defaultSegment, SEGMENT_ENROUTE),
            procedure_name = normalizeProcedureName(defaultProcedureName),
        }
    end

    if apt and ensureParserReady(apt, "earth_apt_parser") and type(apt.byAirport) == "table" then
        local rows = apt.byAirport[ident]
        local best = chooseBestAirportRunway(rows, refWp)
        if best and isFinite(best.lat) and isFinite(best.lon) then
            return {
                ident = ident,
                lat = best.lat,
                lon = best.lon,
                type = "TF",
                fly_over = false,
                segment = normalizeSegment(defaultSegment, SEGMENT_ENROUTE),
                procedure_name = normalizeProcedureName(defaultProcedureName),
            }
        end
    end

    safeLog("LNAV CORE: Could not resolve waypoint ident " .. tostring(ident))
    return nil
end

local function materializeWaypoint(rawWp, index, defaultSegment, defaultProcedureName, refWp)
    if type(rawWp) == "string" then
        return resolveIdentWaypoint(rawWp, refWp, defaultSegment, defaultProcedureName)
    end

    if type(rawWp) ~= "table" then
        return nil
    end

    local segment = normalizeSegment(rawWp.segment or rawWp._segment, defaultSegment)
    local procedureName = normalizeProcedureName(rawWp.procedure_name or rawWp._procedure_name or defaultProcedureName)

    local sanitized = sanitizeWaypoint(rawWp, index, segment, procedureName)
    if sanitized then
        return sanitized
    end

    if rawWp.ident ~= nil then
        local resolved = resolveIdentWaypoint(rawWp.ident, refWp, segment, procedureName)
        if resolved then
            if rawWp.fly_over == true then
                resolved.fly_over = true
            end
            return resolved
        end
    end

    return nil
end

local function sanitizeWaypointList(rawList, defaultSegment, defaultProcedureName)
    local sanitized = {}
    if type(rawList) ~= "table" then
        return sanitized
    end

    local prevWp = nil
    for i = 1, #rawList do
        local wp = materializeWaypoint(rawList[i], i, defaultSegment, defaultProcedureName, prevWp)
        if wp then
            sanitized[#sanitized + 1] = wp
            prevWp = wp
        end
    end

    return sanitized
end

local function cloneWaypoint(wp)
    if type(wp) ~= "table" then
        return nil
    end
    return {
        ident = wp.ident,
        lat = wp.lat,
        lon = wp.lon,
        type = wp.type,
        fly_over = wp.fly_over == true,
        segment = normalizeSegment(wp.segment, SEGMENT_ENROUTE),
        procedure_name = normalizeProcedureName(wp.procedure_name),
    }
end

local function waypointsEquivalent(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end

    if tostring(a.ident or "") ~= tostring(b.ident or "") then
        return false
    end

    local d = geometry.distanceNm(a.lat, a.lon, b.lat, b.lon)
    return isFinite(d) and d <= 0.05
end

local function appendUniqueWaypoints(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return
    end

    for i = 1, #src do
        local wp = src[i]
        local last = dst[#dst]
        if not waypointsEquivalent(last, wp) then
            dst[#dst + 1] = cloneWaypoint(wp)
        end
    end
end

local function normalizeProcedureSpec(spec, segment)
    if spec == nil then
        return nil
    end

    if type(spec) ~= "table" then
        return nil
    end

    local procedureName = normalizeProcedureName(spec.name)
    local waypointsSource = type(spec.waypoints) == "table" and spec.waypoints or spec
    local waypoints = sanitizeWaypointList(waypointsSource, segment, procedureName)

    if #waypoints == 0 then
        return nil
    end

    return {
        name = procedureName,
        segment = normalizeSegment(segment, SEGMENT_ENROUTE),
        waypoints = waypoints,
    }
end

local function rebuildFlightPlanFromPlans()
    local merged = {}

    if type(lnav._plans.sid) == "table" and type(lnav._plans.sid.waypoints) == "table" then
        appendUniqueWaypoints(merged, lnav._plans.sid.waypoints)
    end

    appendUniqueWaypoints(merged, lnav._plans.enroute or {})

    if type(lnav._plans.star) == "table" and type(lnav._plans.star.waypoints) == "table" then
        appendUniqueWaypoints(merged, lnav._plans.star.waypoints)
    end

    lnav.flightplan = merged
    lnav.active_leg = 1
end

local function cloneWaypointList(list)
    local out = {}
    if type(list) ~= "table" then
        return out
    end

    for i = 1, #list do
        local c = cloneWaypoint(list[i])
        if c then
            out[#out + 1] = c
        end
    end

    return out
end

local function cloneProcedure(spec)
    if type(spec) ~= "table" then
        return nil
    end

    return {
        name = normalizeProcedureName(spec.name),
        segment = normalizeSegment(spec.segment, SEGMENT_ENROUTE),
        waypoints = cloneWaypointList(spec.waypoints),
    }
end

local function hasLeg()
    return type(lnav.flightplan) == "table"
        and #lnav.flightplan >= 2
        and lnav.active_leg >= 1
        and lnav.active_leg < #lnav.flightplan
end

local function getLegWaypoints()
    if not hasLeg() then
        return nil, nil, nil
    end

    local fromWp = lnav.flightplan[lnav.active_leg]
    local toWp = lnav.flightplan[lnav.active_leg + 1]
    local nextWp = lnav.flightplan[lnav.active_leg + 2]
    return fromWp, toWp, nextWp
end

local function canComputeLegGeometry()
    return hasLeg() and isFinite(lnav._position.lat) and isFinite(lnav._position.lon)
end

local function computeTurnLeadDistance(currentLegTrackDeg, toWp, nextWp)
    if not nextWp or toWp.fly_over then
        return 0, 0
    end

    local gs = lnav._motion.ground_speed_kt
    if not isFinite(gs) or gs <= 1 then
        return 0, 0
    end

    local outboundTrack = geometry.initialBearingDeg(toWp.lat, toWp.lon, nextWp.lat, nextWp.lon)
    if outboundTrack == nil then
        return 0, 0
    end

    local turnAngle = geometry.turnAngleDeg(currentLegTrackDeg, outboundTrack)
    if not isFinite(turnAngle) or turnAngle < 1e-3 then
        return 0, 0
    end

    local turnRadiusNm = geometry.turnRadiusNm(gs, lnav._config.default_bank_angle_deg)
    local leadDistanceNm = geometry.leadDistanceNm(turnRadiusNm, turnAngle)

    leadDistanceNm = geometry.clamp(leadDistanceNm or 0, 0, lnav._config.max_lead_distance_nm) or 0
    return leadDistanceNm, turnAngle
end

local function computeLegMetrics()
    local fromWp, toWp, nextWp = getLegWaypoints()
    if not fromWp or not toWp then
        return nil
    end

    local curLat = lnav._position.lat
    local curLon = lnav._position.lon
    if not isFinite(curLat) or not isFinite(curLon) then
        return nil
    end

    local desiredTrack = geometry.initialBearingDeg(fromWp.lat, fromWp.lon, toWp.lat, toWp.lon)
    local xtk = geometry.crossTrackErrorNm(curLat, curLon, fromWp.lat, fromWp.lon, toWp.lat, toWp.lon)
    local distToWp = geometry.distanceNm(curLat, curLon, toWp.lat, toWp.lon)
    local alongTrack = geometry.alongTrackDistanceNm(curLat, curLon, fromWp.lat, fromWp.lon, toWp.lat, toWp.lon)
    local legLength = geometry.distanceNm(fromWp.lat, fromWp.lon, toWp.lat, toWp.lon)

    if not isFinite(desiredTrack) or not isFinite(xtk) or not isFinite(distToWp) then
        return nil
    end

    local leadDistance, turnAngle = computeTurnLeadDistance(desiredTrack, toWp, nextWp)
    local trackDiff = math.huge
    if isFinite(lnav._motion.track_deg) then
        trackDiff = geometry.absAngleDiffDeg(lnav._motion.track_deg, desiredTrack) or math.huge
    end

    return {
        from_wp = fromWp,
        to_wp = toWp,
        next_wp = nextWp,
        desired_track_deg = desiredTrack,
        cross_track_error_nm = xtk,
        distance_to_waypoint_nm = distToWp,
        along_track_nm = alongTrack,
        leg_length_nm = legLength,
        lead_distance_nm = leadDistance,
        turn_angle_deg = turnAngle,
        track_diff_deg = trackDiff,
    }
end

local function shouldSequence(metrics)
    if type(metrics) ~= "table" then
        return false
    end

    local distanceToWp = metrics.distance_to_waypoint_nm
    if not isFinite(distanceToWp) then
        return false
    end

    if isFinite(metrics.along_track_nm) and isFinite(metrics.leg_length_nm) then
        if metrics.along_track_nm >= metrics.leg_length_nm then
            return true
        end
    end

    if metrics.to_wp and metrics.to_wp.fly_over then
        return distanceToWp <= lnav._config.flyover_sequence_nm
    end

    local leadDistance = metrics.lead_distance_nm or 0
    if leadDistance > 0 and distanceToWp <= leadDistance then
        return true
    end

    return distanceToWp <= lnav._config.fallback_sequence_nm
end

local function advanceLeg()
    if not hasLeg() then
        return false
    end

    local lastLeg = #lnav.flightplan - 1
    if lnav.active_leg < lastLeg then
        lnav.active_leg = lnav.active_leg + 1
        return true
    end

    lnav.active_leg = #lnav.flightplan
    return false
end

local function applyGuidanceFromMetrics(metrics)
    if not metrics then
        lnav._guidance.desired_track_deg = nil
        lnav._guidance.commanded_track_deg = nil
        lnav._guidance.cross_track_error_nm = nil
        lnav._guidance.distance_to_waypoint_nm = nil
        lnav._guidance.active_waypoint_ident = nil
        lnav._guidance.next_waypoint_ident = nil
        lnav._guidance.active_waypoint_segment = nil
        lnav._guidance.next_waypoint_segment = nil
        lnav._guidance.active_procedure_name = nil
        lnav._guidance.lnav_state = lnav.state
        return
    end

    local interceptAngle = geometry.clamp(
        (metrics.cross_track_error_nm or 0) * lnav._config.intercept_gain,
        -lnav._config.max_intercept_angle_deg,
        lnav._config.max_intercept_angle_deg
    ) or 0

    lnav._guidance.desired_track_deg = metrics.desired_track_deg
    lnav._guidance.commanded_track_deg = geometry.wrap360(metrics.desired_track_deg + interceptAngle)
    lnav._guidance.cross_track_error_nm = metrics.cross_track_error_nm
    lnav._guidance.distance_to_waypoint_nm = metrics.distance_to_waypoint_nm
    lnav._guidance.active_waypoint_ident = metrics.to_wp and metrics.to_wp.ident or nil
    lnav._guidance.next_waypoint_ident = metrics.next_wp and metrics.next_wp.ident or nil
    lnav._guidance.active_waypoint_segment = metrics.to_wp and metrics.to_wp.segment or nil
    lnav._guidance.next_waypoint_segment = metrics.next_wp and metrics.next_wp.segment or nil
    lnav._guidance.active_procedure_name = (metrics.to_wp and metrics.to_wp.procedure_name)
        or (metrics.from_wp and metrics.from_wp.procedure_name)
        or nil
    lnav._guidance.lnav_state = lnav.state
end

local function updateStateMachine(canNavigate, meetsActivation)
    local current = lnav.state

    if current == "OFF" then
        if canNavigate then
            if meetsActivation then
                lnav.state = "ACTIVE"
            else
                lnav.state = "ARMED"
            end
        else
            lnav.state = "OFF"
        end
    elseif current == "ARMED" then
        if not canNavigate then
            lnav.state = "OFF"
        elseif meetsActivation then
            lnav.state = "ACTIVE"
        else
            lnav.state = "ARMED"
        end
    elseif current == "ACTIVE" then
        if not canNavigate then
            lnav.state = "OFF"
        elseif not meetsActivation then
            lnav.state = "ARMED"
        else
            lnav.state = "ACTIVE"
        end
    else
        lnav.state = "OFF"
    end
end

function lnav.setFlightPlan(fp)
    lnav._plans.sid = nil
    lnav._plans.star = nil
    lnav._plans.enroute = sanitizeWaypointList(fp, SEGMENT_ENROUTE, nil)
    rebuildFlightPlanFromPlans()
end

function lnav.setEnrouteFlightPlan(fp)
    lnav._plans.enroute = sanitizeWaypointList(fp, SEGMENT_ENROUTE, nil)
    rebuildFlightPlanFromPlans()
end

function lnav.setSID(spec)
    lnav._plans.sid = normalizeProcedureSpec(spec, SEGMENT_SID)
    rebuildFlightPlanFromPlans()
    return lnav._plans.sid ~= nil
end

function lnav.setSTAR(spec)
    lnav._plans.star = normalizeProcedureSpec(spec, SEGMENT_STAR)
    rebuildFlightPlanFromPlans()
    return lnav._plans.star ~= nil
end

function lnav.clearSID()
    lnav._plans.sid = nil
    rebuildFlightPlanFromPlans()
end

function lnav.clearSTAR()
    lnav._plans.star = nil
    rebuildFlightPlanFromPlans()
end

function lnav.clearProcedures()
    lnav._plans.sid = nil
    lnav._plans.star = nil
    rebuildFlightPlanFromPlans()
end

function lnav.setRoute(route)
    if type(route) ~= "table" then
        lnav._plans.sid = nil
        lnav._plans.enroute = {}
        lnav._plans.star = nil
        rebuildFlightPlanFromPlans()
        return
    end

    lnav._plans.sid = normalizeProcedureSpec(route.sid, SEGMENT_SID)
    lnav._plans.star = normalizeProcedureSpec(route.star, SEGMENT_STAR)

    local enroute = route.enroute
    if enroute == nil then
        enroute = route.flightplan
    end

    lnav._plans.enroute = sanitizeWaypointList(enroute, SEGMENT_ENROUTE, nil)
    rebuildFlightPlanFromPlans()
end

function lnav.resolveWaypoint(ident, referenceWaypoint)
    local wp = resolveIdentWaypoint(ident, referenceWaypoint, SEGMENT_ENROUTE, nil)
    return cloneWaypoint(wp)
end

function lnav.getRoute()
    return {
        sid = cloneProcedure(lnav._plans.sid),
        enroute = cloneWaypointList(lnav._plans.enroute),
        star = cloneProcedure(lnav._plans.star),
        flightplan = cloneWaypointList(lnav.flightplan),
        active_leg = lnav.active_leg,
    }
end

function lnav.setPosition(lat, lon)
    if isFinite(lat) and isFinite(lon) then
        lnav._position.lat = lat
        lnav._position.lon = lon
    else
        lnav._position.lat = nil
        lnav._position.lon = nil
    end
end

function lnav.setMotion(track_deg, ground_speed)
    if isFinite(track_deg) then
        lnav._motion.track_deg = geometry.wrap360(track_deg)
    else
        lnav._motion.track_deg = nil
    end

    if isFinite(ground_speed) then
        lnav._motion.ground_speed_kt = math.max(0, ground_speed)
    else
        lnav._motion.ground_speed_kt = nil
    end
end

function lnav.update(dt)
    if dt and not isFinite(dt) then
        dt = nil
    end

    local metrics = nil

    if canComputeLegGeometry() then
        local sequenceCount = 0

        while sequenceCount < lnav._config.max_sequence_per_update do
            metrics = computeLegMetrics()
            if not metrics then
                break
            end

            if shouldSequence(metrics) then
                local advanced = advanceLeg()
                sequenceCount = sequenceCount + 1
                if not advanced then
                    metrics = nil
                    break
                end
            else
                break
            end
        end

        if metrics == nil then
            metrics = computeLegMetrics()
        end
    end

    local canNavigate = metrics ~= nil
    local meetsActivation = false
    if canNavigate and isFinite(metrics.cross_track_error_nm) and isFinite(metrics.track_diff_deg) then
        meetsActivation = math.abs(metrics.cross_track_error_nm) < lnav._config.activation_xtk_nm
            and metrics.track_diff_deg < lnav._config.activation_track_diff_deg
    end

    updateStateMachine(canNavigate, meetsActivation)
    applyGuidanceFromMetrics(metrics)
    lnav._guidance.lnav_state = lnav.state
end

function lnav.getGuidance()
    local out = copyGuidance(lnav._guidance)
    out.lnav_state = lnav.state
    return out
end

return lnav
