-- Actual interior geometry provider and housing entry client share one delayed
-- model stream. A character unload must prevent every teleport side effect.
package.path='../kora_lib/test/?.lua;'..package.path
local net=require('mocks').install()
local resource='kora_interior'
function GetCurrentResourceName() return resource end
function GetInvokingResource() return 'kora_housing' end
dofile('../kora_lib/build/initiate.lua')
dofile('../kora_lib/modules/util/shared.lua')
dofile('../kora_lib/local/resources/client.lua')
Kora.compat=dofile('../kora_lib/compat/provider.lua')()
local provided,entities,threads,moves={}, {}, {}, {}
local fades,fixtureEntries,pausing,nextEntity=0,0,true,10
exports=setmetatable({kora_interior=setmetatable({}, {__index=function(_,name) return function(_,...) return provided[name](...) end end})},
    {__call=function(_,name,fn) provided[name]=fn end})
function vector3(x,y,z) return {x=x,y=y,z=z} end
function vector4(x,y,z,w) return {x=x,y=y,z=z,w=w} end
function CreateThread(fn) threads[#threads+1]=fn end
function RegisterCommand() end
function PlayerPedId() return 1 end
function TriggerServerEvent() end
function CreateObject(_,x,y,z) nextEntity=nextEntity+1;entities[nextEntity]={x=x,y=y,z=z};return nextEntity end
function CreateObjectNoOffset() error('Fallback must retain legacy placement') end
function DoesEntityExist(id) return entities[id]~=nil end
function DeleteEntity(id) entities[id]=nil end
function SetEntityHeading() end
function SetEntityCoords(_,x,y,z) moves[#moves+1]={x=x,y=y,z=z} end
Kora.stream={loadModel=function(_,callback) if pausing then coroutine.yield() end;callback(123);return true end}
local housingFades,collisionAsks,collisionLoaded,frozenLog=0,0,false,{}
Kora.visuals={fade=function(_,fn) if type(fn)=='function' then housingFades=housingFades+1;fn() else fades=fades+1 end end}
Kora.loops={controlled=function(call) for _=1,3 do if call() then return true end end return false,'timeout' end}
function IsEntityPositionFrozen() return false end
function FreezeEntityPosition(_,v) frozenLog[#frozenLog+1]=v end
function RequestCollisionAtCoord() collisionAsks=collisionAsks+1 end
function HasCollisionLoadedAroundEntity() return collisionLoaded end
Kora.interact={removeZone=function() end}
Kora.textui={hide=function() end}
Kora.keybind={add=function() return {disable=function() end} end}
Kora.zones={sphere=function() return {remove=function() end} end}
Kora.notify={send=function() end}
dofile('../kora_interior/client/main.lua')
resource='kora_housing'
Housing={fixtures={clear=function() end,enter=function() fixtureEntries=fixtureEntries+1 end},app={close=function() end}}
dofile('config.lua');dofile('client/world.lua');dofile('client/main.lua')
local checks=0
local function check(value,message) assert(value,message);checks=checks+1 end
local property={id='home',interior={type='shell',model='standardmotel_shell',exit=Config.shells.CreateFurniMotelStandard.exit,
    entrance={x=1,y=2,z=3},origin={x=1,y=2,z=-27},placement='legacy'}}
local co=coroutine.create(function() net.fire('qbhousing:client:enterShell',property) end)
local ok,err=coroutine.resume(co);assert(ok,err)
check(coroutine.status(co)=='suspended','actual model load is pending')
net.fire('QBCore:Client:OnPlayerUnload')
ok,err=coroutine.resume(co);assert(ok,err)
check(coroutine.status(co)=='dead' and next(entities)==nil,'late shell is released after character unload')
check(#moves==0 and fades==0 and fixtureEntries==0,'replacement character receives no provider fade, teleport or fixture session')
pausing=false;net.fire('qbhousing:client:enterShell',property)
check(#moves==1 and moves[1].z==-26 and fixtureEntries==1,'current character enters at exact original basement plus authored exit')
check(next(entities)~=nil and fades==0,'geometry-only provider preserves local owned shell without early fade')
net.fire('qbhousing:client:leaveProperty')
check(next(entities)==nil and #moves==2 and moves[2].z==3,'leaving releases provider geometry and returns to exterior')
check(housingFades==1 and collisionAsks>=1 and frozenLog[1]==true and frozenLog[#frozenLog]==false,'entry fades, freezes, requests collision at the exit and unfreezes')
Config.interior.waitForCollision.enabled=false;housingFades=0;collisionAsks=0
net.fire('qbhousing:client:enterShell',property)
check(housingFades==0 and collisionAsks==0 and #moves==3,'waitForCollision disabled places the player directly')
print(('housing actual shell lifecycle: %d checks passed'):format(checks))
