Housing.world = { ready = false, spaces = {}, furniture = {}, cameras = {}, alarms = {}, grants = {} }
local World, State, Permissions = Housing.world, Housing.state, Housing.permissions
local placements, viewers, occupants, subscribers, occupantCitizenIds, occupantSessions = {}, {}, {}, {}, {}, {}
local publishedRevisions = {}
local serial = 0
local function uncertain(id) return State.isUncertain and State.isUncertain(id) end

local function token()
    serial = serial + 1
    return ('%x-%08x-%08x-%x'):format(os.time(), math.random(0, 0x7fffffff), math.random(0, 0x7fffffff), serial)
end

local function distance(a, b)
    return (a.x - b.x)^2 + (a.y - b.y)^2 + (a.z - b.z)^2
end

local function position(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function near(src, coords, radius)
    local here = position(src)
    return here and coords and distance(here, coords) <= radius * radius
end

local function contains(bounds, coords)
    if not bounds or not coords or coords.z < bounds.minZ or coords.z > bounds.maxZ then return false end
    local inside, points = false, bounds.points
    local previous = #points
    for index, point in ipairs(points) do
        local other = points[previous]
        if (point.y > coords.y) ~= (other.y > coords.y)
            and coords.x < (other.x - point.x) * (coords.y - point.y) / (other.y - point.y) + point.x then inside = not inside end
        previous = index
    end
    return inside
end
function World.contains(value, coords)
    local bounds = type(value) == 'string' and World.spaces[value] and World.spaces[value].bounds or value
    return contains(bounds, coords)
end

function World.stashCoords(id)
    local property, space = State.get(id), World.spaces[id]
    if not property or not space then return nil end
    local interior = property.interior
    if interior and interior.type == 'shell' then
        return { x = space.origin.x + interior.exit.x, y = space.origin.y + interior.exit.y, z = space.origin.z + interior.exit.z }
    end
    if interior and contains(space.bounds, interior.entrance) then return Housing.copy(interior.entrance) end
    local center = { x = 0, y = 0, z = (space.bounds.minZ + space.bounds.maxZ) / 2 }
    for _, point in ipairs(space.bounds.points) do center.x, center.y = center.x + point.x / #space.bounds.points, center.y + point.y / #space.bounds.points end
    return contains(space.bounds, center) and center or nil
end

local function boundsValid(bounds)
    if type(bounds) ~= 'table' or type(bounds.points) ~= 'table' or #bounds.points < 3 or #bounds.points > 128
        or not Housing.finite(bounds.minZ) or not Housing.finite(bounds.maxZ) or bounds.minZ >= bounds.maxZ
        or math.abs(bounds.minZ) > Config.coordinateLimit or math.abs(bounds.maxZ) > Config.coordinateLimit then return false end
    local count, area, minX, minY, maxX, maxY = 0, 0, math.huge, math.huge, -math.huge, -math.huge
    for key, point in pairs(bounds.points) do
        if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > #bounds.points or not Housing.validCoords(point) then return false end
        local nextPoint = bounds.points[key % #bounds.points + 1]
        if not Housing.validCoords(nextPoint) then return false end
        count = count + 1
        area = area + point.x * nextPoint.y - nextPoint.x * point.y
        minX, minY, maxX, maxY = math.min(minX, point.x), math.min(minY, point.y), math.max(maxX, point.x), math.max(maxY, point.y)
    end
    return count == #bounds.points and math.abs(area) > 0.01 and maxX - minX <= 1000 and maxY - minY <= 1000 and bounds.maxZ - bounds.minZ <= 500
end

local function cross(a, b, c) return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) end
local function overlaps(a, b)
    if a.maxZ <= b.minZ or b.maxZ <= a.minZ then return false end
    local height = (math.max(a.minZ, b.minZ) + math.min(a.maxZ, b.maxZ)) / 2
    for index, point in ipairs(a.points) do
        if contains(b, { x = point.x, y = point.y, z = height }) then return true end
        local nextPoint = a.points[index % #a.points + 1]
        for otherIndex, other in ipairs(b.points) do
            local nextOther = b.points[otherIndex % #b.points + 1]
            if cross(point, nextPoint, other) * cross(point, nextPoint, nextOther) < 0
                and cross(other, nextOther, point) * cross(other, nextOther, nextPoint) < 0 then return true end
        end
    end
    for _, point in ipairs(b.points) do if contains(a, { x = point.x, y = point.y, z = height }) then return true end end
    return false
end

local function authorize(src, id, action, physical)
    local property, space = State.get(id), World.spaces[id]
    if not State.ready or not World.ready or not property or property.state == 'archived' or property.state == 'archiving' or uncertain(id) then return nil, 'Property is unavailable.' end
    local allowed, err = Permissions.can(src, id, action)
    if not allowed then return nil, err end
    if physical and (not space or not contains(space.bounds, position(src))) then return nil, 'You must be inside this property.' end
    return property, space
end

local function checked(statements, src, id, action, context)
    statements[#statements + 1] = { query = 'INSERT INTO `qbhousing_audit` (`property_id`,`actor`,`action`,`outcome`,`context`) VALUES (?,?,?,?,?)',
        values = { id, src and Permissions.citizenId(src) or QB.sql.NULL, action, 'success', json.encode(context or {}) }, expectedRows = 1 }
    local operation = 'qbhousing:world:' .. id .. ':' .. token()
    local cid = src and Permissions.citizenId(src)
    local result, err = QB.sql.transactionChecked(statements, { key = operation, fingerprint = operation, citizenids = cid and { cid } or {} })
    if not result or not result.success then
        if (not result or result.code == 'indeterminate') and State.markUncertain then
            State.markUncertain(id, operation)
            World.changed(id)
        end
        return false, err or result and result.message or 'Property storage is unavailable.'
    end
    return true
end

local function alarm(id)
    return World.alarms[id] or { propertyId = id, armed = false, doorUnlock = true, panic = true, cooldown = Config.alarmCooldown, lastAlertAt = 0, revision = 0 }
end

local function items(id, source, physical)
    local result = {}
    for _, item in pairs(source) do
        if item.propertyId == id and (item.status == nil or item.status == 'placed') then
            local value = Housing.copy(item)
            if physical then value.ownerCid, value.leaseId, value.claimedBy, value.claimTarget = nil, nil, nil, nil end
            result[#result + 1] = value
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

function World.scene(id)
    local property, space = State.get(id), World.spaces[id]
    if not property or not space then return nil end
    return { propertyId = id, label = property.label, space = Housing.copy(space), interior = Housing.publicInterior(property),
        fixtures = Housing.legacy.fixtureData(property),
        furniture = items(id, World.furniture, true), cameras = items(id, World.cameras, true) }
end

function World.publicSpaces()
    local result = {}
    for id, space in pairs(World.spaces) do
        local property = State.get(id)
        if property and property.state ~= 'archived' then
            local center = { x = 0, y = 0, z = (space.bounds.minZ + space.bounds.maxZ) / 2 }
            for _, point in ipairs(space.bounds.points) do center.x, center.y = center.x + point.x / #space.bounds.points, center.y + point.y / #space.bounds.points end
            local radius = 0
            for _, point in ipairs(space.bounds.points) do radius = math.max(radius, math.sqrt(distance(center, point))) end
            result[#result + 1] = { propertyId = id, bounds = Housing.copy(space.bounds), origin = Housing.copy(space.origin), revision = space.revision, center = center, radius = radius + 50 }
        end
    end
    return result
end

local function broadcast(id)
    local scene = World.scene(id)
    for src, subscriptions in pairs(subscribers) do
        if subscriptions[id] then TriggerClientEvent('qbhousing:client:sceneChanged', src, scene) end
    end
end

function World.snapshot(src, id)
    local current = State.get(id)
    if not World.ready or not State.ready or not current or current.state == 'archiving' or current.state == 'archived' or uncertain(id) then return false, 'Property is unavailable.' end
    local property, err = authorize(src, id, 'entry', false)
    if not property and not Permissions.can(src, id, 'property.edit') and not Permissions.can(src, id, 'camera.manage') and not Permissions.can(src, id, 'camera.view') then return false, err end
    local grants = {}
    if Permissions.can(src, id, 'camera.manage') then
        for cid, expires in pairs(World.grants[id] or {}) do grants[#grants + 1] = { citizenid = cid, expiresAt = expires } end
    end
    return true, { space = Housing.copy(World.spaces[id]), furniture = items(id, World.furniture), cameras = items(id, World.cameras),
        alarm = Housing.copy(alarm(id)), grants = grants, models = Housing.copy(Config.furnitureModels) }
end

function World.configureSpace(src, id, payload, revision)
    return State.withWrite(id, function()
        local property, err = authorize(src, id, 'property.edit')
        if not property then return false, err end
        local previous = World.spaces[id]
        if revision ~= (previous and previous.revision or 0) then return false, 'The physical space changed. Refresh it first.' end
        if type(payload) ~= 'table' or not boundsValid(payload.bounds) then return false, 'Use a valid polygon and height bounds for the physical space.' end
        if property.interior and property.interior.type == 'shell' and not Housing.validCoords(payload.origin) then return false, 'A shell requires a physical origin.' end
        if payload.origin and (not Housing.validCoords(payload.origin) or not contains(payload.bounds, payload.origin)) then return false, 'Shell origin must be inside its physical boundary.' end
        if property.interior and property.interior.type == 'shell' then
            local exit = property.interior.exit
            if not exit or not contains(payload.bounds, { x = payload.origin.x + exit.x, y = payload.origin.y + exit.y, z = payload.origin.z + exit.z }) then return false, 'The shell exit must stay inside its physical boundary.' end
        end
        for otherId, space in pairs(World.spaces) do
            local other = State.get(otherId)
            if otherId ~= id and other and other.state ~= 'archived' and overlaps(payload.bounds, space.bounds) then return false, 'This space overlaps another property.' end
        end
        for _, furniture in ipairs(items(id, World.furniture)) do if not contains(payload.bounds, furniture.coords) then return false, 'Move existing furniture inside the new boundary first.' end end
        for _, camera in ipairs(items(id, World.cameras)) do if not contains(payload.bounds, camera.coords) or not contains(payload.bounds, camera.console) then return false, 'Move existing cameras inside the new boundary first.' end end
        local value = { propertyId = id, origin = Housing.copy(payload.origin), bounds = Housing.copy(payload.bounds), revision = revision + 1 }
        local statement = previous and { query = 'UPDATE `qbhousing_spaces` SET `definition`=?,`revision`=? WHERE `property_id`=? AND `revision`=?', values = { json.encode(value), value.revision, id, revision }, expectedRows = 1 }
            or { query = 'INSERT INTO `qbhousing_spaces` (`property_id`,`definition`,`revision`) VALUES (?,?,?)', values = { id, json.encode(value), value.revision }, expectedRows = 1 }
        local ok, saveErr = checked({ statement }, src, id, 'space.configure')
        if not ok then return false, saveErr end
        World.spaces[id] = value
        World.changed(id)
        TriggerClientEvent('qbhousing:client:spacesChanged', -1, World.publicSpaces())
        broadcast(id)
        return World.snapshot(src, id)
    end)
end

local function limit(id)
    local property = State.get(id)
    return Config.furnitureLimits[property.propertyType] or Config.maxFurniture
end

local function validTransform(value, space)
    return type(value) == 'table' and Housing.validCoords(value.coords) and contains(space.bounds, value.coords)
        and type(value.rotation) == 'table' and Housing.finite(value.rotation.pitch) and Housing.finite(value.rotation.roll)
        and Housing.finite(value.rotation.yaw) and (value.heading == nil or Housing.finite(value.heading))
        and math.abs(value.rotation.pitch) <= 360 and math.abs(value.rotation.roll) <= 360 and math.abs(value.rotation.yaw) <= 360
end

local function cancelPlacement(key, reason)
    local session = placements[key]
    if not session then return end
    placements[key] = nil
    TriggerClientEvent('qbhousing:client:placementClosed', session.source, key, session.propertyId, reason)
end

function World.beginPlacement(src, id, model, furnitureId)
    local property, space = authorize(src, id, furnitureId and 'furniture.move' or 'furniture.place', true)
    if not property then return false, space end
    if type(model) ~= 'string' or not Config.furnitureModels[model] then return false, 'Choose a supported furniture model.' end
    local previous = furnitureId and World.furniture[furnitureId]
    local cid = Permissions.citizenId(src)
    local lease = Housing.leases and Housing.leases.active(id)
    if furnitureId and (not previous or previous.propertyId ~= id or previous.status ~= 'placed' or previous.model ~= model) then return false, 'Furniture was not found.' end
    if previous and lease and previous.ownerCid ~= cid then return false, 'You may only move your own furniture during this tenancy.' end
    if not previous and #items(id, World.furniture) >= limit(id) then return false, 'This property has reached its furniture limit.' end
    local key = token()
    for previousKey, session in pairs(placements) do if session.source == src then cancelPlacement(previousKey, 'Another placement was started.') end end
    local session = { token = key, source = src, propertyId = id, model = model, furnitureId = furnitureId, propertyRevision = property.revision,
        spaceRevision = space.revision, revision = previous and previous.revision or 0, leaseId = lease and lease.id, expiresAt = os.time() + 300 }
    placements[key] = session
    SetTimeout(300000, function() if placements[key] == session then cancelPlacement(key, 'Placement authorization expired.') end end)
    return true, { token = key, expiresAt = session.expiresAt, model = model, bounds = Housing.copy(space.bounds),
        transform = previous and Housing.copy(previous) or { coords = Housing.copy(position(src)), rotation = { pitch = 0, roll = 0, yaw = 0 } }, revision = session.revision }
end

local function furnitureWrite(item, previousRevision)
    if previousRevision then return { query = 'UPDATE `qbhousing_furniture` SET `property_id`=?,`owner_cid`=?,`lease_id`=?,`status`=?,`definition`=?,`revision`=? WHERE `id`=? AND `revision`=?',
        values = { item.propertyId, item.ownerCid, item.leaseId or QB.sql.NULL, item.status, json.encode(item), item.revision, item.id, previousRevision }, expectedRows = 1 } end
    return { query = 'INSERT INTO `qbhousing_furniture` (`id`,`property_id`,`owner_cid`,`lease_id`,`status`,`definition`,`revision`) VALUES (?,?,?,?,?,?,?)',
        values = { item.id, item.propertyId, item.ownerCid, item.leaseId or QB.sql.NULL, item.status, json.encode(item), item.revision }, expectedRows = 1 }
end

function World.ownershipStatements(id, buyerCid)
    local statements = {}
    for _, item in pairs(World.furniture) do
        if item.propertyId == id and item.status == 'placed' and not item.leaseId and item.ownerCid ~= buyerCid then
            local value = Housing.copy(item)
            value.ownerCid, value.revision = buyerCid, value.revision + 1
            statements[#statements + 1] = furnitureWrite(value, item.revision)
        end
    end
    statements[#statements + 1] = { query = 'DELETE FROM `qbhousing_camera_grants` WHERE `property_id`=?', values = { id } }
    return statements
end

function World.ownershipChanged(id, buyerCid)
    for _, item in pairs(World.furniture) do
        if item.propertyId == id and item.status == 'placed' and not item.leaseId and item.ownerCid ~= buyerCid then item.ownerCid, item.revision = buyerCid, item.revision + 1 end
    end
    World.grants[id] = nil
    World.changed(id)
    broadcast(id)
end

function World.archive(id)
    if not World.ready then return false, 'Property world storage is unavailable.' end
    return State.withWrite(id, function()
        if not State.get(id) then return false, 'Property was not found.' end
        local statements, changes = {}, {}
        for _, item in pairs(World.furniture) do
            if item.propertyId == id and item.status == 'placed' then
                local value = Housing.copy(item)
                value.status, value.revision = 'recovery', value.revision + 1
                statements[#statements + 1], changes[value.id] = furnitureWrite(value, item.revision), value
            end
        end
        statements[#statements + 1] = { query = 'DELETE FROM `qbhousing_camera_grants` WHERE `property_id`=?', values = { id } }
        local ok, err = checked(statements, nil, id, 'world.archive')
        if not ok then return false, err end
        for key, value in pairs(changes) do World.furniture[key] = value end
        World.grants[id] = nil
        for src, session in pairs(viewers) do if session.propertyId == id then World.closeCamera(src, session.token) end end
        World.changed(id)
        broadcast(id)
        return true
    end)
end

function World.savePlacement(src, id, key, transform, revision)
    return State.withWrite(id, function()
        local session = placements[key]
        if not session or session.source ~= src or session.propertyId ~= id or session.expiresAt <= os.time() then return false, 'Placement session expired.' end
        local property, space = authorize(src, id, session.furnitureId and 'furniture.move' or 'furniture.place', true)
        if not property then return false, space end
        if property.revision ~= session.propertyRevision or space.revision ~= session.spaceRevision or revision ~= session.revision then return false, 'Property access or furniture changed. Start placement again.' end
        if not validTransform(transform, space) then return false, 'Furniture must have a valid transform inside this property.' end
        if not session.furnitureId and #items(id, World.furniture) >= limit(id) then return false, 'This property has reached its furniture limit.' end
        local previous = session.furnitureId and World.furniture[session.furnitureId]
        local lease = Housing.leases and Housing.leases.active(id)
        if (lease and lease.id) ~= session.leaseId then return false, 'The tenancy changed. Start placement again.' end
        if session.furnitureId and (not previous or previous.status ~= 'placed' or previous.revision ~= revision) then return false, 'Furniture changed. Refresh it first.' end
        local value = { id = session.furnitureId or key, propertyId = id, ownerCid = previous and previous.ownerCid or Permissions.citizenId(src), leaseId = previous and previous.leaseId or session.leaseId,
            status = 'placed', model = session.model, coords = Housing.copy(transform.coords), rotation = Housing.copy(transform.rotation), heading = transform.heading or transform.rotation.yaw, revision = revision + 1 }
        local ok, err = checked({ furnitureWrite(value, previous and previous.revision) }, src, id, previous and 'furniture.move' or 'furniture.place', { furniture = value.id })
        if not ok then return false, err end
        World.furniture[value.id], placements[key] = value, nil
        broadcast(id)
        return World.snapshot(src, id)
    end)
end

function World.removeFurniture(src, id, furnitureId, revision)
    return State.withWrite(id, function()
        local property, err = authorize(src, id, 'furniture.remove', true)
        if not property then return false, err end
        local item = World.furniture[furnitureId]
        if not item or item.propertyId ~= id or item.status ~= 'placed' or item.revision ~= revision then return false, 'Furniture changed or was removed.' end
        local lease = Housing.leases and Housing.leases.active(id)
        if lease and item.ownerCid ~= Permissions.citizenId(src) then return false, 'You may only remove your own furniture during this tenancy.' end
        local value = Housing.copy(item)
        value.status, value.revision = 'removed', value.revision + 1
        local ok, saveErr = checked({ furnitureWrite(value, revision) }, src, id, 'furniture.remove', { furniture = item.id })
        if not ok then return false, saveErr end
        World.furniture[item.id] = value
        broadcast(id)
        return World.snapshot(src, id)
    end)
end

function World.recoverLease(id, leaseId, cid, alreadyLocked)
    local function recover()
        local statements, changes = {}, {}
        for _, item in pairs(World.furniture) do
            if item.propertyId == id and item.leaseId == leaseId and item.ownerCid == cid and item.status == 'placed' then
                local value = Housing.copy(item)
                value.status, value.revision = 'recovery', value.revision + 1
                statements[#statements + 1], changes[item.id] = furnitureWrite(value, item.revision), value
            end
        end
        if #statements == 0 then return true end
        local ok, err = checked(statements, nil, id, 'furniture.recover', { lease = leaseId })
        if not ok then return false, err end
        for furnitureId, value in pairs(changes) do World.furniture[furnitureId] = value end
        broadcast(id)
        return true
    end
    if alreadyLocked then return recover() end
    return State.withWrite(id, recover)
end

function World.recovery(src)
    local cid, result = Permissions.citizenId(src), {}
    for _, item in pairs(World.furniture) do if item.status == 'recovery' and item.ownerCid == cid then result[#result + 1] = Housing.copy(item) end end
    return result
end

function World.claimFurniture(src, furnitureId, targetId, transform)
    return State.withWrite(targetId, function()
        local property, space = authorize(src, targetId, 'furniture.place', true)
        if not property then return false, space end
        local cid, item = Permissions.citizenId(src), World.furniture[furnitureId]
        if not item or item.ownerCid ~= cid then return false, 'Recovery entitlement was not found.' end
        if item.status == 'placed' and item.claimTarget == targetId and item.claimedBy == cid then return true, Housing.copy(item) end
        if item.status ~= 'recovery' or not validTransform(transform, space) then return false, 'Choose a valid placement for this recovery item.' end
        if #items(targetId, World.furniture) >= limit(targetId) then return false, 'The destination property is full.' end
        local sourceId, value = item.propertyId, Housing.copy(item)
        value.propertyId, value.status, value.coords, value.rotation = targetId, 'placed', Housing.copy(transform.coords), Housing.copy(transform.rotation)
        value.heading, value.revision, value.claimTarget, value.claimedBy = transform.heading or transform.rotation.yaw, value.revision + 1, targetId, cid
        local lease = Housing.leases and Housing.leases.active(targetId)
        value.leaseId = lease and lease.id
        local ok, err = checked({ furnitureWrite(value, item.revision) }, src, targetId, 'furniture.claim', { furniture = furnitureId })
        if not ok then return false, err end
        World.furniture[furnitureId] = value
        broadcast(sourceId)
        if sourceId ~= targetId then broadcast(targetId) end
        return true, Housing.copy(value)
    end)
end

function World.hasCameraGrantByCitizen(cid, id)
    local expires = (World.grants[id] or {})[cid]
    return not uncertain(id) and expires ~= nil and expires > os.time()
end

function World.hasCameraGrant(src, id) return World.hasCameraGrantByCitizen(Permissions.citizenId(src), id) end

local function closeViewer(src, reason)
    if not viewers[src] then return end
    viewers[src] = nil
    TriggerClientEvent('qbhousing:client:cameraClosed', src, reason or 'Camera session ended.')
end

function World.changed(id)
    for src, session in pairs(viewers) do
        local property = State.get(session.propertyId)
        local lease = Housing.leases and Housing.leases.active(session.propertyId)
        local space = World.spaces[session.propertyId]
        if (not id or id == session.propertyId) and (uncertain(session.propertyId) or not property or not space or space.revision ~= session.spaceRevision or property.revision ~= session.propertyRevision
            or (lease and lease.id) ~= session.leaseId or not Permissions.can(src, session.propertyId, 'camera.view')) then closeViewer(src, 'Camera access changed.') end
    end
    for key, session in pairs(placements) do
        local property, space = State.get(session.propertyId), World.spaces[session.propertyId]
        local lease = Housing.leases and Housing.leases.active(session.propertyId)
        if (not id or session.propertyId == id) and (uncertain(session.propertyId) or not property or property.state == 'archiving' or property.state == 'archived' or not space
            or property.revision ~= session.propertyRevision or space.revision ~= session.spaceRevision or (lease and lease.id) ~= session.leaseId
            or not Permissions.can(session.source, session.propertyId, session.furnitureId and 'furniture.move' or 'furniture.place')) then cancelPlacement(key, 'Property access or placement settings changed.') end
    end
    for src, propertyId in pairs(occupants) do
        if (not id or propertyId == id) and (uncertain(propertyId) or not Permissions.can(src, propertyId, 'entry')) then World.leave(src); TriggerClientEvent('qbhousing:client:leaveProperty', src) end
    end
    local changed = false
    for propertyId in pairs(World.spaces) do
        local property = State.get(propertyId)
        if (not id or id == propertyId) and property and publishedRevisions[propertyId] ~= property.revision then
            publishedRevisions[propertyId], changed = property.revision, true
            broadcast(propertyId)
        end
    end
    if changed then TriggerClientEvent('qbhousing:client:spacesChanged', -1, World.publicSpaces()) end
end

function World.saveCamera(src, id, payload, revision)
    return State.withWrite(id, function()
        local property, space = authorize(src, id, 'camera.manage', true)
        if not property then return false, space end
        if type(payload) ~= 'table' or not validTransform(payload, space) or not Housing.validCoords(payload.console) or not contains(space.bounds, payload.console)
            or not Housing.finite(payload.fov) or payload.fov < 20 or payload.fov > 100 or type(payload.label) ~= 'string' or #payload.label < 1 or #payload.label > 80 then return false, 'Enter valid camera, console, field of view and name settings.' end
        local previous = payload.id and World.cameras[payload.id]
        if payload.id and (not previous or previous.propertyId ~= id or previous.revision ~= revision) then return false, 'Camera changed. Refresh it first.' end
        if not previous and #items(id, World.cameras) >= Config.maxCameras then return false, 'This property has reached its camera limit.' end
        local value = { id = previous and previous.id or token(), propertyId = id, label = payload.label, coords = Housing.copy(payload.coords), rotation = Housing.copy(payload.rotation),
            console = Housing.copy(payload.console), fov = payload.fov, model = Config.cameraModel, revision = previous and previous.revision + 1 or 1 }
        local statement = previous and { query = 'UPDATE `qbhousing_cameras` SET `definition`=?,`revision`=? WHERE `id`=? AND `revision`=?', values = { json.encode(value), value.revision, value.id, revision }, expectedRows = 1 }
            or { query = 'INSERT INTO `qbhousing_cameras` (`id`,`property_id`,`definition`,`revision`) VALUES (?,?,?,?)', values = { value.id, id, json.encode(value), value.revision }, expectedRows = 1 }
        local ok, err = checked({ statement }, src, id, 'camera.save', { camera = value.id })
        if not ok then return false, err end
        World.cameras[value.id] = value
        if not previous then
            for occupant, propertyId in pairs(occupants) do if propertyId == id then TriggerClientEvent('qbhousing:client:cameraPresence', occupant, property.label) end end
        end
        for viewer, session in pairs(viewers) do if session.cameraId == value.id then closeViewer(viewer, 'Camera configuration changed.') end end
        broadcast(id)
        return World.snapshot(src, id)
    end)
end

function World.removeCamera(src, id, cameraId, revision)
    return State.withWrite(id, function()
        local property, err = authorize(src, id, 'camera.manage', true)
        if not property then return false, err end
        local camera = World.cameras[cameraId]
        if not camera or camera.propertyId ~= id or camera.revision ~= revision then return false, 'Camera was not found or changed.' end
        local ok, saveErr = checked({ { query = 'DELETE FROM `qbhousing_cameras` WHERE `id`=? AND `revision`=?', values = { cameraId, revision }, expectedRows = 1 } }, src, id, 'camera.remove', { camera = cameraId })
        if not ok then return false, saveErr end
        World.cameras[cameraId] = nil
        for viewer, session in pairs(viewers) do if session.cameraId == cameraId then closeViewer(viewer, 'Camera removed.') end end
        broadcast(id)
        return World.snapshot(src, id)
    end)
end

function World.grantCamera(src, id, cid, expiresAt)
    return State.withWrite(id, function()
        local property, err = authorize(src, id, 'camera.manage')
        if not property then return false, err end
        local owner = Permissions.citizenId(src)
        if property.owner ~= owner and not (property.coowners and property.coowners[owner]) then return false, 'Only property owners can authorize camera viewing.' end
        if type(cid) ~= 'string' or #cid < 1 or #cid > 50 then return false, 'A valid citizen ID is required.' end
        local target = QB.sql.single('SELECT `citizenid` FROM `players` WHERE `citizenid`=? AND `deleted_at` IS NULL', { cid })
        if not target then return false, 'Character was not found.' end
        expiresAt = expiresAt or os.time() + Config.cameraGrantSeconds
        if not Housing.finite(expiresAt) or expiresAt % 1 ~= 0 or expiresAt <= os.time() or expiresAt > os.time() + Config.cameraGrantSeconds then return false, 'Camera authorization must expire within the configured maximum duration.' end
        local ok, saveErr = checked({ { query = 'INSERT INTO `qbhousing_camera_grants` (`property_id`,`citizenid`,`expires_at`) VALUES (?,?,?) ON DUPLICATE KEY UPDATE `expires_at`=VALUES(`expires_at`)', values = { id, cid, expiresAt } } }, src, id, 'camera.grant', { subject = cid, expiresAt = expiresAt })
        if not ok then return false, saveErr end
        World.grants[id] = World.grants[id] or {}; World.grants[id][cid] = expiresAt
        SetTimeout(math.max(1, (expiresAt - os.time()) * 1000), function() World.changed(id) end)
        return World.snapshot(src, id)
    end)
end

function World.revokeCamera(src, id, cid)
    return State.withWrite(id, function()
        local property, err = authorize(src, id, 'camera.manage')
        if not property then return false, err end
        local owner = Permissions.citizenId(src)
        if property.owner ~= owner and not (property.coowners and property.coowners[owner]) then return false, 'Only property owners can revoke camera viewing.' end
        if type(cid) ~= 'string' then return false, 'A citizen ID is required.' end
        local ok, saveErr = checked({ { query = 'DELETE FROM `qbhousing_camera_grants` WHERE `property_id`=? AND `citizenid`=?', values = { id, cid } } }, src, id, 'camera.revoke', { subject = cid })
        if not ok then return false, saveErr end
        if World.grants[id] then World.grants[id][cid] = nil end
        World.changed(id)
        return World.snapshot(src, id)
    end)
end

function World.openCamera(src, id, cameraId)
    local property, space = authorize(src, id, 'camera.view')
    if not property then return false, space end
    local camera = World.cameras[cameraId]
    if not space or not camera or camera.propertyId ~= id or not near(src, camera.console, 3) or not near(src, camera.coords, 100) then return false, 'Use the physical security console within 100 metres of this camera.' end
    local count = 0
    for viewer, session in pairs(viewers) do if viewer ~= src and session.propertyId == id then count = count + 1 end end
    if count >= Config.maxCameraViewers then return false, 'This property has reached its viewer limit.' end
    local key, expires = token(), os.time() + Config.cameraSessionSeconds
    local lease = Housing.leases and Housing.leases.active(id)
    viewers[src] = { token = key, propertyId = id, cameraId = cameraId, propertyRevision = property.revision, spaceRevision = space.revision, leaseId = lease and lease.id, expiresAt = expires }
    SetTimeout(Config.cameraSessionSeconds * 1000, function() if viewers[src] and viewers[src].token == key then closeViewer(src, 'Camera authorization expired.') end end)
    for occupant, propertyId in pairs(occupants) do if propertyId == id then TriggerClientEvent('qbhousing:client:cameraNotice', occupant, property.label) end end
    return true, { token = key, camera = Housing.copy(camera), expiresAt = expires, scene = World.scene(id) }
end

function World.switchCamera(src, key, cameraId)
    local session = viewers[src]
    if not session or session.token ~= key or session.expiresAt <= os.time() then return false, 'Camera session expired.' end
    local ok, result = World.openCamera(src, session.propertyId, cameraId)
    if not ok then return false, result end
    viewers[src].expiresAt, result.expiresAt = session.expiresAt, session.expiresAt
    SetTimeout(math.max(1, (session.expiresAt - os.time()) * 1000), function()
        if viewers[src] and viewers[src].token == result.token then closeViewer(src, 'Camera authorization expired.') end
    end)
    return true, result
end

function World.closeCamera(src, key)
    if viewers[src] and viewers[src].token == key then closeViewer(src) end
    return true
end

local function saveAlarm(src, id, value, action)
    local previous = World.alarms[id]
    value.revision = (previous and previous.revision or 0) + 1
    local statement = previous and { query = 'UPDATE `qbhousing_alarms` SET `definition`=?,`revision`=? WHERE `property_id`=? AND `revision`=?', values = { json.encode(value), value.revision, id, previous.revision }, expectedRows = 1 }
        or { query = 'INSERT INTO `qbhousing_alarms` (`property_id`,`definition`,`revision`) VALUES (?,?,?)', values = { id, json.encode(value), value.revision }, expectedRows = 1 }
    local ok, err = checked({ statement }, src, id, action)
    if not ok then return false, err end
    World.alarms[id] = value
    return true
end

function World.setAlarm(src, id, armed, revision)
    return State.withWrite(id, function()
        local property, err = authorize(src, id, 'alarm.arm')
        if not property then return false, err end
        local value = Housing.copy(alarm(id))
        if type(armed) ~= 'boolean' or revision ~= value.revision then return false, 'Alarm settings changed. Refresh them first.' end
        value.armed = armed
        local ok, saveErr = saveAlarm(src, id, value, 'alarm.arm')
        if not ok then return false, saveErr end
        return World.snapshot(src, id)
    end)
end

function World.configureAlarm(src, id, payload, revision)
    return State.withWrite(id, function()
        local property, err = authorize(src, id, 'alarm.configure')
        if not property then return false, err end
        local value = Housing.copy(alarm(id))
        if type(payload) ~= 'table' or type(payload.doorUnlock) ~= 'boolean' or type(payload.panic) ~= 'boolean'
            or not Housing.finite(payload.cooldown) or payload.cooldown % 1 ~= 0 or payload.cooldown < 10 or payload.cooldown > 86400 or revision ~= value.revision then return false, 'Use valid alarm triggers and a 10–86400 second cooldown.' end
        value.doorUnlock, value.panic, value.cooldown = payload.doorUnlock, payload.panic, payload.cooldown
        local ok, saveErr = saveAlarm(src, id, value, 'alarm.configure')
        if not ok then return false, saveErr end
        return World.snapshot(src, id)
    end)
end

local function dispatchAlarm(src, id, trigger)
    return State.withWrite(id, function()
        local property, value = State.get(id), Housing.copy(alarm(id))
        if not property or property.state == 'archived' or property.state == 'archiving' or not value.armed or not value[trigger] or os.time() < value.lastAlertAt + value.cooldown then return false, 'Alarm is disarmed or cooling down.' end
        local here = property.interior and property.interior.entrance or World.spaces[id] and World.spaces[id].bounds.points[1]
        if not here then return false, 'Configure a property location first.' end
        value.lastAlertAt = os.time()
        local ok, err = saveAlarm(src, id, value, 'alarm.trigger')
        if not ok then return false, err end
        local sent, callId, reason = pcall(function() return exports.qbdispatch:createCall({ jobs = { 'police' }, code = 'HSG-ALARM', title = 'Property alarm',
            message = property.label .. (trigger == 'panic' and ' · Panic alarm' or ' · Unauthorized door access'), coords = here, priority = 2, duration = 120000, data = { propertyId = id, trigger = trigger } }) end)
        if not sent or not callId then return false, reason or 'Dispatch is unavailable; the alarm event was recorded.' end
        return true, { callId = callId }
    end)
end

function World.panic(src, id)
    local property, err = authorize(src, id, 'alarm.arm', true)
    if not property then return false, err end
    return dispatchAlarm(src, id, 'panic')
end

function World.doorUnlocked(src, id)
    if type(src) ~= 'number' or src <= 0 or Permissions.isAdmin(src) or Permissions.can(src, id, 'entry') then return end
    return dispatchAlarm(src, id, 'doorUnlock')
end

function World.subscribe(src, id, enabled)
    if enabled == false then if subscribers[src] then subscribers[src][id] = nil end; return true end
    local space = World.spaces[id]
    local nearby = false
    for _, descriptor in ipairs(World.publicSpaces()) do if descriptor.propertyId == id then nearby = near(src, descriptor.center, descriptor.radius); break end end
    if not space or not nearby then return false, 'You are not near this physical space.' end
    subscribers[src] = subscribers[src] or {}; subscribers[src][id] = true
    return true, World.scene(id)
end

function World.enter(src, id)
    local property, space = authorize(src, id, 'entry')
    if not property then return false, space end
    local entrance = property.interior and property.interior.entrance
    if not entrance or not near(src, entrance, 5) then return false, 'Use the property entrance.' end
    if not space then
        if property.interior.type == 'shell' then
            local view = State.publicProperty(property)
            view.fixtures, view.furniture = Housing.legacy.fixtureData(property), items(id, World.furniture, true)
            occupants[src], occupantCitizenIds[src], occupantSessions[src] = id, Permissions.citizenId(src), {}; TriggerClientEvent('qbhousing:client:enterShell', src, view); return true
        end
        return false, 'Configure this physical space first.'
    end
    occupants[src], occupantCitizenIds[src], occupantSessions[src] = id, Permissions.citizenId(src), {}
    subscribers[src] = subscribers[src] or {}; subscribers[src][id] = true
    TriggerClientEvent('qbhousing:client:enteredProperty', src, World.scene(id), entrance)
    if #items(id, World.cameras) > 0 then TriggerClientEvent('qbhousing:client:cameraPresence', src, property.label) end
    return true
end

function World.occupies(src, id) return occupants[src] == id and occupantCitizenIds[src] == Permissions.citizenId(src) end

function World.occupancy(src, id) return World.occupies(src, id) and occupantSessions[src] or nil end

function World.leave(src, expectedSession)
    if expectedSession and occupantSessions[src] ~= expectedSession then return false end
    local id = occupants[src]
    occupants[src], occupantCitizenIds[src], occupantSessions[src] = nil, nil, nil
    if id and subscribers[src] then subscribers[src][id] = nil end
    closeViewer(src)
    for key, session in pairs(placements) do if session.source == src then cancelPlacement(key, 'You left the property.') end end
    return true
end

function World.reconcileProperty(id)
    local names, statements = { 'spaces', 'furniture', 'cameras', 'alarms', 'camera_grants' }, {}
    for _, name in ipairs(names) do statements[#statements + 1] = { query = 'SELECT * FROM `qbhousing_' .. name .. '` WHERE `property_id`=?', values = { id } } end
    local result, err = QB.sql.transactionChecked(statements)
    if not result or not result.success or type(result.results) ~= 'table' then return false, err or result and result.message or 'Physical property recovery is unavailable.' end
    local loaded = { spaces = {}, furniture = {}, cameras = {}, alarms = {}, grants = {} }
    for index, name in ipairs(names) do
        if type(result.results[index]) ~= 'table' then return false, 'Physical property recovery returned invalid rows.' end
        if not State.get(id) and #result.results[index] > 0 then return false, 'Physical property recovery found orphan records.' end
        for _, row in ipairs(result.results[index]) do
            if row.property_id ~= id then return false, 'Physical property recovery returned an unrelated row.' end
            if name == 'camera_grants' then
                local expiry = tonumber(row.expires_at)
                if type(row.citizenid) ~= 'string' or not expiry then return false, 'Invalid camera authorization record.' end
                loaded.grants[row.citizenid] = expiry
            else
                local ok, value = pcall(json.decode, row.definition)
                if not ok or type(value) ~= 'table' or not tonumber(row.revision) then return false, 'Invalid persistent physical property record.' end
                value.propertyId, value.revision = id, tonumber(row.revision)
                if name == 'spaces' and not boundsValid(value.bounds) then return false, 'Invalid persistent space boundary.' end
                if name == 'furniture' then value.id, value.ownerCid, value.leaseId, value.status = row.id, row.owner_cid, row.lease_id, row.status end
                if name == 'cameras' then value.id = row.id end
                loaded[name][row.id or id] = value
            end
        end
    end
    for _, name in ipairs({ 'spaces', 'furniture', 'cameras', 'alarms' }) do
        for key, value in pairs(World[name]) do if value.propertyId == id then World[name][key] = nil end end
        for key, value in pairs(loaded[name]) do World[name][key] = value end
    end
    World.grants[id] = loaded.grants
    for _, expiry in pairs(loaded.grants) do if expiry > os.time() then SetTimeout((expiry - os.time()) * 1000, function() World.changed(id) end) end end
    World.changed(id)
    broadcast(id)
    TriggerClientEvent('qbhousing:client:spacesChanged', -1, World.publicSpaces())
    return true
end

function World.load()
    local loaded = { spaces = {}, furniture = {}, cameras = {}, alarms = {}, grants = {} }
    for _, name in ipairs({ 'spaces', 'furniture', 'cameras', 'alarms' }) do
        local rows, err = QB.sql.query('SELECT * FROM `qbhousing_' .. name .. '`')
        if not rows then return false, err end
        for _, row in ipairs(rows) do
            local ok, value = pcall(json.decode, row.definition)
            if not ok or type(value) ~= 'table' or not State.get(row.property_id) then return false, 'Invalid persistent physical property record.' end
            value.propertyId, value.revision = row.property_id, tonumber(row.revision)
            if name == 'spaces' and not boundsValid(value.bounds) then return false, 'Invalid persistent space boundary.' end
            if name == 'furniture' then value.id, value.ownerCid, value.leaseId, value.status = row.id, row.owner_cid, row.lease_id, row.status end
            if name == 'cameras' then value.id = row.id end
            loaded[name][row.id or row.property_id] = value
        end
    end
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_camera_grants`')
    if not rows then return false, err end
    for _, row in ipairs(rows) do
        loaded.grants[row.property_id] = loaded.grants[row.property_id] or {}
        loaded.grants[row.property_id][row.citizenid] = tonumber(row.expires_at)
        if tonumber(row.expires_at) > os.time() then SetTimeout((tonumber(row.expires_at) - os.time()) * 1000, function() World.changed(row.property_id) end) end
    end
    for key, values in pairs(loaded) do World[key] = values end
    World.ready = true
    return true
end

AddEventHandler('playerDropped', function()
    local src = source
    World.leave(src)
    subscribers[src] = nil
    for key, session in pairs(placements) do if session.source == src then placements[key] = nil end end
end)

AddEventHandler('qbdoorlock:stateChanged', function(src, doorId, locked)
    if locked then return end
    for id, property in pairs(State.properties) do
        for _, door in pairs(property.doorlocks or {}) do
            if tostring(type(door) == 'table' and door.id or door) == tostring(doorId) then World.doorUnlocked(src, id); return end
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for src in pairs(viewers) do closeViewer(src, 'Housing stopped.') end
    for src in pairs(occupants) do TriggerClientEvent('qbhousing:client:leaveProperty', src) end
end)
