-- Real physical-space/furniture/security service; controlled identities, SQL and natives.
local jsonTools = dofile('../qbcore/test/mocks.lua')
json = { encode = jsonTools.stableEncode, decode = jsonTools.simpleDecode }
dofile('config.lua')
dofile('shared/schema.lua')
local checks, writes, events, rows = 0, {}, {}, {}
local failed, ambiguous, now = false, false, 1000000
local realOs = os
os = { time = function() return now end, date = realOs.date }
local timers, hooks = {}, {}
function SetTimeout(_, handler) timers[#timers + 1] = handler end
function AddEventHandler(name, handler) hooks[name] = handler end
function TriggerClientEvent(name, target, ...) events[#events + 1] = { name = name, target = target, values = { ... } } end
function GetCurrentResourceName() return 'qbhousing' end
local positions = { [1] = { x = 5, y = 5, z = 2 }, [2] = { x = 5, y = 5, z = 2 }, [3] = { x = 5, y = 5, z = 2 } }
function GetPlayerPed(src) return positions[src] and src or 0 end
function GetEntityCoords(ped) return positions[ped] end
local names = { [1] = 'OWNER', [2] = 'TENANT', [3] = 'GUEST' }
local grants, activeLease = {}, nil
Housing.permissions = {
    citizenId = function(src) return names[src] end,
    isAdmin = function() return false end,
    can = function(src, id, action)
        if action == 'camera.view' then return src == 1 or Housing.world.hasCameraGrant(src, id) end
        return src == 1 or grants[src] and grants[src][action] == true
    end,
}
Housing.leases = { active = function() return activeLease end }
Housing.state = { ready = true, properties = {
    home = { id = 'home', label = 'Home', propertyType = 'house', state = 'owned', revision = 1, owner = 'OWNER', interior = { type = 'mlo', entrance = { x = 5, y = 5, z = 2 } } },
    other = { id = 'other', label = 'Other', propertyType = 'house', state = 'owned', revision = 1, owner = 'TENANT', interior = { type = 'mlo', entrance = { x = 105, y = 5, z = 2 } } },
} }
local locks, quarantined, lastOperation = {}, {}, nil
Housing.state.get = function(id) return Housing.state.properties[id] end
Housing.state.isUncertain = function(id) return quarantined[id] == true end
Housing.state.markUncertain = function(id, operation) quarantined[id], lastOperation = true, operation end
Housing.state.publicProperty = Housing.copy
Housing.state.withWrite = function(id, handler)
    if locks[id] then return false, 'Property is busy.' end
    locks[id] = true
    local result = table.pack(pcall(handler))
    locks[id] = nil
    if not result[1] then error(result[2]) end
    return table.unpack(result, 2, result.n)
end
local dispatched = 0
exports = { qbdispatch = { createCall = function(_, payload) dispatched = dispatched + 1; return 55, 1 end } }
QB = { sql = {
    NULL = {},
    transactionChecked = function(statements, operation)
        writes[#writes + 1] = statements
        if statements[1].query:find('^SELECT') then
            local results = {}
            for index, statement in ipairs(statements) do
                results[index] = {}
                for _, row in ipairs(rows[statement.query:match('qbhousing_([%w_]+)')] or {}) do
                    if row.property_id == statement.values[1] then results[index][#results[index] + 1] = row end
                end
            end
            return { success = true, results = results }
        end
        if ambiguous then return { success = false, code = 'indeterminate', message = 'Commit acknowledgement lost.' } end
        return failed and { success = false, code = 'unavailable', message = 'Controlled SQL failure' } or { success = true }
    end,
    query = function(sql) return rows[sql:match('qbhousing_([%w_]+)')] or {} end,
    single = function(_, values) return values[1] == 'GUEST' and { citizenid = 'GUEST' } or nil end,
} }
dofile('server/world.lua')
local W = Housing.world
local function check(value, message) assert(value, message); checks = checks + 1 end
local function boundary(offset)
    return { points = { { x = offset, y = 0, z = 0 }, { x = offset + 10, y = 0, z = 0 }, { x = offset + 10, y = 10, z = 0 }, { x = offset, y = 10, z = 0 } }, minZ = 0, maxZ = 10 }
end
local function transform(x) return { coords = { x = x or 5, y = 5, z = 2 }, rotation = { pitch = 10, roll = 20, yaw = 30 }, heading = 30 } end
check(W.load(), 'world loads persistent tables before accepting gameplay')
check(not W.configureSpace(1, 'home', { bounds = { points = {} } }, 0), 'malformed bounds are refused')
failed = true
check(not W.configureSpace(1, 'home', { bounds = boundary(0) }, 0) and not W.spaces.home, 'SQL failure leaves the active physical space unchanged')
failed = false
check(W.configureSpace(1, 'home', { bounds = boundary(0) }, 0), 'owner configures a physical space')
check(not W.configureSpace(1, 'other', { bounds = boundary(2) }, 0), 'independently furnished spaces cannot overlap')
check(W.configureSpace(1, 'other', { bounds = boundary(100) }, 0), 'separate properties share one world at distinct origins')
check(W.contains('home', positions[1]) and not W.contains('other', positions[1]), 'server containment resolves the property id')
check(not W.beginPlacement(1, 'home', 'invented_model'), 'unsupported furniture models are refused')
local ok, session = W.beginPlacement(1, 'home', 'prop_chair_01a')
check(ok, 'authorized placement receives a source-bound session')
check(not W.savePlacement(3, 'home', session.token, transform(), 0), 'another player cannot consume a placement session')
check(not W.savePlacement(1, 'home', session.token, transform(90), 0), 'placement cannot escape the authored physical boundary')
Housing.state.properties.home.revision = 2
local priorEvents = #events
W.changed('home')
local placementClosed = false
for index = priorEvents + 1, #events do
    if events[index].name == 'qbhousing:client:placementClosed' and events[index].target == 1 and events[index].values[1] == session.token then placementClosed = true end
end
check(placementClosed, 'changed authorization immediately tells the owning client to release its placement')
check(not W.savePlacement(1, 'home', session.token, transform(), 0), 'access/property revision changes invalidate captured placement')
ok, session = W.beginPlacement(1, 'home', 'prop_chair_01a')
check(W.savePlacement(1, 'home', session.token, transform(), 0), 'confirmed placement persists its full transform')
local furnitureId = session.token
check(W.furniture[furnitureId].rotation.roll == 20, 'persistent furniture keeps full Euler rotation')
local before = #writes
check(not W.savePlacement(1, 'home', session.token, transform(), 0) and #writes == before, 'repeated placement submission cannot create another object')
Config.furnitureLimits.house = 1
check(not W.beginPlacement(1, 'home', 'prop_chair_01a'), 'property-type furniture limit is enforced')
Config.furnitureLimits.house = 100
grants[2] = { entry = true, ['furniture.place'] = true, ['furniture.move'] = true, ['furniture.remove'] = true }
activeLease = { id = 'lease', tenant = 'TENANT' }
ok, session = W.beginPlacement(2, 'home', 'prop_table_03')
check(ok and W.savePlacement(2, 'home', session.token, transform(6), 0), 'tenant placement is tied to its lease and original character')
local recovered = session.token
check(W.recoverLease('home', 'lease', 'TENANT') and W.furniture[recovered].status == 'recovery', 'eviction protects tenant furniture as its original entitlement')
before = #writes
check(W.recoverLease('home', 'lease', 'TENANT') and #writes == before, 'repeated eviction does not repeat recovery')
check(#W.recovery(2) == 1 and #W.recovery(3) == 0, 'only the former tenant can list their protected furniture')
activeLease, positions[2] = nil, { x = 105, y = 5, z = 2 }
check(W.claimFurniture(2, recovered, 'other', transform(105)), 'recovery atomically moves the original row to an authorized property')
before = #writes
check(W.claimFurniture(2, recovered, 'other', transform(105)) and #writes == before, 'duplicate furniture claims return the original outcome without duplication')
check(W.furniture[recovered].id == recovered and W.furniture[recovered].status == 'placed', 'claim preserves stable furniture identity')
ok, session = W.beginPlacement(1, 'home', 'prop_chair_01a')
activeLease = { id = 'replacement-lease', tenant = 'TENANT' }
check(ok and not W.savePlacement(1, 'home', session.token, transform(), 0), 'a changed tenancy invalidates placement even without a property revision change')
activeLease = nil

local camera = transform(7)
camera.console, camera.label, camera.fov = { x = 5, y = 5, z = 2 }, 'Front room', 60
local saved
ok, saved = W.saveCamera(1, 'home', camera)
check(ok and #saved.cameras == 1, 'camera configuration persists real physical camera and console locations')
local cameraId = saved.cameras[1].id
check(W.enter(1, 'home') and events[#events].name == 'qbhousing:client:cameraPresence', 'occupants are informed when entering a property with installed cameras')
check(not W.openCamera(3, 'home', cameraId), 'police/guest identity alone cannot view a camera')
check(W.grantCamera(1, 'home', 'GUEST'), 'owner grants named time-limited viewing')
ok, saved = W.openCamera(3, 'home', cameraId)
check(ok and saved.token and saved.scene.furniture[1].ownerCid == nil, 'authorized camera uses a source-bound session and sanitized shared scene')
priorEvents = #events
check(W.revokeCamera(1, 'home', 'GUEST'), 'revocation removes the viewing grant')
local closed = false
for index = priorEvents + 1, #events do
    if events[index].name == 'qbhousing:client:cameraClosed' and events[index].target == 3 then closed = true end
end
check(closed, 'revocation immediately closes the active camera session')
check(not W.switchCamera(3, saved.token, cameraId), 'revoked camera token cannot switch feeds')
check(W.grantCamera(1, 'home', 'GUEST'), 'view authorization may be renewed explicitly')
Config.maxCameraViewers = 1
check(W.openCamera(1, 'home', cameraId), 'owner opens a physical console feed')
check(not W.openCamera(3, 'home', cameraId), 'simultaneous camera viewer limit is enforced')
W.closeCamera(1, nil)
-- Close requires the actual token, so advancing the server expiry releases it.
now = now + Config.cameraSessionSeconds + 1
for _, callback in ipairs(timers) do callback() end
ok, saved = W.openCamera(3, 'home', cameraId)
check(ok, 'expired viewer sessions free admission capacity')
local originalExpiry = saved.expiresAt
now = now + 1
ok, saved = W.switchCamera(3, saved.token, cameraId)
check(ok and saved.expiresAt == originalExpiry, 'switching camera feeds cannot extend the original viewing authorization')
positions[3] = { x = 500, y = 5, z = 2 }
check(not W.openCamera(3, 'home', cameraId), 'remote viewing cannot bypass physical console and camera range')
positions[3] = { x = 5, y = 5, z = 2 }

local previousOwner, previousRevision = W.furniture[furnitureId].ownerCid, W.furniture[furnitureId].revision
local transferWrites = W.ownershipStatements('home', 'BUYER')
check(#transferWrites == 2 and transferWrites[1].expectedRows == 1 and W.furniture[furnitureId].ownerCid == previousOwner, 'sale prepares checked furniture transfer without publishing before the finance commit')
W.ownershipChanged('home', 'BUYER')
check(W.furniture[furnitureId].ownerCid == 'BUYER' and not W.hasCameraGrantByCitizen('GUEST', 'home'), 'confirmed sale transfers fixtures and revokes previous camera authorizations')
W.ownershipChanged('home', 'BUYER')
check(W.furniture[furnitureId].revision == previousRevision + 1, 'replaying a published sale does not reapply the furniture revision')
Housing.state.properties.home.state = 'archiving'
check(not W.beginPlacement(1, 'home', 'prop_chair_01a') and not W.snapshot(1, 'home'), 'archiving blocks physical operations and security snapshots')
failed = true
check(not W.archive('home') and W.furniture[furnitureId].status == 'placed', 'failed archival preserves active furniture until the recovery write commits')
failed = false
check(W.archive('home') and W.furniture[furnitureId].status == 'recovery' and W.furniture[furnitureId].ownerCid == 'BUYER', 'trusted archival preserves the same furniture id for its current owner')
Housing.state.properties.home.state = 'owned'

W.grants.home = { GUEST = now + Config.cameraGrantSeconds }
check(W.openCamera(3, 'home', cameraId), 'named viewing can start before an uncertain revocation')
ambiguous = true
check(not W.revokeCamera(1, 'home', 'GUEST') and quarantined.home and lastOperation:find('qbhousing:world:home:', 1, true), 'an unknown world commit quarantines the property with its in-flight operation key')
check(not W.openCamera(1, 'home', cameraId) and not W.hasCameraGrantByCitizen('GUEST', 'home'), 'uncertain revocation denies both owner feeds and named grants immediately')
ambiguous = false
for _, name in ipairs({ 'spaces', 'furniture', 'cameras', 'alarms' }) do
    rows[name] = {}
    for key, value in pairs(W[name]) do rows[name][#rows[name] + 1] = { property_id = value.propertyId, id = (name == 'furniture' or name == 'cameras') and key or nil,
        definition = json.encode(value), revision = value.revision, owner_cid = value.ownerCid, lease_id = value.leaseId, status = value.status } end
end
-- The revoke committed, but its reply was lost; the subsequent snapshot is authoritative.
rows.camera_grants = {}
local unaffected = W.furniture[recovered]
check(W.reconcileProperty('home') and quarantined.home and W.furniture[recovered] == unaffected, 'targeted world reconciliation leaves unrelated properties and shared quarantine untouched')
quarantined.home = nil
check(not W.hasCameraGrantByCitizen('GUEST', 'home') and W.furniture[furnitureId].status == 'recovery', 'confirmed snapshot restores the committed revocation and existing recovery entitlement')

check(W.setAlarm(1, 'home', true, 0), 'alarm arms through an authorized revision check')
check(W.panic(1, 'home') and dispatched == 1, 'a real authorized panic creates a dispatch call')
check(not W.panic(1, 'home') and dispatched == 1, 'persistent alarm cooldown suppresses duplicate dispatch')
local savedAlarm = Housing.copy(W.alarms.home)
rows.spaces = { { property_id = 'home', definition = json.encode(W.spaces.home), revision = W.spaces.home.revision } }
rows.alarms = { { property_id = 'home', definition = json.encode(savedAlarm), revision = savedAlarm.revision } }
check(W.load() and not W.panic(1, 'home') and dispatched == 1, 'alarm cooldown survives a service reload')
check(W.reconcileProperty('confirmed-absent'), 'confirmed absence with no physical rows can release a rolled-back new property quarantine')
print(('qbhousing world: %d checks passed'):format(checks))
