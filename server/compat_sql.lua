-- Exact stock SQL reads are projected from native state. Never read archived
-- ownership/keys back into a running provider or expose a half-committed sale.
local State = Housing.state
local arity = { locations = 0, location = 1, owned = 1, locations_like = 1,
    owners = 0, house = 1, citizen = 1, identity = 2 }

local function equal(a, b)
    return type(a) == 'string' and type(b) == 'string' and a:lower() == b:lower()
end

local function stable(property)
    local current = State.get(property.id)
    return State.ready and current and current.revision == property.revision
        and not State.writes[property.id] and not State.isUncertain(property.id)
        and (not Housing.transactions or not Housing.transactions.busy(property.id))
end

local function entryKeys(property)
    local candidates, keys = {}, {}
    for _, field in ipairs({ 'keys', 'coowners', 'permissionGrants' }) do
        for cid in pairs(property[field] or {}) do candidates[cid] = true end
    end
    if property.owner then candidates[property.owner] = true end
    local lease = Housing.leases and Housing.leases.active(property.id)
    if lease then candidates[lease.tenant] = true end
    for cid in pairs(candidates) do
        if Housing.permissions.canCitizen(cid, property.id, 'entry') then keys[#keys + 1] = cid end
    end
    table.sort(keys)
    return keys
end

local function location(property, ownershipOnly)
    if ownershipOnly then return { owned = property.owner and 1 or 0 } end
    local interior = property.interior
    if not interior or not Housing.validCoords(interior.entrance) then
        return nil, 'Legacy housing requires a mapped entrance: ' .. property.id
    end
    local tier
    for number, name in pairs(Config.legacyHousing.shellTiers) do
        if interior.type == 'shell' and interior.name == name then tier = number; break end
    end
    if not tier then return nil, 'Legacy housing requires a stock shell tier mapping: ' .. property.id end
    local entrance = Housing.copy(interior.entrance)
    entrance.h, entrance.w = entrance.w, nil
    local coords = { enter = entrance }
    if property.legacy and property.legacy.viewCamera then coords.cam = Housing.copy(property.legacy.viewCamera) end
    local garage = {}
    if property.garage then
        if not Housing.validCoords(property.garage.coords) or not Housing.validCoords(property.garage.spawn) then
            return nil, 'Legacy housing garage coordinates are unavailable: ' .. property.id
        end
        -- Stock has one physical point for both interaction and spawn. A
        -- split native garage needs an explicit consumer-specific integration.
        for _, axis in ipairs({ 'x', 'y', 'z' }) do
            if property.garage.coords[axis] ~= property.garage.spawn[axis] then
                return nil, 'Legacy housing cannot represent a split garage point: ' .. property.id
            end
        end
        garage = Housing.copy(property.garage.spawn)
    end
    return { id = property.legacy and property.legacy.locationId, name = property.id, label = property.label,
        owned = property.owner and 1 or 0, coords = json.encode(coords), garage = json.encode(garage), tier = tier,
        price = property.listing and property.listing.price or property.soldPrice or property.legacy and property.legacy.price }
end

local function ownership(property)
    if not property.owner then return false end
    local legacy = property.legacy or {}
    if legacy.unmappedFixtures and next(legacy.unmappedFixtures) then
        return nil, 'Legacy housing fixtures require native migration: ' .. property.id
    end
    -- Older ownership-only imports have no reviewed fixture status. They must
    -- be mapped explicitly, not inferred empty from the archival source.
    if legacy.source == 'qb-houses' and legacy.unmappedFixtures == nil then
        return nil, 'Legacy housing import requires fixture review: ' .. property.id
    end
    local character = exports.kora_core:getPlayerByCitizenId(property.owner)
        or exports.kora_core:getOfflinePlayerData(property.owner)
    if not character or character.citizenid ~= property.owner or type(character.license) ~= 'string' then
        return nil, 'Legacy housing owner identity is unavailable: ' .. property.id
    end
    local decorations = {}
    for _, item in pairs(Housing.world.furniture) do
        if item.propertyId == property.id and item.status == 'placed' then
            decorations[#decorations + 1] = { hashname = item.model, x = item.coords.x, y = item.coords.y, z = item.coords.z,
                rotx = item.rotation.pitch, roty = item.rotation.roll, rotz = item.rotation.yaw, nativeId = item.id }
        end
    end
    table.sort(decorations, function(a, b) return a.nativeId < b.nativeId end)
    for index, item in ipairs(decorations) do item.objectId, item.nativeId = index, nil end
    local stashes, err = QB.sql.query('SELECT `id`,`coords` FROM `qbhousing_stashes` WHERE `property_id`=? AND `status`=? AND `lease_id` IS NULL ORDER BY `id`', { property.id, 'active' })
    if not stashes then return nil, err or 'Native housing stash storage is unavailable.' end
    if #stashes > 1 or #(property.clothing or {}) > 1 then
        return nil, 'Legacy housing requires a single primary stash/outfit mapping: ' .. property.id
    end
    local stash = stashes[1] and stashes[1].coords
    if type(stash) == 'table' then stash = json.encode(stash) end
    local outfit = property.clothing and property.clothing[1] and property.clothing[1].coords
    return { id = legacy.ownershipId, house = property.id, citizenid = property.owner, identifier = character.license,
        keyholders = json.encode(entryKeys(property)), decorations = json.encode(decorations), stash = stash,
        outfit = outfit and json.encode(outfit), logout = property.logout and json.encode(property.logout) }
end

local function matchesLike(value, query)
    -- Stock house names are SQL identifiers generated from street labels. The
    -- ASCII subset has the same case-insensitive wildcard behavior in the
    -- pinned default collations; non-ASCII collation needs an explicit bridge.
    if value:find('[\128-\255]') or query:find('[\128-\255]') then return nil end
    local pattern, escaped = { '^' }, false
    for index = 1, #query do
        local char = query:sub(index, index)
        if char == '\\' and not escaped then escaped = true
        else
            if not escaped and char == '%' then pattern[#pattern + 1] = '.*'
            elseif not escaped and char == '_' then pattern[#pattern + 1] = '.'
            else pattern[#pattern + 1] = char:gsub('([^%w])', '%%%1') end
            escaped = false
        end
    end
    if escaped then pattern[#pattern + 1] = '\\' end
    pattern[#pattern + 1] = '$'
    return value:lower():match(table.concat(pattern):lower()) ~= nil
end

local function read(operation, args)
    if arity[operation] == nil or type(args) ~= 'table' or #args ~= arity[operation] then return nil, 'Unsupported legacy housing read.' end
    for _, value in ipairs(args) do
        if type(value) ~= 'string' or value == '' or #value > 255 then return nil, 'Invalid legacy housing filter.' end
    end
    if not State.ready or not Housing.world.ready then return nil, 'Native housing is not ready.' end
    local ownerRows = operation == 'owners' or operation == 'house' or operation == 'citizen' or operation == 'identity'
    local selected = {}
    for _, property in pairs(State.properties) do
        if property.state ~= 'archived' and property.state ~= 'archiving' then
            local wanted = true
            if operation == 'location' or operation == 'owned' or operation == 'house' then wanted = equal(property.id, args[1])
            elseif operation == 'citizen' then wanted = equal(property.owner, args[1])
            elseif operation == 'identity' then wanted = equal(property.owner, args[2])
            elseif operation == 'locations_like' then
                wanted = matchesLike(property.id, args[1])
                if wanted == nil then return nil, 'Non-ASCII stock housing LIKE collation requires a mapping.' end
            end
            if wanted and (not ownerRows or property.owner) then
                if not stable(property) then return nil, 'Native housing is being updated; retry the read.' end
                selected[#selected + 1] = Housing.copy(property)
            end
        end
    end
    table.sort(selected, function(a, b)
        if operation == 'locations_like' then
            if #a.id ~= #b.id then return #a.id > #b.id end
            return a.id:lower() > b.id:lower()
        end
        return a.id < b.id
    end)
    -- All native property/fixture writers share these gates. Acquire the full
    -- selected set before yielding, and release on both success and SQL errors.
    for _, property in ipairs(selected) do State.writes[property.id] = true end
    local called, result, failure = pcall(function()
        local rows = {}
        for _, property in ipairs(selected) do
            local row, err
            if ownerRows then row, err = ownership(property) else row, err = location(property, operation == 'owned') end
            if not row then return nil, err end
            if operation ~= 'identity' or equal(row.identifier, args[1]) then rows[#rows + 1] = row end
        end
        return rows
    end)
    for _, property in ipairs(selected) do State.writes[property.id] = nil end
    if not called then return nil, 'Native housing projection failed.' end
    return result, failure
end

Housing.legacy.read = read
exports('readLegacyHousing', function(operation, args, callback)
    if GetInvokingResource() ~= 'kora_sql' then return callback(nil, 'Legacy housing SQL is restricted to qbsql.') end
    CreateThread(function()
        local deadline = GetGameTimer() + 60000
        while not State.ready or not Housing.world.ready do
            if GetGameTimer() >= deadline then callback(nil, 'Native housing readiness timed out.'); return end
            Wait(50)
        end
        local ok, rows, err = pcall(read, operation, args)
        if not ok then rows, err = nil, 'Native housing projection failed.' end
        callback(rows, err)
    end)
end)
