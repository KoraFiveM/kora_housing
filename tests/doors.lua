local H = dofile('../qbcore/test/harness.lua')
local tools = dofile('../qbcore/test/mocks.lua')
local function copy(value) return tools.simpleDecode(tools.stableEncode(value)) end

local function setup()
    local f = { allowed = false, admin = false, bound = {}, released = {}, saved = 0, doors = {
        front = { id = 'front', coords = { x = 0, y = 0, z = 0 }, definition = { lockpick = true } },
        far = { id = 'far', coords = { x = 500, y = 0, z = 0 }, definition = {} },
    }, records = { home = { id = 'home', owner = 'OWNER', revision = 1, state = 'owned', interior = { entrance = { x = 0, y = 0, z = 0 } }, doorlocks = {} } } }
    local env = {}; for key, value in pairs(_G) do env[key] = value end
    env.Config = {}; env.GetCurrentResourceName = function() return 'qbhousing' end
    env.AddEventHandler = function() end
    local api = {}
    function api.getAllDoors() local rows = {}; for _, door in pairs(f.doors) do rows[#rows + 1] = copy(door) end; return rows end
    function api.getDoor(_, id) return f.doors[id] and copy(f.doors[id]) or false end
    function api.RegisterDoorPolicy(_, id, callback)
        if f.failBind then return false, 'controlled binding failure' end
        f.doors[id].definition.policyOwner, f.bound[id] = 'qbhousing', callback
        return true
    end
    function api.ReleaseDoorPolicy(_, id)
        f.doors[id].definition.policyOwner, f.bound[id], f.released[id] = nil, nil, true
        return true
    end
    env.exports = { qbdoorlock = api }
    env.Housing = { copy = copy, finite = function(v) return type(v) == 'number' and v == v and math.abs(v) ~= math.huge end,
        state = { ready = true, properties = f.records },
        permissions = { citizenId = function() return f.cid or 'OWNER' end, isAdmin = function() return f.admin end,
            can = function() return f.allowed end },
        domain = { owner = function(property, cid) return property.owner == cid or property.coowners and property.coowners[cid] end },
        world = { contains = function() return false end },
    }
    local state = env.Housing.state
    state.get = function(id) return f.records[id] end
    state.isUncertain = function() return f.uncertain == true end
    state.withWrite = function(_, fn) return fn() end
    state.persist = function(property, audit)
        if f.failSave then return nil, 'controlled save failure' end
        assert(audit.action == 'doors.configure')
        property.revision = property.revision + 1
        f.records[property.id], f.saved = copy(property), f.saved + 1
        return copy(property)
    end
    assert(loadfile('server/doors.lua', 't', env))()
    f.service, f.env = env.Housing.doors, env
    return f
end

H.test('door registration enforces current entry grants and validated lockpick policy', function()
    local f = setup()
    assert(f.service.configure(1, 'home', { 'front' }, 1))
    H.assertEqual(f.bound.front(1, 'front', { lockpick = false }), false)
    f.allowed = true
    H.assertEqual(f.bound.front(1, 'front', { lockpick = false }), true)
    f.allowed = false
    H.assertEqual(f.bound.front(1, 'front', { lockpick = true, authorised = true, door = { lockpick = true } }), true)
    H.assertEqual(f.bound.front(1, 'front', { lockpick = true, authorised = false, door = { lockpick = true } }), false)
    f.env.Config.allowDoorLockpick = false
    H.assertEqual(f.bound.front(1, 'front', { lockpick = true, authorised = true, door = { lockpick = true } }), false)
end)

H.test('door configuration rejects stale revisions, strangers, distant and foreign doors', function()
    local f = setup()
    H.assertEqual(f.service.configure(1, 'home', { 'front' }, 0), false)
    f.cid = 'OTHER'; H.assertEqual(f.service.configure(1, 'home', { 'front' }, 1), false)
    f.cid = 'OWNER'; H.assertEqual(f.service.configure(1, 'home', { 'far' }, 1), false)
    f.doors.front.definition.policyOwner = 'another'
    H.assertEqual(f.service.configure(1, 'home', { 'front' }, 1), false)
    H.assertEqual(f.saved, 0)
end)

H.test('door registration preserves legacy records and rejects cross-property assignment', function()
    local f = setup()
    f.records.home.doorlocks = { { id = 'front', legacyFlag = true } }
    assert(f.service.load())
    H.assertEqual(f.records.home.doorlocks[1].legacyFlag, true)
    f.records.other = { id = 'other', owner = 'OWNER', revision = 1, doorlocks = {} }
    H.assertEqual(f.service.configure(1, 'other', { 'front' }, 1), false)
    f.records.other.doorlocks = { 'front' }
    H.assertEqual(f.service.load(), false)
end)

H.test('failed persistence leaves mappings unchanged and releases newly acquired policies', function()
    local f = setup(); f.failSave = true
    H.assertEqual(f.service.configure(1, 'home', { 'front' }, 1), false)
    H.assertEqual(#f.records.home.doorlocks, 0)
    H.assertEqual(f.released.front, true)
    H.assertEqual(f.doors.front.definition.policyOwner, nil)
end)

H.test('explicit unlink releases protection and orphan reconciliation survives a stop', function()
    local f = setup()
    assert(f.service.configure(1, 'home', { 'front' }, 1))
    assert(f.service.configure(1, 'home', {}, 2))
    H.assertEqual(f.released.front, true)
    f.doors.front.definition.policyOwner = 'qbhousing'; f.released.front = nil
    assert(f.service.load())
    H.assertEqual(f.released.front, true)
end)

H.test('unknown save outcomes retain acquired protection until authoritative reconciliation', function()
    local f = setup(); f.failSave, f.uncertain = true, true
    H.assertEqual(f.service.configure(1, 'home', { 'front' }, 1), false)
    H.assertEqual(f.released.front, nil)
    H.assertEqual(f.doors.front.definition.policyOwner, 'qbhousing')
    f.allowed = true
    H.assertEqual(f.bound.front(1, 'front', { lockpick = true, authorised = true, door = { lockpick = true } }), false)
    f.records.home.doorlocks, f.uncertain = { 'front' }, false
    assert(f.service.refresh('home'))
    H.assertEqual(f.bound.front(1, 'front', { lockpick = false }), true)
end)

H.report('housing door registry')
