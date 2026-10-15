-- Phase 1 behavior under plain Lua: real housing validation, permissions and
-- persistence; only framework identities, transport and SQL are controlled.
local h = dofile('../qbcore/test/harness.lua')
local jsonTools = dofile('../qbcore/test/mocks.lua')
local json = { encode = jsonTools.stableEncode, decode = jsonTools.simpleDecode }
local owner, coowner, keyholder, outsider, realtor, admin = 1, 2, 3, 4, 5, 6
local ids = { 'OWNER', 'COOWNER', 'KEYHOLDER', 'OUTSIDER', 'REALTOR', 'ADMIN' }
local databaseError = 'controlled transaction failure'

local function copy(value) return json.decode(json.encode(value)) end

local function property(id)
    return {
        id = id or 'home', label = 'Test property', propertyType = 'house',
        owner = ids[owner], state = 'owned', revision = 1, ownershipRevision = 1,
        interior = { type = 'mlo', entrance = { x = 10, y = 10, z = 30 } },
        exterior = {
            polyzone = { { x = 0, y = 0, z = 30 }, { x = 20, y = 0, z = 30 }, { x = 20, y = 20, z = 30 } },
            minZ = 20, maxZ = 40,
        },
        keys = { [ids[keyholder]] = true }, coowners = { [ids[coowner]] = true },
        permissionGrants = {}, furniture = {}, stashes = {}, clothing = {}, doorlocks = {},
        legacyExtension = { consumer = 'preserve this data' },
    }
end

