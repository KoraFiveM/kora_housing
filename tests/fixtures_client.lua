-- Actual fixture renderer/interaction adapter with controlled native boundaries.
Housing={}
local checks,zones,objects,events,requests,wardrobes,removed,notices=0,{},{},{},{},0,0,{}
local allow,pause,thread=true,false,nil
function AddEventHandler(name,fn) events[name]=fn end
function GetCurrentResourceName() return 'qbhousing' end
function CreateThread(fn)
    local co=coroutine.create(fn);local ok,err=coroutine.resume(co);assert(ok,err)
    if coroutine.status(co)~='dead' then thread=co end
end
function SetEntityRotation(entity,x,y,z) objects[entity].rotation={x,y,z} end
QB={notify={send=function(data) notices[#notices+1]=data end},
    interact={addBoxZone=function(name,coords,_,opts) zones[name]={coords=coords,action=opts.options[1].action};return name end,
        removeZone=function(name) zones[name]=nil end},
    callback={trigger=function(name,id,kind)
        requests[#requests+1]={name,id,kind}
        if not allow then return false,'denied' end
        return true,kind=='outfit' and 'outfit' or nil
    end},
    entities={create=function(model,coords)
        if pause then coroutine.yield() end
        local id=#objects+1;objects[id]={model=model,coords=coords};return id
    end,remove=function(id) objects[id]=nil;removed=removed+1 end}}
exports={qbclothing={OpenWardrobe=function() wardrobes=wardrobes+1 end}}
dofile('client/fixtures.lua')
local function check(value,why) assert(value,why);checks=checks+1 end
local definitions={stash={x=1,y=2,z=-27},outfit={x=3,y=4,z=-26},logout={x=5,y=6,z=-25}}
local furniture={{model='prop_chair_01a',coords={x=10,y=20,z=-24},rotation={pitch=5,roll=6,yaw=7}}}
Housing.fixtures.enter('home',definitions,furniture)
check(zones['qbhousing:fixture:stash'].coords==definitions.stash,'fixture uses the exact authoritative position')
check(objects[1].coords==furniture[1].coords and objects[1].rotation[2]==6,'furniture preserves persisted absolute position and rotation')
zones['qbhousing:fixture:outfit'].action()
check(wardrobes==1 and requests[1][2]=='home' and requests[1][3]=='outfit','wardrobe opens after server authorization')
allow=false;zones['qbhousing:fixture:outfit'].action()
check(wardrobes==1 and #notices==1,'denied request never opens wardrobe')
local stale=zones['qbhousing:fixture:stash'].action
Housing.fixtures.clear();stale()
check(next(zones)==nil and next(objects)==nil and #requests==2,'leaving removes entities/targets and invalidates old callbacks')
pause=true;Housing.fixtures.enter('home',definitions,furniture);Housing.fixtures.clear()
local ok,err=coroutine.resume(thread);assert(ok,err)
check(next(objects)==nil,'late model load after leave cannot leak a decoration')
pause=false;Housing.fixtures.enter('home',definitions,furniture)
events['QBCore:Client:OnPlayerUnload']()
check(next(zones)==nil and next(objects)==nil,'character unload releases fixture resources')
Housing.fixtures.enter('home',definitions,furniture);events.onClientResourceStop('qbhousing')
check(next(zones)==nil and next(objects)==nil,'resource stop releases fixture resources')
print(('housing fixture client: %d checks passed'):format(checks))
