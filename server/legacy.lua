-- Stock qb-houses ownership migration. The old tables remain untouched and
-- every original column is backed up before native ownership becomes active.
-- Known shell/entrance/garage values can be mapped exactly. Physical bounds
-- and archived fixtures still need real native integration before activation.
Housing.legacy = {}

local function decode(value, field)
    if value == nil or value == '' or value == 'null' then return {} end
    local ok, result = pcall(json.decode, value)
    if not ok or type(result) ~= 'table' then return nil, 'Invalid stock housing ' .. field .. ' JSON.' end
    return result
end

local function identity(value, length)
    return type(value) == 'string' and #value > 0 and #value <= length
end

function Housing.legacy.importStock()
    if QB.sql.awaitCheckedOperations then
        local settled, err = QB.sql.awaitCheckedOperations('qbhousing:')
        if not settled then return false, err end
    end
    local tables, err = QB.sql.query([[SELECT TABLE_NAME AS name FROM INFORMATION_SCHEMA.TABLES
        WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('houselocations','player_houses')]])
    if not tables then return false, err end
    local present = {}
    for _, row in ipairs(tables) do present[row.name] = true end
    if not next(present) then return true end
    if not present.houselocations or not present.player_houses then return false, 'Stock housing requires both houselocations and player_houses tables.' end

    local markers, markerError = QB.sql.query('SELECT `property_id` FROM `qbhousing_stock_import`')
    local native, nativeError = QB.sql.query('SELECT `id` FROM `qbhousing_properties`')
    local locations, locationError = QB.sql.query('SELECT * FROM `houselocations`')
    local ownership, ownershipError = QB.sql.query('SELECT * FROM `player_houses`')
    if not markers or not native or not locations or not ownership then return false, markerError or nativeError or locationError or ownershipError end
    local imported, existing, byId, owners = {}, {}, {}, {}
    for _, row in ipairs(markers) do imported[row.property_id] = true end
    for _, row in ipairs(native) do existing[row.id] = true end
    for _, row in ipairs(locations) do
        if not imported[row.name] then
            if not identity(row.name, 64) then return false, 'Stock house name must contain 1 to 64 characters.' end
            if byId[row.name] then return false, 'Duplicate stock house location: ' .. row.name end
            if existing[row.name] then return false, 'Stock house conflicts with an existing native property: ' .. row.name end
            byId[row.name] = row
        end
    end
    for _, row in ipairs(ownership) do
        if not imported[row.house] then
            if not byId[row.house] then return false, 'Stock owner has no matching house location: ' .. tostring(row.house) end
            if owners[row.house] then return false, 'Duplicate stock house ownership: ' .. row.house end
            owners[row.house] = row
        end
    end

    -- Validate the complete pending import before writing any property. The
    -- transaction also rejects case/collation collisions without overwriting.
    local statements = {}
    for id, location in pairs(byId) do
        local owner = owners[id]
        local owned = tonumber(location.owned)
        if owned ~= 0 and owned ~= 1 or (owned == 1) ~= (owner ~= nil) then
            return false, 'Stock house ownership flag is inconsistent: ' .. id
        end
        local keys = {}
        if owner then
            if not identity(owner.citizenid, 50) or not identity(owner.identifier, 50) then return false, 'Invalid stock owner identity: ' .. id end
            local character, characterError = QB.sql.single('SELECT `citizenid`,`license` FROM `players` WHERE `citizenid`=? AND `deleted_at` IS NULL', { owner.citizenid })
            if not character or character.citizenid ~= owner.citizenid or character.license ~= owner.identifier then
                return false, characterError or 'Stock owner license/character mismatch: ' .. id
            end
            local holders, holderError = decode(owner.keyholders, 'keyholders')
            if not holders then return false, holderError end
            local holderCount = 0
            for index, cid in pairs(holders) do
                if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > #holders or not identity(cid, 50) then
                    return false, 'Invalid stock keyholder array: ' .. id
                end
                keys[cid] = true
                holderCount = holderCount + 1
            end
            if holderCount ~= #holders then return false, 'Sparse stock keyholder array: ' .. id end
        end
        for _, field in ipairs({ 'coords', 'garage' }) do
            local decoded, decodeError = decode(location[field], field)
            if not decoded then return false, decodeError end
        end
        if owner then
            for _, field in ipairs({ 'decorations', 'stash', 'outfit', 'logout' }) do
                local decoded, decodeError = decode(owner[field], field)
                if not decoded then return false, decodeError end
            end
        end
        local rawCoords = decode(location.coords, 'coords')
        local shellName = Config.legacyHousing.shellTiers[tonumber(location.tier)]
        local shell = shellName and Config.shells[shellName]
        local entrance = type(rawCoords.enter) == 'table' and Housing.copy(rawCoords.enter)
        if entrance then entrance.w, entrance.h = entrance.w or entrance.h, nil end
        local interior = shell and Housing.validCoords(entrance) and {
            type = 'shell', name = shellName, model = shell.model,
            entrance = entrance, exit = Housing.copy(shell.exit),
        } or nil
        local rawGarage = decode(location.garage, 'garage')
        local garage
        -- The all-zero stock default means no garage; it is not a real point.
        if Housing.validCoords(rawGarage) and (rawGarage.x ~= 0 or rawGarage.y ~= 0 or rawGarage.z ~= 0) then
            garage = { coords = Housing.copy(rawGarage), spawn = Housing.copy(rawGarage), slots = Config.defaultGarageSlots }
        end
        local unmapped = {}
        if owner then
            for _, field in ipairs({ 'decorations', 'stash', 'outfit', 'logout' }) do
                if next(decode(owner[field], field)) then unmapped[field] = true end
            end
        end
        local grants = {}
        for cid in pairs(keys) do grants[cid] = { entry = true } end
        local definition = {
            id = id, label = location.label or id, owner = owner and owner.citizenid,
            state = owner and 'owned' or 'unowned', propertyType = 'legacy',
            interior = interior, garage = garage,
            keys = keys, permissionGrants = grants,
            legacy = { source = 'qb-houses', locationId = location.id,
                ownershipId = owner and owner.id, tier = location.tier, price = location.price,
                needsWorldMapping = true, unmappedFixtures = unmapped,
                viewCamera = type(rawCoords.cam) == 'table' and Housing.copy(rawCoords.cam) or nil,
                stockShellOrigin = interior and { x = entrance.x, y = entrance.y, z = entrance.z - Config.legacyHousing.minZOffset } or nil },
        }
        local fixtures, fixtureWrites = Housing.legacy.prepareFixtures(definition, { houselocations = location, player_houses = owner })
        if not fixtures then return false, fixtureWrites end
        local property, writes = Housing.state.prepare(fixtures, { action = 'legacy.stockImport' })
        if not property then return false, writes end
        for _, write in ipairs(writes) do statements[#statements + 1] = write end
        for _, write in ipairs(fixtureWrites) do statements[#statements + 1] = write end
        local source = json.encode({ houselocations = location, player_houses = owner })
        statements[#statements + 1] = { query = [[INSERT INTO `qbhousing_stock_import`
            (`property_id`,`source_data`,`source_sha256`) VALUES (?,?,SHA2(?,256))]],
            values = { id, source, source }, expectedRows = 1 }
    end
    if #statements == 0 then return true end
    local result, writeError = QB.sql.transactionChecked(statements,
        { key = 'qbhousing:stock-import', fingerprint = json.encode(statements) })
    if not result or not result.success then return false, writeError or (result and result.message) or 'Stock housing import could not be confirmed.' end
    return true
end
