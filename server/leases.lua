Housing.leases = { current = {}, deposits = {} }
local L, D, State, P = Housing.leases, Housing.domain, Housing.state, Housing.permissions
local timer, processing
local retries, revisions = {}, {}
local physical = { entry = true, ['stash.open'] = true, ['property.edit'] = true,
    ['furniture.place'] = true, ['furniture.move'] = true, ['furniture.remove'] = true,
    ['garage.list'] = true, ['garage.store'] = true, ['garage.retrieve'] = true }

local function decode(row)
    if not row then return nil end
    if type(row.permissions) == 'string' then row.permissions = json.decode(row.permissions) end
    if type(row.owner_payees) == 'string' then row.owner_payees = json.decode(row.owner_payees) end
    row.permissions = row.permissions or {}
    return row
end

local function get(id) return decode(QB.sql.single('SELECT * FROM `qbhousing_leases` WHERE `id`=?', { id })) end

function L.active(id) return L.current[id] end

function L.publish(lease)
    if revisions[lease.id] and revisions[lease.id] > lease.revision then return end
    revisions[lease.id] = lease.revision
    local previous = L.current[lease.property_id]
    if previous and previous.id == lease.id and previous.revision > lease.revision then return end
    if lease.status == 'active' or lease.status == 'ending' or lease.status == 'evicting' then
        local value = Housing.copy(lease)
        value.access = Housing.copy(lease.access or previous and previous.id == lease.id and previous.access or {})
        L.current[lease.property_id] = value
    elseif previous and previous.id == lease.id then L.current[lease.property_id] = nil end
    if (lease.status == 'ended' or lease.status == 'evicted') and lease.deposit_remaining > 0 then
        L.deposits[lease.id] = Housing.copy(lease)
    else L.deposits[lease.id] = nil end
    retries[lease.id] = nil
    L.schedule()
end

function L.permission(src, property, action, cid)
    local lease = L.current[property.id]
    if not lease or not physical[action] then return nil end
    if action == 'property.edit' or lease.status == 'evicting' or lease.status == 'ending' and lease.end_at and lease.end_at <= os.time() then return false end
    if cid == lease.tenant then
        local grants = property.permissionGrants and property.permissionGrants[cid]
        if grants and grants[action] ~= nil then return grants[action] == true end
        return lease.permissions[action] == true
    end
    return lease.access[cid] and lease.access[cid][action] == true or false
end

