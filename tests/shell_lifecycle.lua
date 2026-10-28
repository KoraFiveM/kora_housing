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
QB.compat=dofile('../kora_lib/compat/provider.lua')()
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
function FreezeEntityPosition() end
function CreateObject(_,x,y,z) nextEntity=nextEntity+1;entities[nextEntity]={x=x,y=y,z=z};return nextEntity end
function CreateObjectNoOffset() error('Fallback must retain legacy placement') end
function DoesEntityExist(id) return entities[id]~=nil end
function DeleteEntity(id) entities[id]=nil end
function SetEntityHeading() end
function SetEntityCoords(_,x,y,z) moves[#moves+1]={x=x,y=y,z=z} end
QB.stream={loadModel=function(_,callback) if pausing then coroutine.yield() end;callback(123);return true end}
QB.visuals={fade=function() fades=fades+1 end}
QB.interact={removeZone=function() end}
QB.textui={hide=function() end}
QB.notify={send=function() end}
dofile('../kora_interior/client/main.lua')
resource='kora_housing'
Housing={fixtures={clear=function() end,enter=function() fixtureEntries=fixtureEntries+1 end},app={close=function() end}}
dofile('config.lua');dofile('client/main.lua')
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
print(('housing actual shell lifecycle: %d checks passed'):format(checks))
