local h = dofile('../qbcore/test/harness.lua')
local provided, handlers = {}, {}
local record = {id='home',owner='OWNER',state='owned',keys={KEY=true},coowners={},permissionGrants={}}
Housing = {state={ready=true,get=function(id) return id=='home' and record end},
    permissionActions={entry=true},grantablePermissions={entry=true}}
local core = {
    getPlayerByCitizenId=function(_, cid) return cid=='OWNER' and {citizenid=cid,license='license:owner'} end,
    getOfflinePlayerData=function(_, cid) return cid=='OFFLINE' and {citizenid=cid,license='license:offline'} end,
}
exports=setmetatable({qbcore=core},{__call=function(_, name, fn) provided[name]=fn end})
function AddEventHandler(name, fn) handlers[name]=fn end
QB={compat=dofile('../qblib/compat/provider.lua')()}
Config={}
dofile('server/permissions.lua');dofile('server/compat.lua')
local legacy;handlers['__cfx_export_qb-houses_hasKey'](function(fn) legacy=fn end)
h.test('legacy house keys use native property identity and owner license', function()
 h.assertEqual(legacy,provided.hasKey)
 h.assertTrue(legacy('license:owner','OWNER','home'))
 h.assertFalse(legacy('wrong','OWNER','home'))
 h.assertFalse(legacy('license:owner','OWNER','unknown'))
 h.assertFalse(legacy(nil,'OWNER','home'))
 record.owner='OFFLINE';h.assertTrue(legacy('license:offline','OFFLINE','home'));record.owner='OWNER'
end)
h.test('keyholders and explicit revocations follow authoritative entry policy', function()
 h.assertTrue(legacy('unused','KEY','home'))
 h.assertFalse(legacy('unused','OUTSIDER','home'))
 record.permissionGrants.KEY={entry=false};h.assertFalse(legacy('unused','KEY','home'))
 record.permissionGrants.KEY=nil
 record.state='archived';h.assertFalse(legacy('license:owner','OWNER','home'));record.state='owned'
 Housing.state.ready=false;h.assertFalse(legacy('license:owner','OWNER','home'));Housing.state.ready=true
end)
h.test('active native leases cannot be bypassed through the legacy export', function()
 Housing.leases={permission=function(_,_,_,cid) return cid=='TENANT' end,active=function() return {tenant='TENANT'} end}
 h.assertFalse(legacy('license:owner','OWNER','home'))
 h.assertFalse(legacy('unused','KEY','home'))
 h.assertTrue(legacy('unused','TENANT','home'))
end)
h.report('qbhousing legacy access')
