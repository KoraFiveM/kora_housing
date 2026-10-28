-- One-time conversion of archived fixtures into native housing records. The
-- lossless archive remains immutable; it is never consulted during gameplay.
local Legacy, State = Housing.legacy, Housing.state

local function decoded(value)
    if value == nil or value == '' or value == 'null' then return {} end
    local ok, result = pcall(json.decode, value)
    return ok and type(result) == 'table' and result or nil
end

local function point(value)
    if not Housing.validCoords(value) or value.h ~= nil and not Housing.finite(value.h) then return nil end
    return { x = value.x, y = value.y, z = value.z, w = value.w or value.h }
end

function Legacy.prepareFixtures(property, source)
    local legacy, owner = property.legacy, source.player_houses
    if not legacy or not owner or property.owner ~= owner.citizenid then return property, {} end
    local writes, flags, changed = {}, legacy.unmappedFixtures or {}, not legacy.fixtureVersion
    legacy.unmappedFixtures = flags
    if not legacy.fixtureVersion then
        for _, field in ipairs({ 'decorations', 'stash', 'outfit', 'logout' }) do
            local value = decoded(owner[field])
            if not value then return nil, 'Invalid archived housing fixture: ' .. field end
            if next(value) then flags[field] = true end
        end
    end
    if flags.stash then
        local position, capacity = point(decoded(owner.stash)), Config.legacyHousing.stashTiers[tonumber(legacy.tier)]
        local rows, err = QB.sql.query('SELECT `id` FROM `qbhousing_stashes` WHERE `property_id`=?', { property.id })
        if not rows then return nil, err end
        if position and capacity and Housing.finite(capacity.slots) and capacity.slots % 1 == 0 and capacity.slots > 0
            and Housing.finite(capacity.maxWeight) and capacity.maxWeight > 0 and #rows == 0 then
            -- Stock OpenInventory uses the house name itself. Keeping that ID
            -- retains the canonical inventory and its existing imported items.
            writes[#writes + 1] = { query = 'INSERT INTO `qbhousing_stashes` (`id`,`property_id`,`status`,`coords`) VALUES (?,?,?,?)',
                values = { property.id, property.id, 'active', json.encode(position) }, expectedRows = 1 }
            legacy.stash = { id = property.id, coords = position, capacity = Housing.copy(capacity) }
            for cid in pairs(property.keys or {}) do
                local grants = property.permissionGrants[cid] or {}
                if grants.entry ~= false and grants['stash.open'] == nil then grants['stash.open'] = true end
                property.permissionGrants[cid] = grants
            end
            flags.stash, changed = nil, true
        end
    end
    if flags.outfit then
        local position = point(decoded(owner.outfit))
        if position and #(property.clothing or {}) == 0 then
            property.clothing = { { id = 'stock', coords = position } }
            flags.outfit, changed = nil, true
        end
    end
    if flags.logout then
        local position = point(decoded(owner.logout))
        if position and property.logout == nil then property.logout = position; flags.logout, changed = nil, true end
    end
    if flags.decorations then
        local decorations = decoded(owner.decorations)
        local rows, err = QB.sql.query('SELECT `id` FROM `qbhousing_furniture` WHERE `property_id`=?', { property.id })
        if not rows then return nil, err end
        local mapped, count, valid = {}, 0, decorations and #decorations <= Config.maxFurniture and #rows == 0
        for index, item in pairs(decorations or {}) do
            count = count + 1
            local id = 'stock:' .. property.id .. ':' .. tostring(index)
            if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > #decorations or #id > 64
                or type(item) ~= 'table' or type(item.hashname) ~= 'string' or #item.hashname > 100
                or not item.hashname:match('^[%w_]+$') or not point(item)
                or not Housing.finite(item.rotx) or not Housing.finite(item.roty) or not Housing.finite(item.rotz) then valid = false; break end
            mapped[#mapped + 1] = { id = id, propertyId = property.id, ownerCid = property.owner, status = 'placed',
                model = item.hashname, coords = point(item), rotation = { pitch = item.rotx, roll = item.roty, yaw = item.rotz }, revision = 1 }
        end
        if valid and count == #decorations then
            for _, item in ipairs(mapped) do
                writes[#writes + 1] = { query = 'INSERT INTO `qbhousing_furniture` (`id`,`property_id`,`owner_cid`,`status`,`definition`,`revision`) VALUES (?,?,?,?,?,?)',
                    values = { item.id, property.id, property.owner, 'placed', json.encode(item), 1 }, expectedRows = 1 }
            end
            flags.decorations, changed = nil, true
        end
    end
    legacy.fixtureVersion = 1
    return property, writes, changed
