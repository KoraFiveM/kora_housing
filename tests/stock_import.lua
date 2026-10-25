local h = dofile('../qbcore/test/harness.lua')
local setup = dofile('tests/stock_fixture.lua')

h.test('stock ownership and keys load into the native authority with lossless source backup', function()
    local f=setup()
    f.locations[1].customColumn='preserve unknown data'
    local source=f.json.encode({houselocations=f.locations[1],player_houses=f.owners[1]})
    h.assertTrue(f.housing.legacy.importStock())
    h.assertEqual(f.markers.old_home.source_data,source)
    h.assertEqual(f.json.encode({houselocations=f.locations[1],player_houses=f.owners[1]}),source,'source tables remain unchanged')
    h.assertTrue(f.load())
    local property=f.housing.state.get('old_home')
    h.assertEqual(property.owner,'OWNER')
    h.assertEqual(property.propertyType,'legacy')
    h.assertTrue(property.legacy.needsWorldMapping)
    h.assertEqual(property.interior.name,'CreateApartmentShell','pinned tier one uses the apartment shell')
    h.assertEqual(property.interior.entrance.z,3,'real stock entrance is preserved')
    h.assertEqual(property.legacy.stockShellOrigin.z,-27,'pinned stock offset is preserved without inventing a boundary')
    h.assertEqual(property.legacy.unmappedFixtures.stash,nil)
    h.assertEqual(property.legacy.stash.id,'old_home','stock inventory ID is retained')
    h.assertEqual(f.stashes.old_home.status,'active')
    h.assertTrue(property.legacy.unmappedFixtures.decorations,'unknown decoration shape remains explicit')
    h.assertTrue(f.housing.permissions.canCitizen('OWNER','old_home','entry'))
    h.assertTrue(f.housing.permissions.canCitizen('KEY','old_home','entry'))
    h.assertFalse(f.housing.permissions.canCitizen('OUTSIDER','old_home','entry'))
    h.assertFalse(f.json.encode(f.housing.state.publicProperty(property)):find('license:owner',1,true),'private source identity is not broadcast')
end)

h.test('bundled garage and tier sixteen motel map exact models and stock placement without guessing bounds', function()
    for _, entry in ipairs({{11,'CreateGarageMed','shell_garagem'},{16,'CreateFurniMotelStandard','standardmotel_shell'}}) do
        local f=setup(); f.locations[1].tier=entry[1]
        h.assertTrue(f.housing.legacy.importStock()); h.assertTrue(f.load())
        local property=f.housing.state.get('old_home')
        h.assertEqual(property.interior.name,entry[2]);h.assertEqual(property.interior.model,entry[3])
        local public=f.housing.state.publicProperty(property)
        h.assertEqual(public.interior.origin.z,-27);h.assertEqual(public.interior.placement,'legacy')
        h.assertEqual(public.interior.entrance.z,3,'exterior return point stays unchanged')
        h.assertEqual(property.interior.origin,nil,'client projection does not mutate authoritative records')
        h.assertTrue(property.legacy.needsWorldMapping,'unverified world bounds remain explicit')
    end
    local f=setup();f.locations[1].tier=101
    h.assertTrue(f.housing.legacy.importStock());h.assertTrue(f.load())
    local unknown=f.housing.state.get('old_home')
    h.assertEqual(unknown.interior,nil);h.assertTrue(unknown.legacy.needsWorldMapping)
    h.assertTrue(f.markers.old_home.source_data:find('101',1,true)~=nil,'unknown source tier remains losslessly backed up')
end)

