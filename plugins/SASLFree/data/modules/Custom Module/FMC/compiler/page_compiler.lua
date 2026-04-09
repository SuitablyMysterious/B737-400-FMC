-- page_compiler.lua

-- Copyright © 2026 SuitablyMysterious
-- Usage without permission is expressly forbidden

local compiler = {}

local RESERVED_COMMANDS = {
    none = true,
    update = true,
}

local SLOT_ORDER = {
    "L1", "L2", "L3", "L4", "L5", "L6",
    "R1", "R2", "R3", "R4", "R5", "R6",
}

local OP_PRECEDENCE = {
    ["or"] = 1,
    ["and"] = 2,
    ["not"] = 3,
}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitFirst(s, sep)
    local i = s:find(sep, 1, true)
    if not i then
        return s, nil
    end
    return s:sub(1, i - 1), s:sub(i + #sep)
end

local function basenameWithoutExt(path)
    local p = path:gsub("\\", "/")
    local name = p:match("([^/]+)$") or p
    return (name:gsub("%.lua$", ""))
end

local function readAll(path)
    local f, err = io.open(path, "r")
    if not f then
        return nil, err
    end
    local content = f:read("*a")
    f:close()
    return content
end

local function writeAll(path, content)
    local f, err = io.open(path, "w")
    if not f then
        return nil, err
    end
    f:write(content)
    f:close()
    return true
end

local function isIdentifier(s)
    return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function sortedKeys(tbl)
    local keys = {}
    for k in pairs(tbl) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function serializeLua(value, indent)
    indent = indent or ""
    local t = type(value)

    if t == "nil" then
        return "nil"
    end
    if t == "number" or t == "boolean" then
        return tostring(value)
    end
    if t == "string" then
        return string.format("%q", value)
    end
    if t ~= "table" then
        error("Unsupported serialization type: " .. t)
    end

    local out = {"{"}
    local nextIndent = indent .. "    "

    local maxNumeric = 0
    local hasNumeric = false
    for k in pairs(value) do
        if type(k) == "number" and k >= 1 and math.floor(k) == k then
            hasNumeric = true
            if k > maxNumeric then
                maxNumeric = k
            end
        end
    end

    if hasNumeric then
        for i = 1, maxNumeric do
            if value[i] ~= nil then
                out[#out + 1] = nextIndent .. serializeLua(value[i], nextIndent) .. ","
            end
        end
    end

    local strKeys = {}
    for k in pairs(value) do
        if type(k) == "string" then
            strKeys[#strKeys + 1] = k
        end
    end
    table.sort(strKeys)

    for _, k in ipairs(strKeys) do
        local keyExpr
        if isIdentifier(k) then
            keyExpr = k
        else
            keyExpr = "[" .. string.format("%q", k) .. "]"
        end
        out[#out + 1] = nextIndent .. keyExpr .. " = " .. serializeLua(value[k], nextIndent) .. ","
    end

    out[#out + 1] = indent .. "}"
    return table.concat(out, "\n")
end

local function parseDependencyTokens(depRaw)
    local raw = trim(depRaw or "")
    if raw == "" or raw:lower() == "none" then
        return { rpn = {}, symbols = {}, canonicalSymbols = {} }
    end

    local tokens = {}
    local i = 1
    while i <= #raw do
        local ch = raw:sub(i, i)
        if ch:match("%s") then
            i = i + 1
        elseif ch == "(" or ch == ")" then
            tokens[#tokens + 1] = { type = "paren", value = ch }
            i = i + 1
        else
            local j = i
            while j <= #raw do
                local cj = raw:sub(j, j)
                if cj:match("[%s()]") then
                    break
                end
                j = j + 1
            end
            local word = raw:sub(i, j - 1)
            local upper = word:upper()
            if upper == "AND" or upper == "OR" or upper == "NOT" then
                tokens[#tokens + 1] = { type = "op", value = upper:lower() }
            else
                if not word:match("^[%a_][%w_%.]*$") then
                    return nil, "Invalid dependency token: " .. tostring(word)
                end
                tokens[#tokens + 1] = { type = "id", value = word }
            end
            i = j
        end
    end

    if #tokens == 0 then
        return { rpn = {}, symbols = {}, canonicalSymbols = {} }
    end

    local output = {}
    local stack = {}
    local symbols = {}
    local symbolSet = {}

    for _, tok in ipairs(tokens) do
        if tok.type == "id" then
            output[#output + 1] = tok
            if not symbolSet[tok.value] then
                symbols[#symbols + 1] = tok.value
                symbolSet[tok.value] = true
            end
        elseif tok.type == "op" then
            if tok.value == "not" then
                while #stack > 0 and stack[#stack].type == "op" and OP_PRECEDENCE[stack[#stack].value] > OP_PRECEDENCE[tok.value] do
                    output[#output + 1] = table.remove(stack)
                end
            else
                while #stack > 0 and stack[#stack].type == "op" and OP_PRECEDENCE[stack[#stack].value] >= OP_PRECEDENCE[tok.value] do
                    output[#output + 1] = table.remove(stack)
                end
            end
            stack[#stack + 1] = tok
        elseif tok.type == "paren" and tok.value == "(" then
            stack[#stack + 1] = tok
        elseif tok.type == "paren" and tok.value == ")" then
            local matched = false
            while #stack > 0 do
                local top = table.remove(stack)
                if top.type == "paren" and top.value == "(" then
                    matched = true
                    break
                end
                output[#output + 1] = top
            end
            if not matched then
                return nil, "Unbalanced dependency expression parentheses"
            end
        end
    end

    while #stack > 0 do
        local top = table.remove(stack)
        if top.type == "paren" then
            return nil, "Unbalanced dependency expression parentheses"
        end
        output[#output + 1] = top
    end

    return { rpn = output, symbols = symbols, canonicalSymbols = {} }
end

local function parseFieldString(slot, fieldString)
    local pattern = "^#([^#]+)#%{([^}]*)%}%[([^%]]+)%]%(([^)]*)%)|([^|]*)|%*([^*]+)%*:(.*):$"
    local identifier, label, typeSpec, action, depRaw, command, placeholder = fieldString:match(pattern)
    if not identifier then
        return nil, "Invalid field format at " .. slot .. ": " .. tostring(fieldString)
    end

    local fieldType, inputHint = splitFirst(typeSpec, ":")
    fieldType = trim(fieldType or "")
    inputHint = trim(inputHint or "")

    local depParsed, depErr = parseDependencyTokens(depRaw)
    if not depParsed then
        return nil, depErr
    end

    return {
        slot = slot,
        identifier = trim(identifier),
        label = label,
        fieldType = fieldType,
        inputHint = inputHint ~= "" and inputHint or nil,
        action = trim(action),
        dependencyRaw = trim(depRaw),
        dependencyRpn = depParsed.rpn,
        dependencySymbols = depParsed.symbols,
        command = trim(command),
        placeholder = placeholder or "",
    }
end

local function extractLocalFunctions(source)
    local functionsByName = {}
    local pos = 1

    local function skipCommentOrString(i)
        local c = source:sub(i, i)
        local c2 = source:sub(i, i + 1)

        if c2 == "--" then
            if source:sub(i + 2, i + 3) == "[[" then
                local j = source:find("]]", i + 4, true)
                if j then
                    return j + 2
                end
                return #source + 1
            end
            local j = source:find("\n", i + 2, true)
            return j and (j + 1) or (#source + 1)
        end

        if c == "\"" or c == "'" then
            local q = c
            local j = i + 1
            while j <= #source do
                local cj = source:sub(j, j)
                if cj == "\\" then
                    j = j + 2
                elseif cj == q then
                    return j + 1
                else
                    j = j + 1
                end
            end
            return #source + 1
        end

        if source:sub(i, i + 1) == "[[" then
            local j = source:find("]]", i + 2, true)
            return j and (j + 2) or (#source + 1)
        end

        return nil
    end

    while pos <= #source do
        local skippedTo = skipCommentOrString(pos)
        if skippedTo then
            pos = skippedTo
        else
            local fnStart, fnEnd, fnName = source:find("^local%s+function%s+([%a_][%w_]*)%s*%(", pos)
            if not fnStart then
                pos = pos + 1
            else
                local i = fnEnd + 1
                local depth = 1

                while i <= #source and depth > 0 do
                    local innerSkippedTo = skipCommentOrString(i)
                    if innerSkippedTo then
                        i = innerSkippedTo
                    else
                        local word = source:match("^([%a_][%w_]*)", i)
                        if word then
                            if word == "function" or word == "if" or word == "for" or word == "while" or word == "repeat" then
                                depth = depth + 1
                            elseif word == "until" then
                                depth = depth - 1
                            elseif word == "end" then
                                depth = depth - 1
                            end
                            i = i + #word
                        else
                            i = i + 1
                        end
                    end
                end

                if depth ~= 0 then
                    return nil, "Unterminated local function block for " .. fnName
                end

                local body = source:sub(fnStart, i - 1)
                functionsByName[fnName] = body
                pos = i
            end
        end
    end

    return functionsByName
end

local function parseAssignments(source, filePath)
    local function parseRhsValue(rhs, lineNo, key)
        local raw = trim(rhs or "")
        if raw == "" then
            return nil, "Empty assignment for " .. key .. " at line " .. tostring(lineNo)
        end

        if raw == "nil" then
            return nil
        end

        local first = raw:sub(1, 1)
        local last = raw:sub(-1)
        if (first == "\"" and last == "\"") or (first == "'" and last == "'") then
            local expr = "return " .. raw
            local chunk, err = load(expr, "@" .. filePath .. ":" .. lineNo, "t", {})
            if not chunk then
                return nil, "Failed to parse quoted assignment at line " .. tostring(lineNo) .. ": " .. tostring(err)
            end
            local ok, value = pcall(chunk)
            if not ok then
                return nil, "Failed to evaluate quoted assignment at line " .. tostring(lineNo) .. ": " .. tostring(value)
            end
            if type(value) ~= "string" then
                return nil, "Quoted assignment for " .. key .. " at line " .. tostring(lineNo) .. " must evaluate to string"
            end
            return value
        end

        -- Allow raw DSL text without Lua quoting so docs-style files can still compile.
        return raw
    end

    local out = {
        TITLE = nil,
        slots = {},
        lineByKey = {},
    }

    local lineNo = 0
    for line in (source .. "\n"):gmatch("(.-)\n") do
        lineNo = lineNo + 1
        local key, rhs = line:match("^%s*(TITLE)%s*=%s*(.-)%s*$")
        if not key then
            key, rhs = line:match("^%s*([LR][1-6])%s*=%s*(.-)%s*$")
        end
        if key then
            local value, valueErr = parseRhsValue(rhs, lineNo, key)
            if valueErr then
                return nil, valueErr
            end

            if key == "TITLE" then
                out.TITLE = value
            else
                out.slots[key] = value
            end
            out.lineByKey[key] = lineNo
        end
    end

    if type(out.TITLE) ~= "string" or trim(out.TITLE) == "" then
        return nil, "Missing or invalid TITLE assignment"
    end

    return out
end

local function parsePageFile(filePath)
    local source, readErr = readAll(filePath)
    if not source then
        return nil, "Failed to read " .. filePath .. ": " .. tostring(readErr)
    end

    local assignments, assignErr = parseAssignments(source, filePath)
    if not assignments then
        return nil, assignErr
    end

    local localFns, fnErr = extractLocalFunctions(source)
    if not localFns then
        return nil, fnErr
    end

    local fieldsBySlot = {}
    local fieldsById = {}

    for _, slot in ipairs(SLOT_ORDER) do
        local raw = assignments.slots[slot]
        if raw ~= nil then
            local parsed, parseErr = parseFieldString(slot, raw)
            if not parsed then
                return nil, parseErr
            end

            if parsed.identifier ~= "nil" then
                if fieldsById[parsed.identifier] then
                    return nil, "Duplicate field identifier " .. parsed.identifier .. " in " .. filePath
                end
                fieldsById[parsed.identifier] = parsed
            end
            fieldsBySlot[slot] = parsed
        end
    end

    local commandRefs = {}
    for _, field in pairs(fieldsBySlot) do
        if field.command ~= "" and not RESERVED_COMMANDS[field.command] then
            commandRefs[field.command] = true
        end
    end

    for commandName in pairs(commandRefs) do
        if not localFns[commandName] then
            return nil, "Missing local command function for *" .. commandName .. "* in " .. filePath
        end
    end

    return {
        filePath = filePath,
        pageKey = basenameWithoutExt(filePath),
        title = assignments.TITLE,
        fieldsBySlot = fieldsBySlot,
        fieldsById = fieldsById,
        localFunctions = localFns,
    }
end

local function buildDependencyGraphs(pages)
    local pageByKey = {}
    for _, page in ipairs(pages) do
        if pageByKey[page.pageKey] then
            return nil, "Duplicate page key: " .. page.pageKey
        end
        pageByKey[page.pageKey] = page
    end

    local globalReverse = {}
    local edges = {}

    local function addGlobalReverse(symbol, target)
        if not globalReverse[symbol] then
            globalReverse[symbol] = {}
        end
        globalReverse[symbol][#globalReverse[symbol] + 1] = target
    end

    local function resolveDep(pageKey, dep)
        local depPage, depId = splitFirst(dep, ".")
        if depId then
            return depPage, depId, dep
        end
        return pageKey, dep, pageKey .. "." .. dep
    end

    for _, page in ipairs(pages) do
        page.reverseLocal = {}
        page.forwardLocal = {}

        for _, field in pairs(page.fieldsBySlot) do
            if field and field.identifier ~= "nil" then
                local node = page.pageKey .. "." .. field.identifier
                if not edges[node] then
                    edges[node] = {}
                end
                page.forwardLocal[field.identifier] = page.forwardLocal[field.identifier] or {}

                for _, dep in ipairs(field.dependencySymbols) do
                    local depPage, depId, canonical = resolveDep(page.pageKey, dep)
                    field.dependencyCanonical = field.dependencyCanonical or {}
                    field.dependencyCanonical[#field.dependencyCanonical + 1] = canonical

                    addGlobalReverse(canonical, {
                        page = page.pageKey,
                        field = field.identifier,
                        slot = field.slot,
                    })

                    page.reverseLocal[canonical] = page.reverseLocal[canonical] or {}
                    page.reverseLocal[canonical][#page.reverseLocal[canonical] + 1] = {
                        field = field.identifier,
                        slot = field.slot,
                    }

                    if depPage == page.pageKey then
                        page.reverseLocal[dep] = page.reverseLocal[dep] or {}
                        page.reverseLocal[dep][#page.reverseLocal[dep] + 1] = {
                            field = field.identifier,
                            slot = field.slot,
                        }
                    end

                    if pageByKey[depPage] and pageByKey[depPage].fieldsById[depId] then
                        local depNode = depPage .. "." .. depId
                        edges[depNode] = edges[depNode] or {}
                        edges[depNode][#edges[depNode] + 1] = node
                        page.forwardLocal[field.identifier][#page.forwardLocal[field.identifier] + 1] = canonical
                    end
                end
            end
        end
    end

    local visiting = {}
    local visited = {}
    local stack = {}

    local function dfs(node)
        if visiting[node] then
            local cycleStart = 1
            for i = 1, #stack do
                if stack[i] == node then
                    cycleStart = i
                    break
                end
            end
            local cycle = {}
            for i = cycleStart, #stack do
                cycle[#cycle + 1] = stack[i]
            end
            cycle[#cycle + 1] = node
            return false, "Dependency cycle detected: " .. table.concat(cycle, " -> ")
        end

        if visited[node] then
            return true
        end

        visiting[node] = true
        stack[#stack + 1] = node

        for _, nextNode in ipairs(edges[node] or {}) do
            local ok, err = dfs(nextNode)
            if not ok then
                return false, err
            end
        end

        stack[#stack] = nil
        visiting[node] = false
        visited[node] = true
        return true
    end

    for node in pairs(edges) do
        local ok, err = dfs(node)
        if not ok then
            return nil, err
        end
    end

    return {
        globalReverse = globalReverse,
    }
end

local function emitPageModule(page)
    local lines = {}
    lines[#lines + 1] = "-- Copyright © 2026 SuitablyMysterious"
    lines[#lines + 1] = "-- Usage without permission is expressly forbidden"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "-- Generated by FMC page compiler. Do not edit manually."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "local function dirname(path)"
    lines[#lines + 1] = "    local p = path:gsub(\"\\\\\", \"/\")"
    lines[#lines + 1] = "    return (p:match(\"^(.*)/[^/]+$\") or \".\")"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "local validator = nil"
    lines[#lines + 1] = "do"
    lines[#lines + 1] = "    local scriptPath = debug.getinfo(1, \"S\").source:sub(2)"
    lines[#lines + 1] = "    if scriptPath:sub(1, 1) ~= \"/\" and io.popen then"
    lines[#lines + 1] = "        local p = io.popen(\"pwd\")"
    lines[#lines + 1] = "        if p then"
    lines[#lines + 1] = "            local cwd = p:read(\"*l\")"
    lines[#lines + 1] = "            p:close()"
    lines[#lines + 1] = "            if cwd and cwd ~= \"\" then"
    lines[#lines + 1] = "                scriptPath = cwd .. \"/\" .. scriptPath"
    lines[#lines + 1] = "            end"
    lines[#lines + 1] = "        end"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "    local scriptDir = dirname(scriptPath)"
    lines[#lines + 1] = "    local ok, mod = pcall(dofile, scriptDir .. \"/../compiler/validator.lua\")"
    lines[#lines + 1] = "    if ok and type(mod) == \"table\" then"
    lines[#lines + 1] = "        validator = mod"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "local function normalizeFieldValue(field, value)"
    lines[#lines + 1] = "    if not field or field.fieldType ~= \"output\" then"
    lines[#lines + 1] = "        return value"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    if not validator or type(validator.normalize) ~= \"function\" then"
    lines[#lines + 1] = "        return value"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "    local ok, normalized = pcall(validator.normalize, field, value)"
    lines[#lines + 1] = "    if ok then"
    lines[#lines + 1] = "        return normalized"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    return value"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""

    local fnNames = sortedKeys(page.localFunctions)
    for _, fnName in ipairs(fnNames) do
        lines[#lines + 1] = page.localFunctions[fnName]
        lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "local mainTable = {}"
    lines[#lines + 1] = "mainTable.ready = true"
    lines[#lines + 1] = "mainTable.pageKey = " .. serializeLua(page.pageKey)
    lines[#lines + 1] = "mainTable.title = " .. serializeLua(page.title)
    lines[#lines + 1] = "mainTable.fieldsBySlot = " .. serializeLua(page.fieldsBySlot)
    lines[#lines + 1] = "mainTable.reverseDeps = " .. serializeLua(page.reverseLocal)
    lines[#lines + 1] = ""

    lines[#lines + 1] = "mainTable.commands = {"
    for _, field in pairs(page.fieldsBySlot) do
        if field and field.command ~= "" and not RESERVED_COMMANDS[field.command] then
            lines[#lines + 1] = "    [" .. string.format("%q", field.command) .. "] = " .. field.command .. ","
        end
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""

    lines[#lines + 1] = "local function evalDependencyRpn(rpn, values)"
    lines[#lines + 1] = "    if not rpn or #rpn == 0 then"
    lines[#lines + 1] = "        return true"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "    local stack = {}"
    lines[#lines + 1] = "    for i = 1, #rpn do"
    lines[#lines + 1] = "        local tok = rpn[i]"
    lines[#lines + 1] = "        if tok.type == \"id\" then"
    lines[#lines + 1] = "            stack[#stack + 1] = not not values[tok.value]"
    lines[#lines + 1] = "        elseif tok.type == \"op\" then"
    lines[#lines + 1] = "            if tok.value == \"not\" then"
    lines[#lines + 1] = "                local a = stack[#stack]"
    lines[#lines + 1] = "                stack[#stack] = not a"
    lines[#lines + 1] = "            else"
    lines[#lines + 1] = "                local b = stack[#stack]"
    lines[#lines + 1] = "                stack[#stack] = nil"
    lines[#lines + 1] = "                local a = stack[#stack]"
    lines[#lines + 1] = "                stack[#stack] = nil"
    lines[#lines + 1] = "                if tok.value == \"and\" then"
    lines[#lines + 1] = "                    stack[#stack + 1] = a and b"
    lines[#lines + 1] = "                else"
    lines[#lines + 1] = "                    stack[#stack + 1] = a or b"
    lines[#lines + 1] = "                end"
    lines[#lines + 1] = "            end"
    lines[#lines + 1] = "        end"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "    return not not stack[1]"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""

    lines[#lines + 1] = "function mainTable.fieldVisible(slot, values)"
    lines[#lines + 1] = "    local field = mainTable.fieldsBySlot[slot]"
    lines[#lines + 1] = "    if not field then"
    lines[#lines + 1] = "        return false"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    values = values or {}"
    lines[#lines + 1] = "    return evalDependencyRpn(field.dependencyRpn, values)"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""

    lines[#lines + 1] = "function mainTable.runCommand(slot, ...)"
    lines[#lines + 1] = "    local field = mainTable.fieldsBySlot[slot]"
    lines[#lines + 1] = "    if not field then"
    lines[#lines + 1] = "        return nil, \"Unknown slot\""
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "    local cmd = field.command"
    lines[#lines + 1] = "    if cmd == \"\" or cmd == \"none\" then"
    lines[#lines + 1] = "        return nil"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    if cmd == \"update\" then"
    lines[#lines + 1] = "        return true"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "    local fn = mainTable.commands[cmd]"
    lines[#lines + 1] = "    if not fn then"
    lines[#lines + 1] = "        return nil, \"Missing compiled command: \" .. tostring(cmd)"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "    local value = fn(...)"
    lines[#lines + 1] = "    return normalizeFieldValue(field, value)"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""

    lines[#lines + 1] = "function mainTable.updateDependency(symbol, context)"
    lines[#lines + 1] = "    local targets = mainTable.reverseDeps[symbol] or {}"
    lines[#lines + 1] = "    if not context or type(context.recompute) ~= \"function\" then"
    lines[#lines + 1] = "        return targets"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "    for i = 1, #targets do"
    lines[#lines + 1] = "        context.recompute(mainTable, targets[i], context)"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    return targets"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""

    lines[#lines + 1] = "return mainTable"

    return table.concat(lines, "\n") .. "\n"
end

local function emitRegistryModule(pages, globalReverse)
    local lines = {}
    lines[#lines + 1] = "-- Copyright © 2026 SuitablyMysterious"
    lines[#lines + 1] = "-- Usage without permission is expressly forbidden"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "-- Generated by FMC page compiler. Do not edit manually."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "local registry = {}"
    lines[#lines + 1] = "registry.reverse = " .. serializeLua(globalReverse)
    lines[#lines + 1] = "registry.pageKeys = " .. serializeLua((function()
        local arr = {}
        for _, p in ipairs(pages) do
            arr[#arr + 1] = p.pageKey
        end
        table.sort(arr)
        return arr
    end)())
    lines[#lines + 1] = ""

    lines[#lines + 1] = "function registry.loadPages(loader)"
    lines[#lines + 1] = "    local pagesByKey = {}"
    lines[#lines + 1] = "    for i = 1, #registry.pageKeys do"
    lines[#lines + 1] = "        local key = registry.pageKeys[i]"
    lines[#lines + 1] = "        pagesByKey[key] = loader(key)"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    return pagesByKey"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""

    lines[#lines + 1] = "function registry.propagate(symbol, pagesByKey, context)"
    lines[#lines + 1] = "    local targets = registry.reverse[symbol] or {}"
    lines[#lines + 1] = "    for i = 1, #targets do"
    lines[#lines + 1] = "        local t = targets[i]"
    lines[#lines + 1] = "        local page = pagesByKey[t.page]"
    lines[#lines + 1] = "        if page and type(page.updateDependency) == \"function\" then"
    lines[#lines + 1] = "            page.updateDependency(symbol, context)"
    lines[#lines + 1] = "        end"
    lines[#lines + 1] = "    end"
    lines[#lines + 1] = "    return targets"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = ""

    lines[#lines + 1] = "return registry"
    return table.concat(lines, "\n") .. "\n"
end

local function scanLuaFiles(inputDir)
    local files = {}
    if not io.popen then
        return files
    end

    local sep = package.config and package.config:sub(1, 1) or "/"
    local cmd
    if sep == "\\" then
        cmd = 'dir /b "' .. inputDir .. '\\*.lua" 2>nul'
    else
        cmd = 'find "' .. inputDir .. '" -maxdepth 1 -type f -name "*.lua" | sort'
    end

    local p = io.popen(cmd)
    if not p then
        return files
    end

    for line in p:lines() do
        local path = trim(line)
        if path ~= "" then
            if sep == "\\" and path:find("^[A-Za-z]:") == nil and path:sub(1, 1) ~= "\\" then
                path = inputDir:gsub("[\\/]$", "") .. sep .. path
            end
            files[#files + 1] = path
        end
    end
    p:close()

    table.sort(files)
    return files
end

local function defaultPaths()
    local base = ""
    if sasl and sasl.getProjectPath then
        base = sasl.getProjectPath() .. "/Custom Module/FMC"
    end
    return base .. "/pages_input", base .. "/pages_compiled"
end

function compiler.compileAll(options)
    options = options or {}

    local inputDir, outputDir = defaultPaths()
    inputDir = options.inputDir or inputDir
    outputDir = options.outputDir or outputDir

    local files = options.files
    if not files then
        files = scanLuaFiles(inputDir)
    end

    if not files or #files == 0 then
        return nil, "No input Lua page files found"
    end

    local pages = {}
    for _, filePath in ipairs(files) do
        local page, err = parsePageFile(filePath)
        if not page then
            return nil, err
        end
        pages[#pages + 1] = page
    end

    table.sort(pages, function(a, b)
        return a.pageKey < b.pageKey
    end)

    local graphs, graphErr = buildDependencyGraphs(pages)
    if not graphs then
        return nil, graphErr
    end

    for _, page in ipairs(pages) do
        local content = emitPageModule(page)
        local outPath = outputDir .. "/" .. page.pageKey .. ".lua"
        local ok, writeErr = writeAll(outPath, content)
        if not ok then
            return nil, "Failed to write " .. outPath .. ": " .. tostring(writeErr)
        end
    end

    local registryContent = emitRegistryModule(pages, graphs.globalReverse)
    local registryPath = outputDir .. "/pages_registry.lua"
    local ok, writeErr = writeAll(registryPath, registryContent)
    if not ok then
        return nil, "Failed to write " .. registryPath .. ": " .. tostring(writeErr)
    end

    return {
        pagesCompiled = #pages,
        outputDir = outputDir,
        registryPath = registryPath,
    }
end

function compiler.compileFile(filePath, outputDir)
    local outDir = outputDir
    if not outDir or outDir == "" then
        local _, defaultOut = defaultPaths()
        outDir = defaultOut
    end

    return compiler.compileAll({
        files = { filePath },
        outputDir = outDir,
    })
end

return compiler
