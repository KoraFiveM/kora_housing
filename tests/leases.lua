-- Real lease service with checked, rollback-capable SQL and controlled deadlines.
local helpers = dofile('../qbcore/test/mocks.lua')
json = { encode = helpers.stableEncode, decode = helpers.simpleDecode }
dofile('config.lua'); dofile('shared/schema.lua')
local function copy(value) return Housing.copy(value) end
local checks, now, serial = 0, 1000, 0
local realOs = os
os = { time = function() return now end, date = realOs.date }
local db = { leases = {}, deposit_deductions = {}, rent_periods = {}, evictions = {}, lease_access = {}, stashes = {}, furniture = {} }
local timers, sqlWrites, payments, locked, failure, onLock = {}, 0, {}, false, nil, nil
local identities = { [1] = 'OWNER', [2] = 'TENANT', [3] = 'COOWNER', [4] = 'ADMIN' }
function GetCurrentResourceName() return 'qbhousing' end
function AddEventHandler() end
exports = { qbcore = { getPlayerByCitizenId = function(_, cid) return { citizenid = cid } end } }
Housing.permissions = { citizenId = function(src) return identities[src] end, isAdmin = function(src) return src == 4 end }
Housing.grantablePermissions = { entry = true, ['stash.open'] = true, ['access.share'] = true }
local property = { id = 'home', owner = 'OWNER', coowners = { COOWNER = true }, revision = 1, ownershipRevision = 1, propertyType = 'house', state = 'owned' }
Housing.state = { ready = true, properties = { home = property } }
function Housing.state.get(id) return Housing.state.properties[id] end
function Housing.state.withWrite(_, fn)
    if locked then return nil, 'busy' end
    locked = true
    if onLock then local hook = onLock; onLock = nil; hook() end
    local result = table.pack(pcall(fn)); locked = false
    if not result[1] then error(result[2]) end
    return table.unpack(result, 2, result.n)
