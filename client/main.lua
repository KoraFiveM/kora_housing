local Properties = {}
local shellObjects, currentProperty = {}, nil
local leavePrompt
local interactionZones = {}

local function removeObjects(objects)
    if #objects == 0 then return end
    local called, removed = pcall(function() return exports.qbinterior:removeGeometry(objects) end)
    if called and removed then return end
    for _, object in ipairs(objects) do
        if DoesEntityExist(object) then DeleteEntity(object) end
    end
end

local function removeShell()
    local hadProperty = currentProperty ~= nil
    removeObjects(shellObjects)
    shellObjects, currentProperty = {}, nil
    if Housing.fixtures then Housing.fixtures.clear() end
    if leavePrompt then QB.textui.hide(leavePrompt); leavePrompt = nil end
    if hadProperty then TriggerServerEvent('qbhousing:server:leaveProperty') end
end

local function notify(message, kind) QB.notify.send({ title = 'Housing', message = message, type = kind or 'info' }) end
local function money(value) return ('$%s'):format(('%.0f'):format(tonumber(value) or 0)) end

local function clearZones()
    for id in pairs(interactionZones) do QB.interact.removeZone(id) end
    interactionZones = {}
end

local function rebuildZones()
    clearZones()
    for id, property in pairs(Properties) do
        if property.interior and property.interior.entrance and property.state ~= 'unowned' and property.state ~= 'archived' and property.state ~= 'archiving' then
            local name = 'qbhousing:' .. id
            local zone = QB.interact.addBoxZone(name,
                vector3(property.interior.entrance.x, property.interior.entrance.y, property.interior.entrance.z),
                { x = 2.0, y = 2.0, z = 2.5, w = property.interior.entrance.w or 0.0 }, {
                    options = {{ label = property.owner and 'Enter property' or 'View property', icon = 'house',
                        action = function() TriggerServerEvent('qbhousing:server:enter', id) end }},
                })
            if zone then interactionZones[name] = true end
        end
    end
end

local function hydrate()
    local payload, err = QB.callback.trigger('qbhousing:hydrate')
    if not payload then return notify(err or 'Housing is unavailable.', 'error') end
    Properties = payload.properties or {}
    rebuildZones()
    if Housing.scene then
        local ok, spaces = QB.callback.trigger('qbhousing:worldSpaces')
        if ok then Housing.scene.syncSpaces(spaces) end
    end
end

RegisterCommand(Config.command, function() Housing.app.open('market') end, false)
RegisterCommand(Config.homeCommand, function() Housing.app.open('properties') end, false)

RegisterNetEvent('qbhousing:client:synced', function(properties)
    Properties = properties or {}
    rebuildZones()
    Housing.app.sync()
end)
RegisterNetEvent('qbhousing:client:purchaseOffer', function(property)
    local decision = QB.nui.openAlert({ title = 'Purchase ' .. property.id, message = money(property.listing.price) .. ' · This is final.' })
    if not decision or not decision.confirmed then return end
    local saved, err = QB.callback.trigger('qbhousing:confirmPurchase', property.id)
    notify(saved and 'Property purchased.' or err or 'Purchase failed.', saved and 'success' or 'error')
end)

RegisterNetEvent('qbhousing:client:enterShell', function(property)
    if currentProperty then return notify('You are already inside a property.', 'error') end
    currentProperty = property
    local origin = property.interior.origin or property.interior.entrance
    local spawn = vector3(origin.x, origin.y, origin.z)
    local interior = exports['qbinterior']:createGeometry(vector3(spawn.x, spawn.y, spawn.z), property.interior.exit, property.interior.model, 'legacy')
    local objects = type(interior) == 'table' and type(interior[1]) == 'table' and interior[1] or {}
    -- Model streaming can finish after this character has already unloaded.
    if currentProperty ~= property then removeObjects(objects); return end
    if not objects[1] or not DoesEntityExist(objects[1]) then
        removeObjects(objects)
        removeShell()
        return notify('The property interior could not be loaded.', 'error')
    end
    shellObjects = objects
    Housing.fixtures.enter(property.id, property.fixtures, property.furniture)
    SetEntityCoords(PlayerPedId(), spawn.x + (property.interior.exit.x or 0.0), spawn.y + (property.interior.exit.y or 0.0), spawn.z + (property.interior.exit.z or 0.0), false, false, false, false)
    SetEntityHeading(PlayerPedId(), property.interior.exit.w or property.interior.exit.h or 0)
end)

RegisterNetEvent('qbhousing:client:leaveProperty', function()
    if not currentProperty then return end
    local entrance = currentProperty.interior.entrance
    removeShell()
    if entrance then SetEntityCoords(PlayerPedId(), entrance.x, entrance.y, entrance.z, false, false, false, false) end
end)

CreateThread(function()
    while true do
        if not currentProperty then Wait(1000) goto continue end
        Wait(0)
        local exit = currentProperty.interior.exit
        local origin = currentProperty.interior.origin or currentProperty.interior.entrance
        local coords = GetEntityCoords(PlayerPedId())
        local distance = #(coords - vector3(origin.x + (exit.x or 0.0), origin.y + (exit.y or 0.0), origin.z + (exit.z or 0.0)))
        if distance < 1.5 then
            leavePrompt = leavePrompt or QB.textui.show('Leave property', { key = 'E' })
            if IsControlJustReleased(0, 38) then
                local entrance = currentProperty.interior.entrance
                removeShell()
                if entrance then SetEntityCoords(PlayerPedId(), entrance.x, entrance.y, entrance.z, false, false, false, false) end
            end
        elseif leavePrompt then QB.textui.hide(leavePrompt); leavePrompt = nil end
        ::continue::
    end
end)

CreateThread(function() Wait(1000); hydrate() end)
AddEventHandler('QBCore:Client:OnPlayerLoaded', hydrate)

AddEventHandler('QBCore:Client:OnPlayerUnload', function()
    Properties = {}
    clearZones()
    removeShell()
    Housing.app.close()
end)

local function stop(resource)
    if resource ~= GetCurrentResourceName() then return end
    clearZones()
    removeShell()
    Housing.app.close()
end

AddEventHandler('onResourceStop', stop)
AddEventHandler('onClientResourceStop', stop)
