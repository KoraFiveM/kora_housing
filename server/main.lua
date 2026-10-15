local State, P = Housing.state, Housing.permissions
local RESOURCE = GetCurrentResourceName()

local function fail(message) return nil, message end
local function register(name, fn, max)
    QB.callback.register('qbhousing:' .. name, function(src, ...)
        if not State.ready then return nil, 'Housing is unavailable.' end
        local result = table.pack(pcall(fn, src, ...))
        if result[1] then return table.unpack(result, 2, result.n) end
        print(('[qbhousing] callback %s failed: %s'):format(name, tostring(result[2])))
        return nil, 'Housing is unavailable. Please try again.'
    end, { rateLimit = { max = max or 10, window = 10000 } })
end

local function mutation(name, handler)
    register(name, function(src, ...)
        local ok, result, code = handler(src, ...)
        if ok then State.broadcast() end
        return ok, result, code
    end, 5)
end

CreateThread(function()
    if not QB.sql.ready(60000) then return print('^1[qbhousing]^7 qbsql was not ready; resource disabled.') end
    local ok, err = QB.sql.migrateFiles(RESOURCE, {
        { version = 1, name = 'housing', file = 'sql/001_housing.sql' },
        { version = 2, name = 'registry_access', file = 'sql/002_registry_access.sql' },
        { version = 3, name = 'economy', file = 'sql/003_economy.sql' },
        { version = 4, name = 'world', file = 'sql/004_world.sql' },
    })
    if not ok then return print(('^1[qbhousing]^7 migration failed: %s'):format(tostring(err))) end
    for _, loader in ipairs({ State.load, Housing.sales.importLegacy, Housing.domain.load, Housing.leases.load, Housing.world.load, Housing.transactions.load }) do
        local loaded, loadErr = loader()
        if not loaded then return print(('^1[qbhousing]^7 load failed: %s'):format(tostring(loadErr))) end
    end
    local function activate()
        local storageReady, storageErr = Housing.storage.load()
        local doorsReady, doorsErr = Housing.doors.load()
        if not storageReady or not doorsReady then
            print(('[qbhousing] waiting for integrations: %s'):format(tostring(storageErr or doorsErr)))
            QB.timers.setTimeout(activate, 5000)
            return
        end
        State.ready = true
        Housing.leases.schedule()
        Housing.admin.resume()
        State.broadcast()
    end
    activate()
end)

register('creatorSnapshot', Housing.properties.snapshot)
register('propertyView', Housing.properties.view)
mutation('createProperty', Housing.properties.create)
mutation('editProperty', Housing.properties.edit)
mutation('coowners', Housing.ownership.setCoowner)
mutation('setPermission', Housing.ownership.setPermission)
register('permissions', function(src, id)
    local view, err = Housing.ownership.view(src, id)
    return view ~= nil, view or err
end)

for name, handler in pairs({
    assignAgent = Housing.sales.assignAgent, createListing = Housing.sales.createListing,
    submitOffer = Housing.sales.submitOffer, recommendOffer = Housing.sales.recommendOffer,
    decideOffer = Housing.sales.decideOffer, approveSale = Housing.sales.approveSale,
    completeSale = Housing.sales.completeSale, cancelListing = Housing.sales.cancelListing,
    proposeLease = Housing.leases.proposeLease, acceptLease = Housing.leases.acceptLease,
    requestLeaseEnd = Housing.leases.requestLeaseEnd, leaseAccess = Housing.leases.leaseAccess,
    proposeDeduction = Housing.leases.proposeDeduction, decideDeduction = Housing.leases.decideDeduction,
    resolveDeduction = Housing.leases.resolveDeduction, configureStash = Housing.storage.configureStash,
    purchaseStorage = Housing.storage.purchaseStorage, claimRecovery = Housing.storage.claimRecovery,
    configureDoors = Housing.doors.configure, archiveProperty = Housing.admin.archive,
    configureSpace = Housing.world.configureSpace, savePlacement = Housing.world.savePlacement,
    removeFurniture = Housing.world.removeFurniture, saveCamera = Housing.world.saveCamera,
    removeCamera = Housing.world.removeCamera, grantCamera = Housing.world.grantCamera,
    revokeCamera = Housing.world.revokeCamera, setAlarm = Housing.world.setAlarm,
    configureAlarm = Housing.world.configureAlarm, claimFurniture = Housing.world.claimFurniture,
}) do mutation(name, handler) end

for name, handler in pairs({
    openStash = Housing.storage.openStash, openGarage = Housing.storage.openGarage,
    recovery = Housing.storage.recoveryList, archivePreflight = Housing.admin.preflight,
    auditView = Housing.admin.audit, worldSnapshot = Housing.world.snapshot,
    beginPlacement = Housing.world.beginPlacement, openCamera = Housing.world.openCamera,
    switchCamera = Housing.world.switchCamera, closeCamera = Housing.world.closeCamera,
    panic = Housing.world.panic, subscribeSpace = Housing.world.subscribe,
    leaveProperty = Housing.world.leave,
}) do register(name, handler, name == 'subscribeSpace' and 128 or nil) end
register('recoveryList', Housing.storage.recoveryList)
register('worldSpaces', function() return true, Housing.world.publicSpaces() end)