end
QB = { sql = { NULL = '__NULL__' }, timers = {} }
function QB.timers.setTimeout(fn, delay) serial = serial + 1; timers[serial] = { fn = fn, delay = delay }; return serial end
function QB.timers.clearTimeout(id) timers[id] = nil end
local function check(value, message) assert(value, message); checks = checks + 1 end
local function tableName(sql) return sql:match('`qbhousing_([%w_]+)`') end
local function rowsFor(sql, p)
    local name = tableName(sql)
    if name == 'lease_access' or name == 'stashes' then return {} end
    local result = {}
    for _, row in pairs(db[name] or {}) do
        local include = true
        if name == 'deposit_deductions' then include = row.lease_id == p[1] and (row.status == p[2] or row.status == p[3] or row.status == p[4])
        elseif name == 'leases' and sql:find('deposit_remaining', 1, true) then include = (row.status == 'ended' or row.status == 'evicted') and row.deposit_remaining > 0
        elseif name == 'leases' then include = row.status == 'active' or row.status == 'ending' or row.status == 'evicting' end
        if include then result[#result + 1] = copy(row) end
    end
    return result
end
function QB.sql.query(sql, p) return rowsFor(sql, p or {}) end
function QB.sql.single(sql, p)
    local name = tableName(sql)
    if name == 'listings' then return nil end
    if name == 'leases' and sql:find('`property_id`=?', 1, true) then
        for _, row in pairs(db.leases) do
            if row.property_id == p[1] and (row.status == 'proposed' or row.status == 'active' or row.status == 'ending' or row.status == 'evicting' or row.deposit_remaining > 0) then return { id = row.id } end
        end
        return nil
    end
    return copy(db[name] and db[name][p[1]])
end
function QB.sql.scalar(sql, p)
    if sql == 'SELECT UUID()' then serial = serial + 1; return 'id:' .. serial end
    local sum = 0
    for _, row in pairs(db.deposit_deductions) do
        if row.lease_id == p[1] and (row.status == 'proposed' or row.status == 'disputed' or row.status == 'approved') then sum = sum + row.amount end
    end
    return sum
end
local function apply(staged, statement)
    local sql, p = statement.query, statement.values or {}
    local name = tableName(sql)
    if name == 'audit' then return 1 end
    if sql:find('INSERT', 1, true) == 1 then
        local cols = sql:match('`qbhousing_[%w_]+`%s*%((.-)%)')
        local row, index = {}, 0
        for column in cols:gmatch('`([^`]+)`') do index = index + 1; if p[index] ~= QB.sql.NULL then row[column] = copy(p[index]) end end
        local key = row.id or name == 'rent_periods' and row.lease_id .. ':' .. row.period_start or row.lease_id
        if staged[name][key] then return sql:find('IGNORE', 1, true) and 0 or 0 end
        row.revision, row.missed, row.deposit_remaining = row.revision or 1, row.missed or 0, row.deposit_remaining or 0
        staged[name][key] = row
        return 1
    end
    if sql:find('UPDATE', 1, true) == 1 then
        local set, where = sql:match(' SET (.-) WHERE (.+)')
        local changes, index = {}, 0
        for column, value in set:gmatch('`([^`]+)`=([^,]+)') do
            if value == '?' then index = index + 1; changes[column] = p[index] else changes[column] = tonumber(value) end
        end
        local predicates = {}
        for column in where:gmatch('`([^`]+)`=%?') do index = index + 1; predicates[column] = p[index] end
        local affected = 0
        for _, row in pairs(staged[name]) do
            local match = true
            for column, value in pairs(predicates) do if row[column] ~= value then match = false end end
            if match then
                for column, value in pairs(changes) do row[column] = value ~= QB.sql.NULL and value or nil end
                affected = affected + 1
            end
        end
        return affected
    end
    error('Unhandled lease SQL: ' .. sql)
end
function QB.sql.transactionChecked(statements)
    if failure == 'sql' then return { success = false, code = 'unavailable' } end
    local staged = copy(db)
    for _, statement in ipairs(statements) do
        local affected = apply(staged, statement)
        if statement.expectedRows and affected ~= statement.expectedRows then return { success = false, code = 'conflict' } end
    end
    db, sqlWrites = staged, sqlWrites + 1
    return { success = true }
end
function Housing.state.persist(value, _, writes)
    local result = QB.sql.transactionChecked(writes)
    if not result.success then return nil, result.code end
    value.revision = value.revision + 1
    Housing.state.properties[value.id] = value; property = value
    return value
end
dofile('server/domain.lua')
local recovered, notified = 0, 0
Housing.storage = { prepareLease = function() return true end, ensureEscrow = function() return true end,
    recoverLease = function() recovered = recovered + 1; return failure ~= 'recovery', 'deferred recovery' end,
    notifyRecovery = function() notified = notified + 1 end }
Housing.world = { recoverLease = function() return true end }
Housing.transactions = { nextKey = function(base) serial = serial + 1; return base .. ':' .. serial end }
function Housing.transactions.run(key, kind, actor, value, debits, credits, writes, effects)
    if failure == 'insufficient_funds' or failure == 'unavailable' or failure == 'pending' then return false, failure, failure end
    local outcome = QB.sql.transactionChecked(writes)
    if not outcome.success then return false, outcome.code, outcome.code end
    payments[#payments + 1] = { key = key, kind = kind, debits = copy(debits), credits = copy(credits) }
    Housing.leases.publish(effects.lease)
    return true, effects
end
dofile('server/leases.lua')
local L = Housing.leases
local function onlyTimer()
    local found
    for _, timer in pairs(timers) do check(not found, 'Only one deadline timer exists'); found = timer end
    return found
end
local function restart()
    timers = {}; dofile('server/leases.lua'); L = Housing.leases
    check(L.load(), 'Restart loads active leases, deposit deadlines and guest grants')
end

check(L.load() and next(timers) == nil, 'An empty housing service has no polling timer')
local ok, proposed = L.proposeLease(1, 'home', { tenant = 'TENANT', interval = 'daily', rent = 100, deposit = 500 }, property.revision)
check(ok, 'Owner proposes a lease')
local id = proposed.id
check(json.decode(db.leases[id].owner_payees)[2] == 'COOWNER' and db.leases[id].missed_limit == 3, 'Proposal freezes equal owner allocation and missed-rent policy')
check(not L.acceptLease(1, id), 'Only the tenant can accept')
check(L.acceptLease(2, id), 'First rent and deposit commit together')
check(payments[1].debits[1].amount == 600 and payments[1].credits[3].account == Config.escrowAccount, 'Escrow is a separate balanced credit')
check(onlyTimer().delay == Config.rentalIntervals.daily * 1000, 'Timer sleeps until the actual rent deadline')
local count = #payments
check(L.acceptLease(2, id) and #payments == count, 'Repeat acceptance does not charge again')
check(L.permission(2, property, 'entry', 'TENANT') == true, 'Tenant physical access follows signed lease permissions')
check(L.permission(1, property, 'property.edit', 'OWNER') == false, 'Active tenancy protects physical configuration')
L.current.home.access.GUEST = { entry = true }
local published = copy(L.current.home); published.access = nil; published.revision = published.revision + 1
L.publish(published)
check(L.current.home.access.GUEST.entry == true, 'Rent or end publications preserve persisted guest access')
-- Keep the fixture DB revision aligned with the published snapshot.
db.leases[id].revision = published.revision
local signed = json.decode(db.leases[id].permissions); signed['stash.open'] = false; signed['access.share'] = true
db.leases[id].permissions = json.encode(signed)
check(not L.leaseAccess(2, id, 'GUEST', 'stash.open', true), 'Guest grants remain bounded by the tenant permission set')
now = db.leases[id].next_due + 200
failure = 'unavailable'; check(not L.bill(id) and db.leases[id].missed == 0, 'Database outage is never a missed payment')
failure = 'pending'; check(not L.bill(id) and db.leases[id].missed == 0, 'Ambiguous rent does not count as a miss')
failure = 'insufficient_funds'; check(L.bill(id) and db.leases[id].missed == 1, 'Confirmed insufficient funds advances exactly one fixed rent period')
check(db.leases[id].next_due == 1000 + Config.rentalIntervals.daily * 2, 'Billing remains anchored to the original period, not retry time')
Config.missedPayments.daily = 1
now = db.leases[id].next_due
check(L.bill(id) and db.leases[id].status == 'active' and db.leases[id].missed == 2, 'Existing leases retain their captured missed-payment threshold')
now = db.leases[id].next_due
check(L.bill(id) and db.leases[id].status == 'evicting', 'Captured threshold starts protected eviction')
failure = 'recovery'; check(not L.finish(id) and db.leases[id].status == 'evicting', 'Failed item recovery cannot prematurely end tenancy')
failure = nil; check(L.finish(id) and db.leases[id].status == 'evicted' and recovered == 2 and notified == 1, 'Successful protected recovery finalizes eviction once')
check(L.finish(id) and recovered == 2 and notified == 1, 'Repeated completion does not repeat recovery')
restart()
check(onlyTimer().delay == Config.depositReviewSeconds * 1000, 'Restart schedules the persisted deposit deadline')
check(not L.proposeLease(1, 'home', { tenant = 'TENANT', interval = 'daily', rent = 100 }, property.revision), 'Unsettled deposit blocks a new lease')
local deduction
ok, deduction = L.proposeDeduction(1, id, { category = 'damage', amount = 100, note = 'Recorded damage' })
check(ok, 'Owner proposes a bounded deposit deduction during review')
check(L.decideDeduction(2, deduction.id, 'dispute'), 'Tenant may dispute before money moves')
check(not L.resolveDeduction(1, deduction.id, 50, 'Owner resolution'), 'Owners cannot resolve their own dispute')
property.coowners = { NEW_OWNER = true }
check(L.resolveDeduction(4, deduction.id, 51, 'Reviewed evidence'), 'Admin resolves an unsettled dispute')
local payout = payments[#payments]
check(payout.credits[1].citizenid == 'OWNER' and payout.credits[1].amount == 26 and payout.credits[2].citizenid == 'COOWNER' and payout.credits[2].amount == 25, 'Deductions use frozen equal shares with the primary remainder')
check(not L.resolveDeduction(4, deduction.id, 100, 'Second payout') and db.deposit_deductions[deduction.id].status == 'settled', 'Settled deductions can never be reopened for another payout')
ok, deduction = L.proposeDeduction(1, id, { category = 'damage', amount = 50, note = 'Second recorded damage' })
check(ok and L.resolveDeduction(4, deduction.id, 0, 'No supported damage'), 'A zero award still records a final settled decision')
check(db.deposit_deductions[deduction.id].status == 'settled', 'Zero approval is settled without a money transaction')
local before = sqlWrites
check(L.settleDeposit(id) and sqlWrites == before, 'Reviewing an unchanged deposit does not write a new revision')
now = db.leases[id].deposit_release_at
local timeout = onlyTimer(); timers = {}; timeout.fn()
check(db.leases[id].deposit_remaining == 0 and payments[#payments].credits[1].citizenid == 'TENANT', 'Deadline refunds the unclaimed deposit to the original tenant')
check(next(timers) == nil, 'A completed lease and deposit leave no polling timer')
-- Ending is driven by end_at even when next_due is later, and never renews at that boundary.
local ending = copy(db.leases[id]); ending.id = 'ending'; ending.status = 'ending'; ending.revision = 1; ending.deposit_remaining = 0
ending.next_due, ending.end_at, ending.paid_through = now + 200, now + 50, now + 50
ending.owner_payees = json.encode({ 'OWNER' }); db.leases.ending = ending
-- Compose actual world recovery under the actual lease lock. A stub would hide nested-lock failures.
dofile('server/world.lua')
Housing.world.furniture.tenant_chair = { id = 'tenant_chair', propertyId = 'home', leaseId = 'ending', ownerCid = 'TENANT', status = 'placed', revision = 1 }
db.furniture.tenant_chair = { id = 'tenant_chair', property_id = 'home', lease_id = 'ending', owner_cid = 'TENANT', status = 'placed', revision = 1 }
restart(); check(onlyTimer().delay == 50000, 'Ending deadline takes precedence over a later next_due')
now = ending.end_at; count = #payments
local t = onlyTimer(); timers = {}; failure = 'sql'; t.fn()
check(db.leases.ending.status == 'ending' and onlyTimer().delay == 30000, 'A failed due operation retries only that known deadline with backoff')
failure = nil; now = now + 30; t = onlyTimer(); timers = {}; t.fn()
check(db.leases.ending.status == 'ended' and #payments == count, 'Termination completes without charging another rent period')
check(Housing.world.furniture.tenant_chair.status == 'recovery' and db.furniture.tenant_chair.status == 'recovery', 'Actual lease and world services recover furniture under one property lock')
check(L.permission(2, property, 'entry', 'TENANT') == nil, 'Ended lease clears physical access')
-- Re-read after acquiring the property lock, so stale deduction snapshots cannot reopen settled money.
db.deposit_deductions.race = { id = 'race', lease_id = id, status = 'proposed', amount = 5 }
onLock = function() db.deposit_deductions.race.status = 'settled' end
check(not L.resolveDeduction(4, 'race', 5, 'Racing settlement'), 'Deduction state is refreshed inside the lock')
print(('qbhousing leases: %d assertions passed; deadlines, fixed rent, protected eviction and immutable deposit settlement'):format(checks))
os = realOs
