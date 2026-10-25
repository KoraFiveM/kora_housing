local H = dofile('../qbcore/test/harness.lua')
local setup = dofile('tests/domain_fixture.lua')
local function stash(f, id, status)
    f.db.stashes[id] = { id = id, property_id = 'home', status = status or 'active', coords = { x = 0, y = 0, z = 0 } }
end

H.test('storage authorizes every open and rechecks revoked permissions in existing policy', function()
    local f = setup(); stash(f, 'p:home')
    H.assertEqual(f.housing.storage.openStash(2, 'home'), false)
    H.assertEqual(f.housing.storage.openStash(1, 'home'), true)
    H.assertEqual(f.policies['p:home'](2), false)
    f.housing.state.get('home').permissionGrants.BUYER = { ['stash.open'] = true }
    H.assertEqual(f.policies['p:home'](2), true)
    f.housing.state.get('home').permissionGrants.BUYER['stash.open'] = false
    H.assertEqual(f.policies['p:home'](2), false)
    f.housing.state.get('home').state = 'archiving'
    H.assertEqual(f.policies['p:home'](1), false)
end)

H.test('imported stock stash retains inventory identity, capacity and current access policy', function()
    local f=setup();stash(f,'home')
    local p=f.housing.state.get('home')
    p.legacy={stash={id='home',coords={x=0,y=0,z=0},capacity={slots=50,maxWeight=1000000}}}
    f.inventory.home={{name='bread',amount=2}}
    H.assertTrue(f.housing.storage.openStash(1,'home'))
    H.assertEqual(f.registered.home.maxWeight,1000000)
    H.assertEqual(f.registered.home.slots,50)
    H.assertEqual(f.inventory.home[1].amount,2,'existing canonical contents are not copied or replaced')
    p.permissionGrants.BUYER={entry=true,['stash.open']=true}
    H.assertTrue(f.policies.home(2))
    p.permissionGrants.BUYER.entry=false
    H.assertFalse(f.policies.home(2),'revoked entry also revokes the old stash policy')
    H.assertFalse(f.housing.storage.purchaseStorage(1,'home'),'do not charge for a downgrade of imported capacity')
    H.assertEqual(#f.bankCalls,0)
end)

H.test('configured larger imported-stash upgrade changes real capacity with the paid property transaction', function()
    local f=setup();stash(f,'home')
    f.housing.state.get('home').legacy={stash={id='home',coords={x=0,y=0,z=0},capacity={slots=50,maxWeight=1000000}}}
    f.env.Config.storageTiers[2]={slots=80,maxWeight=2000000,price=10000,label='Larger stock storage'}
    f.balances.OWNER=50000
    H.assertTrue(f.housing.storage.purchaseStorage(1,'home'))
    H.assertEqual(f.housing.state.get('home').legacy.stash.capacity.maxWeight,2000000)
    H.assertEqual(f.registered.home.maxWeight,2000000);H.assertEqual(f.registered.home.slots,80)
    H.assertEqual(f.balances.OWNER,40000)
end)

H.test('sale emptiness requires a completed transfer barrier and unfreezes on rejection', function()
    local f = setup(); stash(f, 'p:home'); assert(f.housing.storage.refresh('home'))
    f.busyStash = 'p:home'
    H.assertEqual(f.housing.storage.freezeForSale('home'), false)
    H.assertEqual(#f.calls, 0)
    f.busyStash = nil; f.inventory['p:home'] = { { name = 'bread', amount = 1 } }
    H.assertEqual(f.housing.storage.freezeForSale('home'), false)
    H.assertEqual(f.calls[1].blocked, true)
    H.assertEqual(f.blocks['p:home'], false)
    f.inventory['p:home'] = {}
    H.assertEqual(f.housing.storage.freezeForSale('home'), true)
    H.assertEqual(f.policies['p:home'](1), false)
    H.assertEqual(f.blocks['p:home'], true)
    f.housing.storage.unfreeze('home')
    H.assertEqual(f.policies['p:home'](1), true)
end)

H.test('unowned storage preflight rejects belongings without leaving permanent freeze', function()
    local f = setup(); f.housing.state.get('home').owner = nil
    stash(f, 'p:home'); assert(f.housing.storage.refresh('home'))
    f.inventory['p:home'] = { { name = 'bread', amount = 1 } }
    H.assertEqual(f.housing.storage.canArchive('home'), false)
    H.assertEqual(f.housing.storage.frozen.home, nil)
    f.inventory['p:home'] = {}
    H.assertEqual(f.housing.storage.canArchive('home'), true)
    H.assertEqual(f.blocks['p:home'], false)
end)

H.test('storage upgrade retries an immutable pending payment and applies capacity once', function()
    local f = setup(); stash(f, 'p:home'); assert(f.housing.storage.refresh('home'))
    f.balances.OWNER, f.failBankSQL = 50000, true
    H.assertEqual(f.housing.storage.purchaseStorage(2, 'home'), false)
    H.assertEqual(#f.bankCalls, 0)
    H.assertEqual(f.housing.storage.purchaseStorage(1, 'home'), false)
    H.assertEqual(f.housing.storage.purchaseStorage(1, 'home'), false)
    H.assertEqual(#f.bankCalls, 1)
    f.failBankSQL = false; f.reloadTransactions()
    H.assertEqual(f.db.tiers.home, 2)
    H.assertEqual(f.registered['p:home'].slots, f.env.Config.storageTiers[2].slots)
    H.assertEqual(f.balances.OWNER, 40000)
    f.housing.transactions.resume()
    H.assertEqual(f.balances.OWNER, 40000); H.assertEqual(#f.db.ledger, 2)
end)

H.test('recovery binds tenant and retries capacity or metadata failure without redelivery', function()
    local f = setup(); stash(f, 'lease:one', 'recovery'); f.db.stashes['lease:one'].tenant = 'BUYER'
    f.db.recovery.claim = { id = 'claim', property_id = 'home', citizenid = 'BUYER', kind = 'stash', reference = 'lease:one', status = 'pending' }
    H.assertEqual(f.housing.storage.claimRecovery(1, 'claim'), false)
    f.full = true
    H.assertEqual(f.housing.storage.claimRecovery(2, 'claim'), false)
    H.assertEqual(f.db.recovery.claim.status, 'pending'); H.assertEqual(f.delivered, 0)
    f.full = false; f.afterClaim = function() f.failSQL = true end
    H.assertEqual(f.housing.storage.claimRecovery(2, 'claim'), false)
    H.assertEqual(f.delivered, 1); H.assertEqual(f.db.recovery.claim.status, 'pending')
    f.failSQL, f.afterClaim = false, nil
    H.assertEqual(f.housing.storage.claimRecovery(2, 'claim'), true)
    H.assertEqual(f.delivered, 1); H.assertEqual(f.db.recovery.claim.status, 'claimed')
    H.assertEqual(f.housing.storage.claimRecovery(2, 'claim'), true)
    H.assertEqual(f.delivered, 1)
end)

H.test('pending recovery rebind needs no item snapshot write or unfreeze', function()
    local f = setup(); stash(f, 'lease:one', 'recovery'); f.db.stashes['lease:one'].tenant = 'BUYER'
    f.db.recovery.claim = { id = 'claim', property_id = 'home', citizenid = 'BUYER', kind = 'stash', reference = 'lease:one', status = 'pending' }
    assert(f.housing.storage.refresh('home'))
    f.failRegister, f.busyStash = true, 'lease:one'
    H.assertEqual(f.housing.storage.claimRecovery(2, 'claim'), true)
    H.assertEqual(f.delivered, 1)
end)

H.test('garage registration ignores imported resource ids and scopes each action', function()
    local f = setup({ garage = true }); f.db.garages.home = 'housing-owned-id'
    assert(f.housing.storage.registerGarage('home'))
    H.assertEqual(f.garage.id, 'housing-owned-id')
    H.assertEqual(f.garage.callback(1, 'store'), true)
    H.assertEqual(f.garage.callback(2, 'store'), false)
    f.formerGarage = true
    H.assertEqual(f.garage.callback(2, 'retrieve'), true)
    H.assertEqual(f.garage.callback(2, 'store'), false)
end)

H.test('archived shared storage snapshots original owners and the first claim completes all entitlements', function()
    local f = setup({ coowner = true }); stash(f, 'p:home')
    f.inventory['p:home'] = { { name = 'bread', amount = 2 } }
    assert(f.housing.storage.refresh('home'))
    f.housing.state.get('home').state = 'archiving'
    assert(f.housing.storage.archive('home'))
    local coowner, owner
    for _, row in pairs(f.db.recovery) do if row.citizenid == 'COOWNER' then coowner = row else owner = row end end
    assert(coowner and owner)
    H.assertEqual(f.policies['p:home'](4), false, 'recovery cannot open as a normal stash or accept deposits')
    H.assertEqual(f.policies['p:home'](4, nil, nil, { recovery = true }), true)
    f.housing.state.get('home').permissionGrants.SECOND = { ['stash.open'] = true }
    H.assertEqual(f.policies['p:home'](3, nil, nil, { recovery = true }), false, 'later property grants cannot acquire archived belongings')
    assert(f.housing.storage.claimRecovery(4, coowner.id))
    H.assertEqual(f.delivered, 1)
    H.assertEqual(f.db.recovery[owner.id].status, 'claimed')
    H.assertEqual(f.db.stashes['p:home'].status, 'claimed')
    assert(f.housing.storage.claimRecovery(1, owner.id))
    H.assertEqual(f.delivered, 1)
end)

H.report('housing storage and recovery')