local function setup()
    local f = { writes = {}, events = {}, callbacks = {}, net = {}, provided = {}, queries = {} }
    local env = {}
    for key, value in pairs(_G) do env[key] = value end
    env.json, env.Config, env.Housing = json, nil, nil
    env.GetCurrentResourceName = function() return 'qbhousing' end
    env.GetInvokingResource = function() return nil end
    env.CreateThread = function() end
    env.AddEventHandler = function() end
    env.RegisterNetEvent = function(name, fn) f.net[name] = fn end
    env.TriggerClientEvent = function(name, target, ...)
        f.events[#f.events + 1] = { name = name, target = target, args = { ... } }
    end
    env.QB = {
        sql = {},
        permissions = { hasPermission = function(src) return src == admin end },
        callback = { register = function(name, handler, options)
            f.callbacks[name] = handler
            h.assertTrue(options and options.rateLimit, 'Every client callback must declare a request limit')
        end },
    }
    env.QB.sql.NULL = {}
    env.QB.sql.transaction = function(statements, params)
        f.writes[#f.writes + 1] = { statements = statements, params = params }
        if f.beforeWrite then f.beforeWrite() end
        if f.pauseNextWrite then
            f.pauseNextWrite = false
            return coroutine.yield('transaction wait')
        end
        if f.failWrite then return false, databaseError end
        return true
    end
    env.QB.sql.transactionChecked = function(statements)
        local ok, err = env.QB.sql.transaction(statements)
        return { success = ok, error = err }
    end
    env.QB.sql.execute = function(sql, params)
        f.writes[#f.writes + 1] = { statement = sql, params = params }
        if f.failWrite then return nil, databaseError end
        return { affectedRows = 1 }
    end
    env.QB.sql.query = function(sql, params)
        f.queries[#f.queries + 1] = { sql = sql, params = params }
        if f.query then return f.query(sql, params) end
        return {}
    end
    local core = {}
    function core.getPlayer(_, src)
        if not ids[src] then return nil end
        return { citizenid = ids[src], source = src, money = { bank = 1000000 },
            job = { name = src == realtor and 'realestate' or 'unemployed' } }
    end
    function core.getPlayerByCitizenId(_, cid)
        if f.lookupError then error('controlled character lookup failure') end
        for src, id in ipairs(ids) do if cid == id then return core.getPlayer(nil, src) end end
        return nil
    end
    function core.getOfflinePlayerData(_, cid)
        if f.lookupError then error('controlled offline lookup failure') end
        if cid == 'OFFLINE' then return { citizenid = cid } end
        return nil
    end
    env.exports = setmetatable({ qbcore = core }, {
        __call = function(_, name, fn) f.provided[name] = fn end,
    })
    function f.load(path)
        if path == 'server/main.lua' then
            for _, name in ipairs({ 'sales', 'leases', 'world', 'transactions', 'storage', 'doors', 'admin' }) do env.Housing[name] = env.Housing[name] or {} end
            env.Housing.storage.frozen = {}
            env.Housing.leases.permission = function() end
            env.Housing.leases.active = function() end
            env.Housing.transactions.busy = function() return false end
        end
        assert(loadfile(path, 't', env))()
    end
    for _, path in ipairs({
        'config.lua', 'shared/schema.lua', 'shared/permissions.lua', 'server/state.lua',
        'server/permissions.lua', 'server/ownership.lua', 'server/properties.lua',
    }) do f.load(path) end
    f.env, f.housing = env, env.Housing
    f.state = env.Housing.state
    f.state.ready = true
    f.state.properties.home = assert(env.Housing.normalise(property()))
    f.permissions, f.ownership, f.properties = env.Housing.permissions, env.Housing.ownership, env.Housing.properties
    return f
end

local function unchanged(f, before, writes)
    h.assertEqual(json.encode(f.state.properties.home), before, 'A refusal must preserve authoritative state')
    h.assertEqual(#f.writes, writes or 0, 'A refusal must not submit a write')
end

h.test('legacy normalization preserves unknown integration data and entry keys', function()
    local f = setup()
    local legacy = property()
    legacy.propertyType, legacy.revision = nil, nil
    local saved = assert(f.housing.normalise(legacy))
    h.assertEqual(saved.id, 'home')
    h.assertEqual(saved.propertyType, 'legacy')
    h.assertEqual(saved.legacyExtension.consumer, 'preserve this data')
    h.assertTrue(saved.keys[ids[keyholder]])
end)

h.test('land needs exterior bounds without an interior or mandatory garage', function()
    local f = setup()
    local value = property()
    value.propertyType, value.interior, value.garage = 'land', nil, nil
    local saved, err = f.housing.validateProperty(value)
    h.assertTrue(saved, err)
    h.assertEqual(saved.propertyType, 'land')
    h.assertEqual(saved.interior, nil)
    h.assertEqual(saved.garage, nil)
end)

h.test('strict creation rejects unknown types and missing required interiors', function()
    local f = setup()
    for _, kind in ipairs({ 'invented', 'house', 'apartment', 'mansion' }) do
        local value = property()
        value.propertyType, value.interior = kind, nil
        local saved, err = f.housing.validateProperty(value)
        h.assertFalse(saved, kind .. ' must be rejected')
        h.assertTrue(type(err) == 'string')
    end
end)

h.test('malformed and nonfinite world coordinates fail validation without throwing', function()
    local f = setup()
    for _, bad in ipairs({ math.huge, -math.huge, 0 / 0, '10', 20001 }) do
        local value = property()
        value.interior.entrance.x = bad
        local ok, saved, err = pcall(f.housing.validateProperty, value)
        h.assertTrue(ok, 'Malformed coordinate must return a useful error')
        h.assertFalse(saved)
        h.assertTrue(type(err) == 'string')
    end
end)

h.test('bounds and optional garage transforms are validated on the server', function()
    local f = setup()
    local value = property()
    value.exterior.minZ, value.exterior.maxZ = 40, 20
    h.assertFalse(f.housing.validateProperty(value))
    value = property()
    value.exterior.polyzone = { { x = 0, y = 0, z = 30 }, { x = 1, y = 1, z = 30 } }
    h.assertFalse(f.housing.validateProperty(value))
    value = property()
    value.garage = { slots = 1, coords = { x = 0, y = 0, z = 30 }, spawn = { x = 'bad', y = 1, z = 30 } }
    h.assertFalse(f.housing.validateProperty(value))
end)

h.test('land creator ignores forged ownership grants and protected gameplay fields', function()
    local f = setup()
    local value = property('new_land')
    value.propertyType, value.interior = 'land', nil
    value.owner, value.coowners = ids[outsider], { [ids[outsider]] = true }
    value.permissionGrants = { [ids[outsider]] = { entry = true } }
    value.pending, value.soldPrice, value.soldAt = { buyer = ids[outsider] }, 1, 1
    value.furniture = { { model = 'forged_reward' } }
    local ok, saved = f.properties.create(realtor, value)
    h.assertTrue(ok, saved)
    h.assertEqual(saved.propertyType, 'land')
    h.assertEqual(saved.interior, nil)
    h.assertEqual(saved.garage, nil)
    h.assertEqual(saved.owner, nil)
    h.assertEqual(saved.state, 'unowned')
    h.assertEqual(next(saved.coowners), nil)
    h.assertEqual(next(saved.permissionGrants), nil)
    h.assertEqual(next(saved.keys), nil)
    h.assertEqual(next(saved.furniture), nil)
    h.assertEqual(saved.pending, nil)
    h.assertEqual(saved.soldPrice, nil)
    h.assertEqual(saved.soldAt, nil)
end)

h.test('configuration edits preserve authoritative ownership access and unknown legacy data', function()
    local f = setup()
    local value = property()
    value.label, value.owner, value.state = 'Changed label', ids[outsider], 'listed'
    value.coowners, value.permissionGrants, value.keys = {}, { [ids[outsider]] = { entry = true } }, {}
    value.legacyExtension, value.furniture = { consumer = 'client overwrite' }, { { model = 'unapproved' } }
    local ok, saved = f.properties.edit(coowner, 'home', value, 1)
    h.assertTrue(ok, saved)
    h.assertEqual(saved.label, 'Changed label')
    h.assertEqual(saved.owner, ids[owner])
    h.assertEqual(saved.state, 'owned')
    h.assertTrue(saved.coowners[ids[coowner]])
    h.assertTrue(saved.keys[ids[keyholder]])
    h.assertEqual(next(saved.permissionGrants), nil)
    h.assertEqual(saved.legacyExtension.consumer, 'preserve this data')
    h.assertEqual(next(saved.furniture), nil)
    h.assertEqual(saved.ownershipRevision, 1)
    h.assertEqual(saved.revision, 2)
end)

h.test('unauthorized stale and renamed configuration edits submit no persistence', function()
    local f = setup()
    local before = json.encode(f.state.properties.home)
    h.assertFalse(f.properties.edit(outsider, 'home', property(), 1))
    h.assertFalse(f.properties.edit(owner, 'home', property(), 0))
    h.assertFalse(f.properties.edit(owner, 'home', property('different'), 1))
    h.assertFalse(f.properties.create(owner, property('new_property')))
    unchanged(f, before)
end)

h.test('unit parents must exist support units and cannot create an ancestry cycle', function()
    local f = setup()
    local value = property()
    for _, parentId in ipairs({ 'missing', 'home' }) do
        value.parentId = parentId
        h.assertFalse(f.properties.edit(owner, 'home', value, 1))
    end
    f.state.properties.child = assert(f.housing.normalise(property('child')))
    value.parentId = 'child'
    h.assertFalse(f.properties.edit(owner, 'home', value, 1), 'A house cannot be a building parent')
    f.state.properties.child.propertyType, f.state.properties.child.parentId = 'building', 'home'
    value.propertyType = 'building'
    h.assertFalse(f.properties.edit(owner, 'home', value, 1), 'Ancestry cycle must be rejected')
    h.assertEqual(#f.writes, 0)
end)

h.test('unit attachment and detachment require authority over the affected parent', function()
    local f = setup()
    local foreign = property('foreign_building')
    foreign.owner, foreign.coowners, foreign.propertyType = ids[outsider], {}, 'building'
    f.state.properties.foreign_building = assert(f.housing.normalise(foreign))
    local value = property()
    value.parentId = 'foreign_building'
    h.assertFalse(f.properties.edit(owner, 'home', value, 1))
    f.state.properties.home.parentId = 'foreign_building'
    value.parentId = nil
    h.assertFalse(f.properties.edit(owner, 'home', value, 1))
    h.assertEqual(#f.writes, 0)
end)

h.test('failed configuration persistence preserves the original registry and releases the creator', function()
    local f = setup()
    local original, before = f.state.properties.home, json.encode(f.state.properties.home)
    local value = property()
    value.label = 'Changed label'
    f.failWrite = true
    h.assertFalse(f.properties.edit(owner, 'home', value, 1))
    h.assertEqual(f.state.properties.home, original)
    unchanged(f, before, 1)
    f.failWrite = false
    local ok, saved = f.properties.edit(owner, 'home', value, 1)
    h.assertTrue(ok, saved)
    h.assertEqual(saved.label, 'Changed label')
end)

h.test('registered creator callbacks publish only successful mutations and keep new grants private', function()
    local f = setup()
    f.load('server/main.lua')
    for _, name in ipairs({ 'creatorSnapshot', 'propertyView', 'createProperty', 'editProperty', 'coowners', 'setPermission', 'permissions' }) do
        h.assertTrue(type(f.callbacks['qbhousing:' .. name]) == 'function', name .. ' must be registered')
    end
    local value = property('callback_land')
    value.propertyType, value.interior = 'land', nil
    local ok, saved = f.callbacks['qbhousing:createProperty'](realtor, value)
    h.assertTrue(ok, saved)
    h.assertEqual(#f.events, 1)
    h.assertEqual(f.events[1].name, 'qbhousing:client:synced')
    h.assertEqual(f.events[1].args[1].home.coowners, nil)
    h.assertEqual(f.events[1].args[1].home.permissionGrants, nil)
    h.assertFalse(f.callbacks['qbhousing:editProperty'](outsider, 'home', property(), 1))
    h.assertEqual(#f.events, 1)
    f.failWrite = true
    h.assertFalse(f.callbacks['qbhousing:editProperty'](owner, 'home', property(), 1))
    h.assertEqual(#f.events, 1)
end)

h.test('legacy archival helper retains its original admin and unowned-only contract', function()
    local f = setup()
    f.load('server/main.lua')
    local remove = f.properties.archiveLegacy
    h.assertFalse(remove(realtor, 'home'))
    h.assertFalse(remove(admin, 'home'))
    h.assertEqual(#f.writes, 0)
    f.state.properties.home.owner, f.state.properties.home.coowners = nil, {}
    h.assertTrue(remove(admin, 'home'))
    h.assertEqual(f.state.properties.home.state, 'archived')
    h.assertTrue(f.provided.GetProperty('home'))
    h.assertFalse(f.provided.HasAccess(owner, 'home'))
end)

h.test('archival cannot race a pending unit attachment through another property id', function()
    local f = setup()
    f.load('server/main.lua')
    local building = property('building')
    building.owner, building.coowners, building.propertyType, building.state = nil, {}, 'building', 'unowned'
    f.state.properties.building = assert(f.housing.normalise(building))
    local unit = property('unit')
    unit.parentId = 'building'
    f.pauseNextWrite = true
    local thread = coroutine.create(function() return f.properties.create(admin, unit) end)
    local started, marker = coroutine.resume(thread)
    h.assertTrue(started, marker)
    h.assertEqual(marker, 'transaction wait')
    h.assertFalse(f.properties.archiveLegacy(admin, 'building'))
    h.assertEqual(#f.writes, 1)
    local finished, ok, saved = coroutine.resume(thread, true)
    h.assertTrue(finished, ok)
    h.assertTrue(ok)
    h.assertEqual(saved.parentId, 'building')
    h.assertFalse(f.properties.archiveLegacy(admin, 'building'), 'An attached unit blocks subsequent archival')
    h.assertEqual(f.state.properties.building.state, 'unowned')
end)

h.test('configuration and membership changes invalidate old purchase confirmations', function()
    local f = setup()
    f.state.properties.home.pending = { buyer = ids[outsider], expires = os.time() + 300 }
    local value = property()
    value.listing = { price = 5000 }
    local ok, saved = f.properties.edit(owner, 'home', value, 1)
    h.assertTrue(ok, saved)
    h.assertEqual(saved.pending, nil)
    f.state.properties.home.pending = { buyer = ids[outsider], expires = os.time() + 300 }
    local changed, membership = f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE', saved.revision)
    h.assertTrue(changed, membership)
    h.assertEqual(membership.pending, nil)
end)

h.test('entry roles stay distinct and unknown actions deny even administrators', function()
    local f = setup()
    for _, src in ipairs({ owner, coowner, keyholder }) do h.assertTrue(f.permissions.can(src, 'home', 'entry')) end
    for _, src in ipairs({ outsider, realtor }) do h.assertFalse(f.permissions.can(src, 'home', 'entry')) end
    h.assertFalse(f.permissions.can(admin, 'home', 'invented:authority'))
    h.assertFalse(f.permissions.can(owner, 'missing', 'entry'))
    h.assertFalse(f.permissions.can(999, 'home', 'entry'))
end)

h.test('forged property snapshots cannot provide authority and admins need camera grants', function()
    local f = setup()
    h.assertFalse(f.permissions.can(outsider, { id = 'home', owner = ids[outsider] }, 'entry'))
    h.assertFalse(f.permissions.can(admin, 'home', 'camera.view'))
    h.assertTrue(f.permissions.can(admin, 'home', 'property.edit'))
    h.assertEqual(f.permissions.relationship(coowner, 'home'), 'coowner')
    h.assertEqual(f.permissions.relationship(keyholder, 'home'), 'keyholder')
end)

h.test('access management views require owner authority and return detached relationships', function()
    local f = setup()
    h.assertFalse(f.ownership.view(outsider, 'home'))
    h.assertFalse(f.ownership.view(keyholder, 'home'))
    local view = assert(f.ownership.view(coowner, 'home'))
    h.assertTrue(view.coowners[ids[coowner]])
    view.coowners[ids[outsider]] = true
    h.assertFalse(f.state.properties.home.coowners[ids[outsider]])
end)

h.test('only primary owner can add or remove coowners', function()
    local f = setup()
    local before = json.encode(f.state.properties.home)
    for _, src in ipairs({ coowner, keyholder, outsider, realtor }) do
        local ok, err = f.ownership.setCoowner(src, 'home', 'add', 'OFFLINE', 1)
        h.assertFalse(ok)
        h.assertTrue(type(err) == 'string')
        unchanged(f, before)
    end
end)

h.test('coowner targets must exist and cannot duplicate existing ownership', function()
    local f = setup()
    local before = json.encode(f.state.properties.home)
    for _, cid in ipairs({ ids[owner], ids[coowner], 'MISSING' }) do
        h.assertFalse(f.ownership.setCoowner(owner, 'home', 'add', cid, 1))
        unchanged(f, before)
    end
    f.lookupError = true
    local ok, result = pcall(f.ownership.setCoowner, owner, 'home', 'add', 'OFFLINE', 1)
    h.assertTrue(ok, 'Framework lookup error must fail closed')
    h.assertFalse(result)
    unchanged(f, before)
end)

h.test('character lookup cannot change the acting character or substitute the target', function()
    local f = setup()
    local before = json.encode(f.state.properties.home)
    f.env.exports.qbcore.getPlayerByCitizenId = function() return { citizenid = 'WRONG_TARGET' } end
    h.assertFalse(f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE', 1))
    unchanged(f, before)
    f.env.exports.qbcore.getPlayerByCitizenId = function()
        local original = f.env.exports.qbcore.getPlayer
        f.env.exports.qbcore.getPlayer = function(_, src)
            if src == owner then return { citizenid = ids[outsider], source = src, job = { name = 'unemployed' } } end
            return original(nil, src)
        end
        return { citizenid = 'OFFLINE' }
    end
    h.assertFalse(f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE', 1))
    unchanged(f, before)
end)

h.test('missing malformed and stale revisions cannot change memberships', function()
    local f = setup()
    local before = json.encode(f.state.properties.home)
    for _, revision in ipairs({ false, '1', 0, -1, 2, 1.5, math.huge }) do
        h.assertFalse(f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE', revision))
        unchanged(f, before)
    end
    h.assertFalse(f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE'))
    unchanged(f, before)
end)

h.test('a migrated revision zero record can receive its first relationship write', function()
    local f = setup()
    f.state.properties.home.revision, f.state.properties.home.ownershipRevision = 0, 0
    local ok, saved = f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE', 0)
    h.assertTrue(ok)
    h.assertEqual(saved.revision, 1)
    h.assertEqual(saved.ownershipRevision, 1)
end)

h.test('failed membership persistence changes neither title nor permissions', function()
    local f = setup()
    local original = f.state.properties.home
    local before = json.encode(original)
    f.failWrite = true
    local ok, err = f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE', 1)
    h.assertFalse(ok)
    h.assertTrue(type(err) == 'string')
    h.assertEqual(f.state.properties.home, original)
    unchanged(f, before, 1)
    h.assertEqual(#f.events, 0)
    f.failWrite = false
    h.assertTrue(f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE', 1), 'A failed write must release the guard')
end)

h.test('successful membership persists one transaction before publishing access', function()
    local f = setup()
    f.beforeWrite = function()
        h.assertFalse(f.state.properties.home.coowners.OFFLINE)
        h.assertEqual(#f.events, 0)
    end
    local ok, saved = f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE', 1)
    h.assertTrue(ok)
    h.assertTrue(saved.coowners.OFFLINE)
    h.assertEqual(saved.revision, 2)
    h.assertEqual(saved.ownershipRevision, 2)
    h.assertEqual(saved.legacyExtension.consumer, 'preserve this data')
    h.assertEqual(#f.writes, 1)
    h.assertTrue(type(f.writes[1].statements) == 'table', 'Relationships and audit belong to the property transaction')
    saved.coowners.FORGED = true
    h.assertFalse(f.state.properties.home.coowners.FORGED, 'Returned data must be detached')
end)

h.test('revoking entry overrides a legacy key immediately and removal restores no forged right', function()
    local f = setup()
    h.assertTrue(f.permissions.can(keyholder, 'home', 'entry'))
    local ok, saved = f.ownership.setPermission(owner, 'home', ids[keyholder], 'entry', false, 1)
    h.assertTrue(ok)
    h.assertFalse(f.permissions.can(keyholder, 'home', 'entry'))
    h.assertEqual(saved.permissionGrants[ids[keyholder]].entry, false)
    h.assertFalse(saved.keys[ids[keyholder]])
    h.assertTrue(f.ownership.setPermission(coowner, 'home', ids[keyholder], 'entry', true, saved.revision))
    h.assertTrue(f.permissions.can(keyholder, 'home', 'entry'))
end)

h.test('keyholders cannot share rights and owners cannot alter title through grants', function()
    local f = setup()
    local before = json.encode(f.state.properties.home)
    h.assertFalse(f.ownership.setPermission(keyholder, 'home', ids[outsider], 'entry', true, 1))
    for _, target in ipairs({ ids[owner], ids[coowner] }) do
        h.assertFalse(f.ownership.setPermission(owner, 'home', target, 'entry', false, 1))
    end
    h.assertFalse(f.ownership.setPermission(owner, 'home', ids[outsider], 'invented:authority', true, 1))
    unchanged(f, before)
end)

h.test('permission persistence failure preserves previous grants and revision', function()
    local f = setup()
    local before = json.encode(f.state.properties.home)
    f.failWrite = true
    h.assertFalse(f.ownership.setPermission(owner, 'home', ids[keyholder], 'entry', false, 1))
    unchanged(f, before, 1)
    h.assertTrue(f.permissions.can(keyholder, 'home', 'entry'))
    h.assertEqual(#f.events, 0)
end)

h.test('a pending transaction prevents a second membership writer on that property', function()
    local f = setup()
    f.pauseNextWrite = true
    local thread = coroutine.create(function() return f.ownership.setCoowner(owner, 'home', 'add', 'OFFLINE', 1) end)
    local started, marker = coroutine.resume(thread)
    h.assertTrue(started, marker)
    h.assertEqual(marker, 'transaction wait')
    h.assertFalse(f.ownership.setPermission(owner, 'home', ids[outsider], 'entry', true, 1))
    h.assertEqual(#f.writes, 1)
    local finished, ok, saved = coroutine.resume(thread, true)
    h.assertTrue(finished, ok)
    h.assertTrue(ok)
    h.assertTrue(saved.coowners.OFFLINE)
    h.assertEqual(coroutine.status(thread), 'dead')
end)

local function storedRow(value)
    return {
        id = value.id, owner = value.owner, definition = json.encode(value),
        property_type = value.propertyType, revision = value.revision, ownership_revision = value.ownershipRevision,
    }
end

local function loadRows(f, rows, coowners, grants, units)
    f.query = function(sql, params)
        if sql:find('FROM `qbhousing_properties`', 1, true) then return rows end
        if sql:find('FROM `qbhousing_coowners`', 1, true) then return coowners or {} end
        if sql:find('FROM `qbhousing_permissions`', 1, true) then return grants or {} end
        if sql:find('FROM `qbhousing_units`', 1, true) then return units or {} end
        if sql:find('FROM `players`', 1, true) then
            local result = {}
            for _, cid in ipairs(params or {}) do
                for _, existing in ipairs(ids) do
                    if cid == existing then result[#result + 1] = { citizenid = cid } end
                end
                if cid == 'OFFLINE' then result[#result + 1] = { citizenid = cid } end
            end
            return result
        end
        error('Unexpected SQL read: ' .. sql)
    end
end

h.test('restart restores authoritative relationships and explicit denial over legacy keys', function()
    local f = setup()
    local stored = property()
    stored.coowners = { FORGED_JSON_OWNER = true }
    stored.permissionGrants = { [ids[outsider]] = { entry = true } }
    loadRows(f, { storedRow(stored) },
        { { property_id = 'home', citizenid = ids[coowner] } },
        { { property_id = 'home', citizenid = ids[keyholder], action = 'entry', allowed = 0 } })
    local loaded, err = f.state.load()
    h.assertTrue(loaded, err)
    h.assertTrue(f.permissions.can(coowner, 'home', 'entry'))
    h.assertFalse(f.state.properties.home.coowners.FORGED_JSON_OWNER)
    h.assertFalse(f.permissions.can(keyholder, 'home', 'entry'))
    h.assertFalse(f.permissions.can(outsider, 'home', 'entry'))
    h.assertEqual(f.state.properties.home.legacyExtension.consumer, 'preserve this data')
    h.assertTrue(f.writes[1].statement:find('qbhousing_legacy_backup', 1, true), 'Back up definitions before conversion')
end)

h.test('unknown types and orphan owners block migration activation without guessing', function()
    for _, field in ipairs({ 'owner', 'propertyType' }) do
        local f = setup()
        local before = json.encode(f.state.properties)
        local value = property()
        value[field] = 'unknown'
        loadRows(f, { storedRow(value) })
        local loaded, err = f.state.load()
        h.assertFalse(loaded)
        h.assertTrue(type(err) == 'string')
        h.assertEqual(json.encode(f.state.properties), before)
    end
end)

h.test('invalid stored unit parents and cycles prevent registry publication', function()
    for _, invalid in ipairs({ 'wrong_type', 'cycle' }) do
        local f = setup()
        local before = json.encode(f.state.properties)
        local a, b = property('unit_a'), property('unit_b')
        a.propertyType = 'building'
        if invalid == 'cycle' then b.propertyType = 'building' end
        local units = { { property_id = 'unit_a', parent_id = 'unit_b', unit_label = 'a' } }
        if invalid == 'cycle' then units[#units + 1] = { property_id = 'unit_b', parent_id = 'unit_a', unit_label = 'b' } end
        loadRows(f, { storedRow(a), storedRow(b) }, {}, {}, units)
        local loaded, err = f.state.load()
        h.assertFalse(loaded)
        h.assertTrue(type(err) == 'string')
        h.assertEqual(json.encode(f.state.properties), before)
    end
end)

h.test('corrupt and conflicting stored identities fail the whole load without partial publication', function()
    for _, bad in ipairs({ 'not JSON', json.encode({ id = 'different', owner = ids[owner] }), json.encode({ id = 'home', owner = 'different' }) }) do
        local f = setup()
        local before = json.encode(f.state.properties)
        local row = storedRow(property())
        row.definition = bad
        loadRows(f, { storedRow(property('valid')), row })
        local loaded, err = f.state.load()
        h.assertFalse(loaded)
        h.assertTrue(type(err) == 'string')
        h.assertEqual(json.encode(f.state.properties), before)
    end
end)

h.test('malformed nested legacy records report a load failure instead of crashing bootstrap', function()
    for _, field in ipairs({ 'interior', 'garage' }) do
        local f = setup()
        local before = json.encode(f.state.properties)
        local value = property()
        value[field] = 42
        loadRows(f, { storedRow(value) })
        local ok, loaded, err = pcall(f.state.load)
        h.assertTrue(ok, 'Malformed nested ' .. field .. ' must produce a repair diagnostic')
        h.assertFalse(loaded)
        h.assertTrue(type(err) == 'string')
        h.assertEqual(json.encode(f.state.properties), before)
    end
end)

h.test('backup or legacy-key import failure prevents publishing a new registry', function()
    local f = setup()
    local before = json.encode(f.state.properties)
    loadRows(f, { storedRow(property('different')) })
    f.failWrite = true
    h.assertFalse(f.state.load())
    h.assertEqual(json.encode(f.state.properties), before)
    f.env.QB.sql.execute = function() return { affectedRows = 1 } end
    h.assertFalse(f.state.load())
    h.assertEqual(json.encode(f.state.properties), before)
end)

h.test('public snapshots omit new relationship grants and are detached from live data', function()
    local f = setup()
    f.state.properties.home.permissionGrants[ids[outsider]] = { ['camera.view'] = true }
    local view = f.state.snapshot()
    h.assertEqual(view.home.coowners, nil)
    h.assertEqual(view.home.permissionGrants, nil)
    view.home.legacyExtension.consumer = 'modified'
    h.assertEqual(f.state.properties.home.legacyExtension.consumer, 'preserve this data')
end)

h.test('public synchronization hides private quotes and pending buyers while preserving server records', function()
    local f = setup()
    f.state.properties.home.listing = { type = 'direct', price = 1234, biography = 'Private negotiations' }
    f.state.properties.home.pending = { buyer = 'PRIVATE_BUYER' }
    local public = f.state.snapshot().home
    h.assertEqual(public.listing, nil)
    h.assertEqual(public.pending, nil)
    h.assertEqual(f.state.get('home').listing.price, 1234)
    h.assertEqual(f.state.get('home').pending.buyer, 'PRIVATE_BUYER')
end)

h.report('housing phase 1')
