Housing.storage = { frozen = {} }
local S, D, State, P = Housing.storage, Housing.domain, Housing.state, Housing.permissions

local function invoke(method, ...)
    local args = table.pack(...)
    local ok, result, detail = pcall(function() return exports.qbinventory[method](exports.qbinventory, table.unpack(args, 1, args.n)) end)
    if not ok then return false, 'Inventory is unavailable.' end
    return result, detail
end

local function coords(property)
    return property and (Housing.world.stashCoords(property.id) or property.interior and property.interior.entrance)
end

function S.ensureEscrow()
    local ok, account = pcall(function() return exports.qbbanking:GetAccount(Config.escrowAccount) end)
    if ok and account then return true end
    local created, result = pcall(function() return exports.qbbanking:CreateJobAccount(Config.escrowAccount, 0) end)
    if not created or not result then
        local found, existing = pcall(function() return exports.qbbanking:GetAccount(Config.escrowAccount) end)
        if not found or not existing then return false, 'Deposit escrow is unavailable.' end
    end
    return true
end

local function policy(row)
    return function(src, _, _, context)
        local cid = P.citizenId(src)
        if not cid or S.frozen[row.property_id] or Housing.transactions.busy(row.property_id)
            or State.isUncertain and State.isUncertain(row.property_id) then return false end
        if row.status == 'recovery' then
            if not context or not context.recovery then return false end
            if row.lease_id then return cid == row.tenant end
            local entitled = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_recovery` WHERE `kind`=? AND `reference`=? AND `citizenid`=? AND `status`=?', { 'stash', row.id, cid, 'pending' })
            return tonumber(entitled or 0) > 0
        end
        if row.status ~= 'active' then return false end
        local property = State.get(row.property_id)
        if not property or property.state == 'archiving' or property.state == 'archived' then return false end
        if property.legacy and property.legacy.stash and property.legacy.stash.id == row.id and not P.can(src, row.property_id, 'entry') then return false end
        if not row.lease_id and Housing.leases.active(row.property_id) then return false end
        if row.lease_id then
            local lease = Housing.leases.active(row.property_id)
            return lease and lease.id == row.lease_id and P.can(src, row.property_id, 'stash.open')
        end
        return P.can(src, row.property_id, 'stash.open')
    end
end

local function register(row)
    if not row then return false, 'Stash was not found.' end
    local property = State.get(row.property_id)
    if not row or not property then return false, 'Stash property was not found.' end
    if row.status == 'recovery' then
        local rebound = invoke('RebindStashPolicy', row.id, policy(row))
        if rebound then return true end
    end
    local tier = tonumber(QB.sql.scalar('SELECT COALESCE(MAX(`tier`),1) FROM `qbhousing_storage_purchases` WHERE `property_id`=?', { property.id }))
    if not tier then return false, 'Storage tier is unavailable.' end
    local legacyStash = property.legacy and property.legacy.stash
    local capacity = legacyStash and legacyStash.id == row.id and legacyStash.capacity or Config.storageTiers[tier]
    if not capacity then return false, 'Storage tier is not configured.' end
    local position = type(row.coords) == 'string' and json.decode(row.coords) or row.coords
    if row.status == 'recovery' then position = nil end
    local ok, err = invoke('RegisterStashPolicy', row.id, { label = row.status == 'recovery' and 'Recovered property belongings' or property.label,
        slots = capacity.slots, maxWeight = capacity.maxWeight, coords = position, distance = 3.0 }, policy(row))
    if not ok then return false, err end
    if Housing.transactions.busy(property.id) then S.frozen[property.id] = true
    else
        local unblocked, unblockErr = invoke('SetStashBlocked', row.id, false)
        if not unblocked then return false, unblockErr end
    end
    return true
end

function S.refresh(id)
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_stashes` WHERE `property_id`=? AND `status`<>?', { id, 'claimed' })
    if not rows then return false, err end
    for _, row in ipairs(rows) do
        local ok, registerErr = register(row)
        if not ok then return false, registerErr end
    end
    return S.registerGarage(id)
end

