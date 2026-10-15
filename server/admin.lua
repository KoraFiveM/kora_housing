Housing.admin = {}
local A, D, State, P = Housing.admin, Housing.domain, Housing.state, Housing.permissions
local confirmations, timer = {}, nil

local function inspect(id)
    local property = State.get(id)
    if not property then return nil, 'Property was not found.' end
    if property.state == 'archived' then return nil, 'This property is already archived.' end
    if Housing.properties.configurationBusy() then return nil, 'Wait for the property creator to finish saving.' end
    if Housing.transactions.busy(id) then return nil, 'Wait for the pending payment to finish.' end
    for _, child in pairs(State.properties) do
        if child.parentId == id and child.state ~= 'archived' then return nil, 'Archive or move this building\'s units first.' end
    end
    local leases, err = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_leases` WHERE `property_id`=? AND (`status` IN (?,?,?,?) OR `deposit_remaining`>0)', { id, 'proposed', 'active', 'ending', 'evicting' })
    if leases == nil or tonumber(leases) > 0 then return nil, err or 'Resolve active leases and outstanding deposits first.' end
    if Housing.storage.canArchive then
        local ready, storageErr = Housing.storage.canArchive(id)
        if not ready then return nil, storageErr end
    end
    return property
end

function A.preflight(src, id)
    if not P.isAdmin(src) then return false, 'Only administrators can archive properties.' end
    local property, err = inspect(id)
    if not property then return false, err end
    local token = D.id()
    if not token then return false, 'Confirmation storage is unavailable.' end
    confirmations[src] = { token = token, id = id, revision = property.revision, citizenid = P.citizenId(src), expires = os.time() + 120 }
    return true, { token = token, revision = property.revision,
        summary = 'Listings will close. Furniture and shared owner storage remain claimable through recovery. Vehicles keep their owners and remain retrievable. Ownership, financial history and audit records are retained.' }
end

function A.finish(id)
    local property = State.get(id)
    if not property or property.state == 'archived' then return true end
    if property.state ~= 'archiving' then return false, 'Property archival was not started.' end
    local ready, err = Housing.storage.archive(id)
    if not ready then return false, err end
    ready, err = Housing.world.archive(id)
    if not ready then return false, err end
    return D.lock(id, function()
        property = State.get(id)
        if property.state == 'archived' then return true end
        local changed = Housing.copy(property)
        changed.state = 'archived'
        local saved, saveErr = State.persist(changed, { actor = property.archivedBy, action = 'property.archived' })
        if not saved then return false, saveErr end
        Housing.storage.refresh(id)
        Housing.doors.refresh(id)
        State.broadcast()
        return true, saved
    end)
end

function A.resume()
    timer = nil
    local pending = false
    for id, property in pairs(State.properties) do
        if property.state == 'archiving' then
            local ok, err = A.finish(id)
            if not ok then pending = true; print(('[qbhousing] archival recovery deferred for %s: %s'):format(id, tostring(err))) end
        end
    end
    if pending then timer = QB.timers.setTimeout(A.resume, 30000) end
end

function A.archive(src, id, token)
    if not P.isAdmin(src) then return false, 'Only administrators can archive properties.' end
    local confirmation = confirmations[src]
    confirmations[src] = nil
    if not confirmation or confirmation.token ~= token or confirmation.id ~= id or confirmation.citizenid ~= P.citizenId(src) or confirmation.expires < os.time() then return false, 'Review the property again before confirming archival.' end
    local ok, err = D.lock(id, function()
        local property, inspectErr = inspect(id)
        if not property then return false, inspectErr end
        if property.revision ~= confirmation.revision then return false, 'This property changed. Review it again.' end
        if not property.owner then
            local frozen, freezeErr = Housing.storage.freezeForSale(id)
            if not frozen then return false, freezeErr end
        end
        local changed = Housing.copy(property)
        changed.state, changed.archivedBy, changed.pending = 'archiving', P.citizenId(src), nil
        local writes = {
            { query = 'UPDATE `qbhousing_offers` o JOIN `qbhousing_listings` l ON l.id=o.listing_id SET o.status=? WHERE l.property_id=? AND o.status IN (?,?)', values = { 'cancelled', id, 'submitted', 'accepted' } },
            { query = 'UPDATE `qbhousing_listings` SET `status`=? WHERE `property_id`=? AND `status`=?', values = { 'cancelled', id, 'active' } },
        }
        for _, owner in ipairs(D.owners(property)) do writes[#writes + 1] = { query = 'INSERT IGNORE INTO `qbhousing_garage_recovery` (`property_id`,`citizenid`) VALUES (?,?)', values = { id, owner } } end
        local saved, saveErr = State.persist(changed, { actor = changed.archivedBy, action = 'property.archiveStarted' }, writes)
        return saved ~= nil, saved or saveErr
    end)
    if not ok then return false, err end
    State.broadcast()
    local completed, result = A.finish(id)
    if not completed and not timer then timer = QB.timers.setTimeout(A.resume, 30000) end
    if not completed then return true, { status = 'archiving', message = 'Archival is safely queued and will resume automatically.' } end
    return true, result
end

function A.audit(src, id)
    if not P.isAdmin(src) then return false, 'Only administrators can inspect the audit log.' end
    if not State.get(id) then return false, 'Property was not found.' end
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_audit` WHERE `property_id`=? ORDER BY `id` DESC LIMIT 200', { id })
    return rows ~= nil, rows or err
end

AddEventHandler('playerDropped', function() confirmations[source] = nil end)
AddEventHandler('onResourceStop', function(resource) if resource == GetCurrentResourceName() and timer then QB.timers.clearTimeout(timer) end end)
