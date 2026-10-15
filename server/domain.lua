Housing.domain = { agents = {} }
local D = Housing.domain

function D.id()
    return QB.sql.scalar('SELECT UUID()')
end

function D.amount(value, allowZero)
    return Housing.finite(value) and value % 1 == 0 and value >= (allowZero and 0 or 1) and value <= 1000000000
end

function D.character(cid)
    if type(cid) ~= 'string' or #cid < 1 or #cid > 50 then return false, 'Choose a valid character.' end
    local ok, data = pcall(function()
        return exports.qbcore:getPlayerByCitizenId(cid) or exports.qbcore:getOfflinePlayerData(cid)
    end)
    if not ok then return false, 'Character lookup is unavailable.' end
    return type(data) == 'table' and data.citizenid == cid, 'Character was not found.'
end

function D.owners(property)
    local owners = {}
    if property.owner then owners[#owners + 1] = property.owner end
    local others = {}
    for cid in pairs(property.coowners or {}) do others[#others + 1] = cid end
    table.sort(others)
    for _, cid in ipairs(others) do owners[#owners + 1] = cid end
    return owners
end

function D.owner(property, cid)
    return property and cid and (property.owner == cid or property.coowners and property.coowners[cid] == true) or false
end

function D.split(property, amount)
    local owners, credits = D.owners(property), {}
    if #owners == 0 then return { { account = Config.societyAccount, amount = amount } } end
    local share = math.floor(amount / #owners)
    for index, cid in ipairs(owners) do
        local value = share + (index == 1 and amount - share * #owners or 0)
        if value > 0 then credits[#credits + 1] = { citizenid = cid, amount = value } end
    end
    return credits
end

function D.audit(propertyId, actor, action, context, outcome)
    return { query = 'INSERT INTO `qbhousing_audit` (`property_id`,`actor`,`action`,`outcome`,`context`) VALUES (?,?,?,?,?)',
        values = { propertyId, actor or QB.sql.NULL, action, outcome or 'success', json.encode(context or {}) } }
end

function D.sql(statements)
    local result = QB.sql.transactionChecked(statements)
    if not result or not result.success then return false, result and (result.message or result.error) or 'Property storage is unavailable.' end
    return true
end

function D.lock(id, handler)
    local ok, result, code = Housing.state.withWrite(id, handler)
    return ok == true, result, code
end

function D.agent(propertyId, cid)
    return cid and D.agents[propertyId] and D.agents[propertyId][cid] == true or false
end

function D.load()
    local rows, err = QB.sql.query('SELECT `property_id`,`citizenid` FROM `qbhousing_agents`')
    if not rows then return false, err end
    D.agents = {}
    for _, row in ipairs(rows) do
        D.agents[row.property_id] = D.agents[row.property_id] or {}
        D.agents[row.property_id][row.citizenid] = true
    end
    return true
end

function D.near(src, coords, distance)
    if not Housing.validCoords(coords) then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local position = GetEntityCoords(ped)
    return #(position - vector3(coords.x, coords.y, coords.z)) <= (distance or 3.0)
end
