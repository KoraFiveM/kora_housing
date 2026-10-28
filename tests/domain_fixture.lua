-- Runs real domain services; substitutes SQL/financial transport and the host.
local tools = dofile('../kora_core/test/mocks.lua')
local json = { encode = tools.stableEncode, decode = tools.simpleDecode }
local function copy(value) return json.decode(json.encode(value)) end
local function has(text, part) return text:find(part, 1, true) ~= nil end
return function(options)
    options = options or {}
    local f = { bankCalls = {}, receipts = {}, balances = { BUYER = 10000, SECOND = 10000, OWNER = 0, COOWNER = 0 },
        db = { properties = {}, listings = {}, offers = {}, approvals = {}, transactions = {}, ledger = {}, stashes = {}, recovery = {}, tiers = {}, garages = {} },
        inventory = {}, policies = {}, blocks = {}, inventoryReceipts = {}, delivered = 0, sequence = 0, timers = {}, events = {}, registered = {}, calls = {} }
    local env = {}; for key, value in pairs(_G) do env[key] = value end
    env.Housing, env.Config, env.json = nil, nil, json
    env.GetCurrentResourceName = function() return 'kora_housing' end
    env.GetResourceState = function() return 'missing' end
    env.TriggerClientEvent, env.GetPlayerPed = function() end, function(src) return src end
    env.AddEventHandler = function(name, fn) f.events[name] = fn end
    local players = { [1] = { citizenid = 'OWNER' }, [2] = { citizenid = 'BUYER' }, [3] = { citizenid = 'SECOND' }, [4] = { citizenid = 'COOWNER' }, [5] = { citizenid = 'AGENT', job = { name = 'realestate' } } }
    local sql = { NULL = '__SQL_NULL__' }
    local function null(value) return value ~= sql.NULL and value or nil end
    local function rows(values, predicate)
        local result = {}; for _, row in pairs(values) do if not predicate or predicate(row) then result[#result + 1] = copy(row) end end; return result
    end
    sql.query = function(query, p)
        p = p or {}; if f.failRead then return nil, 'controlled read failure' end
        if has(query, 'FROM `qbhousing_sale_approvals`') then return rows(f.db.approvals, function(row) return row.offer_id == p[1] end) end
        if has(query, 'FROM `qbhousing_listings`') then return rows(f.db.listings, function(row)
            if has(query, 'WHERE `property_id`=?') then return row.property_id == p[1] end
            return row.status == p[1] and row.channel == p[2]
        end) end
        if has(query, 'FROM `qbhousing_offers`') then return rows(f.db.offers, function(row) return row.listing_id == p[1] and (not p[2] or row.buyer == p[2]) end) end
        if has(query, 'FROM `qbhousing_offer_history`') then return {} end
        if has(query, 'FROM `qbhousing_transactions`') then return rows(f.db.transactions, function(row) return row.status == p[1] end) end
        if has(query, 'FROM `qbhousing_stashes`') then return rows(f.db.stashes, function(row)
            if has(query, 'WHERE `lease_id`=?') then return row.lease_id == p[1] and row.status ~= p[2] end
            if row.property_id ~= p[1] or has(query, '`lease_id` IS NULL') and row.lease_id then return false end
            if has(query, '`status`<>?') then return row.status ~= p[2] end
            return not p[2] or row.status == p[2]
        end) end
        error('Unmocked SQL query: ' .. query)
    end
    sql.single = function(query, p)
        if f.failRead then return nil, 'controlled read failure' end
        for tableName, name in pairs({ qbhousing_transactions = 'transactions', qbhousing_listings = 'listings', qbhousing_offers = 'offers', qbhousing_stashes = 'stashes', qbhousing_recovery = 'recovery' }) do
            if has(query, 'FROM `' .. tableName .. '`') then
                local row = f.db[name][p[1]]
                if row and has(query, 'AND `citizenid`=?') and row.citizenid ~= p[2] or row and has(query, 'AND `property_id`=?') and row.property_id ~= p[2] then return nil end
                return row and copy(row)
            end
        end
        error('Unmocked SQL single: ' .. query)
    end
    sql.scalar = function(query, p)
        if f.failRead then return nil, 'controlled read failure' end
        if has(query, 'UUID()') then f.sequence = f.sequence + 1; return 'generated-' .. f.sequence end
        if has(query, 'MAX(`tier`)') then return f.db.tiers[p[1]] or 1 end
        if has(query, 'FROM `qbhousing_transactions`') then
            local base, count = p[1]:sub(1, -2), 0
            for id in pairs(f.db.transactions) do if id:sub(1, #base) == base then count = count + 1 end end; return count
        end
        if has(query, 'FROM `qbhousing_leases`') then return f.blockingLeases or 0 end
        if has(query, 'FROM `qbhousing_garage_recovery`') then return f.formerGarage and 1 or 0 end
        if has(query, 'FROM `qbhousing_recovery`') then return #rows(f.db.recovery, function(row) return row.kind == p[1] and row.reference == p[2] and row.citizenid == p[3] and row.status == p[4] end) end
        if has(query, 'FROM `qbhousing_stashes`') then return #rows(f.db.stashes, function(row) return row.property_id == p[1] and not row.lease_id end) end
        if has(query, 'garage_key FROM `qbhousing_garages`') then return f.db.garages[p[1]] end
        error('Unmocked SQL scalar: ' .. query)
    end
    local function write(query, p)
        if has(query, 'INSERT INTO `qbhousing_properties`') then f.db.properties[p[1]] = { id = p[1], owner = null(p[2]), definition = p[3], property_type = p[4], revision = p[5], ownership_revision = p[6] }; return 1 end
        if has(query, 'UPDATE `qbhousing_properties`') then
            local old = f.db.properties[p[6]]; if not old or old.revision ~= p[7] then return 0 end
            f.db.properties[p[6]] = { id = p[6], owner = null(p[1]), definition = p[2], property_type = p[3], revision = p[4], ownership_revision = p[5] }; return 1
        end
        if has(query, 'INSERT INTO `qbhousing_transactions`') then
            if f.failReservation then return nil, 'controlled reservation failure' end
            if f.db.transactions[p[1]] then return nil, 'duplicate key' end
            f.db.transactions[p[1]] = { id = p[1], property_id = p[2], kind = p[3], actor = p[4], status = p[5], request = p[6], result = p[7], created_at = p[8] }; return 1
        end
        if has(query, 'UPDATE `qbhousing_transactions`') then
            local row = f.db.transactions[has(query, '`error`=?') and p[4] or p[3]]
            if not row or row.status ~= p[#p] then return 0 end
            row.status = p[1]; if has(query, '`error`=?') then row.error = p[2] end; return 1
        end
        if has(query, 'INSERT INTO `qbhousing_ledger`') then f.db.ledger[#f.db.ledger + 1] = copy(p); return 1 end
        if has(query, 'INSERT INTO `qbhousing_listings`') then
            for _, row in pairs(f.db.listings) do if row.property_id == p[2] and row.status == 'active' then return nil, 'active listing exists' end end
            f.db.listings[p[1]] = { id = p[1], property_id = p[2], channel = p[3], seller = null(p[4]), agent = null(p[5]), buyer = null(p[6]), biography = p[7], price = p[8], status = p[9], ownership_revision = p[10], created_at = p[11], commission_policy = p[12], policy_version = p[13] }; return 1
        end
        if has(query, 'INSERT INTO `qbhousing_offers`') then f.db.offers[p[1]] = { id = p[1], listing_id = p[2], buyer = p[3], amount = p[4], status = p[5], created_at = p[6] }; return 1 end
        if has(query, 'INSERT INTO `qbhousing_sale_approvals`') then f.db.approvals[p[1] .. ':' .. p[2]] = { offer_id = p[1], citizenid = p[2], ownership_revision = p[3], approved = p[4] }; return 1 end
        if has(query, 'UPDATE `qbhousing_offers` o JOIN') then
            local count = 0
            for _, row in pairs(f.db.offers) do
                local listing = f.db.listings[row.listing_id]
                if listing.property_id == p[2] and listing.status == p[3] and (row.status == p[4] or row.status == p[5]) then row.status = p[1]; count = count + 1 end
            end
            return count
        end
        if has(query, 'UPDATE `qbhousing_offers`') then
            if has(query, '`recommendation`=?') then local row = f.db.offers[p[2]]; if not row or row.status ~= p[3] then return 0 end; row.recommendation = p[1]; return 1 end
            if has(query, '`id`<>?') then
                local count = 0; for id, row in pairs(f.db.offers) do if row.listing_id == p[2] and id ~= p[3] and (row.status == p[4] or row.status == p[5]) then row.status = p[1]; count = count + 1 end end; return count
            end
            local row = f.db.offers[p[2]]; if not row or p[3] and row.status ~= p[3] then return 0 end; row.status = p[1]; return 1
        end
        if has(query, 'UPDATE `qbhousing_listings`') and has(query, 'WHERE `property_id`=?') then
            local count = 0; for _, row in pairs(f.db.listings) do if row.property_id == p[2] and row.status == p[3] then row.status = p[1]; count = count + 1 end end; return count
        end
        if has(query, 'UPDATE `qbhousing_listings`') then local row = f.db.listings[p[2]]; if not row or p[3] and row.status ~= p[3] then return 0 end; row.status = p[1]; return 1 end
        if has(query, 'INSERT INTO `qbhousing_storage_purchases`') then if f.db.tiers[p[1]] and f.db.tiers[p[1]] >= p[2] then return nil, 'duplicate tier' end; f.db.tiers[p[1]] = p[2]; return 1 end
        if has(query, 'INSERT IGNORE INTO `qbhousing_garages`') then f.db.garages[p[1]] = f.db.garages[p[1]] or p[2]; return 1 end
        if has(query, 'INSERT IGNORE INTO `qbhousing_recovery`') then
            for _, row in pairs(f.db.recovery) do if row.kind == p[4] and row.reference == p[5] and row.citizenid == p[3] then return 0 end end
            f.db.recovery[p[1]] = { id = p[1], property_id = p[2], citizenid = p[3], kind = p[4], reference = p[5], status = p[6], created_at = p[7] }; return 1
        end
        if has(query, 'UPDATE `qbhousing_recovery`') then
            local count = 0; for _, row in pairs(f.db.recovery) do if row.kind == p[2] and row.reference == p[3] and row.status == p[4] then row.status = p[1]; count = count + 1 end end; return count
        end
        if has(query, 'UPDATE `qbhousing_stashes`') then
            if has(query, '`tenant`=?') then local row = f.db.stashes[p[3]]; if not row or row.status ~= p[4] then return 0 end; row.status, row.tenant = p[1], null(p[2]); return 1 end
            local row = f.db.stashes[p[2]]; if not row or p[3] and row.status ~= p[3] then return 0 end; row.status = p[1]; return 1
        end
        for _, name in ipairs({ 'qbhousing_coowners', 'qbhousing_permissions', 'qbhousing_units', 'qbhousing_audit', 'qbhousing_agents', 'qbhousing_offer_history', 'qbhousing_garage_recovery' }) do if has(query, '`' .. name .. '`') then return 1 end end
        error('Unmocked SQL mutation: ' .. query)
    end
    sql.execute = function(query, p) local count, err = write(query, p); return count and { affectedRows = count } or nil, err end
    sql.insert, sql.update = write, write
    sql.transactionChecked = function(statements)
        if f.failSQL then return { success = false, code = 'unavailable', message = 'controlled SQL failure' } end
        local old = copy(f.db)
        for _, statement in ipairs(statements) do
            local count, err = write(statement.query, statement.values)
            if count == nil or statement.expectedRows and count ~= statement.expectedRows then f.db = old; return { success = false, code = 'conflict', message = err or 'precondition changed' } end
        end
        return { success = true, results = {} }
    end
    env.QB = { sql = sql, permissions = { hasPermission = function(src) return f.admin == src end }, timers = {
        setTimeout = function(fn) f.timers[#f.timers + 1] = fn; return #f.timers end, clearTimeout = function() end } }
    local banking, inventory, garages = {}, {}, {}
    function banking.ExecuteTransaction(_, key, request)
        f.bankCalls[#f.bankCalls + 1] = { key = key, request = copy(request) }
        if f.bankYield then coroutine.yield('bank wait') end
        if f.bankMode == 'throw' then error('controlled transport failure') end
        if f.receipts[key] then return copy(f.receipts[key]) end
        if f.bankMode then return nil, f.bankMode, 'controlled payment failure' end
        for _, debit in ipairs(request.debits) do if (f.balances[debit.citizenid or debit.account] or 0) < debit.amount then return nil, 'insufficient_funds', 'Not enough money.' end end
        if f.failBankSQL then return nil, 'unavailable', 'controlled bank SQL failure' end
        local result = sql.transactionChecked(request.statements); if not result.success then return nil, result.code, result.message end
        for _, group in ipairs({ { entries = request.debits, sign = -1 }, { entries = request.credits, sign = 1 } }) do for _, entry in ipairs(group.entries) do local id = entry.citizenid or entry.account; f.balances[id] = (f.balances[id] or 0) + group.sign * entry.amount end end
        f.receipts[key] = { id = key, status = 'completed' }
        if f.commitThenThrow then error('response lost after commit') end
        return copy(f.receipts[key])
    end
    function banking.GetOperation(_, key) return f.receipts[key] and copy(f.receipts[key]) end
    function inventory.RegisterStashPolicy(_, id, config, callback)
        if f.failRegister then return false, 'controlled register failure' end
        f.policies[id], f.registered[id] = callback, copy(config); f.inventory[id] = f.inventory[id] or {}; return true, 'stash:' .. id
    end
    function inventory.RebindStashPolicy(_, id, callback) if not f.registered[id] then return false, 'not registered' end; f.policies[id] = callback; return true end
    function inventory.SetStashBlocked(_, id, blocked) if f.busyStash == id then return false, 'inventory busy' end; f.blocks[id] = blocked; return true end
    function inventory.GetStashItems(_, id) f.calls[#f.calls + 1] = { kind = 'read', id = id, blocked = f.blocks[id] }; return copy(f.inventory[id] or {}) end
    function inventory.stashOpen(_, src, id) return not f.blocks[id] and f.policies[id](src) == true end
    function inventory.ClaimStash(_, src, id, key)
        if f.inventoryReceipts[key] then return true, copy(f.inventoryReceipts[key]) end
        if f.full then return false, 'Inventory full.' end
        if not f.policies[id](src, nil, nil, { recovery = true }) then return false, 'Denied.' end
        local receipt = { operationKey = key, stashId = id, citizenid = players[src].citizenid }
        f.inventoryReceipts[key], f.inventory[id], f.delivered = receipt, {}, f.delivered + 1
        if f.afterClaim then f.afterClaim() end; return true, copy(receipt)
    end
    function garages.RegisterPropertyGarage(_, id, definition, callback) f.garage = { id = id, definition = copy(definition), callback = callback }; return true end
    env.exports = { kora_banking = banking, kora_inventory = inventory, kora_garages = garages, kora_core = {
        getPlayer = function(_, src) return players[src] end,
        getPlayerByCitizenId = function(_, cid) for _, player in pairs(players) do if player.citizenid == cid then return player end end end,
        getOfflinePlayerData = function() return nil end } }
    local function load(path) assert(loadfile(path, 't', env))() end
    for _, path in ipairs({ 'config.lua', 'shared/schema.lua', 'shared/permissions.lua', 'server/state.lua', 'server/permissions.lua', 'server/domain.lua' }) do load(path) end
    local housing = env.Housing
    housing.world = { stashCoords = function() return { x = 0, y = 0, z = 0 } end, contains = function() return true end, ownershipChanged = function() end, recovery = function() return {} end }
    housing.leases = { active = function(id) return f.lease and f.lease.property_id == id and f.lease or nil end,
        permission = function() return nil end, publish = function() end }
    load('server/transactions.lua'); load('server/storage.lua'); load('server/sales.lua')
    local property = assert(housing.normalise({ id = 'home', label = 'Home', owner = 'OWNER', coowners = options.coowner and { COOWNER = true } or {},
        permissionGrants = { OLD = { entry = true } }, keys = { OLD = true }, state = 'listed', propertyType = 'land', revision = 1, ownershipRevision = 1,
        exterior = { polyzone = { { x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 }, { x = 10, y = 10, z = 0 } }, minZ = -1, maxZ = 3 }, listing = { id = 'listing', price = 5000 },
        garage = options.garage and { resourceId = 'foreign', coords = { x = 0, y = 0, z = 0 }, spawn = { x = 1, y = 0, z = 0 }, slots = 2 } or nil }))
    housing.state.properties.home, housing.state.ready = property, true
    f.db.properties.home = { id = 'home', owner = property.owner, definition = json.encode(property), revision = 1, ownership_revision = 1 }
    f.db.listings.listing = { id = 'listing', property_id = 'home', channel = 'private', status = 'active', ownership_revision = 1, price = 5000, seller = property.owner }
    for id, cid in pairs({ offer = 'BUYER', competing = 'SECOND' }) do
        f.db.offers[id] = { id = id, listing_id = 'listing', buyer = cid, amount = 5000, status = 'accepted' }
        for _, owner in ipairs(housing.domain.owners(property)) do f.db.approvals[id .. ':' .. owner] = { offer_id = id, citizenid = owner, ownership_revision = 1, approved = 1 } end
    end
    f.env, f.housing, f.json, f.players = env, housing, json, players
    f.reloadTransactions = function() load('server/transactions.lua'); assert(housing.transactions.load()); housing.transactions.resume() end
    return f
end
