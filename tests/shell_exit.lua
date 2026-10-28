-- Actual client/config; FiveM coordinates, input and UI are controlled transports.
local clientPath = arg[1] or 'client/main.lua'
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end

-- Match FiveM vector subtraction/length for the distance calculation under test.
local vector = {}
function vector.__sub(a, b)
    return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, vector)
end
function vector.__len(a)
    return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end
function vector3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, vector)
end

dofile('config.lua')
Housing={fixtures={enter=function() end,clear=function() end}}
for _, name in ipairs({ 'CreateApartmentShell', 'CreateCaravanShell', 'CreateLesterShell', 'CreateGarageMed', 'CreateFurniMotelStandard' }) do
    local events, threads, position, prompt, removed = {}, {}, nil, nil, {}
    local pressed, shows, hides, created, heading = false, 0, 0, 0, nil
    QB = {
        textui = {
            show = function(message, options)
                check(message == 'Leave property' and options.key == 'E', 'existing leave UI contract')
                shows, prompt = shows + 1, 'leave-prompt'
                return prompt
            end,
            hide = function(id)
                check(id == prompt, 'hide the active prompt')
                hides, prompt = hides + 1, nil
            end,
        },
        notify = { send = function() error('Unexpected housing notification') end },
    }
    function RegisterCommand() end
    function RegisterNetEvent(name, callback) events[name] = callback end
    function TriggerServerEvent(name) check(name == 'qbhousing:server:leaveProperty', 'legacy exit releases its authoritative occupant session') end
    function AddEventHandler() end
    function CreateThread(callback) threads[#threads + 1] = coroutine.create(callback) end
    function Wait(duration) coroutine.yield(duration) end
    function PlayerPedId() return 41 end
    function GetEntityCoords(ped)
        check(ped == 41, 'read the local player position')
        return position
    end
    function SetEntityCoords(ped, x, y, z)
        check(ped == 41, 'move the local player')
        position = vector3(x, y, z)
    end
    function SetEntityHeading(_, value) heading = value end
    function IsControlJustReleased(group, control)
        check(group == 0 and control == 38, 'preserve the exit control')
        return pressed
    end
    function DoesEntityExist(object) return object == 91 end
    function DeleteEntity(object) removed[#removed + 1] = object end
    exports = {
        kora_interior = {
            createGeometry = function(_, origin, exit, model, placement)
                check(placement == 'legacy', 'fallback shell retains stock native placement without early teleport')
                check(origin.x == 800 and origin.y == -1500 and origin.z == (name == 'CreateFurniMotelStandard' and 70 or 100), 'retain shell origin')
                check(exit == Config.shells[name].exit and model == Config.shells[name].model, 'retain relative provider arguments')
                created = created + 1
                return { { 91 }, { exit = exit } }
            end,
        },
    }
    assert(loadfile(clientPath))()
    local entrance = { x = 800, y = -1500, z = 100 }
    local offset = Config.shells[name].exit
    local before = { x = offset.x, y = offset.y, z = offset.z, w = offset.w }
    local property = { id = 'test-home', interior = {
        type = 'shell', entrance = entrance, exit = offset, model = Config.shells[name].model,
        origin = name == 'CreateFurniMotelStandard' and {x=800,y=-1500,z=70} or nil,
    } }
    events['qbhousing:client:enterShell'](property)
    local origin = property.interior.origin or entrance
    local inside = vector3(origin.x + offset.x, origin.y + offset.y, origin.z + offset.z)
    check(#(position - inside) == 0 and created == 1, 'entry uses origin plus offset')
    check(heading == offset.w, 'entry retains the authored shell heading')
    local function frame()
        local ok, delay = coroutine.resume(threads[1])
        check(ok, tostring(delay))
        return delay
    end
    check(frame() == 0, 'start the existing leave loop')
    frame()
    check(prompt and shows == 1, 'leave prompt appears at the entered world position: ' .. name)
    frame()
    check(shows == 1, 'do not recreate an active prompt')

    position = vector3(inside.x + 2, inside.y, inside.z)
    frame()
    check(not prompt and hides == 1, 'hide the prompt outside the exit radius')
    position = vector3(offset.x, offset.y, offset.z)
    frame()
    check(not prompt, 'relative coordinates are not a world exit')

    position, pressed = inside, true
    check(frame() == 1000, 'after leaving, use the existing idle wait')
    check(#removed == 1 and removed[1] == 91, 'delete the owned shell object')
    check(position.x == entrance.x and position.y == entrance.y and position.z == entrance.z, 'return to the existing exterior entrance')
    check(not prompt and shows == 2 and hides == 2, 'clear the leave prompt')
    check(offset.x == before.x and offset.y == before.y and offset.z == before.z and offset.w == before.w, 'configuration remains a relative offset')
end
print(('qbhousing shell exit: %d checks passed'):format(checks))
