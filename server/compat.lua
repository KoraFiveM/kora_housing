local function hasKey(identifier, citizenid, house)
    if type(identifier) ~= 'string' or type(citizenid) ~= 'string' or citizenid == ''
        or type(house) ~= 'string' or not Housing.state.ready then return false end
    local property = Housing.state.get(house)
    if not property then return false end
    -- Upstream checks both license and character for owners. Existing granted
    -- keys are character-specific; native leases/revocations remain authoritative.
    if property.owner == citizenid then
        local player = exports.qbcore:getPlayerByCitizenId(citizenid)
            or exports.qbcore:getOfflinePlayerData(citizenid)
        if not player or player.license ~= identifier then return false end
    end
    return Housing.permissions.canCitizen(citizenid, house, 'entry') == true
end

exports('hasKey', hasKey)
QB.compat.provideExport('qb-houses', 'hasKey', hasKey)
