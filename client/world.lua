Housing.scene = {}
local Scene = Housing.scene
local scenes, zones = {}, {}
local visit, viewing
local lifecycle = 0
local cameraBindings = {}

local function notify(message, kind) QB.notify.send({ title = 'Housing', message = message, type = kind or 'info' }) end
local function request(name, ...)
    local ok, result = QB.callback.trigger('qbhousing:' .. name, ...)
    if ok ~= true then return nil, result or 'Housing is unavailable.' end
    return result
end

local function deleteShell(objects)
    if #objects == 0 then return end
    local ok, removed = pcall(function() return exports.qbinterior:removeGeometry(objects) end)
    if ok and removed then return end
    for _, object in ipairs(objects) do if DoesEntityExist(object) then DeleteEntity(object) end end
end

local function deleteObject(entity)
    pcall(QB.entities.remove, entity)
    if DoesEntityExist(entity) then DeleteEntity(entity) end
end

local function destroy(record)
    record.generation = record.generation + 1
    for _, entity in pairs(record.entities) do deleteObject(entity) end
    deleteShell(record.shell)
    record.entities, record.revisions, record.shell, record.shellRevision = {}, {}, {}, nil
end

local function release(id, reason)
    local record = scenes[id]
    if not record then return end
    record.refs[reason] = nil
    if next(record.refs) then return end
    destroy(record)
    scenes[id] = nil
end

local function rebuild(record)
    record.generation = record.generation + 1
    local generation, scene = record.generation, record.scene
    CreateThread(function()
        local function current() return scenes[scene.propertyId] == record and record.generation == generation end
        local shellKey = scene.space.revision .. ':' .. tostring(scene.interior and scene.interior.model) .. ':' .. tostring(scene.interior and scene.interior.placement)
        if (not scene.interior or scene.interior.type ~= 'shell') and #record.shell > 0 then
            deleteShell(record.shell); record.shell, record.shellRevision = {}, nil
        end
        if scene.interior and scene.interior.type == 'shell' and record.shellRevision ~= shellKey then
            deleteShell(record.shell); record.shell = {}
            local result, err = exports.qbinterior:createGeometry(scene.space.origin, scene.interior.exit, scene.interior.model, scene.interior.placement)
            if not result then if current() then notify(err or 'The shell could not be streamed.', 'error') end; return end
            if not current() then deleteShell(result[1]); return end
            record.shell, record.shellRevision = result[1], shellKey
        end
        local wanted = {}
        for _, collection in ipairs({ scene.furniture or {}, scene.cameras or {} }) do
            for _, item in ipairs(collection) do wanted[item.id] = item end
        end
        for id, entity in pairs(record.entities) do
            if not wanted[id] or record.revisions[id] ~= wanted[id].revision then
                QB.entities.remove(entity); record.entities[id], record.revisions[id] = nil, nil
            end
        end
        for id, item in pairs(wanted) do
            if not current() then return end
            if not record.entities[id] then
                local entity, err = QB.entities.create(item.model, item.coords, { preset = 'static' })
                if entity then
                    if not current() then QB.entities.remove(entity); return end
                    SetEntityRotation(entity, item.rotation.pitch, item.rotation.roll, item.rotation.yaw, 2, true)
                    record.entities[id], record.revisions[id] = entity, item.revision
                else notify(err or 'A property object could not be streamed.', 'error') end
            end
        end
    end)
end

function Scene.retain(scene, reason)
    if type(scene) ~= 'table' or not scene.space then return nil end
    local record = scenes[scene.propertyId]
    if not record then
        record = { refs = {}, entities = {}, revisions = {}, shell = {}, generation = 0 }
        scenes[scene.propertyId] = record
    end
    record.scene, record.refs[reason] = scene, true
    rebuild(record)
    return record
end