function L.load()
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_leases` WHERE `status` IN (?,?,?)', { 'active', 'ending', 'evicting' })
    if not rows then return false, err end
    L.current, L.deposits = {}, {}
    for _, row in ipairs(rows) do
        local lease = decode(row); lease.access = {}
        L.current[row.property_id] = lease; revisions[row.id] = row.revision
    end
    local grants, grantErr = QB.sql.query([[SELECT a.* FROM `qbhousing_lease_access` a JOIN `qbhousing_leases` l ON l.id=a.lease_id WHERE l.status IN ('active','ending','evicting')]])
    if not grants then return false, grantErr end
    for _, row in ipairs(grants) do
        for _, lease in pairs(L.current) do
            if lease.id == row.lease_id then
                lease.access[row.citizenid] = lease.access[row.citizenid] or {}
                lease.access[row.citizenid][row.action] = tonumber(row.allowed) == 1
            end
        end
    end
    local deposits, depositErr = QB.sql.query("SELECT * FROM `qbhousing_leases` WHERE `status` IN ('ended','evicted') AND `deposit_remaining`>0")
    if not deposits then return false, depositErr end
    for _, row in ipairs(deposits) do L.deposits[row.id] = decode(row); revisions[row.id] = row.revision end
    L.schedule()
    return true
end

function L.reconcileProperty(id)
    local result, err = QB.sql.transactionChecked({
        { query = 'SELECT * FROM `qbhousing_leases` WHERE `property_id`=? FOR UPDATE', values = { id } },
        { query = 'SELECT a.* FROM `qbhousing_lease_access` a JOIN `qbhousing_leases` l ON l.id=a.lease_id WHERE l.property_id=?', values = { id } },
    })
    if not result or not result.success or type(result.results) ~= 'table' or type(result.results[1]) ~= 'table' or type(result.results[2]) ~= 'table' then return false, err or 'Lease snapshot is unavailable.' end
    local current, deposits, byId = nil, {}, {}
    for _, row in ipairs(result.results[1]) do
        local lease = decode(row); lease.access = {}
        byId[lease.id] = lease
        if lease.status == 'active' or lease.status == 'ending' or lease.status == 'evicting' then
            if current then return false, 'Multiple active leases require repair.' end
            current = lease
        elseif (lease.status == 'ended' or lease.status == 'evicted') and lease.deposit_remaining > 0 then deposits[lease.id] = lease end
    end
    for _, row in ipairs(result.results[2]) do
        local lease = byId[row.lease_id]
        if not lease then return false, 'Orphaned lease access requires repair.' end
        lease.access[row.citizenid] = lease.access[row.citizenid] or {}
        lease.access[row.citizenid][row.action] = tonumber(row.allowed) == 1
    end
    L.current[id] = current
    for leaseId, lease in pairs(L.deposits) do if lease.property_id == id then L.deposits[leaseId] = nil end end
    for leaseId, lease in pairs(byId) do revisions[leaseId] = lease.revision; retries[leaseId] = nil end
    for leaseId, lease in pairs(deposits) do L.deposits[leaseId] = lease end
    L.schedule()
    return true
end

function L.proposeLease(src, id, payload, revision)
    return D.lock(id, function()
        local property, cid = State.get(id), P.citizenId(src)
        if not D.owner(property, cid) or property.state == 'archived' or property.state == 'archiving' or property.revision ~= revision then return false, 'Only current owners can propose a lease.' end
        if type(payload) ~= 'table' or not Config.rentalIntervals[payload.interval] or not D.amount(payload.rent) or not D.amount(payload.deposit or 0, true) or payload.rent + (payload.deposit or 0) > 1000000000 then return false, 'Choose daily or weekly rent and valid whole amounts.' end
        local exists, err = D.character(payload.tenant)
        if not exists then return false, err end
        if D.owner(property, payload.tenant) then return false, 'An owner cannot also be the tenant.' end
        local listing, listingErr = QB.sql.single('SELECT `id` FROM `qbhousing_listings` WHERE `property_id`=? AND `status`=?', { id, 'active' })
        if listingErr or listing then return false, 'Cancel the property listing before renting it.' end
        local occupied, leaseErr = QB.sql.single([[SELECT `id` FROM `qbhousing_leases` WHERE `property_id`=? AND (`status` IN ('proposed','active','ending','evicting') OR `deposit_remaining`>0) LIMIT 1]], { id })
        if leaseErr or occupied then return false, 'Finish the existing lease and its deposit before creating another.' end
        for _, child in pairs(State.properties) do if child.parentId == id then return false, 'Rent the individual units of this building.' end end
        local permissions = Housing.copy(Config.tenantPermissions)
        for action, allowed in pairs(payload.permissions or {}) do
            if not Housing.grantablePermissions[action] or type(allowed) ~= 'boolean' then return false, 'Invalid tenant permission.' end
            permissions[action] = allowed
        end
        local leaseId = D.id()
        if not leaseId then return false, 'Lease storage is unavailable.' end
        local ok, writeErr = D.sql({
            { query = [[INSERT INTO `qbhousing_leases` (`id`,`property_id`,`tenant`,`landlord`,`interval_name`,`rent`,`deposit`,`permissions`,`status`,`ownership_revision`,`deposit_review_seconds`,`created_at`,`owner_payees`,`missed_limit`,`policy_version`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)]],
                values = { leaseId, id, payload.tenant, property.owner, payload.interval, payload.rent, payload.deposit or 0, json.encode(permissions), 'proposed', property.ownershipRevision, Config.depositReviewSeconds, os.time(), json.encode(D.owners(property)), Config.missedPayments[payload.interval], Config.salePolicyVersion or 1 } },
            D.audit(id, cid, 'lease.propose', { lease = leaseId }),
        })
        return ok, ok and { id = leaseId, status = 'proposed' } or writeErr
    end)
end

function L.acceptLease(src, leaseId)
    local lease = get(leaseId)
    if not lease or lease.tenant ~= P.citizenId(src) then return false, 'Only the proposed tenant can accept this lease.' end
    if lease.status == 'active' then return true, lease end
    return D.lock(lease.property_id, function()
        lease = get(leaseId)
        if not lease then return false, 'Lease was not found.' end
        local property = State.get(lease.property_id)
        if not property then return false, 'Property was not found.' end
        if lease.status ~= 'proposed' or property.state == 'archived' or property.state == 'archiving' or property.owner ~= lease.landlord or property.ownershipRevision ~= lease.ownership_revision then return false, 'Lease terms or ownership changed. Request a new lease.' end
        local ready, err = Housing.storage.prepareLease(lease)
        if not ready then return false, err end
        if lease.deposit > 0 then
            local escrow, escrowErr = Housing.storage.ensureEscrow()
            if not escrow then return false, escrowErr end
        end
        local now, interval = os.time(), Config.rentalIntervals[lease.interval_name]
        local changed = Housing.copy(lease)
        changed.status, changed.next_due, changed.paid_through, changed.revision = 'active', now + interval, now + interval, lease.revision + 1
        changed.deposit_remaining = lease.deposit
        local credits = D.split(property, lease.rent)
        if lease.deposit > 0 then credits[#credits + 1] = { account = Config.escrowAccount, amount = lease.deposit } end
        local key, keyErr = Housing.transactions.nextKey('lease:' .. leaseId)
        if not key then return false, keyErr end
        local writes = {
            { query = 'UPDATE `qbhousing_leases` SET `status`=?,`next_due`=?,`paid_through`=?,`deposit_remaining`=?,`revision`=? WHERE `id`=? AND `status`=? AND `revision`=?',
                values = { 'active', changed.next_due, changed.paid_through, lease.deposit, changed.revision, leaseId, 'proposed', lease.revision }, expectedRows = 1 },
            { query = 'INSERT INTO `qbhousing_rent_periods` (`lease_id`,`period_start`,`period_end`,`amount`,`status`,`operation_id`) VALUES (?,?,?,?,?,?)', values = { leaseId, now, now + interval, lease.rent, 'paid', key } },
            { query = 'UPDATE `qbhousing_stashes` SET `status`=? WHERE `lease_id`=? AND `status`=?', values = { 'active', leaseId, 'prepared' } },
        }
        return Housing.transactions.run(key, 'lease.initial', lease.tenant, Housing.copy(property), { { citizenid = lease.tenant, amount = lease.rent + lease.deposit } }, credits, writes, { lease = changed })
    end)
end

function L.requestLeaseEnd(src, leaseId)
    local lease, cid = get(leaseId), P.citizenId(src)
    if not lease then return false, 'Lease was not found.' end
    return D.lock(lease.property_id, function()
        lease = get(leaseId)
        if not lease then return false, 'Lease was not found.' end
        local property = State.get(lease.property_id)
        if cid ~= lease.tenant and not D.owner(property, cid) then return false, 'Only a lease party can request its end.' end
        if lease.status == 'proposed' then
            local ok, err = D.sql({ { query = 'UPDATE `qbhousing_leases` SET `status`=? WHERE `id`=? AND `status`=?', values = { 'cancelled', leaseId, 'proposed' }, expectedRows = 1 }, D.audit(property.id, cid, 'lease.cancel', { lease = leaseId }) })
            return ok, ok and true or err
        end
        if lease.status ~= 'active' and lease.status ~= 'ending' then return false, 'This lease is already ending or has ended.' end
        if lease.status == 'ending' then L.publish(lease); return true, lease end
        local changed = Housing.copy(lease)
        changed.status, changed.end_at, changed.revision = 'ending', math.max(os.time(), lease.paid_through or os.time()), lease.revision + 1
        local saved, err = State.persist(Housing.copy(property), { actor = cid, action = 'lease.endRequested' }, {
            { query = 'UPDATE `qbhousing_leases` SET `status`=?,`end_at`=?,`revision`=? WHERE `id`=? AND `revision`=? AND `status`=?', values = { changed.status, changed.end_at, changed.revision, leaseId, lease.revision, lease.status }, expectedRows = 1 },
        })
        if not saved then return false, err end
        L.publish(changed)
        return true, changed
    end)
end

function L.leaseAccess(src, leaseId, target, action, allowed)
    local lease = get(leaseId)
    if not lease then return false, 'Lease was not found.' end
    return D.lock(lease.property_id, function()
        lease = get(leaseId)
        if not lease or lease.status ~= 'active' and lease.status ~= 'ending' then return false, 'Lease is no longer active.' end
        local cid, property = P.citizenId(src), State.get(lease.property_id)
        if cid ~= lease.tenant or not property or not L.current[property.id] or not physical[action] or action == 'property.edit' or allowed ~= nil and type(allowed) ~= 'boolean' then return false, 'Only the active tenant can share physical access.' end
        if not D.owner(property, target) and not lease.permissions['access.share'] then return false, 'Your lease does not allow sharing guest access.' end
        if allowed == true and lease.permissions[action] ~= true then return false, 'Your lease does not allow sharing this permission.' end
        local exists, err = D.character(target)
        if not exists then return false, err end
        local write = allowed == nil and { query = 'DELETE FROM `qbhousing_lease_access` WHERE `lease_id`=? AND `citizenid`=? AND `action`=?', values = { leaseId, target, action } }
            or { query = 'INSERT INTO `qbhousing_lease_access` (`lease_id`,`citizenid`,`action`,`allowed`) VALUES (?,?,?,?) ON DUPLICATE KEY UPDATE `allowed`=VALUES(`allowed`)', values = { leaseId, target, action, allowed and 1 or 0 } }
        local saved, saveErr = State.persist(Housing.copy(property), { actor = cid, action = 'lease.access', target = target, permission = action, allowed = allowed }, { write })
        if not saved then return false, saveErr end
        local current = L.current[property.id]
        current.access[target] = current.access[target] or {}; current.access[target][action] = allowed
        return true, saved
    end)
end

function L.bill(leaseId)
    local lease = get(leaseId)
    if not lease then return false, 'Lease storage is unavailable.' end
    if lease.status ~= 'active' and lease.status ~= 'ending' then L.publish(lease); return true end
    if lease.status == 'ending' and lease.end_at and lease.end_at <= os.time() then return L.finish(leaseId) end
    if not lease.next_due or lease.next_due > os.time() then L.publish(lease); return true end
    return D.lock(lease.property_id, function()
        lease = get(leaseId)
        if not lease then return false, 'Lease was not found.' end
        if lease.status ~= 'active' and lease.status ~= 'ending' then L.publish(lease); return true end
        if not lease.next_due or lease.next_due > os.time() or lease.status == 'ending' and lease.end_at and lease.end_at <= os.time() then L.publish(lease); return true end
        local property, start = State.get(lease.property_id), lease.next_due
        local finish = start + Config.rentalIntervals[lease.interval_name]
        local key = 'rent:' .. lease.id .. ':' .. start
        local changed = Housing.copy(lease)
        changed.next_due, changed.paid_through, changed.missed, changed.revision = finish, finish, 0, lease.revision + 1
        local writes = {
            { query = 'INSERT INTO `qbhousing_rent_periods` (`lease_id`,`period_start`,`period_end`,`amount`,`status`,`operation_id`) VALUES (?,?,?,?,?,?)', values = { lease.id, start, finish, lease.rent, 'paid', key } },
            { query = 'UPDATE `qbhousing_leases` SET `next_due`=?,`paid_through`=?,`missed`=0,`revision`=? WHERE `id`=? AND `revision`=?', values = { finish, finish, changed.revision, lease.id, lease.revision }, expectedRows = 1 },
        }
        local ok, result, code = Housing.transactions.run(key, 'rent', lease.tenant, Housing.copy(property), { { citizenid = lease.tenant, amount = lease.rent } }, D.split(property, lease.rent), writes, { lease = changed })
        if ok or code ~= 'insufficient_funds' then return ok, result end
        changed = Housing.copy(lease)
        changed.next_due, changed.missed, changed.revision = finish, lease.missed + 1, lease.revision + 1
        if changed.missed >= (lease.missed_limit or Config.missedPayments[lease.interval_name]) then changed.status = 'evicting' end
        local saved, err = State.persist(Housing.copy(property), { actor = lease.tenant, action = 'rent.missed' }, {
            { query = 'INSERT INTO `qbhousing_rent_periods` (`lease_id`,`period_start`,`period_end`,`amount`,`status`,`operation_id`) VALUES (?,?,?,?,?,?)', values = { lease.id, start, finish, lease.rent, 'missed', key } },
            { query = 'UPDATE `qbhousing_leases` SET `next_due`=?,`missed`=?,`status`=?,`revision`=? WHERE `id`=? AND `revision`=? AND `status`=?', values = { finish, changed.missed, changed.status, changed.revision, lease.id, lease.revision, lease.status }, expectedRows = 1 },
        })
        if not saved then return false, err end
        L.publish(changed)
        return true, changed
    end)
end

function L.finish(leaseId)
    local lease = get(leaseId)
    if not lease then return false, 'Lease was not found.' end
    return D.lock(lease.property_id, function()
        lease = get(leaseId)
        if not lease then return false, 'Lease was not found.' end
        if lease.status == 'ended' or lease.status == 'evicted' then L.publish(lease); return true, lease end
        if lease.status ~= 'evicting' and not (lease.status == 'ending' and lease.end_at and lease.end_at <= os.time()) then return false, 'Lease is not due to end.' end
        local property = State.get(lease.property_id)
        if not property then return false, 'Property was not found.' end
        local ok, err = D.sql({ { query = 'INSERT IGNORE INTO `qbhousing_evictions` (`lease_id`,`reason`,`status`,`created_at`) VALUES (?,?,?,?)', values = { lease.id, lease.status == 'evicting' and 'missed_rent' or 'termination', 'pending', os.time() } } })
        if not ok then return false, err end
        ok, err = Housing.storage.recoverLease(lease)
        if not ok then return false, err end
        ok, err = Housing.world.recoverLease(lease.property_id, lease.id, lease.tenant, true)
        if not ok then return false, err end
        local changed = Housing.copy(lease)
        changed.status, changed.revision = lease.status == 'evicting' and 'evicted' or 'ended', lease.revision + 1
        changed.deposit_release_at = lease.deposit_remaining > 0 and os.time() + lease.deposit_review_seconds or nil
        local saved, saveErr = State.persist(Housing.copy(property), { actor = lease.tenant, action = 'lease.' .. changed.status }, {
            { query = 'UPDATE `qbhousing_leases` SET `status`=?,`revision`=?,`deposit_release_at`=? WHERE `id`=? AND `revision`=? AND `status`=?', values = { changed.status, changed.revision, changed.deposit_release_at or QB.sql.NULL, lease.id, lease.revision, lease.status }, expectedRows = 1 },
            { query = 'UPDATE `qbhousing_evictions` SET `status`=? WHERE `lease_id`=?', values = { 'completed', lease.id } },
        })
        if not saved then return false, saveErr end
        L.publish(changed)
        Housing.storage.notifyRecovery(lease)
        return true, changed
    end)
end

function L.proposeDeduction(src, leaseId, payload)
    local lease = get(leaseId)
    if not lease then return false, 'Lease was not found.' end
    return D.lock(lease.property_id, function()
        lease = get(leaseId)
        if not lease then return false, 'Lease was not found.' end
        local property, cid = State.get(lease.property_id), P.citizenId(src)
        if not D.owner(property, cid) or lease.status ~= 'ended' and lease.status ~= 'evicted' or lease.deposit_remaining < 1 or not lease.deposit_release_at or lease.deposit_release_at <= os.time() or type(payload) ~= 'table' then return false, 'There is no refundable deposit to deduct from.' end
        if payload.category ~= 'damage' and payload.category ~= 'unpaid_rent' or not D.amount(payload.amount) or type(payload.note) ~= 'string' or #payload.note < 1 or #payload.note > 2000 then return false, 'Provide a valid category, amount and evidence note.' end
        local reserved, reservedErr = QB.sql.scalar('SELECT COALESCE(SUM(`amount`),0) FROM `qbhousing_deposit_deductions` WHERE `lease_id`=? AND `status` IN (?,?,?)', { lease.id, 'proposed', 'disputed', 'approved' })
        if reserved == nil or payload.amount > lease.deposit_remaining - tonumber(reserved) then return false, reservedErr or 'Deductions exceed the remaining deposit.' end
        local id = D.id()
        if not id then return false, 'Deposit storage is unavailable.' end
        local ok, err = D.sql({ { query = 'INSERT INTO `qbhousing_deposit_deductions` (`id`,`lease_id`,`category`,`amount`,`note`,`status`,`actor`,`created_at`) VALUES (?,?,?,?,?,?,?,?)', values = { id, lease.id, payload.category, payload.amount, payload.note, 'proposed', cid, os.time() } }, D.audit(property.id, cid, 'deposit.propose', { deduction = id }) })
        return ok, ok and { id = id } or err
    end)
end

function L.decideDeduction(src, id, decision, amount, note)
    local row = QB.sql.single('SELECT * FROM `qbhousing_deposit_deductions` WHERE `id`=?', { id })
    if not row then return false, 'Deduction was not found.' end
    local lease = get(row.lease_id)
    if not lease then return false, 'Lease was not found.' end
    local ok, result = D.lock(lease.property_id, function()
        row = QB.sql.single('SELECT * FROM `qbhousing_deposit_deductions` WHERE `id`=?', { id })
        lease = get(lease.id)
        if not row or not lease or row.lease_id ~= lease.id or row.status ~= 'proposed' and row.status ~= 'disputed' and row.status ~= 'approved' then return false, 'This deduction is already settled or unavailable.' end
        if decision == 'resolve' then
            if not P.isAdmin(src) or not D.amount(amount, true) or amount > row.amount or type(note) ~= 'string' or #note < 1 or #note > 2000 then return false, 'An administrator must provide a valid resolution and reason.' end
        else
            if lease.tenant ~= P.citizenId(src) or row.status ~= 'proposed' or decision ~= 'accept' and decision ~= 'dispute' then return false, 'Only the tenant can decide the proposed deduction.' end
            amount = decision == 'accept' and row.amount or nil
        end
        local status = decision == 'dispute' and 'disputed' or 'approved'
        local saved, err = D.sql({ { query = 'UPDATE `qbhousing_deposit_deductions` SET `status`=?,`approved_amount`=?,`decision_note`=? WHERE `id`=? AND `status`=?', values = { status, amount or QB.sql.NULL, note or QB.sql.NULL, id, row.status }, expectedRows = 1 }, D.audit(lease.property_id, P.citizenId(src), 'deposit.' .. decision, { deduction = id, amount = amount }) })
        return saved, saved and true or err
    end)
    if ok then L.settleDeposit(lease.id) end
    return ok, result
end

function L.resolveDeduction(src, id, amount, note) return L.decideDeduction(src, id, 'resolve', amount, note) end

function L.settleDeposit(leaseId)
    local lease = get(leaseId)
    if not lease then return false, 'Lease storage is unavailable.' end
    if lease.status ~= 'ended' and lease.status ~= 'evicted' or lease.deposit_remaining < 1 then L.publish(lease); return true end
    return D.lock(lease.property_id, function()
        lease = get(leaseId)
        if not lease then return false, 'Lease was not found.' end
        if lease.status ~= 'ended' and lease.status ~= 'evicted' or lease.deposit_remaining < 1 then L.publish(lease); return true end
        local property = State.get(lease.property_id)
        if not property then return false, 'Property was not found.' end
        local rows, err = QB.sql.query('SELECT * FROM `qbhousing_deposit_deductions` WHERE `lease_id`=? AND `status` IN (?,?,?) ORDER BY `created_at`', { leaseId, 'proposed', 'disputed', 'approved' })
        if not rows then return false, err end
        local writes, credits, payout, held = {}, {}, 0, 0
        for _, row in ipairs(rows) do
            if row.status == 'approved' then
                if not D.amount(row.approved_amount, true) or row.approved_amount > row.amount then return false, 'Invalid approved deposit amount.' end
                payout = payout + row.approved_amount
                writes[#writes + 1] = { query = 'UPDATE `qbhousing_deposit_deductions` SET `status`=? WHERE `id`=? AND `status`=?', values = { 'settled', row.id, 'approved' }, expectedRows = 1 }
            else held = held + row.amount end
        end
        if payout > lease.deposit_remaining or held + payout > lease.deposit_remaining then return false, 'Deposit records require reconciliation.' end
        local refund = 0
        if not lease.deposit_release_at or lease.deposit_release_at <= os.time() then refund = lease.deposit_remaining - payout - held end
        if payout > 0 then
            local owners = lease.owner_payees or { lease.landlord }
            if #owners < 1 then return false, 'Lease owner allocation is unavailable.' end
            local allocation = { owner = owners[1], coowners = {} }
            for index = 2, #owners do allocation.coowners[owners[index]] = true end
            credits = D.split(allocation, payout)
        end
        if refund > 0 then credits[#credits + 1] = { citizenid = lease.tenant, amount = refund } end
        if payout + refund == 0 and #writes == 0 and not (lease.deposit_release_at and lease.deposit_release_at <= os.time()) then L.publish(lease); return true, lease end
        local changed = Housing.copy(lease)
        changed.deposit_remaining, changed.revision = lease.deposit_remaining - payout - refund, lease.revision + 1
        if lease.deposit_release_at and lease.deposit_release_at <= os.time() then changed.deposit_release_at = nil end
        writes[#writes + 1] = { query = 'UPDATE `qbhousing_leases` SET `deposit_remaining`=?,`revision`=?,`deposit_release_at`=? WHERE `id`=? AND `revision`=?', values = { changed.deposit_remaining, changed.revision, changed.deposit_release_at or QB.sql.NULL, leaseId, lease.revision }, expectedRows = 1 }
        if payout + refund == 0 then
            local saved, saveErr = State.persist(Housing.copy(property), { actor = lease.tenant, action = 'deposit.review' }, writes)
            if not saved then return false, saveErr end
            L.publish(changed)
            return true, changed
        end
        local key, keyErr = Housing.transactions.nextKey('deposit:' .. leaseId)
        if not key then return false, keyErr end
        return Housing.transactions.run(key, 'deposit.settle', lease.tenant, Housing.copy(property), { { account = Config.escrowAccount, amount = payout + refund } }, credits, writes, { lease = changed })
    end)
end

local function deadline(lease)
    if lease.status == 'evicting' then return os.time() end
    if lease.status == 'ended' or lease.status == 'evicted' then return lease.deposit_release_at end
    if lease.status == 'ending' and lease.end_at then return math.min(lease.next_due or lease.end_at, lease.end_at) end
    return lease.next_due
end

function L.schedule()
    if processing then return end
    if timer then QB.timers.clearTimeout(timer); timer = nil end
    if not State.ready then return end
    local nextAt
    for _, collection in ipairs({ L.current, L.deposits }) do
        for _, lease in pairs(collection) do
            local at = deadline(lease)
            if at then
                at = math.max(at, retries[lease.id] or 0)
                if not nextAt or at < nextAt then nextAt = at end
            end
        end
    end
    if not nextAt then return end
    timer = QB.timers.setTimeout(function()
        timer, processing = nil, true
        local due = {}
        for _, collection in ipairs({ L.current, L.deposits }) do
            for _, lease in pairs(collection) do
                local at = deadline(lease)
                if at and math.max(at, retries[lease.id] or 0) <= os.time() then due[#due + 1] = lease end
            end
        end
        for _, lease in ipairs(due) do
            local called, ok, err = pcall(function()
                if lease.status == 'evicting' or lease.status == 'ending' and lease.end_at and lease.end_at <= os.time() then return L.finish(lease.id) end
                if lease.status == 'ended' or lease.status == 'evicted' then return L.settleDeposit(lease.id) end
                return L.bill(lease.id)
            end)
            if not called or not ok then
                retries[lease.id] = os.time() + 30
                print(('[qbhousing] lease processing deferred: %s'):format(tostring(called and err or ok)))
            end
        end
        processing = false
        L.schedule()
    end, math.min(math.max(0, nextAt - os.time()) * 1000, 2147483000))
end

function L.view(src, id)
    local cid, property = P.citizenId(src), State.get(id)
    local manage = D.owner(property, cid) or P.isAdmin(src)
    local sql, params = 'SELECT * FROM `qbhousing_leases` WHERE `property_id`=?', { id }
    if not manage then sql = sql .. ' AND `tenant`=?'; params[#params + 1] = cid end
    local history = QB.sql.query(sql .. ' ORDER BY `created_at` DESC LIMIT 100', params) or {}
    local result = { active = Housing.copy(L.current[id]), history = history, payments = {}, deductions = {} }
    if not manage and (not result.active or result.active.tenant ~= cid) then result.active = nil end
    for _, lease in ipairs(history) do
        lease.permissions = type(lease.permissions) == 'string' and json.decode(lease.permissions) or lease.permissions
        for _, row in ipairs(QB.sql.query('SELECT * FROM `qbhousing_rent_periods` WHERE `lease_id`=? ORDER BY `period_start` DESC LIMIT 100', { lease.id }) or {}) do result.payments[#result.payments + 1] = row end
        for _, row in ipairs(QB.sql.query('SELECT * FROM `qbhousing_deposit_deductions` WHERE `lease_id`=? ORDER BY `created_at` DESC LIMIT 100', { lease.id }) or {}) do result.deductions[#result.deductions + 1] = row end
    end
    return result
end

AddEventHandler('onResourceStop', function(resource) if resource == GetCurrentResourceName() and timer then QB.timers.clearTimeout(timer) end end)
