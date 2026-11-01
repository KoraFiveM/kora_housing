local h = dofile('../kora_core/test/harness.lua')
local callbacks = {}
local players = {
    [1] = {citizenid='OWNER',name='Owner',charinfo={firstname='O',lastname='W'},job={name='unemployed',type='none'}},
    [2] = {citizenid='KEY',name='Key',charinfo={firstname='K',lastname='Y'},job={name='police',type='leo',onduty=true}},
    [3] = {citizenid='COP',name='Cop',charinfo={firstname='C',lastname='P'},job={name='police',type='leo',onduty=false}},
    [4] = {citizenid='DUTY',name='Duty',charinfo={firstname='D',lastname='T'},job={name='police',type='leo',onduty=true}},
}
local byCid = {}
for _, p in pairs(players) do byCid[p.citizenid] = p end
local core = {
    getPlayer=function(_, src) return players[src] end,
    getPlayerByCitizenId=function(_, cid) return byCid[cid] end,
    getOfflinePlayerData=function() return nil end,
}
exports = setmetatable({kora_core=core}, {__call=function() end})
function AddEventHandler() end
json = {encode=function(v) return '[' .. table.concat(v, ',') .. ']' end, decode=function() return {firstname='O'} end}
local lastSql
Kora = {compat={provideExport=function() end}, callback={register=function(name, fn) callbacks[name]=fn end},
    sql={single=function(q, args) lastSql={q,args}; if args[1]=='OWNER' then return {citizenid='OWNER',charinfo='{}'} end end}}
Config = {legacyHousing={shellTiers={[2]='shell_a'}}}
local props = {
    home={id='home',label='1 Main',owner='OWNER',state='owned',keys={KEY=true},coowners={},permissionGrants={},
        interior={entrance={x=1,y=2,z=3,w=4},name='shell_a'},garage={coords={x=5,y=6,z=7,w=8}},listing={price=500}},
    other={id='other',label='2 Side',owner='STRANGER',state='owned',keys={},coowners={},permissionGrants={}},
    gone={id='gone',label='3 Old',owner='OWNER',state='archived',keys={},coowners={},permissionGrants={}},
}
Housing = {state={ready=true,properties=props,get=function(id) return props[id] end},
    permissionActions={entry=true}, grantablePermissions={entry=true}}
Housing.permissions = {canCitizen=function(cid, id) return props[id].keys[cid] == true end}
dofile('server/compat.lua')

h.test('GetPlayerHouses returns only the caller\'s live houses in stock shape', function()
    local r = callbacks['qb-phone:server:GetPlayerHouses'](1)
    h.assertEqual(#r, 1); h.assertEqual(r[1].name, 'home'); h.assertEqual(r[1].owner, 'OWNER')
    h.assertEqual(r[1].label, '1 Main'); h.assertEqual(r[1].price, 500); h.assertEqual(r[1].tier, 2)
    h.assertEqual(r[1].keyholders[1].citizenid, 'KEY'); h.assertEqual(r[1].garage.h, 8)
    h.assertEqual(#callbacks['qb-phone:server:GetPlayerHouses'](3), 0)
    h.assertEqual(#callbacks['qb-phone:server:GetPlayerHouses'](99), 0)
end)
h.test('GetHouseKeys lists owned and keyed houses, honouring revocation', function()
    local owner = callbacks['qb-phone:server:GetHouseKeys'](1)
    h.assertEqual(#owner, 1); h.assertEqual(owner[1].HouseData.name, 'home')
    h.assertEqual(owner[1].HouseData.coords.enter.h, 4)
    h.assertEqual(#callbacks['qb-phone:server:GetHouseKeys'](2), 1)
    h.assertEqual(#callbacks['qb-phone:server:GetHouseKeys'](3), 0)
    props.home.keys.KEY = nil
    h.assertEqual(#callbacks['qb-phone:server:GetHouseKeys'](2), 0)
    props.home.keys.KEY = true
end)
h.test('MeosGetPlayerHouses needs an on-duty police caller and a string search', function()
    local meos = callbacks['qb-phone:server:MeosGetPlayerHouses']
    h.assertEqual(meos(1, 'OWNER'), nil)
    h.assertEqual(meos(3, 'OWNER'), nil)
    h.assertEqual(meos(4, 42), nil)
    h.assertEqual(meos(4, 'NOBODY'), nil)
    local r = meos(4, 'OWNER')
    h.assertEqual(#r, 1); h.assertEqual(r[1].owner, 'OWNER'); h.assertEqual(r[1].coords.x, 1)
    h.assertEqual(r[1].keyholders, '[KEY]')
    meos(4, '100%_x'); h.assertEqual(lastSql[2][2], '%100\\%\\_x%')
end)
h.test('callbacks are unavailable before housing is ready', function()
    Housing.state.ready = false
    h.assertEqual(callbacks['qb-phone:server:GetHouseKeys'](1), nil)
    Housing.state.ready = true
end)
h.report('qb-phone housing compat')
