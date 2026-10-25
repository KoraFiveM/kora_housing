-- Fixture positions are server-published native records. The server repeats
-- access, active occupancy and distance checks before every interaction.
Housing.fixtures = {}
local Fixtures = Housing.fixtures
local active, zones, furniture, generation = nil, {}, {}, 0
local labels = { stash = 'Open storage', outfit = 'Open wardrobe', logout = 'Change character' }
local function notify(message) QB.notify.send({ title = 'Housing', message = message, type = 'error' }) end

function Fixtures.clear()
    generation = generation + 1
    active = nil
    for _, zone in ipairs(zones) do QB.interact.removeZone(zone) end
    for _, entity in ipairs(furniture) do QB.entities.remove(entity) end
    zones, furniture = {}, {}
end

function Fixtures.enter(id, definitions, decorations)
    Fixtures.clear()
    active = id
    local current = generation
    for kind, coords in pairs(definitions or {}) do
        if labels[kind] then
            local name = 'qbhousing:fixture:' .. kind
            local zone = QB.interact.addBoxZone(name, coords, { x=1.5, y=1.5, z=2.0 }, { options = {
                { label=labels[kind], action=function()
                    CreateThread(function()
                        if active ~= id or generation ~= current then return end
                        local ok, result = QB.callback.trigger('qbhousing:useFixture', id, kind)
                        if not ok then notify(result or 'The fixture is unavailable.'); return end
                        if active ~= id or generation ~= current then return end
                        if result == 'outfit' then
                            local called, opened, err = pcall(function() return exports.qbclothing:OpenWardrobe() end)
                            if not called or opened == false then notify(err or 'The wardrobe is unavailable.') end
                        end
                    end)
                end },
            } })
            if zone then zones[#zones + 1] = name end
        end
    end
    -- Shared physical spaces already render furniture through Housing.scene.
    -- Legacy shells without bounds use these same native furniture rows.
    if decorations then CreateThread(function()
        for _, item in ipairs(decorations) do
            if active ~= id or generation ~= current then return end
            local entity, err = QB.entities.create(item.model, item.coords, { preset='static' })
            if entity then
                if active ~= id or generation ~= current then QB.entities.remove(entity); return end
                SetEntityRotation(entity, item.rotation.pitch, item.rotation.roll, item.rotation.yaw, 2, true)
                furniture[#furniture + 1] = entity
            else notify(err or 'A property object could not be streamed.') end
        end
    end) end
end

AddEventHandler('QBCore:Client:OnPlayerUnload', Fixtures.clear)
AddEventHandler('onClientResourceStop', function(resource) if resource == GetCurrentResourceName() then Fixtures.clear() end end)
