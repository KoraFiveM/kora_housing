-- Shared-scene rendering against controlled streaming and world callbacks.
Housing = {fixtures={clear=function() end,enter=function() end}}
local checks, entities, geometries, rotations, events, bindings, zones = 0, {}, {}, {}, {}, {}, {}
local geometryCalls = {}
local nextEntity, sceneReply, pauseSubscribe, pauseSwitch, switchReply = 10, nil, false, false, nil
local cams, frozen, controlLeases = {}, false, {}
local placementCancelled, placementSaves, refreshed, notices = false, 0, 0, {}
local pending, sceneEvents = {}, {}
local function check(value, message) assert(value, message); checks = checks + 1 end
function CreateThread(handler)
    local thread = coroutine.create(handler)
    local ok, value = coroutine.resume(thread)
    assert(ok, value)
    if coroutine.status(thread) ~= 'dead' then pending[#pending + 1] = thread end
end
local function finish()
    for _, thread in ipairs(pending) do if coroutine.status(thread) ~= 'dead' then local ok, err = coroutine.resume(thread); assert(ok, err) end end
    pending = {}
end
function RegisterNetEvent(name, handler) events[name] = handler end
function AddEventHandler(name, handler) events[name] = handler end
function TriggerServerEvent(name, ...) sceneEvents[#sceneEvents + 1] = { name, ... } end
function GetCurrentResourceName() return 'kora_housing' end
function DoesEntityExist(entity) return entity == 1 or entities[entity] or geometries[entity] end
function DeleteEntity(entity) entities[entity], geometries[entity] = nil, nil end
function SetEntityRotation(entity, pitch, roll, yaw) rotations[entity] = { pitch, roll, yaw } end
function PlayerPedId() return 1 end
function SetEntityCoords() end
function SetEntityHeading() end
function FreezeEntityPosition(_, value) frozen = value end
function IsEntityPositionFrozen() return frozen end
function CreateCamWithParams() nextEntity = nextEntity + 1; cams[nextEntity] = true; return nextEntity end
function DoesCamExist(cam) return cams[cam] == true end
function DestroyCam(cam) cams[cam] = nil end
function SetCamActive() end
function RenderScriptCams() end
QB = {
    notify = { send = function(payload) notices[#notices + 1] = payload end },
    callback = { trigger = function(name)
        if name == 'qbhousing:subscribeSpace' then if pauseSubscribe then coroutine.yield() end; return true, sceneReply end
        if name == 'qbhousing:switchCamera' then if pauseSwitch then coroutine.yield() end; return true, switchReply end
        if name == 'qbhousing:beginPlacement' then return true, { token = 'placement-token', model = 'prop_chair_01a', transform = { coords = { x = 1, y = 2, z = 3 } }, bounds = {}, revision = 0 } end
        if name == 'qbhousing:savePlacement' then placementSaves = placementSaves + 1; return true, {} end
        error('Unexpected callback ' .. name)
    end },
    entities = {
        create = function() nextEntity = nextEntity + 1; entities[nextEntity] = true; return nextEntity end,
        remove = function(entity) entities[entity] = nil end,
    },
    zones = { sphere = function(options) zones[#zones + 1] = options; return { remove = function() options.removed = true end } end },
    keybind = { add = function(definition) bindings[definition.name] = definition; return definition end },
    freecam = { isActive = function() return false end }, placement = { isActive = function() return false end },
    controls = { acquire = function() local lease = {}; controlLeases[lease] = true; return lease end, release = function(lease) controlLeases[lease] = nil end },
    instructional = { show = function() return { hide = function() end } end },
    interact = { removeZone = function() end, addBoxZone = function() end },
}
exports = { kora_interior = {
    createGeometry = function(_, origin, exit, model, placement) geometryCalls[#geometryCalls+1]={origin=origin,placement=placement}; nextEntity = nextEntity + 1; geometries[nextEntity] = true; return { { nextEntity }, {} } end,
    removeGeometry = function(_, objects) for _, entity in ipairs(objects) do geometries[entity] = nil end; return true end,
} }
dofile('client/world.lua')
sceneReply = { propertyId = 'home', label = 'Home', space = { revision = 1, origin = { x = 0, y = 0, z = 0 } },
    interior = { type = 'shell', model = 'shell_v16low', exit = { x = 1, y = 2, z = 3 } },
    furniture = { { id = 'chair', model = 'prop_chair_01a', coords = { x = 1, y = 2, z = 3 }, rotation = { pitch = 10, roll = 20, yaw = 30 }, revision = 1 } }, cameras = {} }
local definitions = { { propertyId = 'home', center = { x = 0, y = 0, z = 0 }, radius = 100, revision = 1 } }
Housing.scene.syncSpaces(definitions)
zones[1].onEnter()
local count, furnitureEntity = 0, nil
for entity in pairs(entities) do count, furnitureEntity = count + 1, entity end
check(count == 1 and next(geometries), 'nearby players stream the same server scene with one local shell')
check(rotations[furnitureEntity][2] == 20, 'shared furniture renders its full persisted rotation')
sceneReply.interior.placement='legacy'
events['qbhousing:client:sceneChanged'](sceneReply)
check(#geometryCalls==2 and geometryCalls[2].placement=='legacy', 'placement changes rebuild geometry through the original stock native')
check(geometryCalls[2].origin==sceneReply.space.origin, 'configured authoritative origin reaches the geometry provider unchanged')
check(entities[furnitureEntity], 'an unchanged scene does not rebuild existing furniture')
sceneReply.furniture[1].revision, sceneReply.furniture[1].rotation.roll = 2, 25
events['qbhousing:client:sceneChanged'](sceneReply)
check(not entities[furnitureEntity], 'a newer furniture revision replaces its old entity')
sceneReply.interior = { type = 'mlo' }
events['qbhousing:client:sceneChanged'](sceneReply)
check(not next(geometries), 'changing a physical interior from shell to MLO releases the old shell geometry')
zones[1].onExit()
check(not next(entities) and not next(geometries), 'leaving streaming range releases all scene entities')
pauseSubscribe = true
zones[1].onEnter()
zones[1].onExit()
finish()
check(not next(entities) and not next(geometries), 'leaving while subscribing cannot leave a late scene behind')
local camera = { id = 'camera', propertyId = 'home', coords = { x = 1, y = 2, z = 3 }, rotation = { pitch = 0, roll = 0, yaw = 30 }, fov = 60 }
sceneReply.cameras = { camera }
switchReply = { token = 'new-token', camera = camera, scene = sceneReply }
Housing.scene.viewCamera({ token = 'old-token', camera = camera, scene = sceneReply })
check(frozen and next(cams) and next(controlLeases), 'a physical camera view acquires its camera and control lease')
pauseSwitch = true
bindings.qbhousing_camera_next.onPressed()
Housing.scene.stopCamera()
finish()
check(not frozen and not next(cams) and not next(controlLeases), 'closing during a pending feed switch cannot reopen the camera or leave controls frozen')
check(sceneEvents[#sceneEvents][1] == 'qbhousing:server:closeCamera' and sceneEvents[#sceneEvents][2] == 'new-token', 'a late camera switch response releases its replacement server authorization')
frozen, pauseSwitch = true, false
Housing.scene.viewCamera({ token = 'revoked-token', camera = camera, scene = sceneReply })
events['qbhousing:client:cameraClosed']('Access revoked')
check(frozen and not next(cams) and not next(controlLeases), 'revocation restores the prior freeze state and releases camera controls')
frozen = false
pauseSubscribe = false
zones[1].onEnter()
QB.entities.remove = function() error('qblib already stopped') end
exports.kora_interior.removeGeometry = function() error('qbinterior already stopped') end
Housing.scene.clear()
check(not next(entities) and not next(geometries) and zones[1].removed, 'character/resource cleanup removes the scene and its spatial registration')
dofile('config.lua')
Housing.app = { refreshProperty = function() refreshed = refreshed + 1 end }
QB.placement.start = function()
    coroutine.yield()
    if placementCancelled then return nil end
    return { coords = { x = 1, y = 2, z = 3 } }
end
QB.placement.cancel = function() placementCancelled = true; return true end
dofile('client/gameplay.lua')
local view = { property = { id = 'home' }, world = { space = { bounds = {} } } }
Housing.gameplay.action('world:furniture-place', { value = { model = 'prop_chair_01a' } }, view)
events['qbhousing:client:placementClosed']('foreign-token', 'home', 'Unrelated session')
check(not placementCancelled, 'a delayed cancellation for another placement cannot close the current editor')
events['qbhousing:client:placementClosed']('placement-token', 'home', 'Access changed')
finish()
check(placementCancelled and placementSaves == 0 and refreshed == 1, 'authorization revocation cancels the delegated editor and prevents a save')
placementCancelled = false
Housing.gameplay.action('world:furniture-place', { value = { model = 'prop_chair_01a' } }, view)
events['QBCore:Client:OnPlayerUnload']()
finish()
check(placementCancelled and refreshed == 1, 'character unload cancels an editor without reopening the housing app')
QB.placement.start = function() error('The preview model could not be streamed.') end
Housing.gameplay.action('world:furniture-place', { value = { model = 'prop_chair_01a' } }, view)
check(refreshed == 2 and placementSaves == 0 and notices[#notices].message:find('could not be streamed', 1, true), 'a rejected shared placement reports its error and returns to the property app')
print(('qbhousing scene: %d checks passed'):format(checks))
