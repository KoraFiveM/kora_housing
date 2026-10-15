Housing.permissions = {}

local Permissions = Housing.permissions
local State = Housing.state

local function player(src)
    if type(src) ~= 'number' or src < 1 or src % 1 ~= 0 then return nil end
    local ok, data = pcall(function() return exports.qbcore:getPlayer(src) end)
    if not ok or type(data) ~= 'table' or type(data.citizenid) ~= 'string' or data.citizenid == '' then return nil end
    return data
end

local function property(value)
    return State.get(type(value) == 'table' and value.id or value)
end

local function isAdmin(src)
    local ok, allowed = pcall(function() return QB.permissions.hasPermission(src, 'admin', 'qbcore') end)
    return ok and allowed == true
end

local function isRealtor(data)
    return data ~= nil and type(data.job) == 'table' and data.job.name == Config.realtorJob
end

local function relationship(record, cid, admin, realtor)
    if record.owner == cid then return 'primary_owner' end
    if record.coowners and record.coowners[cid] == true then return 'coowner' end
    if Housing.leases and Housing.leases.active(record.id) and Housing.leases.active(record.id).tenant == cid then return 'tenant' end
    if admin then return 'admin' end
    if record.keys and record.keys[cid] == true then return 'keyholder' end
    if realtor then return 'agent' end
    return 'guest'
end

local function can(record, action, cid, admin, realtor)
    if action == 'property.create' then
        if admin or realtor then return true end
        return false, 'Only realtors or administrators can create properties.'
    end
    if not record then return false, 'Property not found.' end
    if record.state == 'archived' or record.state == 'archiving' then return false, 'This property is archived.' end
    if State.isUncertain and State.isUncertain(record.id) then return false, 'This property is being reconciled after a database interruption.' end
    if Housing.transactions and Housing.transactions.busy(record.id) then return false, 'A payment is being confirmed for this property.' end
    local primary = record.owner == cid
    local owner = primary or record.coowners and record.coowners[cid] == true
    if action == 'coowners.manage' then
        if primary then return true end
        return false, 'Only the primary owner can manage co-owners.'
    end
    if action == 'permissions.manage' then
        if owner then return true end
        return false, 'Only owners can manage property permissions.'
    end
    if action == 'property.archive' then
        if admin then return true end
        return false, 'Only administrators can archive properties.'
    end
    if Housing.leases then
        local allowed = Housing.leases.permission(nil, record, action, cid)
        if allowed ~= nil then return allowed, allowed and nil or 'The active tenant controls physical access.' end
        local lease = Housing.leases.active(record.id)
        if lease and lease.tenant == cid and Housing.grantablePermissions[action] and action ~= 'camera.view' then
            local grant = record.permissionGrants and record.permissionGrants[cid]
            if grant and grant[action] ~= nil then return grant[action] == true, 'Your permission for this action has been revoked.' end
            if lease.permissions[action] ~= nil then return lease.permissions[action] == true, 'This action is not included in your lease.' end
        end
    end
    if owner then return true end
    if action == 'camera.view' then
        local granted = Housing.world and Housing.world.hasCameraGrantByCitizen and Housing.world.hasCameraGrantByCitizen(cid, record.id)
        return granted == true, 'Camera viewing requires a current owner authorization.'
    end
    -- Camera viewing always needs ownership or a named grant, including police staff.
    if admin and action ~= 'camera.view' then return true end
    if action == 'property.edit' and not record.owner and realtor then return true end
    if action == 'sales.manage' and realtor
        and (not record.owner or Housing.domain and Housing.domain.agent(record.id, cid)) then return true end

    local grants = record.permissionGrants and record.permissionGrants[cid]
    if Housing.grantablePermissions[action] and grants and grants[action] ~= nil then
        if grants[action] == true then return true end
        return false, 'Your permission for this action has been revoked.'
    end
    if action == 'entry' and record.keys and record.keys[cid] == true then return true end
    return false, 'You do not have permission to perform this action.'
end

function Permissions.citizenId(src)
    local data = player(src)
    if not data then return nil, 'Player data is unavailable.' end
    return data.citizenid
end

function Permissions.isAdmin(src)
    return player(src) ~= nil and isAdmin(src)
end

function Permissions.isRealtor(src)
    return isRealtor(player(src))
end

function Permissions.relationship(src, value)
    local record = property(value)
    if not record then return nil, 'Property not found.' end
    local data = player(src)
    if not data then return nil, 'Player data is unavailable.' end
    return relationship(record, data.citizenid, isAdmin(src), isRealtor(data))
end

function Permissions.can(src, value, action)
    if type(action) ~= 'string' or not Housing.permissionActions[action] then return false, 'Unknown property action.' end
    local data = player(src)
    if not data then return false, 'Player data is unavailable.' end
    return can(property(value), action, data.citizenid, isAdmin(src), isRealtor(data))
end

function Permissions.snapshot(src, value)
    local record = property(value)
    if not record then return nil, 'Property not found.' end
    local data = player(src)
    if not data then return nil, 'Player data is unavailable.' end
    local admin, realtor = isAdmin(src), isRealtor(data)
    local actions = {}
    for action in pairs(Housing.permissionActions) do
        actions[action] = can(record, action, data.citizenid, admin, realtor) == true
    end
    return { relationship = relationship(record, data.citizenid, admin, realtor), actions = actions, allowed = actions }
end
