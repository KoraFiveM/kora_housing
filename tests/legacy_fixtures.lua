local h = dofile('../qbcore/test/harness.lua')
local setup = dofile('tests/stock_fixture.lua')
local function fixture()
    local f=setup()
    f.owners[1].outfit='{"x":4,"y":5,"z":6}'
    f.owners[1].logout='{"x":4,"y":5,"z":6}'
    h.assertTrue(f.housing.legacy.importStock());h.assertTrue(f.load())
    f.current='OWNER'; f.position={x=1,y=2,z=3};f.events={};f.opens={};f.states={}
    f.env.exports.qbcore.getPlayer=function() return {citizenid=f.current} end
    f.env.exports.qbcore.logout=function(_,src,options) f.logout={src,options};return not f.failLogout, f.failLogout and 'durability failure' or nil end
    f.env.QB.permissions={hasPermission=function() return false end}
    f.housing.transactions={busy=function() return f.busy or false end}
    f.env.GetPlayerPed=function() return 1 end
    f.env.GetEntityCoords=function() return f.position end
    f.env.GetCurrentResourceName=function() return 'qbhousing' end
    f.env.GetResourceState=function(name) return f.stopped==name and 'stopped' or 'started' end
    f.env.Player=function() return {state=f.states} end
    f.env.TriggerClientEvent=function(name,target,value) f.events[#f.events+1]={name,target,value} end
    f.housing.storage={openStash=function(src,id,stash) f.opens[#f.opens+1]={src,id,stash};return true end}
    assert(loadfile('server/world.lua','t',f.env))()
    f.housing.world.ready=true
    return f
end

h.test('legacy fallback entry publishes exact origin only after current server permission and proximity',function()
    local f=fixture();local world=f.housing.world
    f.current='OUTSIDER';h.assertFalse(world.enter(1,'old_home'));h.assertEqual(#f.events,0)
    f.current='OWNER';f.position={x=100,y=100,z=3};h.assertFalse(world.enter(1,'old_home'))
    f.position={x=1,y=2,z=3};h.assertTrue(world.enter(1,'old_home'))
    local payload=f.events[#f.events][3]
    h.assertEqual(payload.interior.origin.z,-27);h.assertEqual(payload.interior.entrance.z,3)
    h.assertEqual(payload.fixtures.outfit.z,6);h.assertTrue(world.occupies(1,'old_home'))
    f.current='KEY';h.assertFalse(world.occupies(1,'old_home'),'source reuse cannot inherit occupancy')
end)

h.test('fixtures require native occupancy, current access, readiness and actual position',function()
    local f=fixture();local use=f.housing.legacy.useFixture
    f.position={x=4,y=5,z=6};h.assertFalse(use(1,'old_home','stash'))
    f.position={x=1,y=2,z=3};h.assertTrue(f.housing.world.enter(1,'old_home'))
    f.position={x=4,y=5,z=6};h.assertTrue(use(1,'old_home','stash'))
    h.assertEqual(f.opens[1][3],'old_home','old inventory ID reaches native storage unchanged')
    local ok,action=use(1,'old_home','outfit');h.assertTrue(ok);h.assertEqual(action,'outfit')
    f.position.z=30;h.assertFalse(use(1,'old_home','outfit'))
    f.position.z=6;f.busy=true;h.assertFalse(use(1,'old_home','outfit'));f.busy=false
    f.housing.state.ready=false;h.assertFalse(use(1,'old_home','stash'));f.housing.state.ready=true
    f.current='KEY';h.assertFalse(use(1,'old_home','stash'))
    f.current='OWNER';f.stopped='qbclothing';h.assertFalse(use(1,'old_home','outfit'))
    h.assertFalse(use(1,'old_home','invented'))
    f.housing.world.leave(1);h.assertFalse(use(1,'old_home','stash'))
end)

h.test('revoking a key while inside immediately closes fixture authority',function()
    local f=fixture();f.current='KEY';h.assertTrue(f.housing.world.enter(1,'old_home'))
    f.position={x=4,y=5,z=6};h.assertTrue(f.housing.legacy.useFixture(1,'old_home','outfit'))
    f.housing.state.get('old_home').permissionGrants.KEY.entry=false
    h.assertFalse(f.housing.legacy.useFixture(1,'old_home','outfit'))
end)

h.test('logout rejects cinematic state and failed persistence, then saves only the trusted exterior',function()
    local f=fixture();h.assertTrue(f.housing.world.enter(1,'old_home'));f.position={x=4,y=5,z=6}
    f.states['qbmultichar:mode']='creator'
    h.assertFalse(f.housing.legacy.useFixture(1,'old_home','logout'));h.assertEqual(f.logout,nil)
    f.states['qbmultichar:mode']=false;f.failLogout=true
    local ok,err=f.housing.legacy.useFixture(1,'old_home','logout')
    h.assertFalse(ok);h.assertEqual(err,'durability failure');h.assertTrue(f.housing.world.occupies(1,'old_home'))
    f.failLogout=false;h.assertTrue(f.housing.legacy.useFixture(1,'old_home','logout'))
    h.assertEqual(f.logout[2].position.z,3,'saved position is the exterior, not fixture or shell basement')
    h.assertEqual(f.logout[2].position.x,1);h.assertFalse(f.housing.world.occupies(1,'old_home'))
end)

h.test('public shell placement only accepts protected imported origin',function()
    local f=fixture()
    local property={interior={type='shell',name='CreateApartmentShell',origin={x=99,y=99,z=99},placement='legacy'}}
    local interior=f.housing.publicInterior(property)
    h.assertEqual(interior.origin,nil);h.assertEqual(interior.placement,nil)
    h.assertEqual(property.interior.origin.x,99,'projection must not mutate the saved property')
end)

h.test('logout completion does not clear a replacement visit across the provider await',function()
    local f=fixture();local world=f.housing.world
    h.assertTrue(world.enter(1,'old_home'));f.position={x=4,y=5,z=6}
    local original=world.occupancy(1,'old_home')
    f.env.exports.qbcore.logout=function()
        world.leave(1)
        f.position={x=1,y=2,z=3}
        h.assertTrue(world.enter(1,'old_home'),'same source and citizen may start a different visit')
        return true
    end
    h.assertTrue(f.housing.legacy.useFixture(1,'old_home','logout'))
    h.assertTrue(world.occupies(1,'old_home'))
    h.assertTrue(world.occupancy(1,'old_home')~=original)
end)

h.report('housing legacy fixture authority')
