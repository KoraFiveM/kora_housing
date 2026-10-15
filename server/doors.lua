Housing.doors = { bindings = {} }
local Doors, State, P = Housing.doors, Housing.state, Housing.permissions
local resource, editing = GetCurrentResourceName(), false

local function invoke(method, ...)
    local args = table.pack(...)
    local ok, value, err = pcall(function() return exports.qbdoorlock[method](exports.qbdoorlock, table.unpack(args, 1, args.n)) end)
    if not ok then return false, 'Door locks are unavailable.' end
    return value, err
end

local function doorId(value)
    if type(value) == 'table' then value = value.id end
    if type(value) == 'number' and value % 1 == 0 then value = tostring(value) end
    return type(value) == 'string' and #value > 0 and #value <= 64 and value or nil
end

local function hasDoor(property, id)
    for _, value in pairs(property.doorlocks or {}) do if doorId(value) == id then return true end end
    return false
end

local function callback(propertyId)
    return function(src, id, context)
        local property = State.get(propertyId)
        if not State.ready or not property or property.state == 'archived' or property.state == 'archiving'
            or State.isUncertain and State.isUncertain(propertyId)
            or Housing.transactions and Housing.transactions.busy(propertyId) or not hasDoor(property, id) then return false end
        if context.lockpick then
            -- qbdoorlock checks items and consumes the server-issued minigame proof.
            return Config.allowDoorLockpick ~= false and context.authorised == true
        end
        return P.can(src, propertyId, 'entry') == true
    end
end

local function registry()
    local result = {}
    for propertyId, property in pairs(State.properties) do
        for _, value in pairs(property.doorlocks or {}) do
            local id = doorId(value)
            if not id then return nil, 'A property has an invalid door identity.' end
            if result[id] and result[id] ~= propertyId then return nil, 'A door is assigned to multiple properties.' end
            result[id] = propertyId
        end
    end
    return result
end

function Doors.load()
    local bindings, err = registry()
    if not bindings then return false, err end
    local all, lookupErr = invoke('getAllDoors')
    if type(all) ~= 'table' then return false, lookupErr or 'Door locks are unavailable.' end
    local existing = {}
    for _, door in ipairs(all) do existing[door.id] = door end
    for id in pairs(bindings) do
        local door = existing[id]
        if not door then return false, 'A configured property door was not found: ' .. id end
        if door.definition.policyOwner and door.definition.policyOwner ~= resource then return false, 'A property door belongs to another provider.' end
    end
    for id, propertyId in pairs(bindings) do
        local ok, bindErr = invoke('RegisterDoorPolicy', id, callback(propertyId))
        if not ok then return false, bindErr end
    end
    -- Reconcile an unlink whose property save committed before a resource stop.
    for id, door in pairs(existing) do
        if door.definition.policyOwner == resource and not bindings[id] then
            local ok, releaseErr = invoke('ReleaseDoorPolicy', id)
            if not ok then return false, releaseErr end
        end
    end
    Doors.bindings = bindings
    return true
end

function Doors.refresh()
    return Doors.load()
end

local function nearby(property, door)
    if Housing.world and Housing.world.contains(property.id, door.coords) then return true end
    local entrance = property.interior and property.interior.entrance
    if not entrance then return false end
    local dx, dy, dz = entrance.x - door.coords.x, entrance.y - door.coords.y, entrance.z - door.coords.z
    return dx * dx + dy * dy + dz * dz <= 25
end

function Doors.configure(src, id, values, revision)
    if editing then return false, 'Door assignments are being updated. Please try again.' end
    editing = true
    local ok, result = State.withWrite(id, function()
        local property, cid = State.get(id), P.citizenId(src)
        local admin = P.isAdmin(src)
        if not State.ready or not property or property.state == 'archived' or not admin and not Housing.domain.owner(property, cid) then return false, 'Only property owners or administrators can configure doors.' end
        if not Housing.finite(revision) or revision % 1 ~= 0 or revision ~= property.revision then return false, 'This property changed. Refresh it before saving.' end
        if type(values) ~= 'table' or #values > (Config.maxDoors or 50) then return false, 'Choose a valid list of doors.' end
        local bindings, registryErr = registry()
        if not bindings then return false, registryErr end
        local ids, seen, acquired = {}, {}, {}
        for index, value in pairs(values) do
            if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > #values then return false, 'Choose a valid list of doors.' end
            local key = doorId(value)
            if not key or seen[key] or bindings[key] and bindings[key] ~= id then return false, 'A door is invalid, repeated or assigned to another property.' end
            local door, lookupErr = invoke('getDoor', key)
            if type(door) ~= 'table' or type(door.definition) ~= 'table' then return false, lookupErr or 'A selected door was not found.' end
            if door.definition.policyOwner and door.definition.policyOwner ~= resource then return false, 'A selected door belongs to another provider.' end
            if not admin and not nearby(property, door) then return false, 'Choose a door at this property.' end
            ids[index], seen[key] = key, true
            if not door.definition.policyOwner then acquired[#acquired + 1] = key end
        end
        -- Protect new doors before the property mapping becomes authoritative.
        for _, key in ipairs(ids) do
            local bound, bindErr = invoke('RegisterDoorPolicy', key, callback(id))
            if not bound then return false, bindErr end
        end
        local changed = Housing.copy(property)
        changed.doorlocks = ids
        local saved, saveErr = State.persist(changed, { actor = cid, action = 'doors.configure' })
        if not saved then
            if not State.isUncertain or not State.isUncertain(id) then
                for _, key in ipairs(acquired) do invoke('ReleaseDoorPolicy', key) end
            end
            return false, saveErr
        end
        local refreshed, refreshErr = Doors.load()
        if not refreshed then return false, 'Door assignments were saved; policy refresh failed: ' .. tostring(refreshErr) end
        return true, saved
    end)
    editing = false
    return ok == true, result
end

function Doors.view(src, id)
    local property = State.get(id)
    if not property or not P.can(src, id, 'property.edit') then return false, 'You cannot configure these doors.' end
    return true, Housing.copy(property.doorlocks or {})
end

AddEventHandler('qbdoorlock:loaded', function()
    if not State.ready then return end
    local ok, err = Doors.load()
    if not ok then print('[qbhousing] Door policies could not rebind: ' .. tostring(err)) end
end)