h.test('completed import never overwrites native ownership, revoked keys or archived properties', function()
    local f=setup(); h.assertTrue(f.housing.legacy.importStock())
    f.characters.NEW={citizenid='NEW',license='license:new'}
    local row=f.rows.old_home;local raw=f.json.decode(row.definition)
    row.owner,raw.owner,raw.state='NEW','NEW','archived';row.definition=f.json.encode(raw)
    f.grants['old_home:KEY:entry'].allowed=0
    local before=f.json.encode(f.rows)
    h.assertTrue(f.housing.legacy.importStock());h.assertEqual(#f.writes,1)
    h.assertEqual(f.json.encode(f.rows),before)
    h.assertTrue(f.load());h.assertFalse(f.housing.permissions.canCitizen('KEY','old_home','entry'))
    f.rows.old_home=nil
    h.assertTrue(f.housing.legacy.importStock());h.assertEqual(f.rows.old_home,nil,'marker prevents recreation after native deletion')
end)

h.test('unknown committed import retries from its durable markers without duplicated authority', function()
    local f=setup();f.unknownCommit=true
    h.assertFalse(f.housing.legacy.importStock());h.assertFalse(f.housing.state.ready)
    h.assertTrue(f.housing.legacy.importStock());h.assertEqual(#f.writes,1)
    h.assertTrue(f.load());h.assertEqual(f.housing.state.get('old_home').owner,'OWNER')
end)

h.test('malformed and ambiguous stock ownership fails before writing any property', function()
    local cases={
        function(f) f.owners[1].identifier='license:other' end,
        function(f) f.characters.OWNER=nil end,
        function(f) f.owners[2]=f.owners[1] end,
        function(f) f.locations[2]=f.locations[1] end,
        function(f) f.owners[1].house='unknown' end,
        function(f) f.locations[1].owned=0 end,
        function(f) f.owners[1].keyholders='{"OUTSIDER":true}' end,
        function(f) f.owners[1].keyholders='[null,"KEY"]' end,
        function(f) f.owners[1].decorations='broken' end,
        function(f) f.locations[1].coords='broken' end,
        function(f) f.rows.old_home={id='old_home',owner='NEW'} end,
    }
    for _,change in ipairs(cases) do
        local f=setup();change(f)
        local ok,err=f.housing.legacy.importStock()
        h.assertFalse(ok);h.assertEqual(type(err),'string');h.assertEqual(#f.writes,0)
    end
end)

h.test('empty stock databases and unowned locations keep valid native startup behavior', function()
    local f=setup();f.present=false
    h.assertTrue(f.housing.legacy.importStock());h.assertEqual(#f.writes,0)
    f=setup();f.owners={};f.locations[1].owned=0
    h.assertTrue(f.housing.legacy.importStock());h.assertTrue(f.load())
    h.assertEqual(f.housing.state.get('old_home').owner,nil)
    h.assertFalse(f.housing.permissions.canCitizen('KEY','old_home','entry'))
end)

h.test('database failures stay explicit and never claim imported data', function()
    local f=setup();f.readFailure=true
    local ok,err=f.housing.legacy.importStock();h.assertFalse(ok);h.assertEqual(err,'read failure')
    f=setup();f.failWrite=true
    ok,err=f.housing.legacy.importStock();h.assertFalse(ok);h.assertEqual(err,'write failure')
    h.assertEqual(next(f.rows),nil);h.assertEqual(next(f.markers),nil)
end)

h.test('exact stock fixture records become native inventory, furniture, wardrobe and logout data atomically', function()
    local f=setup()
    f.owners[1].decorations='[{"hashname":"prop_chair_01a","x":2,"y":3,"z":-26,"rotx":10,"roty":20,"rotz":30,"objectId":42}]'
    f.owners[1].outfit='{"x":3,"y":4,"z":-25}'
    f.owners[1].logout='{"x":5,"y":6,"z":-25}'
    h.assertTrue(f.housing.legacy.importStock());h.assertTrue(f.load())
    local p=f.housing.state.get('old_home')
    h.assertEqual(next(p.legacy.unmappedFixtures),nil)
    h.assertEqual(p.legacy.stash.id,'old_home');h.assertEqual(p.legacy.stash.capacity.maxWeight,1000000)
    h.assertEqual(p.clothing[1].coords.z,-25);h.assertEqual(p.logout.x,5)
    local item=f.json.decode(f.furniture['stock:old_home:1'].definition)
    h.assertEqual(item.coords.z,-26);h.assertEqual(item.rotation.roll,20);h.assertEqual(item.ownerCid,'OWNER')
    h.assertTrue(p.permissionGrants.KEY['stash.open'])
    local before=f.json.encode({f.rows,f.stashes,f.furniture})
    h.assertTrue(f.housing.legacy.upgradeFixtures());h.assertEqual(#f.writes,1)
    h.assertEqual(f.json.encode({f.rows,f.stashes,f.furniture}),before,'restart does not repeat fixture insertion')
end)

h.test('previous ownership-only imports upgrade once without restoring revoked grants or replacing native fixtures', function()
    local f=setup();h.assertTrue(f.housing.legacy.importStock());h.assertTrue(f.load())
    local p=f.housing.state.get('old_home')
    p.legacy.fixtureVersion=nil;p.legacy.stash=nil;p.legacy.unmappedFixtures={stash=true}
    p.permissionGrants.KEY={entry=false,['stash.open']=false};f.stashes={}
    h.assertTrue(f.housing.legacy.upgradeFixtures())
    p=f.housing.state.get('old_home');h.assertEqual(p.legacy.stash.id,'old_home')
    h.assertFalse(p.permissionGrants.KEY.entry);h.assertFalse(p.permissionGrants.KEY['stash.open'])
    p.legacy.unmappedFixtures.stash=true;p.legacy.stash=nil
    f.stashes.other={id='other',property_id='old_home',status='active',coords='{}'}
    local count=#f.writes
    h.assertTrue(f.housing.legacy.upgradeFixtures());h.assertEqual(#f.writes,count)
    h.assertTrue(p.legacy.unmappedFixtures.stash,'native fixture conflicts stay explicit')
    p.owner='NEW';p.legacy.fixtureVersion=nil
    h.assertTrue(f.housing.legacy.upgradeFixtures());h.assertEqual(#f.writes,count,'sale does not restore former owner data')
end)

h.test('missing capacity and malformed fixture transforms remain backed up and unmapped', function()
    local f=setup();f.locations[1].tier=16
    f.owners[1].outfit='{"x":"3","y":4,"z":5}'
    f.owners[1].decorations='[{"hashname":"prop_chair_01a","x":2,"y":3,"z":4,"rotx":0,"roty":0}]'
    h.assertTrue(f.housing.legacy.importStock());h.assertTrue(f.load())
    local p=f.housing.state.get('old_home')
    h.assertTrue(p.legacy.unmappedFixtures.stash);h.assertTrue(p.legacy.unmappedFixtures.outfit);h.assertTrue(p.legacy.unmappedFixtures.decorations)
    h.assertEqual(next(f.stashes),nil);h.assertEqual(next(f.furniture),nil)
end)

h.test('new standard motel mapping upgrades the prior unmapped record without changing owner or source archive', function()
    local f=setup();f.locations[1].tier=16
    h.assertTrue(f.housing.legacy.importStock());h.assertTrue(f.load())
    local p=f.housing.state.get('old_home');p.interior=nil;p.legacy.stockShellOrigin=nil;p.legacy.fixtureVersion=nil
    local backup=f.markers.old_home.source_data
    h.assertTrue(f.housing.legacy.upgradeFixtures())
    p=f.housing.state.get('old_home')
    h.assertEqual(p.interior.model,'standardmotel_shell');h.assertEqual(p.owner,'OWNER')
    h.assertEqual(p.legacy.stockShellOrigin.z,-27);h.assertEqual(f.markers.old_home.source_data,backup)
end)

h.report('stock housing import')
