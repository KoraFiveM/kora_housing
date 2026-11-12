Housing.ownership = {}

local Ownership = Housing.ownership
local Permissions = Housing.permissions
local State = Housing.state

local function targetExists(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 50 then
        return false, 'Use a valid character ID.'
    end
    local ok, data = pcall(function() return exports.kora_core:getPlayerByCitizenId(citizenid) end)
    if not ok then return false, 'Character lookup is unavailable. Try again.' end
    if data then
        if type(data) ~= 'table' or data.citizenid ~= citizenid then return false, 'Character could not be verified.' end
        return true
    end
    local loaded, offline, err = pcall(function() return exports.kora_core:getOfflinePlayerData(citizenid) end)
    if not loaded or err then return false, 'Character lookup is unavailable. Try again.' end
    if type(offline) ~= 'table' or offline.citizenid ~= citizenid then return false, 'Character not found.' end
    return true
end

local function authorize(src, id, action, expectedRevision)
    local record = State.get(id)
    if not record then return nil, 'Property not found.' end
    if type(expectedRevision) ~= 'number' or expectedRevision < 0 or expectedRevision % 1 ~= 0
        or record.revision ~= expectedRevision then
        return nil, 'This property changed. Refresh it and try again.'
    end
    local allowed, err = Permissions.can(src, record, action)
    if not allowed then return nil, err end
    return record
end

local function locked(id, fn)
    local ok, result = State.withWrite(id, fn)
    return ok == true, result
end

function Ownership.view(src, id)
    local record = State.get(id)
    if not record then return nil, 'Property not found.' end
    if not Permissions.can(src, record, 'permissions.manage') and not Permissions.isAdmin(src) then
        return nil, 'Only owners or administrators can inspect property access.'
    end
    return Housing.copy({
        id = record.id, revision = record.revision, owner = record.owner,
        coowners = record.coowners or {}, permissionGrants = record.permissionGrants or {}, keys = record.keys or {},
    })
end

function Ownership.setCoowner(src, id, action, targetCid, expectedRevision)
    if action ~= 'add' and action ~= 'remove' then return false, 'Invalid co-owner action.' end
    return locked(id, function()
        local record, err = authorize(src, id, 'coowners.manage', expectedRevision)
        if not record then return false, err end
        if targetCid == record.owner then return false, 'The primary owner cannot be a co-owner.' end
        local actor = Permissions.citizenId(src)
        local exists, targetErr = targetExists(targetCid)
        if not exists then return false, targetErr end
        record, err = authorize(src, id, 'coowners.manage', expectedRevision)
        if not record then return false, err end
        if Permissions.citizenId(src) ~= actor then return false, 'Your character changed. Try again.' end
        local coowner = record.coowners and record.coowners[targetCid] == true
        if action == 'add' and coowner then return false, 'That character is already a co-owner.' end
        if action == 'remove' and not coowner then return false, 'That character is not a co-owner.' end

        local changed = Housing.copy(record)
        changed.coowners = changed.coowners or {}
        changed.coowners[targetCid] = action == 'add' and true or nil
        local saved, saveErr = State.persist(changed, {
            actor = actor, action = 'coowner.' .. action, target = targetCid,
        })
        if not saved then return false, saveErr or 'Co-owner change could not be saved.' end
        return true, saved
    end)
end

function Ownership.setPermission(src, id, targetCid, action, allowed, expectedRevision)
    if type(action) ~= 'string' or not Housing.grantablePermissions[action] then
        return false, 'This permission cannot be shared.'
    end
    if allowed ~= nil and type(allowed) ~= 'boolean' then return false, 'Permission must be allowed or denied.' end
    return locked(id, function()
        local record, err = authorize(src, id, 'permissions.manage', expectedRevision)
        if not record then return false, err end
        local actor = Permissions.citizenId(src)
        local exists, targetErr = targetExists(targetCid)
        if not exists then return false, targetErr end
        record, err = authorize(src, id, 'permissions.manage', expectedRevision)
        if not record then return false, err end
        if Permissions.citizenId(src) ~= actor then return false, 'Your character changed. Try again.' end
        if record.owner == targetCid or record.coowners and record.coowners[targetCid] == true then
            return false, 'Owner permissions come from ownership.'
        end

        local changed = Housing.copy(record)
        changed.permissionGrants = changed.permissionGrants or {}
        local grants = changed.permissionGrants[targetCid] or {}
        grants[action] = allowed
        changed.permissionGrants[targetCid] = next(grants) and grants or nil
        if action == 'entry' then
            changed.keys = changed.keys or {}
            changed.keys[targetCid] = allowed == true and true or nil
        end
        local saved, saveErr = State.persist(changed, {
            actor = actor, action = 'permission.update', target = targetCid,
            permission = action, allowed = allowed,
        })
        if not saved then return false, saveErr or 'Permission change could not be saved.' end
        return true, saved
    end)
end