function Scene.syncSpaces(definitions)
    local wanted = {}
    for _, definition in ipairs(definitions or {}) do wanted[definition.propertyId] = definition end
    for id, registration in pairs(zones) do
        if not wanted[id] or registration.revision ~= wanted[id].revision then registration.zone.remove(); zones[id] = nil; release(id, 'nearby') end
    end
    for id, definition in pairs(wanted) do
        if not zones[id] then
            local started = lifecycle
            local registration = { revision = definition.revision, inside = false }
            zones[id] = registration
            local zone = QB.zones.sphere({ coords = definition.center, radius = definition.radius,
                onEnter = function()
                    registration.inside = true
                    CreateThread(function()
                        local scene = request('subscribeSpace', id, true)
                        if scene and lifecycle == started and zones[id] == registration and registration.inside then Scene.retain(scene, 'nearby') end
                    end)
                end,
                onExit = function()
                    registration.inside = false
                    release(id, 'nearby')
                    TriggerServerEvent('qbhousing:server:unsubscribeSpace', id)
                end,
            })
            registration.zone = zone
        end
    end
end

function Scene.leave(tellServer)
    Housing.fixtures.clear()
    local previous = visit
    visit = nil
    Scene.stopCamera(tellServer)
    if not previous then return end
    pcall(QB.interact.removeZone, 'qbhousing:world-exit')
    local entrance = previous.entrance
    if entrance then SetEntityCoords(PlayerPedId(), entrance.x, entrance.y, entrance.z, false, false, false, false); SetEntityHeading(PlayerPedId(), entrance.w or 0) end
    release(previous.propertyId, 'inside')
    if tellServer ~= false then TriggerServerEvent('qbhousing:server:leaveProperty') end
end

function Scene.enter(scene, entrance)
    if visit then Scene.leave() end
    local started = lifecycle
    local record = Scene.retain(scene, 'inside')
    if not record then return end
    visit = { propertyId = scene.propertyId, entrance = entrance }
    CreateThread(function()
        if scene.interior and scene.interior.type == 'shell' then
            local ready, err = QB.loops.controlled(function() return lifecycle ~= started or #record.shell > 0 end, 25, 10000)
            if lifecycle ~= started or not visit or visit.propertyId ~= scene.propertyId then return end
            if not ready then notify(err or 'The interior could not be loaded.', 'error'); Scene.leave(); return end
            local origin, exit = scene.space.origin, scene.interior.exit
            SetEntityCoords(PlayerPedId(), origin.x + exit.x, origin.y + exit.y, origin.z + exit.z, false, false, false, false)
            SetEntityHeading(PlayerPedId(), exit.w or 0)
        elseif scene.interior and scene.interior.exit then
            local exit = scene.interior.exit
            SetEntityCoords(PlayerPedId(), exit.x, exit.y, exit.z, false, false, false, false)
            SetEntityHeading(PlayerPedId(), exit.w or 0)
        end
        Housing.fixtures.enter(scene.propertyId, scene.fixtures)
        local exit = scene.interior and scene.interior.exit
        local coords = entrance
        if scene.interior and scene.interior.type == 'shell' then
            local origin = scene.space.origin
            coords = { x = origin.x + exit.x, y = origin.y + exit.y, z = origin.z + exit.z }
        elseif exit then coords = exit end
        QB.interact.addBoxZone('qbhousing:world-exit', coords, { x = 2, y = 2, z = 2.5 }, { options = {
            { label = 'Leave property', action = function() CreateThread(function() Scene.leave() end) end },
        } })
    end)
end

function Scene.stopCamera(tellServer)
    local previous = viewing
    viewing = nil
    if not previous then return end
    if previous.instructions then pcall(previous.instructions.hide) end
    if previous.controls then pcall(QB.controls.release, previous.controls) end
    RenderScriptCams(false, false, 0, true, true)
    if DoesCamExist(previous.cam) then DestroyCam(previous.cam, false) end
    if DoesEntityExist(previous.ped) then FreezeEntityPosition(previous.ped, previous.wasFrozen) end
    release(previous.propertyId, 'camera')
    if tellServer ~= false then TriggerServerEvent('qbhousing:server:closeCamera', previous.token) end
end

function Scene.viewCamera(data)
    Scene.stopCamera()
    if QB.freecam.isActive() or QB.placement.isActive() then notify('Finish the active editor before viewing a camera.', 'error'); TriggerServerEvent('qbhousing:server:closeCamera', data.token); return end
    Scene.retain(data.scene, 'camera')
    local camera = data.camera
    local ped = PlayerPedId()
    local state = { token = data.token, propertyId = camera.propertyId, cameraId = camera.id, cameras = data.scene.cameras, ped = ped,
        wasFrozen = type(IsEntityPositionFrozen) == 'function' and IsEntityPositionFrozen(ped) or false }
    state.cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', camera.coords.x, camera.coords.y, camera.coords.z,
        camera.rotation.pitch, camera.rotation.roll, camera.rotation.yaw, camera.fov, false, 2)
    if not state.cam or not DoesCamExist(state.cam) then release(camera.propertyId, 'camera'); TriggerServerEvent('qbhousing:server:closeCamera', data.token); return notify('The camera view could not be created.', 'error') end
    viewing = state
    state.controls = QB.controls.acquire({ 1, 2, 30, 31, 24, 25, 37, 75, 200, 202 }, { disablePlayerFiring = true })
    FreezeEntityPosition(ped, true)
    SetCamActive(state.cam, true)
    RenderScriptCams(true, false, 0, true, true)
    state.instructions = QB.instructional.show({
        { keybind = cameraBindings.exit, label = 'Close camera' }, { keybind = cameraBindings.next, label = 'Next camera' }, { keybind = cameraBindings.previous, label = 'Previous camera' },
    })
