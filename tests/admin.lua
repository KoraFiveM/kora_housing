local h = dofile('../kora_core/test/harness.lua')
local m = dofile('../kora_core/test/mocks.lua')
local function setup()
    local f, e = { writes = {}, allowed = true, timers = {}, events = {} }, {}
    for k, v in pairs(_G) do e[k] = v end
    e.json = { encode = m.stableEncode, decode = m.simpleDecode }
    e.GetCurrentResourceName = function() return 'kora_housing' end
    e.AddEventHandler = function() end
    e.TriggerClientEvent = function(name) f.events[#f.events + 1] = name end
    e.QB = { timers = { clearTimeout = function() end, setTimeout = function(fn) f.timers[#f.timers+1] = fn; return #f.timers end }, sql = { NULL = '__NULL__' } }
    function e.QB.sql.transactionChecked(writes)
        if f.fail then return { success = false, message = 'SQL unavailable' } end
        f.writes[#f.writes + 1] = writes
        return { success = true }
    end
    function e.QB.sql.scalar(sql)
        if sql == 'SELECT UUID()' then return 'uuid' end
        if f.dbFail then return nil, 'SQL unavailable' end
        return f.leaseBlock and 1 or 0
    end
    function e.QB.sql.query() return f.audit or {} end
    local function load(path) assert(loadfile(path, 't', e))() end
    load('config.lua'); load('shared/schema.lua'); load('server/state.lua')
    local H, S = e.Housing, e.Housing.state
    H.permissions = { isAdmin = function(src) return src == 9 end, citizenId = function(src) return 'CID' .. src end }
    H.properties = { configurationBusy = function() return f.configBusy end }
    H.transactions = { busy = function() return f.pending end }
    H.storage = { frozen = {}, canArchive = function() return not f.nonempty, 'Unowned belongings' end,
        freezeForSale = function() f.frozen = true; return true end, refresh = function() return true end,
        archive = function() f.storageCalls = (f.storageCalls or 0) + 1; return not f.storageFail, 'Inventory busy' end }
    H.world = { ready = true, changed = function() end, archive = function() f.worldCalls = (f.worldCalls or 0) + 1; return not f.worldFail, 'World SQL unavailable' end }
    H.doors = { refresh = function() return true end }
    load('server/domain.lua'); load('server/admin.lua')
    S.ready = true
    S.properties.home = assert(H.normalise({ id = 'home', owner = 'OWNER', coowners = { COOWNER = true }, propertyType = 'land', revision = 3, state = 'owned', legacyField = true }))
    f.H, f.S = H, S
    return f
end
h.test('only administrators can review or archive and confirmation binds source and revision', function()
    local f = setup()
    h.assertFalse(f.H.admin.preflight(1, 'home'))
    local ok, preview = f.H.admin.preflight(9, 'home'); h.assertTrue(ok)
    h.assertFalse(f.H.admin.archive(1, 'home', preview.token))
    f.S.properties.home.revision = 4
    h.assertFalse(f.H.admin.archive(9, 'home', preview.token))
    h.assertEqual(#f.writes, 0)
end)
h.test('leases deposits pending payments child units configuration and nonempty unowned storage block archival', function()
    for _, key in ipairs({ 'leaseBlock', 'pending', 'configBusy', 'nonempty', 'dbFail' }) do
        local f = setup(); f[key] = true
        h.assertFalse(f.H.admin.preflight(9, 'home'), key)
        h.assertEqual(#f.writes, 0)
    end
    local f = setup(); f.S.properties.child = { parentId = 'home', state = 'owned' }
    h.assertFalse(f.H.admin.preflight(9, 'home'))
end)
h.test('archival retains ownership and history, protects recovery before finalizing, and audits both stages', function()
    local f = setup()
    local ok, preview = f.H.admin.preflight(9, 'home'); h.assertTrue(ok)
    h.assertTrue(f.H.admin.archive(9, 'home', preview.token))
    h.assertEqual(f.S.properties.home.state, 'archived')
    h.assertEqual(f.S.properties.home.owner, 'OWNER')
    h.assertTrue(f.S.properties.home.coowners.COOWNER)
    h.assertTrue(f.S.properties.home.legacyField)
    h.assertEqual(f.storageCalls, 1); h.assertEqual(f.worldCalls, 1)
    h.assertEqual(#f.writes, 2)
    h.assertFalse(f.H.admin.archive(9, 'home', preview.token), 'Consumed confirmation cannot repeat work')
    h.assertTrue(f.H.admin.finish('home'))
    h.assertEqual(f.storageCalls, 1)
end)
h.test('recovery failure leaves durable archiving status and retry completes without reopening occupancy', function()
    local f = setup(); f.worldFail = true
    local _, preview = f.H.admin.preflight(9, 'home')
    local ok, result = f.H.admin.archive(9, 'home', preview.token)
    h.assertTrue(ok); h.assertEqual(result.status, 'archiving')
    h.assertEqual(f.S.properties.home.state, 'archiving')
    h.assertTrue(#f.timers > 0)
    f.worldFail = false; f.H.admin.resume()
    h.assertEqual(f.S.properties.home.state, 'archived')
end)
h.test('failed archival persistence keeps the original property and audit remains admin-only', function()
    local f = setup(); local _, preview = f.H.admin.preflight(9, 'home'); f.fail = true
    h.assertFalse(f.H.admin.archive(9, 'home', preview.token))
    h.assertEqual(f.S.properties.home.state, 'owned')
    h.assertFalse(f.H.admin.audit(1, 'home'))
    f.audit = { { action = 'property.create' } }
    local ok, rows = f.H.admin.audit(9, 'home'); h.assertTrue(ok); h.assertEqual(#rows, 1)
end)
h.report('housing administration')