end

function Legacy.upgradeFixtures()
    local rows, err = QB.sql.query('SELECT `property_id`,`source_data` FROM `qbhousing_stock_import`')
    if not rows then return false, err end
    for _, row in ipairs(rows) do
        local property, archive = State.get(row.property_id), decoded(row.source_data)
        -- Never restore fixtures after a sale, archive, native classification,
        -- deletion or replacement. Current owners/keys always win over backups.
        if property and property.propertyType == 'legacy' and property.state == 'owned'
            and property.legacy and property.legacy.source == 'qb-houses' and archive and archive.player_houses
            and property.owner == archive.player_houses.citizenid then
            local candidate, mapped = Housing.copy(property), false
            local location = archive.houselocations
            if not candidate.legacy.fixtureVersion and not candidate.interior and location then
                local name = Config.legacyHousing.shellTiers[tonumber(location.tier)]
                local shell, coords = name and Config.shells[name], decoded(location.coords)
                local entrance = coords and point(coords.enter)
                if shell and entrance then
                    candidate.interior = { type = 'shell', name = name, model = shell.model, entrance = entrance, exit = Housing.copy(shell.exit) }
                    candidate.legacy.stockShellOrigin = { x=entrance.x, y=entrance.y, z=entrance.z-Config.legacyHousing.minZOffset }
                    mapped = true
                end
            end
            if candidate.interior and candidate.interior.name == 'CreateGarageMed' and candidate.interior.model == 'shell_garagemed' then
                candidate.interior.model, mapped = 'shell_garagem', true
            end
            local changed, extra, converted = Legacy.prepareFixtures(candidate, archive)
            if not changed then return false, extra end
            if mapped or converted then
                local saved, saveError = State.persist(changed, { action = 'legacy.fixtureImport' }, extra)
                if not saved then return false, saveError end
            end
        end
    end
    return true
end

function Legacy.fixtureData(property)
    local fixtures = {}
    local stash = property.legacy and property.legacy.stash
    if stash then fixtures.stash = Housing.copy(stash.coords) end
    if property.clothing and #property.clothing == 1 then fixtures.outfit = Housing.copy(property.clothing[1].coords) end
    if property.logout then fixtures.logout = Housing.copy(property.logout) end
    return fixtures
end

local function available(src, id)
    local property = State.get(id)
    if not State.ready or not Housing.world.ready or not property or not Housing.world.occupies(src, id)
        or not Housing.permissions.can(src, id, 'entry') then return nil, 'Enter a property you can access first.' end
    if State.isUncertain(id) or State.writes[id] or Housing.transactions.busy(id) then return nil, 'Property is being updated.' end
    return property
end

function Legacy.useFixture(src, id, kind)
    if kind ~= 'stash' and kind ~= 'outfit' and kind ~= 'logout' then return false, 'Unknown property fixture.' end
    local property, err = available(src, id)
    if not property then return false, err end
    local position = Legacy.fixtureData(property)[kind]
    if not Housing.validCoords(position) then return false, 'Property fixture is unavailable.' end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false, 'Player is unavailable.' end
    local here = GetEntityCoords(ped)
    if not here or (here.x-position.x)^2 + (here.y-position.y)^2 + (here.z-position.z)^2 > 4 then return false, 'Use the fixture inside the property.' end
    if kind == 'stash' then return Housing.storage.openStash(src, id, property.legacy.stash.id) end
    if kind == 'outfit' then
        if GetResourceState('kora_clothing') ~= 'started' then return false, 'Wardrobe is unavailable.' end
        return true, 'outfit'
    end
    if GetResourceState('kora_multichar') ~= 'started' then return false, 'Character selection is unavailable.' end
    if Player(src).state['qbmultichar:mode'] then return false, 'Finish the current character selection session first.' end
    local entrance = property.interior and property.interior.entrance
    if not Housing.validCoords(entrance) then return false, 'Property entrance is unavailable.' end
    local occupancy = Housing.world.occupancy(src, id)
    if not occupancy then return false, 'Property visit changed; try again.' end
    local called, loggedOut, failure = pcall(function()
        return exports.kora_core:logout(src, { position = { x=entrance.x, y=entrance.y, z=entrance.z, h=entrance.w or 0 } })
    end)
    if not called or loggedOut ~= true then return false, failure or 'Your character could not be saved; logout was cancelled.' end
    Housing.world.leave(src, occupancy)
    return true
end
