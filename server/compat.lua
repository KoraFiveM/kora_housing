local function hasKey(identifier, citizenid, house)
    if type(identifier) ~= 'string' or type(citizenid) ~= 'string' or citizenid == ''
        or type(house) ~= 'string' or not Housing.state.ready then return false end
    local property = Housing.state.get(house)
    if not property then return false end
    -- Upstream checks both license and character for owners. Existing granted
    -- keys are character-specific; native leases/revocations remain authoritative.
    if property.owner == citizenid then
        local player = exports.kora_core:getPlayerByCitizenId(citizenid)
            or exports.kora_core:getOfflinePlayerData(citizenid)
        if not player or player.license ~= identifier then return false end
    end
    return Housing.permissions.canCitizen(citizenid, house, 'entry') == true
end

exports('hasKey', hasKey)
Kora.compat.provideExport('qb-houses', 'hasKey', hasKey)

local function callerData(src)
    local ok, data = pcall(function() return exports.kora_core:getPlayer(src) end)
    if ok and type(data) == 'table' and type(data.citizenid) == 'string' and data.citizenid ~= '' then return data end
end

local function live(property)
    return property.state ~= 'archived' and property.state ~= 'archiving'
end

local function tierOf(property)
    local name = property.interior and property.interior.name
    for tier, shell in pairs(Config.legacyHousing and Config.legacyHousing.shellTiers or {}) do
        if shell == name then return tier end
    end
end

local function houseData(property)
    local entrance = property.interior and property.interior.entrance
    local garage = property.garage and property.garage.coords
    return {
        name = property.id,
        adress = property.label,
        label = property.label,
        price = property.listing and property.listing.price or 0,
        tier = tierOf(property),
        owned = property.owner ~= nil,
        garage = garage and { x = garage.x, y = garage.y, z = garage.z, h = garage.w } or nil,
        coords = entrance and { enter = { x = entrance.x, y = entrance.y, z = entrance.z, h = entrance.w } } or nil,
    }
end

local function holderRecord(citizenid)
    local data = exports.kora_core:getPlayerByCitizenId(citizenid) or exports.kora_core:getOfflinePlayerData(citizenid)
    if type(data) ~= 'table' or type(data.charinfo) ~= 'table' then return nil end
    return { charinfo = { firstname = data.charinfo.firstname, lastname = data.charinfo.lastname }, citizenid = citizenid, name = data.name }
end

local function sortedIds(set)
    local ids = {}
    for id in pairs(set) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

local function register(name, handler, max)
    Kora.callback.register(name, function(src, ...)
        if not Housing.state.ready then return nil end
        local ok, result = pcall(handler, src, ...)
        if ok then return result end
        print(('[qbhousing] compat callback %s failed: %s'):format(name, tostring(result)))
    end, { rateLimit = { max = max, window = 10000 } })
end

local function holdersOf(property)
    local set = {}
    for cid, enabled in pairs(property.keys or {}) do if enabled == true then set[cid] = true end end
    for cid, enabled in pairs(property.coowners or {}) do if enabled == true then set[cid] = true end end
    set[property.owner] = nil
    return sortedIds(set)
end

register('qb-phone:server:GetPlayerHouses', function(src)
    local me = callerData(src)
    if not me then return {} end
    local houses = {}
    for _, id in ipairs(sortedIds(Housing.state.properties)) do
        local property = Housing.state.properties[id]
        if property.owner == me.citizenid and live(property) then
            local entry = houseData(property)
            entry.keyholders, entry.owner = {}, me.citizenid
            for _, cid in ipairs(holdersOf(property)) do
                local record = holderRecord(cid)
                if record then entry.keyholders[#entry.keyholders + 1] = record end
            end
            if #entry.keyholders == 0 then
                entry.keyholders[1] = { charinfo = { firstname = me.charinfo and me.charinfo.firstname, lastname = me.charinfo and me.charinfo.lastname }, citizenid = me.citizenid, name = me.name }
            end
            houses[#houses + 1] = { name = entry.name, keyholders = entry.keyholders, owner = entry.owner, price = entry.price, label = entry.adress, tier = entry.tier, garage = entry.garage }
        end
    end
    return houses
end, 3)

register('qb-phone:server:GetHouseKeys', function(src)
    local me = callerData(src)
    if not me then return {} end
    local keys = {}
    for _, id in ipairs(sortedIds(Housing.state.properties)) do
        local property = Housing.state.properties[id]
        if live(property) and (property.owner == me.citizenid
            or (property.keys[me.citizenid] == true or property.coowners[me.citizenid] == true)
            and Housing.permissions.canCitizen(me.citizenid, id, 'entry') == true) then
            keys[#keys + 1] = { HouseData = houseData(property) }
        end
    end
    return keys
end, 3)

local function isOnDutyPolice(data)
    local job = data.job
    return type(job) == 'table' and job.type == 'leo' and job.onduty == true
end

register('qb-phone:server:MeosGetPlayerHouses', function(src, input)
    local me = callerData(src)
    if not me or not isOnDutyPolice(me) or type(input) ~= 'string' then return nil end
    local search = input:sub(1, 50)
    if search == '' then return nil end
    local pattern = '%' .. search:gsub('[\\%%_]', '\\%0') .. '%'
    local row = Kora.sql.single('SELECT `citizenid`,`charinfo` FROM `players` WHERE `deleted_at` IS NULL AND (`citizenid`=? OR `charinfo` LIKE ?) LIMIT 1', { search, pattern })
    if not row then return nil end
    local charinfo = json.decode(row.charinfo or '{}')
    local found = {}
    for _, id in ipairs(sortedIds(Housing.state.properties)) do
        local property = Housing.state.properties[id]
        if property.owner == row.citizenid and live(property) then
            local entry = houseData(property)
            found[#found + 1] = {
                name = entry.name, keyholders = json.encode(holdersOf(property)), owner = row.citizenid,
                price = entry.price, label = entry.adress, tier = entry.tier, garage = entry.garage,
                charinfo = charinfo, coords = entry.coords and { x = entry.coords.enter.x, y = entry.coords.enter.y, z = entry.coords.enter.z },
            }
        end
    end
    return found
end, 3)