end

local function switchCamera(direction)
    local state = viewing
    if not state then return end
    local index = 1
    for i, camera in ipairs(state.cameras) do if camera.id == state.cameraId then index = i; break end end
    local nextCamera = state.cameras[(index - 1 + direction) % #state.cameras + 1]
    CreateThread(function()
        local result, err = request('switchCamera', state.token, nextCamera.id)
        if viewing ~= state then
            if result then TriggerServerEvent('qbhousing:server:closeCamera', result.token) end
            return
        end
        if result then Scene.viewCamera(result) else Scene.stopCamera(); notify(err, 'error') end
    end)
end

cameraBindings.exit = QB.keybind.add({ name = 'qbhousing_camera_exit', description = 'Housing: Close Security Camera', defaultMapper = 'keyboard', defaultKey = 'BACK', onPressed = function() Scene.stopCamera() end })
cameraBindings.next = QB.keybind.add({ name = 'qbhousing_camera_next', description = 'Housing: Next Security Camera', defaultMapper = 'keyboard', defaultKey = 'RIGHT', onPressed = function() switchCamera(1) end })
cameraBindings.previous = QB.keybind.add({ name = 'qbhousing_camera_previous', description = 'Housing: Previous Security Camera', defaultMapper = 'keyboard', defaultKey = 'LEFT', onPressed = function() switchCamera(-1) end })

RegisterNetEvent('qbhousing:client:spacesChanged', Scene.syncSpaces)
RegisterNetEvent('qbhousing:client:sceneChanged', function(scene)
    local record = scene and scenes[scene.propertyId]
    if record then record.scene = scene; rebuild(record) end
    if scene and visit and visit.propertyId == scene.propertyId then Housing.fixtures.enter(scene.propertyId, scene.fixtures) end
end)
RegisterNetEvent('qbhousing:client:enteredProperty', Scene.enter)
RegisterNetEvent('qbhousing:client:leaveProperty', function() Scene.leave(false) end)
RegisterNetEvent('qbhousing:client:cameraClosed', function(reason) Scene.stopCamera(false); if reason then notify(reason) end end)
RegisterNetEvent('qbhousing:client:cameraNotice', function(label) notify('Security cameras are being viewed in ' .. label .. '.') end)
RegisterNetEvent('qbhousing:client:cameraPresence', function(label) notify('Security cameras are installed in ' .. label .. '.') end)

function Scene.clear()
    lifecycle = lifecycle + 1
    Scene.leave()
    Scene.stopCamera()
    for _, registration in pairs(zones) do pcall(registration.zone.remove) end
    for _, record in pairs(scenes) do destroy(record) end
    zones, scenes = {}, {}
end

AddEventHandler('QBCore:Client:OnPlayerUnload', Scene.clear)
AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() or resource == 'qbinterior' or resource == 'qblib' then Scene.clear() end
end)
