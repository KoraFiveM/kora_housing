Housing.state = { properties = {}, ready = false, writes = {}, uncertain = {} }

local State = Housing.state
local recoveryTimer, scheduleRecovery

function State.get(id)
    return type(id) == 'string' and State.properties[id] or nil
end

function State.publicProperty(property)
    local copy = Housing.copy(property)
    if copy then
        copy.coowners, copy.permissionGrants, copy.pending = nil, nil, nil
        if copy.listing and copy.listing.type == 'direct' then copy.listing = nil end
    end
    return copy
end

function State.snapshot()
    local snapshot = {}
    for id, property in pairs(State.properties) do snapshot[id] = State.publicProperty(property) end
    return snapshot
end

function State.broadcast(target)
    if Housing.world and Housing.world.ready then Housing.world.changed() end
    TriggerClientEvent('qbhousing:client:synced', target or -1, State.snapshot())
end

function State.withWrite(id, handler)
    if type(id) ~= 'string' then return nil, 'Invalid property id.' end
    if State.uncertain[id] then return nil, 'This property is being reconciled after a database interruption.' end
    if State.writes[id] then return nil, 'This property is being updated. Please try again.' end
    if Housing.transactions and Housing.transactions.busy(id) then return nil, 'A payment is being confirmed for this property.' end
    State.writes[id] = true
    local result = table.pack(pcall(handler))
    State.writes[id] = nil
    if Housing.storage and Housing.storage.frozen[id] and (not Housing.transactions or not Housing.transactions.busy(id)) then Housing.storage.unfreeze(id) end
    if not result[1] then
        print(('[qbhousing] property write failed for %s: %s'):format(id, tostring(result[2])))
        return nil, 'Property storage is unavailable. Please try again.'
    end
    return table.unpack(result, 2, result.n)
end

local function sameOwners(a, b)
    if not a or a.owner ~= b.owner then return false end
    for cid in pairs(a.coowners or {}) do if not b.coowners[cid] then return false end end
    for cid in pairs(b.coowners) do if not (a.coowners and a.coowners[cid]) then return false end end
    return true
end