-- Retain the original callback names and result shapes for external consumers.
register('hydrate', function(src)
    return { properties = State.snapshot(), realtor = P.isRealtor(src), citizenid = P.citizenId(src), ready = State.ready }
end)
register('catalog', function() return Housing.sales.catalog() end)
register('saveProperty', function(src, payload)
    local saved, err = Housing.properties.saveLegacy(src, payload)
    if not saved then return nil, err end
    if saved.listing.type ~= 'direct' then
        local listed, listingErr = Housing.sales.createListing(src, saved.id, { channel = 'public', price = saved.listing.price, biography = saved.label }, saved.revision)
        if not listed then return nil, 'Configuration was saved; listing could not be published: ' .. tostring(listingErr) end
        saved = State.get(saved.id)
    end
    State.broadcast()
    return saved
end)
register('realtorDashboard', function(src)
    if not P.isRealtor(src) then return fail('Only realtors can view the dashboard.') end
    local result, total = { forSale = Housing.sales.catalog() or {}, sold = {}, averagePrice = 0, soldCount = 0 }, 0
    for _, property in ipairs(result.forSale) do total = total + property.listing.price end
    for _, property in pairs(State.properties) do
        if property.soldAt then result.sold[#result.sold + 1] = State.publicProperty(property); result.soldCount = result.soldCount + 1 end
    end
    result.averagePrice = #result.forSale > 0 and math.floor(total / #result.forSale) or 0
    return result
end)
register('removeProperty', function(src, id)
    local reviewed, preview = Housing.admin.preflight(src, id)
    if not reviewed then return fail(preview) end
    local ok, err = Housing.admin.archive(src, id, preview.token)
    if not ok then return fail(err) end
    return true
end)
register('offer', function(src, id, buyer)
    local cid, property = P.citizenId(src), State.get(id)
    if buyer and buyer ~= cid then return fail('The selected buyer must submit or accept the offer through Housing.') end
    if not property then return fail('Property was not found.') end
    local listing = QB.sql.single('SELECT * FROM `qbhousing_listings` WHERE `property_id`=? AND `status`=?', { id, 'active' })
    if not listing then return fail('This property has no active listing.') end
    local ok, err = Housing.sales.submitOffer(src, listing.id, listing.price)
    if not ok then return fail(err) end
    State.broadcast()
    return true
end)
register('confirmPurchase', function(src, id)
    local offer = QB.sql.single('SELECT o.id FROM `qbhousing_offers` o JOIN `qbhousing_listings` l ON l.id=o.listing_id WHERE l.property_id=? AND o.buyer=? AND o.status=? ORDER BY o.created_at DESC LIMIT 1', { id, P.citizenId(src), 'accepted' })
    if not offer then return fail('The seller and every co-owner must approve an offer before checkout.') end
    local ok, result = Housing.sales.completeSale(src, offer.id)
    if not ok then return fail(result) end
    return result
end)
register('keys', function(src, id, action, target)
    local property = State.get(id)
    if not property or action ~= 'give' and action ~= 'remove' then return fail('Invalid property or key action.') end
    local ok, saved = Housing.ownership.setPermission(src, id, target, 'entry', action == 'give', property.revision)
    if not ok then return fail(saved) end
    State.broadcast()
    return saved.keys
end)
register('update', function(src, id, field, value)
    if field ~= 'furniture' and field ~= 'stashes' and field ~= 'clothing' then return fail('Invalid property update.') end
    local ok, result = Housing.domain.lock(id, function()
        local property = State.get(id)
        if not property or not P.can(src, id, 'property.edit') or type(value) ~= 'table' then return false, 'You cannot manage this property.' end
        local limit = field == 'furniture' and Config.maxFurniture or field == 'stashes' and Config.maxStashes or Config.maxClothingSpots
        if #value > limit then return false, 'Property fixture limit reached.' end
        for _, fixture in pairs(value) do
            if type(fixture) ~= 'table' then return false, 'Invalid property fixture.' end
            if fixture.coords and (not Housing.validCoords(fixture.coords) or not Housing.world.contains(id, fixture.coords)) then return false, 'Fixture must be inside the property space.' end
            if field == 'furniture' and not Config.furnitureModels[fixture.model] then return false, 'Furniture model is not supported.' end
        end
        local changed = Housing.copy(property); changed[field] = value
        local saved, err = State.persist(changed, { actor = P.citizenId(src), action = 'property.legacyFixtures' })
        return saved ~= nil, saved or err
    end)
    if not ok then return fail(result) end
    State.broadcast()
    return result
end)
RegisterNetEvent('qbhousing:server:unsubscribeSpace', function(id) Housing.world.subscribe(source, id, false) end)
RegisterNetEvent('qbhousing:server:leaveProperty', function() Housing.world.leave(source) end)
RegisterNetEvent('qbhousing:server:closeCamera', function(token) Housing.world.closeCamera(source, token) end)
RegisterNetEvent('qbhousing:server:enter', function(id) Housing.world.enter(source, id) end)
exports('GetProperty', function(id) return Housing.copy(State.get(id)) end)
exports('HasAccess', function(src, id) return P.can(src, id, 'entry') == true end)
exports('HasPermission', function(src, id, action) return P.can(src, id, action) end)
