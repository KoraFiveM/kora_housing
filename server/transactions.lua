Housing.transactions = { pending = {} }
local T, State, D = Housing.transactions, Housing.state, Housing.domain
local timer

function T.busy(id) return T.pending[id] ~= nil end

local function publish(row)
    local result = type(row.result) == 'string' and json.decode(row.result) or row.result
    local stale = false
    if result.property then
        local current = State.get(row.property_id)
        stale = current and current.revision > result.property.revision or false
        if not stale then State.publish(result.property) end
    end
    if not stale and result.lease and Housing.leases then Housing.leases.publish(result.lease) end
    if T.pending[row.property_id] and T.pending[row.property_id].id == row.id then T.pending[row.property_id] = nil end
    if not stale and row.kind == 'sale' then
        D.agents[row.property_id] = nil
        if Housing.world.ownershipChanged then Housing.world.ownershipChanged(row.property_id, result.property.owner) end
    end
    if Housing.storage then
        Housing.storage.unfreeze(row.property_id)
        local ready, err = Housing.storage.refresh(row.property_id)
        if not ready then print(('[qbhousing] integration refresh deferred: %s'):format(tostring(err))) end
    end
    State.broadcast()
    return result
end

local function execute(row)
    local request = type(row.request) == 'string' and json.decode(row.request) or row.request
    local called, receipt, code, message = pcall(function() return exports.kora_banking:ExecuteTransaction(row.id, request) end)
    if not called or not receipt then
        local found, existing = pcall(function() return exports.kora_banking:GetOperation(row.id) end)
        if found and existing and existing.status == 'completed' then receipt = existing end
    end
    if receipt and receipt.status == 'completed' then return true, publish(row) end
    if called and (code == 'insufficient_funds' or code == 'conflict' or code == 'invalid_request' or code == 'rejected' or code == 'not_found') then
        local updated = QB.sql.update('UPDATE `qbhousing_transactions` SET `status`=?,`error`=?,`updated_at`=? WHERE `id`=? AND `status`=?',
            { 'rejected', code .. ':' .. tostring(message or 'Payment rejected.'), os.time(), row.id, 'pending' })
        if not updated or updated < 1 then return false, 'Payment rejection is being confirmed.', 'pending' end
        T.pending[row.property_id] = nil
        if Housing.storage then Housing.storage.unfreeze(row.property_id) end
        return false, message or 'Payment was rejected.', code
    end
    return false, 'Payment confirmation is pending. The operation will be recovered automatically.', 'pending'
end

function T.resume()
    timer = nil
    for _, row in pairs(T.pending) do
        if not State.writes[row.property_id] then
            State.writes[row.property_id] = true
            local ok, err = pcall(execute, row)
            State.writes[row.property_id] = nil
            if not ok then print(('[qbhousing] transaction recovery deferred: %s'):format(tostring(err))) end
        end
    end
    if next(T.pending) then timer = QB.timers.setTimeout(T.resume, 30000) end
end

function T.schedule()
    if not timer and next(T.pending) then timer = QB.timers.setTimeout(T.resume, 30000) end
end

function T.load()
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_transactions` WHERE `status`=?', { 'pending' })
    if not rows then return false, err end
    T.pending = {}
    for _, row in ipairs(rows) do T.pending[row.property_id] = row end
    T.schedule()
    return true
end

function T.nextKey(base)
    local count, err = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_transactions` WHERE `id` LIKE ?', { base .. ':%' })
    if count == nil then return nil, err end
    return base .. ':' .. tostring(tonumber(count) + 1)
end

function T.run(key, kind, actor, property, debits, credits, statements, effects)
    local existing, readErr = QB.sql.single('SELECT * FROM `qbhousing_transactions` WHERE `id`=?', { key })
    if readErr then return false, 'Transaction storage is unavailable.', 'unavailable' end
    if existing then
        if existing.property_id ~= property.id or existing.kind ~= kind or existing.actor ~= actor then return false, 'Transaction identity conflict.', 'conflict' end
        if existing.status == 'completed' then return true, publish(existing) end
        if existing.status == 'rejected' then
            local code, message = (existing.error or ''):match('^([^:]+):(.*)$')
            return false, message or 'Payment was rejected.', code or 'rejected'
        end
        local ok, result, code = execute(existing)
        T.schedule()
        return ok, result, code
    end
    if T.busy(property.id) then return false, 'Another payment is being confirmed for this property.', 'pending' end
    local value, writes = State.prepare(property, { actor = actor, action = kind })
    if not value then return false, writes, 'invalid_request' end
    for _, statement in ipairs(statements or {}) do writes[#writes + 1] = statement end
    effects = effects or {}
    effects.property = value
    local leg = 0
    for _, group in ipairs({ { rows = debits, sign = -1, kind = 'debit' }, { rows = credits, sign = 1, kind = 'credit' } }) do
        for _, entry in ipairs(group.rows) do
            leg = leg + 1
            writes[#writes + 1] = { query = 'INSERT INTO `qbhousing_ledger` (`operation_id`,`leg`,`citizenid`,`account`,`amount`,`kind`) VALUES (?,?,?,?,?,?)',
                values = { key, leg, entry.citizenid or QB.sql.NULL, entry.account or QB.sql.NULL, group.sign * entry.amount, group.kind } }
        end
    end
    local now = os.time()
    writes[#writes + 1] = { query = 'UPDATE `qbhousing_transactions` SET `status`=?,`updated_at`=? WHERE `id`=? AND `status`=?', values = { 'completed', now, key, 'pending' }, expectedRows = 1 }
    local request = { debits = debits, credits = credits, statements = writes, context = { kind = kind, propertyId = property.id, actor = actor, policyVersion = Config.salePolicyVersion } }
    local row = { id = key, property_id = property.id, kind = kind, actor = actor, status = 'pending', request = json.encode(request), result = json.encode(effects), created_at = now }
    local inserted, err = QB.sql.insert([[INSERT INTO `qbhousing_transactions` (`id`,`property_id`,`kind`,`actor`,`status`,`request`,`result`,`created_at`,`updated_at`) VALUES (?,?,?,?,?,?,?,?,?)]],
        { key, property.id, kind, actor, 'pending', row.request, row.result, now, now })
    if not inserted then return false, err or 'Transaction could not be reserved.', 'unavailable' end
    T.pending[property.id] = row
    local ok, result, code = execute(row)
    T.schedule()
    return ok, result, code
end

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() and timer then QB.timers.clearTimeout(timer) end
end)
