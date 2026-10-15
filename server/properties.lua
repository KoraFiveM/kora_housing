Housing.properties = {}

local Properties, State, Permissions = Housing.properties, Housing.state, Housing.permissions
local editing = false
local configurationFields = { 'label', 'propertyType', 'parentId', 'unitLabel', 'interior', 'exterior', 'garage' }
local editableKeys = {
    interior = { 'type', 'name', 'model', 'entrance', 'exit' },
    exterior = { 'polyzone', 'minZ', 'maxZ', 'thickness' },
    garage = { 'coords', 'spawn', 'slots' },
}

local function configurationValue(field, value, previous)
    if not editableKeys[field] or type(value) ~= 'table' or type(previous) ~= 'table' then return Housing.copy(value) end
    local result = Housing.copy(previous)
    for _, key in ipairs(editableKeys[field]) do result[key] = nil end
    for key, item in pairs(value) do result[key] = Housing.copy(item) end
    return result
end

local function validateParent(src, property, previous)
    for _, child in pairs(State.properties) do
        if child.parentId == property.id and property.propertyType ~= 'building' and property.propertyType ~= 'hotel' and property.propertyType ~= 'motel' then
            return false, 'Move this building\'s units before changing its type.'
        end
    end
    if property.parentId and (State.writes[property.parentId] or Housing.transactions and Housing.transactions.busy(property.parentId)) then return false, 'The parent building is being updated.' end
    local previousId = previous and previous.parentId
    if previousId ~= property.parentId then
        if previousId and not Permissions.can(src, previousId, 'property.edit') then return false, 'You cannot change this building\'s units.' end
        if property.parentId and not Permissions.can(src, property.parentId, 'property.edit') then return false, 'You cannot add units to this building.' end
    end
    if not property.parentId then return true end
    local parent = State.get(property.parentId)
    if not parent or parent.state == 'archived' then return false, 'Parent building was not found.' end
    if parent.propertyType ~= 'building' and parent.propertyType ~= 'hotel' and parent.propertyType ~= 'motel' then return false, 'The parent must be a building, hotel or motel.' end
    local visited = { [property.id] = true }
    while parent do
        if visited[parent.id] then return false, 'A building cannot contain itself.' end
        visited[parent.id] = true
        parent = parent.parentId and State.get(parent.parentId) or nil
    end
    return true
end

local function withConfigurationWrite(id, handler)
    -- Unit moves must see other creator writes before checking for parent cycles.
    if editing then return false, 'The property creator is saving another change. Please try again.' end
    editing = true
    local result = table.pack(State.withWrite(id, handler))
    editing = false
    if result[1] == nil then return false, result[2] end
    return table.unpack(result, 1, result.n)
end

local function priceRange(property)
    local listing, interior = property.listing, property.interior
    if not listing or not listing.price or not interior or interior.type ~= 'shell' then return true end
    local shell = Config.shells[interior.name]
    if listing.price < shell.basePrice * 0.75 or listing.price > shell.basePrice * 1.25 then return false, 'Shell prices must stay within 25% of the base price.' end
    return true
end

local function prepare(src, payload, previous)
    if type(payload) ~= 'table' then return nil, 'Invalid property data.' end
    local value = previous and Housing.copy(previous) or { id = payload.id, state = 'unowned' }
    if previous and payload.id ~= nil and payload.id ~= previous.id then return nil, 'The property id cannot change.' end
    for _, field in ipairs(configurationFields) do value[field] = configurationValue(field, payload[field], previous and previous[field]) end
    value.label = value.label or value.id
    if payload.listing ~= nil then
        if type(payload.listing) ~= 'table' then return nil, 'Invalid listing settings.' end
        value.listing = value.listing or {}
        if payload.listing.price ~= nil then value.listing.price = payload.listing.price end
    end
    local valid, err = Housing.validateProperty(value)
    if not valid then return nil, err end
    local parentOk, parentErr = validateParent(src, valid, previous)
    if not parentOk then return nil, parentErr end
    local rangeOk, rangeErr = priceRange(valid)
    if not rangeOk then return nil, rangeErr end
    if previous then
        valid.pending = nil
    end
    return valid
end

function Properties.configurationBusy() return editing end

function Properties.create(src, payload)
    if not State.ready then return false, 'Housing is unavailable.' end
    if not Permissions.can(src, nil, 'property.create') then return false, 'Only authorized realtors or administrators can create properties.' end
    local id = type(payload) == 'table' and payload.id
    if type(id) ~= 'string' then return false, 'Property id is required.' end
    return withConfigurationWrite(id, function()
        if State.get(id) then return false, 'That property id already exists.' end
        local property, err = prepare(src, payload)
        if not property then return false, err end
        local saved, saveErr = State.persist(property, { actor = Permissions.citizenId(src), action = 'property.create' })
        if not saved then return false, saveErr or 'Property could not be saved.' end
        return true, saved
    end)
end

