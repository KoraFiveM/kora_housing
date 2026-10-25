local h = dofile('../qbcore/test/harness.lua')
local tools = dofile('../qbcore/test/mocks.lua')
local json = { encode = tools.stableEncode, decode = tools.simpleDecode }
local function setup()
    local env = {}; for key, value in pairs(_G) do env[key] = value end
    local f = { stashes = {}, characters = { OWNER = { citizenid = 'OWNER', license = 'license:owner' }, NEW = { citizenid = 'NEW', license = 'license:new' } }, provided = {} }
    env.json, env.Config, env.Housing = json, nil, nil
    for _, path in ipairs({ 'config.lua', 'shared/schema.lua', 'shared/permissions.lua' }) do assert(loadfile(path, 't', env))() end
    local housing = env.Housing
    housing.state = { ready = true, properties = {}, writes = {}, uncertain = {} }
    function housing.state.get(id) return housing.state.properties[id] end
    function housing.state.isUncertain(id) return housing.state.uncertain[id] end
    housing.world = { ready = true, furniture = {} }
    housing.legacy = {}
    env.exports = setmetatable({ qbcore = {
        getPlayerByCitizenId = function(_, cid) return f.characters[cid] end,
        getOfflinePlayerData = function(_, cid) return f.characters[cid] end,
    } }, { __call = function(_, name, fn) f.provided[name] = fn end })
    env.QB = { sql = { query = function()
        if f.duringRead then f.duringRead() end
        if f.failSQL then return nil, 'storage unavailable' end
        if f.throwSQL then error('driver stopped') end
        return f.stashes
    end } }
    env.GetInvokingResource = function() return f.invoker or 'qbsql' end
    env.CreateThread = function(fn) fn() end
    env.GetGameTimer = function() return 0 end
    env.Wait = function() error('unexpected wait') end
    for _, path in ipairs({ 'server/permissions.lua', 'server/compat_sql.lua' }) do assert(loadfile(path, 't', env))() end
    f.housing, f.env = housing, env
    f.home = { id = 'home1', label = 'Home', owner = 'OWNER', state = 'owned', revision = 1,
        keys = { KEY = true }, coowners = {}, permissionGrants = {}, clothing = {},
        interior = { type = 'shell', name = 'CreateApartmentShell', entrance = { x = 1, y = 2, z = 40, w = 90 } },
        garage = { coords = { x = 5, y = 6, z = 7, w = 30 }, spawn = { x = 5, y = 6, z = 7, w = 30 } },
        listing = { price = 5000 } }
    housing.state.properties.home1 = f.home
    return f
end