function S.configureStash(src, id, payload, revision)
    return D.lock(id, function()
        local property = State.get(id)
        if not property or property.revision ~= revision or not P.can(src, id, 'property.edit') or type(payload) ~= 'table' or not Housing.validCoords(payload.coords) or not Housing.world.contains(id, payload.coords) then return false, 'Choose an authorized stash position inside the property.' end
        local stashId = payload.id or 'p:' .. id
        if type(stashId) ~= 'string' or #stashId > 100 then return false, 'Invalid stash identity.' end
        local existing = QB.sql.single('SELECT * FROM `qbhousing_stashes` WHERE `id`=?', { stashId })
        if existing and (existing.property_id ~= id or existing.lease_id or existing.status ~= 'active') then return false, 'This stash cannot be reconfigured.' end
        local count = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_stashes` WHERE `property_id`=? AND `lease_id` IS NULL', { id })
        if count == nil or not existing and tonumber(count) >= Config.maxStashes then return false, 'Stash limit reached or storage unavailable.' end
        local changed = Housing.copy(property)
        if changed.legacy and changed.legacy.stash and changed.legacy.stash.id == stashId then changed.legacy.stash.coords = Housing.copy(payload.coords) end
        local saved, err = State.persist(changed, { actor = P.citizenId(src), action = 'stash.configure' }, {
            { query = 'INSERT INTO `qbhousing_stashes` (`id`,`property_id`,`status`,`coords`) VALUES (?,?,?,?) ON DUPLICATE KEY UPDATE `coords`=VALUES(`coords`)', values = { stashId, id, 'active', json.encode(payload.coords) } },
        })
        if not saved then return false, err end
        local ready, readyErr = S.refresh(id)
        if not ready then return false, readyErr end
        return true, saved
    end)
end

function S.prepareLease(lease)
    local property = State.get(lease.property_id)
    local position = coords(property)
    if not position then return false, 'Configure a property space or stash position before renting it.' end
    local id = 'lease:' .. lease.id
    local inserted, err = QB.sql.execute('INSERT IGNORE INTO `qbhousing_stashes` (`id`,`property_id`,`lease_id`,`tenant`,`status`,`coords`) VALUES (?,?,?,?,?,?)', { id, lease.property_id, lease.id, lease.tenant, 'prepared', json.encode(position) })
    if not inserted then return false, err end
    local row = QB.sql.single('SELECT * FROM `qbhousing_stashes` WHERE `id`=?', { id })
    return register(row)
end

function S.openStash(src, id, stashId)
    if not P.can(src, id, 'stash.open') then return false, 'You cannot open this property storage.' end
    local lease = Housing.leases.active(id)
    local property = State.get(id)
    local expected = lease and 'lease:' .. lease.id or property and property.legacy and property.legacy.stash and property.legacy.stash.id or 'p:' .. id
    stashId = stashId or expected
    local row = QB.sql.single('SELECT * FROM `qbhousing_stashes` WHERE `id`=? AND `property_id`=?', { stashId, id })
    if not row and not lease and stashId == expected then
        local property, position = State.get(id), coords(State.get(id))
        if not position then return false, 'Configure a stash position first.' end
        local saved, err = QB.sql.execute('INSERT IGNORE INTO `qbhousing_stashes` (`id`,`property_id`,`status`,`coords`) VALUES (?,?,?,?)', { stashId, id, 'active', json.encode(position) })
        if not saved then return false, err end
        row = { id = stashId, property_id = id, status = 'active', coords = position }
    end
    if not row or row.status ~= 'active' or lease and row.lease_id ~= lease.id then return false, 'This storage does not belong to your occupancy.' end
    local ok, err = register(row)
    if not ok then return false, err end
    return invoke('stashOpen', src, stashId, {})
end

function S.freezeForSale(id)
    S.frozen[id] = true
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_stashes` WHERE `property_id`=? AND `status`=? AND `lease_id` IS NULL', { id, 'active' })
    if not rows then S.frozen[id] = nil; return false, err end
    for _, row in ipairs(rows) do
        local ok, blockedErr = invoke('SetStashBlocked', row.id, true)
        if not ok then S.unfreeze(id); return false, blockedErr end
        local read, items = pcall(function() return exports.qbinventory:GetStashItems(row.id) end)
        if not read or type(items) ~= 'table' or next(items) then S.unfreeze(id); return false, 'Empty all owner stashes before selling the property.' end
    end
    return true
end

function S.unfreeze(id)
    S.frozen[id] = nil
    local rows = QB.sql.query('SELECT `id` FROM `qbhousing_stashes` WHERE `property_id`=? AND `lease_id` IS NULL', { id }) or {}
    for _, row in ipairs(rows) do invoke('SetStashBlocked', row.id, false) end
end

function S.purchaseStorage(src, id)
    return D.lock(id, function()
        local property, cid = State.get(id), P.citizenId(src)
        if not property or not P.can(src, id, 'storage.upgrade') then return false, 'You cannot upgrade this storage.' end
        local tier = tonumber(QB.sql.scalar('SELECT COALESCE(MAX(`tier`),1) FROM `qbhousing_storage_purchases` WHERE `property_id`=?', { id }))
        if not tier then return false, 'Storage is unavailable.' end
        local nextTier = Config.storageTiers[tier + 1]
        if not nextTier then return false, 'This property already has the largest storage tier.' end
        local imported = property.legacy and property.legacy.stash and property.legacy.stash.capacity
        if imported and (nextTier.slots < imported.slots or nextTier.maxWeight < imported.maxWeight) then return false, 'Configure an upgrade above the imported storage capacity.' end
        local key, err = Housing.transactions.nextKey('storage:' .. id .. ':' .. (tier + 1))
        if not key then return false, err end
        local changed = Housing.copy(property); changed.storageTier = tier + 1
        if changed.legacy and changed.legacy.stash then changed.legacy.stash.capacity = Housing.copy(nextTier) end
        return Housing.transactions.run(key, 'storage.upgrade', cid, changed, { { citizenid = cid, amount = nextTier.price } }, { { account = Config.societyAccount, amount = nextTier.price } }, {
            { query = 'INSERT INTO `qbhousing_storage_purchases` (`property_id`,`tier`,`operation_id`,`buyer`) VALUES (?,?,?,?)', values = { id, tier + 1, key, cid } },
        })
    end)
end

function S.recoverLease(lease)
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_stashes` WHERE `lease_id`=? AND `status`<>?', { lease.id, 'claimed' })
    if not rows then return false, err end
    for _, row in ipairs(rows) do
        row.status = 'recovery'
        local ok, policyErr = register(row)
        if not ok then return false, policyErr end
        local saved, saveErr = D.sql({
            { query = 'UPDATE `qbhousing_stashes` SET `status`=? WHERE `id`=?', values = { 'recovery', row.id } },
            { query = 'INSERT IGNORE INTO `qbhousing_recovery` (`id`,`property_id`,`lease_id`,`citizenid`,`kind`,`reference`,`status`,`created_at`) VALUES (?,?,?,?,?,?,?,?)', values = { row.id, row.property_id, lease.id, lease.tenant, 'stash', row.id, 'pending', os.time() } },
        })
        if not saved then return false, saveErr end
    end
    return true
end

function S.notifyRecovery(lease)
    if GetResourceState('qbphone') ~= 'started' then return end
    pcall(function() exports.qbphone:sendMailToOffline(lease.tenant, { sender = 'Property recovery', subject = 'Your property belongings are protected', message = 'Your lease has ended. Open Housing recovery to collect your belongings. They do not expire.' }) end)
end

function S.recoveryList(src)
    local cid = P.citizenId(src)
    if not cid then return false, 'Player data is unavailable.' end
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_recovery` WHERE `citizenid`=? AND `status`=? ORDER BY `created_at` LIMIT 200', { cid, 'pending' })
    if not rows then return false, err end
    local garages = QB.sql.query([[SELECT DISTINCT p.id,p.definition FROM qbhousing_properties p LEFT JOIN qbhousing_garage_recovery g ON g.property_id=p.id AND g.citizenid=? LEFT JOIN qbhousing_leases l ON l.property_id=p.id AND l.tenant=? AND l.status IN ('ended','evicted') WHERE g.citizenid IS NOT NULL OR l.tenant IS NOT NULL]], { cid, cid }) or {}
    for _, row in ipairs(garages) do
        local property = State.get(row.id)
        if property and property.garage then rows[#rows + 1] = { id = 'garage:' .. row.id, property_id = row.id, label = property.label, kind = 'garage' } end
    end
    for _, row in ipairs(Housing.world.recovery(src) or {}) do rows[#rows + 1] = row end
    return true, rows
end

function S.claimRecovery(src, id)
    local cid = P.citizenId(src)
    if not cid then return false, 'Player data is unavailable.' end
    local row = QB.sql.single('SELECT * FROM `qbhousing_recovery` WHERE `id`=? AND `citizenid`=?', { id, cid })
    if not row then return false, 'Recovery record was not found.' end
    return D.lock(row.property_id, function()
        if P.citizenId(src) ~= cid then return false, 'Your character changed. Try again.' end
        row = QB.sql.single('SELECT * FROM `qbhousing_recovery` WHERE `id`=? AND `citizenid`=?', { id, cid })
        if not row or row.kind ~= 'stash' then return false, 'Recovery record was not found.' end
        if row.status == 'claimed' then return true, true end
        if row.status ~= 'pending' then return false, 'Recovery storage is not ready.' end
        local stash = QB.sql.single('SELECT * FROM `qbhousing_stashes` WHERE `id`=?', { row.reference })
        if not stash or stash.status ~= 'recovery' or stash.property_id ~= row.property_id or stash.lease_id ~= row.lease_id
            or stash.lease_id and stash.tenant ~= cid then return false, 'Recovery storage is not ready.' end
        local ready, err = register(stash)
        if not ready then return false, err end
        local ok, receipt = invoke('ClaimStash', src, row.reference, 'claim:' .. id)
        if not ok then return false, receipt end
        local saved, saveErr = D.sql({
            { query = 'UPDATE `qbhousing_recovery` SET `status`=? WHERE `kind`=? AND `reference`=? AND `status`=?', values = { 'claimed', 'stash', row.reference, 'pending' } },
            { query = 'UPDATE `qbhousing_stashes` SET `status`=? WHERE `id`=? AND `status`=?', values = { 'claimed', row.reference, 'recovery' }, expectedRows = 1 },
            D.audit(row.property_id, cid, 'recovery.claim', { recovery = id, operation = 'claim:' .. id }),
        })
        return saved, saved and receipt or saveErr
    end)
end

function S.registerGarage(id)
    local property = State.get(id)
    if not property or not property.garage then return true end
    -- Imported resourceId fields may name a public or foreign provider's
    -- garage. Only this property's durable housing mapping is authoritative.
    local key = QB.sql.scalar('SELECT garage_key FROM `qbhousing_garages` WHERE property_id=?', { id })
    if not key then
        key = D.id()
        if not key then return false, 'Garage storage is unavailable.' end
        local inserted, err = QB.sql.execute('INSERT IGNORE INTO `qbhousing_garages` (`property_id`,`garage_key`) VALUES (?,?)', { id, key })
        if not inserted then return false, err end
        key = QB.sql.scalar('SELECT garage_key FROM `qbhousing_garages` WHERE property_id=?', { id })
    end
    local lease, owners = Housing.leases.active(id), D.owners(property)
    if lease then owners = { lease.tenant } end
    local ok, result, err = pcall(function()
        return exports.qbgarages:RegisterPropertyGarage(key, { label = property.label, coords = property.garage.coords, spawn = property.garage.spawn,
            slots = property.garage.slots, capacityOwnerIds = owners, retrievalOnly = property.state == 'archived' }, function(src, action)
                if Housing.transactions.busy(id) or State.isUncertain and State.isUncertain(id) then return false end
                if P.can(src, id, 'garage.' .. action) then return true end
                if action ~= 'retrieve' and action ~= 'list' then return false end
                local cid = P.citizenId(src)
                local prior = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_leases` WHERE `property_id`=? AND `tenant`=? AND `status` IN (?,?)', { id, cid, 'ended', 'evicted' })
                local former = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_garage_recovery` WHERE `property_id`=? AND `citizenid`=?', { id, cid })
                return tonumber(prior or 0) > 0 or tonumber(former or 0) > 0
            end)
    end)
    if not ok or not result then return false, err or 'Garage integration is unavailable.' end
    return true, key
end

function S.openGarage(src, id)
    local property = State.get(id)
    if not property or not property.garage then return false, 'This property has no garage.' end
    local ready, key = S.registerGarage(id)
    if not ready then return false, key end
    if not D.near(src, property.garage.coords, 8) then return false, 'Go to the property garage.' end
    if not P.can(src, id, 'garage.list') then
        local cid = P.citizenId(src)
        local recovery = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_garage_recovery` WHERE `property_id`=? AND `citizenid`=?', { id, cid })
        local prior = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_leases` WHERE `property_id`=? AND `tenant`=? AND `status` IN (?,?)', { id, cid, 'ended', 'evicted' })
        if tonumber(recovery or 0) == 0 and tonumber(prior or 0) == 0 then return false, 'You cannot use this garage.' end
    end
    return true, { id = key }
end

function S.view(src, id)
    local cid, lease = P.citizenId(src), Housing.leases.active(id)
    local rows = QB.sql.query('SELECT * FROM `qbhousing_stashes` WHERE `property_id`=? AND `status`=?', { id, 'active' }) or {}
    local stashes = {}
    for _, row in ipairs(rows) do if lease and row.lease_id == lease.id or not lease and not row.lease_id then stashes[#stashes + 1] = row end end
    local position = stashes[1] and (type(stashes[1].coords) == 'string' and json.decode(stashes[1].coords) or stashes[1].coords) or coords(State.get(id))
    return { coords = position, tier = tonumber(QB.sql.scalar('SELECT COALESCE(MAX(`tier`),1) FROM `qbhousing_storage_purchases` WHERE `property_id`=?', { id })) or 1, tiers = Housing.copy(Config.storageTiers), stashes = stashes }
end

function S.load()
    for id in pairs(State.properties) do
        local ok, err = S.refresh(id)
        if not ok then return false, err end
    end
    return true
end

AddEventHandler('qbinventory:ready', function() if State.ready then S.load() end end)
AddEventHandler('qbgarages:ready', function() if State.ready then S.load() end end)

function S.archive(id)
    local property = State.get(id)
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_stashes` WHERE `property_id`=? AND `lease_id` IS NULL AND `status`=?', { id, 'active' })
    if not rows then return false, err end
    if #rows > 0 and not property.owner then
        for _, row in ipairs(rows) do
            local read, items = pcall(function() return exports.qbinventory:GetStashItems(row.id) end)
            if not read or type(items) ~= 'table' or next(items) then return false, 'An administrator must assign ownership before archiving unowned storage with belongings.' end
        end
    end
    for _, row in ipairs(rows) do
        if property.owner then
            local writes = { { query = 'UPDATE `qbhousing_stashes` SET `status`=?,`tenant`=? WHERE `id`=? AND `status`=?', values = { 'recovery', QB.sql.NULL, row.id, 'active' }, expectedRows = 1 } }
            for _, cid in ipairs(D.owners(property)) do
                local recoveryId = D.id()
                if not recoveryId then return false, 'Recovery storage is unavailable.' end
                writes[#writes + 1] = { query = 'INSERT IGNORE INTO `qbhousing_recovery` (`id`,`property_id`,`citizenid`,`kind`,`reference`,`status`,`created_at`) VALUES (?,?,?,?,?,?,?)', values = { recoveryId, id, cid, 'stash', row.id, 'pending', os.time() } }
            end
            local saved, saveErr = D.sql(writes)
            if not saved then return false, saveErr end
            row.status, row.tenant = 'recovery', nil
            local ready, policyErr = register(row)
            if not ready then return false, policyErr end
        end
    end
    return true
end

function S.canArchive(id)
    local property = State.get(id)
    if not property then return false, 'Property was not found.' end
    if property.owner then return true end
    local frozen, err = S.freezeForSale(id)
    if not frozen then return false, err end
    S.unfreeze(id)
    return true
end