function State.prepare(property, audit)
    local value, err = Housing.normalise(Housing.copy(property))
    if not value then return nil, err end
    local previous = State.get(value.id)
    value.revision = (previous and previous.revision or 0) + 1
    value.ownershipRevision = (previous and previous.ownershipRevision or 0) + (sameOwners(previous, value) and 0 or 1)
    if previous and not sameOwners(previous, value) then value.pending = nil end
    local definition = Housing.copy(value)
    definition.coowners, definition.permissionGrants = nil, nil
    local write = { query = 'INSERT INTO `qbhousing_properties` (`id`,`owner`,`definition`,`property_type`,`revision`,`ownership_revision`) VALUES (?,?,?,?,?,?)',
        values = { value.id, value.owner or QB.sql.NULL, json.encode(definition), value.propertyType, value.revision, value.ownershipRevision } }
    if previous then
        write = { query = 'UPDATE `qbhousing_properties` SET `owner`=?,`definition`=?,`property_type`=?,`revision`=?,`ownership_revision`=? WHERE `id`=? AND `revision`=?',
            values = { value.owner or QB.sql.NULL, json.encode(definition), value.propertyType, value.revision, value.ownershipRevision, value.id, previous.revision }, expectedRows = 1 }
    end
    local statements = {
        write,
        { query = 'DELETE FROM `qbhousing_coowners` WHERE `property_id`=?', values = { value.id } },
        { query = 'DELETE FROM `qbhousing_permissions` WHERE `property_id`=?', values = { value.id } },
        { query = 'DELETE FROM `qbhousing_units` WHERE `property_id`=?', values = { value.id } },
    }
    for cid, enabled in pairs(value.coowners) do
        if type(cid) ~= 'string' or #cid < 1 or #cid > 50 or enabled ~= true or cid == value.owner then return nil, 'Invalid co-owner record.' end
        statements[#statements + 1] = { query = 'INSERT INTO `qbhousing_coowners` (`property_id`,`citizenid`) VALUES (?,?)', values = { value.id, cid } }
    end
    for cid, grants in pairs(value.permissionGrants) do
        if type(cid) ~= 'string' or #cid < 1 or #cid > 50 or type(grants) ~= 'table' then return nil, 'Invalid permission subject.' end
        for action, allowed in pairs(grants) do
            if type(action) ~= 'string' or #action > 48 or type(allowed) ~= 'boolean' then return nil, 'Invalid permission record.' end
            statements[#statements + 1] = { query = 'INSERT INTO `qbhousing_permissions` (`property_id`,`citizenid`,`action`,`allowed`) VALUES (?,?,?,?)', values = { value.id, cid, action, allowed and 1 or 0 } }
        end
    end
    if value.parentId then
        statements[#statements + 1] = { query = 'INSERT INTO `qbhousing_units` (`property_id`,`parent_id`,`unit_label`) VALUES (?,?,?)', values = { value.id, value.parentId, value.unitLabel or QB.sql.NULL } }
    end
    audit = audit or { action = 'legacy.write' }
    statements[#statements + 1] = {
        query = 'INSERT INTO `qbhousing_audit` (`property_id`,`actor`,`action`,`target`,`outcome`,`context`) VALUES (?,?,?,?,?,?)',
        values = { value.id, audit.actor or QB.sql.NULL, audit.action or 'property.update', audit.target or QB.sql.NULL, 'success',
            json.encode({ revision = value.revision, ownershipRevision = value.ownershipRevision, permission = audit.permission, allowed = audit.allowed }) },
    }
    return value, statements
end

function State.publish(value)
    State.properties[value.id] = Housing.copy(value)
    return Housing.copy(value)
end

function State.persist(property, audit, extra)
    local value, statements = State.prepare(property, audit)
    if not value then return nil, statements end
    for _, statement in ipairs(extra or {}) do statements[#statements + 1] = statement end
    local key = 'qbhousing:state:' .. value.id
    local result = QB.sql.transactionChecked(statements, { key = key, fingerprint = json.encode(statements) })
    if not result or not result.success then
        if not result or result.code == 'indeterminate' then State.markUncertain(value.id, key) end
        return nil, result and (result.message or result.error) or 'Property storage is unavailable.'
    end
    return State.publish(value)
end

function State.isUncertain(id) return State.uncertain[id] ~= nil end

function State.markUncertain(id, operationKey)
    local pending = State.uncertain[id] or { generation = 0, keys = {} }
    pending.generation = pending.generation + 1
    if operationKey then pending.keys[operationKey] = true end
    State.uncertain[id] = pending
    if Housing.world and Housing.world.changed then pcall(Housing.world.changed, id) end
    scheduleRecovery()
end

local function reconciledProperty(id, results)
    local rows, coowners, grants, units = table.unpack(results)
    if type(rows) ~= 'table' or type(coowners) ~= 'table' or type(grants) ~= 'table' or type(units) ~= 'table' then return nil, 'Property snapshot is unavailable.' end
    if #rows == 0 then
        if #coowners + #grants + #units > 0 then return nil, 'Orphaned property relationships require repair.' end
        return false
    end
    if #rows ~= 1 or #units > 1 then return nil, 'Property snapshot is inconsistent.' end
    local row = rows[1]
    local decoded, raw = pcall(json.decode, row.definition or '')
    if not decoded or type(raw) ~= 'table' or raw.id ~= id or raw.owner ~= row.owner then return nil, 'Stored property identity is inconsistent.' end
    local value, err = Housing.normalise(raw)
    if not value then return nil, err end
    value.propertyType = row.property_type or 'legacy'
    if value.propertyType ~= 'legacy' and not Config.propertyTypes[value.propertyType] then return nil, 'Stored property type is invalid.' end
    value.revision, value.ownershipRevision = tonumber(row.revision), tonumber(row.ownership_revision)
    if not value.revision or not value.ownershipRevision then return nil, 'Stored property revision is invalid.' end
    value.coowners, value.permissionGrants, value.parentId, value.unitLabel = {}, {}, nil, nil
    for _, relationship in ipairs(coowners) do
        local cid = relationship.citizenid
        if relationship.property_id ~= id or type(cid) ~= 'string' or #cid < 1 or #cid > 50 or not value.owner or cid == value.owner then return nil, 'Invalid stored co-owner.' end
        value.coowners[cid] = true
    end
    for _, grant in ipairs(grants) do
        if grant.property_id ~= id or type(grant.citizenid) ~= 'string' or #grant.citizenid < 1 or #grant.citizenid > 50
            or type(grant.action) ~= 'string' or tonumber(grant.allowed) ~= 0 and tonumber(grant.allowed) ~= 1 then return nil, 'Invalid stored permission.' end
        value.permissionGrants[grant.citizenid] = value.permissionGrants[grant.citizenid] or {}
        value.permissionGrants[grant.citizenid][grant.action] = tonumber(grant.allowed) == 1
    end
    if units[1] then
        local relationship, visited = units[1], { [id] = true }
        if relationship.property_id ~= id then return nil, 'Invalid stored unit.' end
        value.parentId, value.unitLabel = relationship.parent_id, relationship.unit_label
        local parent = State.get(value.parentId)
        if not parent then return nil, 'Stored unit parent is unavailable.' end
        while parent do
            if visited[parent.id] or parent.propertyType ~= 'building' and parent.propertyType ~= 'hotel' and parent.propertyType ~= 'motel' then return nil, 'Invalid stored unit hierarchy.' end
            visited[parent.id] = true
            parent = parent.parentId and State.get(parent.parentId)
        end
    end
    return value
end

function State.reconcileProperty(id)
    local pending = State.uncertain[id]
    if not pending then return true end
    if State.writes[id] or Housing.transactions and Housing.transactions.busy(id) then return false, 'Property work is still pending.' end
    State.writes[id] = true
    local called, ok, err = pcall(function()
        local generation = pending.generation
        for key in pairs(pending.keys) do
            local settled, waitErr = QB.sql.awaitCheckedOperation(key)
            if not settled then return false, waitErr end
        end
        local result, readErr = QB.sql.transactionChecked({
            { query = 'SELECT `id`,`owner`,`definition`,`property_type`,`revision`,`ownership_revision` FROM `qbhousing_properties` WHERE `id`=? FOR UPDATE', values = { id } },
            { query = 'SELECT `property_id`,`citizenid` FROM `qbhousing_coowners` WHERE `property_id`=?', values = { id } },
            { query = 'SELECT `property_id`,`citizenid`,`action`,`allowed` FROM `qbhousing_permissions` WHERE `property_id`=?', values = { id } },
            { query = 'SELECT `property_id`,`parent_id`,`unit_label` FROM `qbhousing_units` WHERE `property_id`=?', values = { id } },
        })
        if not result or not result.success then return false, readErr or 'Property snapshot could not be confirmed.' end
        local value, valueErr = reconciledProperty(id, result.results or {})
        if value == nil then return false, valueErr end
        if generation ~= pending.generation then return false, 'A newer property write needs reconciliation.' end
        if value then State.publish(value) else State.properties[id] = nil end
        for _, name in ipairs({ 'leases', 'world' }) do
            local service = Housing[name]
            if service and service.reconcileProperty then
                local refreshed, refreshErr = service.reconcileProperty(id)
                if not refreshed then return false, refreshErr end
            end
        end
        for _, name in ipairs({ 'storage', 'doors' }) do
            local service = Housing[name]
            if value and service and service.refresh then
                local refreshed, refreshErr = service.refresh(id)
                if not refreshed then return false, refreshErr end
            end
        end
        if generation ~= pending.generation then return false, 'A newer property write needs reconciliation.' end
        State.uncertain[id] = nil
        if recoveryTimer and not next(State.uncertain) then QB.timers.clearTimeout(recoveryTimer); recoveryTimer = nil end
        State.broadcast()
        return true
    end)
    State.writes[id] = nil
    if not called then return false, tostring(ok) end
    return ok, err
end

scheduleRecovery = function()
    if recoveryTimer or not State.ready or not next(State.uncertain) or not QB.timers then return end
    recoveryTimer = QB.timers.setTimeout(function()
        recoveryTimer = nil
        local ids = {}
        for id in pairs(State.uncertain) do ids[#ids + 1] = id end
        for _, id in ipairs(ids) do
            local ok, err = State.reconcileProperty(id)
            if not ok then print(('[qbhousing] property reconciliation deferred: %s'):format(tostring(err))) end
        end
        scheduleRecovery()
    end, 30000)
end

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and recoveryTimer then QB.timers.clearTimeout(recoveryTimer) end
end)

function State.load()
    if QB.sql.awaitCheckedOperations then
        for _, prefix in ipairs({ 'qbhousing:', 'qbbanking:qbhousing:' }) do
            local settled, waitErr = QB.sql.awaitCheckedOperations(prefix)
            if not settled then return false, waitErr end
        end
    end
    local backedUp, backupErr = QB.sql.execute([[INSERT IGNORE INTO `qbhousing_legacy_backup` (`property_id`,`owner`,`definition`,`definition_sha256`)
        SELECT `id`,`owner`,`definition`,SHA2(`definition`,256) FROM `qbhousing_properties`]])
    if not backedUp then return false, backupErr or 'Legacy backup failed.' end
    local rows, err = QB.sql.query('SELECT `id`,`owner`,`definition`,`property_type`,`revision`,`ownership_revision` FROM `qbhousing_properties`')
    if not rows then return false, err end
    local loaded = {}
    for _, row in ipairs(rows) do
        local ok, raw = pcall(json.decode, row.definition or '')
        if not ok or type(raw) ~= 'table' or raw.id ~= row.id or raw.owner ~= row.owner then
            return false, ('Property %s has invalid JSON or conflicting identity/owner data; repair the backed-up record before starting housing.'):format(row.id)
        end
        for _, field in ipairs({ 'keys', 'furniture', 'stashes', 'clothing', 'doorlocks' }) do
            if raw[field] ~= nil and type(raw[field]) ~= 'table' then return false, ('Property %s has invalid %s data; repair the backed-up record.'):format(row.id, field) end
        end
        local property, normaliseErr = Housing.normalise(raw)
        if not property then return false, ('Property %s: %s'):format(row.id, normaliseErr) end
        property.propertyType = row.property_type or 'legacy'
        if property.propertyType ~= 'legacy' and not Config.propertyTypes[property.propertyType] then return false, ('Property %s has an unknown property type.'):format(row.id) end
        property.revision, property.ownershipRevision = tonumber(row.revision) or 0, tonumber(row.ownership_revision) or 0
        property.coowners, property.permissionGrants = {}, {}
        property.parentId, property.unitLabel = nil, nil
        loaded[row.id] = property
        if property.propertyType == 'legacy' then print(('[qbhousing] property %s needs property-type classification in the creator.'):format(row.id)) end
    end
    local backfill = {}
    for id, property in pairs(loaded) do
        for cid, enabled in pairs(property.keys) do
            if enabled and type(cid) == 'string' and #cid > 0 and #cid <= 50 then
                backfill[#backfill + 1] = { query = 'INSERT IGNORE INTO `qbhousing_permissions` (`property_id`,`citizenid`,`action`,`allowed`) VALUES (?,?,?,1)', values = { id, cid, 'entry' } }
            end
        end
    end
    if #backfill > 0 then
        local imported, importErr = QB.sql.transaction(backfill)
        if not imported then return false, importErr or 'Legacy key import failed.' end
    end
    local coowners, coownerErr = QB.sql.query('SELECT `property_id`,`citizenid` FROM `qbhousing_coowners`')
    local grants, grantErr = QB.sql.query('SELECT `property_id`,`citizenid`,`action`,`allowed` FROM `qbhousing_permissions`')
    local units, unitErr = QB.sql.query('SELECT `property_id`,`parent_id`,`unit_label` FROM `qbhousing_units`')
    if not coowners or not grants or not units then return false, coownerErr or grantErr or unitErr end
    for _, row in ipairs(coowners) do
        local property = loaded[row.property_id]
        if not property or not property.owner or property.owner == row.citizenid then return false, 'Invalid co-owner relationship in storage.' end
        property.coowners[row.citizenid] = true
    end
    for _, row in ipairs(grants) do
        local property = loaded[row.property_id]
        if not property then return false, 'Invalid permission relationship in storage.' end
        property.permissionGrants[row.citizenid] = property.permissionGrants[row.citizenid] or {}
        property.permissionGrants[row.citizenid][row.action] = tonumber(row.allowed) == 1
    end
    for _, row in ipairs(units) do
        if not loaded[row.property_id] or not loaded[row.parent_id] or row.property_id == row.parent_id then return false, 'Invalid unit relationship in storage.' end
        loaded[row.property_id].parentId, loaded[row.property_id].unitLabel = row.parent_id, row.unit_label
    end
    local subjects = {}
    for id, property in pairs(loaded) do
        if property.owner then subjects[property.owner] = true end
        for cid in pairs(property.coowners) do subjects[cid] = true end
        local visited, parent = { [id] = true }, property.parentId and loaded[property.parentId]
        while parent do
            if visited[parent.id] then return false, ('Property %s has a cyclic parent relationship.'):format(id) end
            if parent.propertyType ~= 'building' and parent.propertyType ~= 'hotel' and parent.propertyType ~= 'motel' then return false, ('Property %s has an invalid parent type.'):format(id) end
            visited[parent.id] = true
            parent = parent.parentId and loaded[parent.parentId]
        end
    end
    local ids, placeholders = {}, {}
    for cid in pairs(subjects) do ids[#ids + 1], placeholders[#placeholders + 1] = cid, '?' end
    if #ids > 0 then
        local characters, characterErr = QB.sql.query('SELECT `citizenid` FROM `players` WHERE `deleted_at` IS NULL AND `citizenid` IN (' .. table.concat(placeholders, ',') .. ')', ids)
        if not characters then return false, characterErr or 'Could not validate property owners.' end
        for _, row in ipairs(characters) do subjects[row.citizenid] = nil end
        local missing = next(subjects)
        if missing then return false, ('Property owner %s was not found; reconcile the backed-up ownership before starting housing.'):format(missing) end
    end
    State.properties = loaded
    return true
end