h.test('native owner changes and revocations replace stale stock identities immediately', function()
    local f = setup()
    local rows = assert(f.housing.legacy.read('citizen', { 'OWNER' }))
    h.assertEqual(rows[1].identifier, 'license:owner')
    h.assertEqual(json.decode(rows[1].keyholders)[1], 'KEY')
    f.home.owner, f.home.revision = 'NEW', 2
    f.home.permissionGrants.KEY = { entry = false }
    h.assertEqual(#f.housing.legacy.read('citizen', { 'OWNER' }), 0)
    rows = assert(f.housing.legacy.read('identity', { 'license:new', 'NEW' }))
    h.assertEqual(rows[1].citizenid, 'NEW')
    h.assertEqual(json.encode(json.decode(rows[1].keyholders)), '["NEW"]')
    f.home.state = 'archived'
    h.assertEqual(#f.housing.legacy.read('locations', {}), 0)
end)

h.test('location and physical fixture fields come from native coordinates and live rows', function()
    local f = setup()
    local row = assert(f.housing.legacy.read('location', { 'home1' }))[1]
    h.assertEqual(json.decode(row.coords).enter.h, 90)
    h.assertEqual(json.decode(row.garage).x, 5)
    h.assertEqual(row.tier, 1)
    f.home.interior.name='CreateFurniMotelStandard'
    h.assertEqual(f.housing.legacy.read('location',{'home1'})[1].tier,16)
    f.home.interior.name='CreateApartmentShell'
    f.home.interior.entrance.x, f.home.listing.price = 12, 6000
    row = assert(f.housing.legacy.read('locations', {}))[1]
    h.assertEqual(json.decode(row.coords).enter.x, 12)
    h.assertEqual(row.price, 6000)
    f.stashes = { { id = 'p:home1', coords = '{"x":3,"y":4,"z":5}' } }
    f.housing.world.furniture.chair = { id = 'chair', propertyId = 'home1', status = 'placed', model = 'prop_chair_01a', coords = { x = 1, y = 2, z = 3 }, rotation = { pitch = 0, roll = 1, yaw = 2 } }
    row = assert(f.housing.legacy.read('house', { 'home1' }))[1]
    h.assertEqual(json.decode(row.stash).x, 3)
    h.assertEqual(json.decode(row.decorations)[1].hashname, 'prop_chair_01a')
    h.assertEqual(json.decode(row.decorations)[1].rotz, 2)
    f.home.clothing={{coords={x=1,y=2,z=3}}};f.home.logout={x=4,y=5,z=6}
    row=assert(f.housing.legacy.read('house',{'home1'}))[1]
    h.assertEqual(json.decode(row.outfit).z,3);h.assertEqual(json.decode(row.logout).z,6)
end)

h.test('unmapped archive fixtures and unsupported shell or garage layouts fail explicitly', function()
    local f = setup()
    f.home.legacy = { source = 'qb-houses', unmappedFixtures = { stash = true } }
    local rows, err = f.housing.legacy.read('house', { 'home1' })
    h.assertEqual(rows, nil); h.assertTrue(err:find('migration', 1, true))
    h.assertEqual(f.housing.legacy.read('owned', { 'home1' })[1].owned, 1)
    f.home.legacy = nil; f.home.interior.type = 'mlo'
    rows, err = f.housing.legacy.read('locations', {}); h.assertEqual(rows, nil); h.assertTrue(err:find('tier mapping', 1, true))
    f.home.interior.type = 'shell'; f.home.garage.spawn.x = 99
    rows, err = f.housing.legacy.read('locations', {}); h.assertEqual(rows, nil); h.assertTrue(err:find('split garage', 1, true))
end)

h.test('reads hold native mutation gates while SQL yields and always release on failure', function()
    local f = setup()
    f.duringRead = function() h.assertTrue(f.housing.state.writes.home1) end
    h.assertTrue(f.housing.legacy.read('owners', {}) ~= nil)
    h.assertEqual(f.housing.state.writes.home1, nil)
    for _, mode in ipairs({ 'failSQL', 'throwSQL' }) do
        f[mode] = true
        local rows, err = f.housing.legacy.read('owners', {})
        h.assertEqual(rows, nil); h.assertEqual(type(err), 'string'); h.assertEqual(f.housing.state.writes.home1, nil)
        f[mode] = nil
    end
    f.housing.state.uncertain.home1 = true
    h.assertEqual(f.housing.legacy.read('owned', { 'home1' }), nil)
end)

h.test('live leases retain native entry policy and export caller cannot be spoofed by data', function()
    local f = setup()
    f.housing.leases = { active = function() return { tenant = 'TENANT' } end,
        permission = function(_, _, _, cid) return cid == 'TENANT' end }
    local row = assert(f.housing.legacy.read('owners', {}))[1]
    h.assertEqual(row.keyholders, '["TENANT"]')
    local result, failure
    f.invoker = 'other'
    f.provided.readLegacyHousing('owners', {}, function(rows, err) result, failure = rows, err end)
    h.assertEqual(result, nil); h.assertTrue(failure:find('restricted', 1, true))
    f.invoker = 'qbsql'
    f.provided.readLegacyHousing('owners', {}, function(rows, err) result, failure = rows, err end)
    h.assertEqual(result[1].house, 'home1'); h.assertEqual(failure, nil)
end)

h.report('qbhousing legacy SQL projection')
