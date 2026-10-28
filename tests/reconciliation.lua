-- Actual registry, permissions, leases and world caches after an ambiguous write.
local helpers = dofile('../kora_core/test/mocks.lua')
json = { encode = helpers.stableEncode, decode = helpers.simpleDecode }
dofile('config.lua'); dofile('shared/schema.lua'); dofile('shared/permissions.lua')
local checks, timers, broadcasts, refreshed = 0, {}, 0, 0
local committed, worldFailure, newerAmbiguity, pendingWorker, readFailure
function GetCurrentResourceName() return 'kora_housing' end
function AddEventHandler() end
function TriggerClientEvent() broadcasts = broadcasts + 1 end
function SetTimeout() end
exports = { kora_core = { getPlayer = function(_, src) return { citizenid = src == 1 and 'OWNER' or 'GUEST' } end } }
QB = { permissions = { hasPermission = function() return false end }, timers = {}, sql = { NULL = '__NULL__' } }
function QB.timers.setTimeout(fn, delay) timers[#timers + 1] = { fn = fn, delay = delay }; return #timers end
function QB.timers.clearTimeout(id) timers[id] = nil end
function QB.sql.awaitCheckedOperation()
    if pendingWorker then pendingWorker = false; coroutine.yield('old driver worker') end
    return { active = false }
end
function QB.sql.transactionChecked(statements)
    local sql = statements[1].query
    if sql:find('SELECT', 1, true) ~= 1 then return { success = false, code = 'indeterminate' } end
    if readFailure then return { success = false, code = 'unavailable' } end
    if sql:find('qbhousing_properties', 1, true) then
        if not committed then return { success = true, results = { {}, {}, {}, {} } } end
        local definition = Housing.copy(committed); definition.permissionGrants, definition.coowners = nil, nil
        return { success = true, results = {
            { { id = committed.id, owner = committed.owner, definition = json.encode(definition), property_type = committed.propertyType, revision = committed.revision, ownership_revision = committed.ownershipRevision } }, {},
            { { property_id = committed.id, citizenid = 'GUEST', action = 'entry', allowed = 0 } }, {},
        } }
    end
    if sql:find('qbhousing_leases', 1, true) then
        return { success = true, results = { committed and { { id = 'oldlease', property_id = 'home', tenant = 'GUEST', landlord = 'OWNER', status = 'ended', revision = 3, permissions = '{}', deposit_remaining = 10, deposit_release_at = os.time() + 50 } } or {}, {} } }
    end
    if sql:find('qbhousing_spaces', 1, true) then
        if worldFailure then return { success = false, code = 'unavailable' } end
        if newerAmbiguity then newerAmbiguity = false; Housing.state.markUncertain('home', 'qbhousing:world:newer') end
        return { success = true, results = { {}, {}, {}, {}, {} } }
    end
    error('Unexpected reconciliation SQL: ' .. sql)
end
dofile('server/state.lua'); dofile('server/permissions.lua'); dofile('server/domain.lua')
Housing.transactions = { busy = function() return false end }
Housing.storage = { frozen = {}, refresh = function(id)
    assert(Housing.state.isUncertain(id), 'Publication is still fenced while provider policies refresh')
    refreshed = refreshed + 1; return true
end }
Housing.doors = { refresh = function(id) assert(Housing.state.isUncertain(id)); refreshed = refreshed + 1; return true end }
dofile('server/leases.lua'); dofile('server/world.lua')
local State, P, L, W = Housing.state, Housing.permissions, Housing.leases, Housing.world
local function check(value, message) assert(value, message); checks = checks + 1 end
local property = assert(Housing.normalise({ id = 'home', owner = 'OWNER', propertyType = 'land', state = 'owned', revision = 1, ownershipRevision = 1, keys = { GUEST = true } }))
State.properties.home, State.ready = property, true
W.ready = true; W.grants.home = { GUEST = os.time() + 100 }
L.current.home = { id = 'oldlease', property_id = 'home', status = 'active', tenant = 'GUEST', revision = 2, permissions = { entry = true }, access = {} }
check(P.can(2, 'home', 'entry'), 'Initial persisted lease permits access')
committed = Housing.copy(property); committed.keys.GUEST = nil; committed.permissionGrants.GUEST = { entry = false }; committed.revision = 2
local saved = State.persist(committed, { action = 'permissions.entry' })
check(not saved and State.isUncertain('home'), 'An indeterminate revocation quarantines its property')
check(State.get('home').keys.GUEST == true, 'Ambiguous write does not claim to publish unconfirmed state')
check(not P.can(2, 'home', 'entry') and not P.can(1, 'home', 'permissions.manage'), 'Old cache grants and owner authority both fail closed')
check(not State.withWrite('home', function() return true end), 'New property writes cannot cross quarantine')
check(#timers == 1 and timers[1].delay == 30000, 'Only the known uncertain property gets a recovery timer')
pendingWorker = true
local worker = coroutine.create(function() return State.reconcileProperty('home') end)
local resumed, wait = coroutine.resume(worker)
check(resumed and wait == 'old driver worker' and State.isUncertain('home'), 'Recovery waits for the old driver before reading a snapshot')
resumed, saved = coroutine.resume(worker)
check(resumed and saved and not State.isUncertain('home'), 'Confirmed coherent snapshots release quarantine')
check(State.get('home').permissionGrants.GUEST.entry == false and not State.get('home').keys.GUEST, 'Committed revocation replaces the stale registry and legacy key')
check(not L.active('home') and L.deposits.oldlease.deposit_remaining == 10, 'Lease reconciliation refreshes terminal status and deposit deadlines')
check(not W.hasCameraGrantByCitizen('GUEST', 'home'), 'World reconciliation refreshes named camera authorizations')
check(refreshed == 2 and broadcasts > 0, 'Provider policies and clients refresh after confirmed cache publication')
check(not P.can(2, 'home', 'entry'), 'Revoked access stays denied after recovery')
State.markUncertain('home', 'qbhousing:state:home'); worldFailure = true
check(not State.reconcileProperty('home') and State.isUncertain('home'), 'A failed physical snapshot keeps the whole property quarantined')
worldFailure, newerAmbiguity = nil, true
check(not State.reconcileProperty('home') and State.isUncertain('home'), 'A newer ambiguous write invalidates an older recovery attempt')
check(State.reconcileProperty('home') and not State.isUncertain('home'), 'A later complete reconciliation safely recovers')
State.markUncertain('home'); readFailure = true
check(not State.reconcileProperty('home') and State.isUncertain('home'), 'Database read failure cannot lift quarantine')
readFailure = nil; check(State.reconcileProperty('home'), 'Known pending recovery retries without a new mutation')
-- An uncertain new INSERT may have rolled back, leaving no registry or related rows.
committed = nil; State.markUncertain('newproperty', 'qbhousing:state:newproperty')
check(State.reconcileProperty('newproperty') and not State.isUncertain('newproperty') and not State.get('newproperty'), 'Confirmed absence releases a rolled-back new property safely')
print(('qbhousing reconciliation: %d assertions passed; ambiguous revocation, joined workers, coherent snapshots and fail-closed recovery'):format(checks))