function Properties.edit(src, id, payload, revision)
    if not State.ready then return false, 'Housing is unavailable.' end
    return withConfigurationWrite(id, function()
        local previous = State.get(id)
        if not previous or not Permissions.can(src, id, 'property.edit') then return false, 'You cannot edit this property.' end
        if not Housing.finite(revision) or revision % 1 ~= 0 or revision ~= previous.revision then return false, 'This property changed. Refresh it before saving.' end
        local property, err = prepare(src, payload, previous)
        if not property then return false, err end
        local saved, saveErr = State.persist(property, { actor = Permissions.citizenId(src), action = 'property.edit' })
        if not saved then return false, saveErr or 'Property could not be saved.' end
        return true, saved
    end)
end

function Properties.view(src, id, details)
    local property = State.get(id)
    if not State.ready or not property then return false, 'Property was not found.' end
    local permission = Permissions.snapshot(src, id)
    if not permission then return false, 'Property was not found.' end
    local cid = Permissions.citizenId(src)
    local lease = Housing.leases and Housing.leases.active(id)
    local canManage = permission.actions['property.edit'] or permission.actions['permissions.manage'] or permission.actions['sales.manage'] or Permissions.isAdmin(src)
    local involved = lease and lease.tenant == cid
    if Housing.sales and not canManage and not permission.actions.entry and not involved then
        local count = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_offers` o JOIN `qbhousing_listings` l ON l.id=o.listing_id WHERE l.property_id=? AND o.buyer=?', { id, cid })
        involved = tonumber(count or 0) > 0
        if not involved then
            local agreements = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_leases` WHERE `property_id`=? AND `tenant`=?', { id, cid })
            involved = tonumber(agreements or 0) > 0
        end
        if not involved and details ~= false then
            local browse = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_listings` WHERE `property_id`=? AND `status`=? AND (`channel`=? OR `buyer`=?)', { id, 'active', 'public', cid })
            involved = tonumber(browse or 0) > 0
        end
    end
    if not canManage and not permission.actions.entry and not permission.actions['camera.view'] and not involved then return false, 'You cannot view this property.' end
    local copy = Housing.copy(property)
    if not canManage then
        copy.coowners, copy.permissionGrants, copy.keys, copy.pending = nil, nil, nil, nil
        if copy.listing and copy.listing.type == 'direct' then copy.listing = nil end
    end
    local view = { property = copy, relationship = permission.relationship, allowed = permission.actions }
    if details == false then return true, view end
    if Housing.sales then view.sales = Housing.sales.view(src, id) end
    if Housing.leases then view.lease = Housing.leases.view(src, id) end
    if Housing.storage then view.storage = Housing.storage.view(src, id) end
    if Housing.world and Housing.world.ready then local ok, world = Housing.world.snapshot(src, id); if ok then view.world = world end end
    return true, view
end

function Properties.snapshot(src)
    if not State.ready then return false, 'Housing is unavailable.' end
    local result = { properties = {}, types = Housing.copy(Config.propertyTypes), shells = Housing.copy(Config.shells), actions = {},
        admin = Permissions.isAdmin(src), realtor = Permissions.isRealtor(src), citizenid = Permissions.citizenId(src) }
    for action, label in pairs(Housing.permissionActions) do result.actions[action] = { label = label, grantable = Housing.grantablePermissions[action] == true } end
    for id in pairs(State.properties) do
        local ok, view = Properties.view(src, id, false)
        if ok then result.properties[#result.properties + 1] = view.property end
    end
    table.sort(result.properties, function(a, b) return a.id < b.id end)
    if Housing.sales then
        local cid = result.citizenid
        local offers = QB.sql.query('SELECT o.*,l.property_id,l.channel,l.agent,l.commission_policy FROM `qbhousing_offers` o JOIN `qbhousing_listings` l ON l.id=o.listing_id WHERE o.buyer=? OR l.agent=? OR l.seller=? OR EXISTS (SELECT 1 FROM `qbhousing_coowners` c WHERE c.property_id=l.property_id AND c.citizenid=?) ORDER BY o.created_at DESC LIMIT 200', { cid, cid, cid, cid }) or {}
        for _, offer in ipairs(offers) do local property = State.get(offer.property_id); if property then offer.settlementSummary = Housing.sales.summary(property, { channel = offer.channel, commission_policy = offer.commission_policy }, offer.amount) end end
        local leases = QB.sql.query('SELECT l.* FROM `qbhousing_leases` l WHERE (l.tenant=? OR l.landlord=? OR EXISTS (SELECT 1 FROM `qbhousing_coowners` c WHERE c.property_id=l.property_id AND c.citizenid=?)) AND (l.status IN (?,?,?,?) OR l.deposit_remaining>0) ORDER BY l.created_at DESC LIMIT 100', { cid, cid, cid, 'proposed', 'active', 'ending', 'evicting' }) or {}
        for _, lease in ipairs(leases) do if type(lease.permissions) == 'string' then lease.permissions = json.decode(lease.permissions) end end
        local operations = QB.sql.query('SELECT t.id,t.property_id,t.kind,t.status,t.error,t.created_at,t.updated_at FROM `qbhousing_transactions` t JOIN `qbhousing_properties` p ON p.id=t.property_id WHERE t.actor=? OR p.owner=? OR EXISTS (SELECT 1 FROM `qbhousing_coowners` c WHERE c.property_id=p.id AND c.citizenid=?) ORDER BY t.created_at DESC LIMIT 100', { cid, cid, cid }) or {}
        local ok, recovery = Housing.storage.recoveryList(src)
        result.inbox = { offers = offers, leases = leases, transactions = operations, recoveries = ok and recovery or {} }
    end
    return true, result
end

function Properties.archiveLegacy(src, id)
    if not State.ready or not Permissions.isAdmin(src) then return false, 'Only administrators can remove properties.' end
    return withConfigurationWrite(id, function()
        local property = State.get(id)
        if not property or property.owner then return false, 'Owned properties cannot be removed.' end
        for _, child in pairs(State.properties) do
            if child.parentId == id then return false, 'Move this building\'s units before archiving it.' end
        end
        property = Housing.copy(property)
        property.state, property.pending = 'archived', nil
        local saved, err = State.persist(property, { actor = Permissions.citizenId(src), action = 'property.archive' })
        if not saved then return false, err or 'Property could not be archived.' end
        return true
    end)
end

function Properties.saveLegacy(src, payload)
    if not State.ready or not Permissions.isRealtor(src) then return nil, 'Only realtors can create or edit properties.' end
    if type(payload) ~= 'table' then return nil, 'Invalid property data.' end
    local id = type(payload.id) == 'string' and payload.id:gsub('[^%w_-]', '') or ''
    if id == '' or #id > 64 then return nil, 'Use a valid property id.' end
    local ok, result = withConfigurationWrite(id, function()
        local existing = State.get(id)
        if existing and not Permissions.can(src, id, 'property.edit') then return false, 'You cannot edit this property.' end
        local copy = existing and Housing.copy(existing) or { id = id }
        for _, field in ipairs(configurationFields) do
            if payload[field] ~= nil then copy[field] = configurationValue(field, payload[field], existing and existing[field]) end
        end
        copy.id, copy.label = id, copy.label or id
        copy.propertyType = copy.propertyType or 'legacy'
        copy.listing = existing and Housing.copy(existing.listing) or {}
        copy.listing = copy.listing or {}
        copy.listing.price = type(payload.listing) == 'table' and tonumber(payload.listing.price) or nil
        copy.listing.realtor = Permissions.citizenId(src)
        copy.listing.type = type(payload.listing) == 'table' and payload.listing.type == 'direct' and 'direct' or 'open_market'
        if not Housing.finite(copy.listing.price) or copy.listing.price < 1 or copy.listing.price > 1000000000 then return false, 'Listing price must be positive.' end
        copy.listing.price = math.floor(copy.listing.price)
        if type(copy.interior) ~= 'table' or (copy.interior.type ~= 'mlo' and copy.interior.type ~= 'shell') or not Housing.validCoords(copy.interior.entrance) then return false, 'Enter valid interior and entrance coordinates.' end
        if copy.interior.type == 'shell' then
            local shell = Config.shells[copy.interior.name]
            if not shell then return false, 'That shell is not available.' end
            copy.interior.model, copy.interior.exit = shell.model, Housing.copy(shell.exit)
        end
        local valid, err
        if copy.propertyType == 'legacy' then valid, err = Housing.normalise(copy)
        else valid, err = Housing.validateProperty(copy) end
        if not valid then return false, err end
        local parentOk, parentErr = validateParent(src, valid, existing)
        if not parentOk then return false, parentErr end
        local rangeOk, rangeErr = priceRange(valid)
        if not rangeOk then return false, rangeErr end
        valid.pending = nil
        if valid.garage and (not Housing.validCoords(valid.garage.coords) or not Housing.validCoords(valid.garage.spawn)) then return false, 'Enter valid garage coordinates.' end
        valid.state = valid.owner and 'owned' or 'listed'
        local writes
        if Housing.sales then
            -- A legacy listing edit must invalidate approvals for its previous quote.
            writes = {
                { query = 'UPDATE `qbhousing_offers` o JOIN `qbhousing_listings` l ON l.id=o.listing_id SET o.status=? WHERE l.property_id=? AND l.status=? AND o.status IN (?,?)', values = { 'cancelled', id, 'active', 'submitted', 'accepted' } },
                { query = 'UPDATE `qbhousing_listings` SET `status`=? WHERE `property_id`=? AND `status`=?', values = { 'cancelled', id, 'active' } },
            }
        end
        local saved, saveErr = State.persist(valid, { actor = Permissions.citizenId(src), action = 'property.legacySave' }, writes)
        if not saved then return false, saveErr or 'Property could not be saved.' end
        return true, saved
    end)
    if not ok then return nil, result end
    return result
end
