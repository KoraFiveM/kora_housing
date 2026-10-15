Housing = Housing or {}

local function number(value, fallback)
    value = tonumber(value)
    return value or fallback
end

function Housing.copy(value)
    return json.decode(json.encode(value))
end

function Housing.normalise(value)
    if type(value) ~= 'table' or type(value.id) ~= 'string' or value.id == '' then return nil, 'Property id is required.' end
    if value.interior and (type(value.interior) ~= 'table' or (value.interior.type ~= 'shell' and value.interior.type ~= 'mlo')) then return nil, 'Invalid interior type.' end
    if value.garage ~= nil and type(value.garage) ~= 'table' then return nil, 'Invalid garage settings.' end
    value.state = value.state or 'unowned'
    value.keys = type(value.keys) == 'table' and value.keys or {}
    value.furniture = type(value.furniture) == 'table' and value.furniture or {}
    value.stashes = type(value.stashes) == 'table' and value.stashes or {}
    value.clothing = type(value.clothing) == 'table' and value.clothing or {}
    value.doorlocks = type(value.doorlocks) == 'table' and value.doorlocks or {}
    value.coowners = type(value.coowners) == 'table' and value.coowners or {}
    value.permissionGrants = type(value.permissionGrants) == 'table' and value.permissionGrants or {}
    value.propertyType = value.propertyType or 'legacy'
    value.label = value.label or value.id
    value.revision = tonumber(value.revision) or 0
    value.ownershipRevision = tonumber(value.ownershipRevision) or 0
    if value.garage then value.garage.slots = math.max(1, math.min(Config.maxGarageSlots, number(value.garage.slots, Config.defaultGarageSlots))) end
    return value
end

function Housing.finite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

function Housing.validCoords(value)
    if type(value) ~= 'table' then return false end
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        if not Housing.finite(value[axis]) or math.abs(value[axis]) > Config.coordinateLimit then return false end
    end
    return value.w == nil or Housing.finite(value.w)
end

local function validExterior(exterior)
    if type(exterior) ~= 'table' or type(exterior.polyzone) ~= 'table' then return false end
    local points = exterior.polyzone
    if #points < 3 or #points > 128 then return false end
    if not Housing.finite(exterior.minZ) or not Housing.finite(exterior.maxZ) or exterior.minZ >= exterior.maxZ then return false end
    local count, area = 0, 0
    for index, point in pairs(points) do
        if type(index) ~= 'number' or index % 1 ~= 0 or index < 1 or index > #points or not Housing.validCoords(point) then return false end
        count = count + 1
        local nextPoint = points[index % #points + 1]
        if not Housing.validCoords(nextPoint) then return false end
        area = area + point.x * nextPoint.y - nextPoint.x * point.y
    end
    return count == #points and math.abs(area) > 0.01
end

-- Strict validation is for the creator; legacy records remain available for classification.
function Housing.validateProperty(value)
    if type(value) ~= 'table' or type(value.id) ~= 'string' or #value.id < 1 or #value.id > 64 or value.id:find('[^%w_-]') then
        return nil, 'Use a property id containing only letters, numbers, underscores or hyphens.'
    end
    if type(value.label) ~= 'string' or #value.label < 1 or #value.label > 100 then return nil, 'Property name must contain 1 to 100 characters.' end
    local kind = Config.propertyTypes[value.propertyType]
    if not kind then return nil, 'Choose a supported property type.' end
    if value.parentId ~= nil and (type(value.parentId) ~= 'string' or #value.parentId < 1 or #value.parentId > 64 or value.parentId == value.id) then
        return nil, 'Choose a different parent building.'
    end
    if value.unitLabel ~= nil and (type(value.unitLabel) ~= 'string' or #value.unitLabel > 50) then return nil, 'Unit label must be at most 50 characters.' end
    if kind.interior == 'none' and value.interior ~= nil then return nil, 'Land does not use an interior.' end
    if kind.interior == 'required' and not value.interior then return nil, 'This property type requires an interior.' end
    if value.interior then
        local interior = value.interior
        if type(interior) ~= 'table' or (interior.type ~= 'shell' and interior.type ~= 'mlo') then return nil, 'Choose shell or MLO.' end
        if not Housing.validCoords(interior.entrance) then return nil, 'Enter valid entrance coordinates.' end
        if interior.type == 'shell' then
            local shell = Config.shells[interior.name]
            if not shell then return nil, 'That shell is not available.' end
            interior.model, interior.exit = shell.model, Housing.copy(shell.exit)
        elseif not validExterior(value.exterior) then
            return nil, 'An MLO requires a valid exterior polygon and height bounds.'
        end
    elseif not validExterior(value.exterior) then
        return nil, 'This property requires an exterior polygon and height bounds.'
    end
    if value.exterior and not validExterior(value.exterior) then return nil, 'Enter a valid exterior polygon and height bounds.' end
    if value.garage then
        local garage = value.garage
        if type(garage) ~= 'table' or not Housing.validCoords(garage.coords) or not Housing.validCoords(garage.spawn) then return nil, 'Enter valid garage and vehicle spawn coordinates.' end
        if not Housing.finite(garage.slots) or garage.slots % 1 ~= 0 or garage.slots < 1 or garage.slots > Config.maxGarageSlots then
            return nil, ('Garage slots must be between 1 and %d.'):format(Config.maxGarageSlots)
        end
    end
    if value.listing then
        if type(value.listing) ~= 'table' then return nil, 'Invalid listing settings.' end
        local price = value.listing.price
        if price ~= nil and (not Housing.finite(price) or price % 1 ~= 0 or price < 1 or price > 1000000000) then return nil, 'Price must be a positive whole amount of at most 1000000000.' end
    end
    return Housing.normalise(value)
end
