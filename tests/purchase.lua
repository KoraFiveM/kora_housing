local H = dofile('../qbcore/test/harness.lua')
local setup = dofile('tests/domain_fixture.lua')

H.test('sale commits one balanced journal, transfers ownership and clears old access', function()
    local f = setup({ coowner = true })
    assert(f.housing.sales.completeSale(2, 'offer'))
    local property = f.housing.state.get('home')
    H.assertEqual(property.owner, 'BUYER'); H.assertEqual(next(property.coowners), nil)
    H.assertEqual(next(property.keys), nil); H.assertEqual(next(property.permissionGrants), nil)
    H.assertEqual(f.balances.BUYER, 5000); H.assertEqual(f.balances.OWNER, 2500); H.assertEqual(f.balances.COOWNER, 2500)
    local sum = 0; for _, leg in ipairs(f.db.ledger) do sum = sum + leg[5] end
    H.assertEqual(sum, 0); H.assertEqual(#f.bankCalls, 1)
    H.assertEqual(f.db.offers.competing.status, 'superseded')
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), true)
    H.assertEqual(#f.bankCalls, 1); H.assertEqual(#f.db.ledger, 3)
end)

H.test('competing buyers and duplicate checkout cannot settle while the first save yields', function()
    local f = setup(); f.bankYield = true
    local thread = coroutine.create(function() return f.housing.sales.completeSale(2, 'offer') end)
    local resumed, waiting = coroutine.resume(thread); assert(resumed, waiting); H.assertEqual(waiting, 'bank wait')
    H.assertEqual(f.housing.sales.completeSale(3, 'competing'), false)
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
    H.assertEqual(#f.bankCalls, 1); H.assertEqual(f.balances.BUYER, 10000)
    f.bankYield = false
    local finished, result = coroutine.resume(thread); assert(finished, result); H.assertEqual(result, true)
    H.assertEqual(f.housing.sales.completeSale(3, 'competing'), false)
    H.assertEqual(f.balances.SECOND, 10000)
end)

H.test('all current coowners must approve the exact ownership revision', function()
    local f = setup({ coowner = true }); f.db.approvals['offer:COOWNER'] = nil
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
    assert(f.housing.sales.approveSale(4, 'offer', true))
    f.db.approvals['offer:COOWNER'].ownership_revision = 0
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
    assert(f.housing.sales.approveSale(4, 'offer', true))
    assert(f.housing.sales.approveSale(1, 'offer', false))
    H.assertEqual(f.db.offers.offer.status, 'rejected')
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
    H.assertEqual(#f.bankCalls, 0)
end)

H.test('forged buyer and changed ownership cannot settle an accepted offer', function()
    local f = setup()
    H.assertEqual(f.housing.sales.completeSale(3, 'offer'), false)
    f.housing.state.get('home').ownershipRevision = 2
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
    H.assertEqual(#f.bankCalls, 0)
end)

H.test('insufficient funds and intent SQL failure leave ownership and money unchanged', function()
    local f = setup(); f.balances.BUYER = 4999
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
    H.assertEqual(f.housing.state.get('home').owner, 'OWNER'); H.assertEqual(f.balances.OWNER, 0)
    H.assertEqual(f.db.transactions['sale:offer:1'].status, 'rejected')
    H.assertEqual(f.housing.transactions.busy('home'), false)
    f.balances.BUYER, f.failReservation = 10000, true
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
    H.assertEqual(#f.bankCalls, 1); H.assertEqual(f.housing.state.get('home').owner, 'OWNER')
    f.failReservation = false
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), true)
    H.assertEqual(f.bankCalls[2].key, 'sale:offer:2')
end)

for _, mode in ipairs({ 'transport', 'SQL' }) do
    H.test(mode .. ' failure keeps immutable journal pending and restart resumes exactly once', function()
        local f = setup()
        if mode == 'transport' then f.bankMode = 'throw' else f.failBankSQL = true end
        H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
        H.assertEqual(f.housing.transactions.busy('home'), true)
        H.assertEqual(f.housing.state.get('home').owner, 'OWNER'); H.assertEqual(f.balances.BUYER, 10000)
        local intent = f.db.transactions['sale:offer:1'].request
        f.env.Config.saleCommissions.private.society = 0.8
        f.bankMode, f.failBankSQL = nil, false
        f.reloadTransactions()
        H.assertEqual(f.db.transactions['sale:offer:1'].request, intent)
        H.assertEqual(f.json.encode(f.bankCalls[2].request), intent)
        H.assertEqual(f.housing.state.get('home').owner, 'BUYER'); H.assertEqual(f.balances.BUYER, 5000)
        H.assertEqual(f.balances.OWNER, 5000); H.assertEqual(#f.db.ledger, 2)
        f.housing.transactions.resume()
        H.assertEqual(#f.bankCalls, 2); H.assertEqual(f.housing.transactions.busy('home'), false)
    end)
end

H.test('lost response after durable settlement reconciles the banking receipt', function()
    local f = setup(); f.commitThenThrow = true
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), true)
    H.assertEqual(f.balances.BUYER, 5000); H.assertEqual(f.housing.state.get('home').owner, 'BUYER')
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), true)
    H.assertEqual(#f.bankCalls, 1); H.assertEqual(#f.db.ledger, 2)
end)

H.test('failing an exact row precondition rolls back every financial and property effect', function()
    local f = setup(); f.db.properties.home.revision = 5
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
    H.assertEqual(f.balances.BUYER, 10000); H.assertEqual(f.balances.OWNER, 0)
    H.assertEqual(f.housing.state.get('home').owner, 'OWNER'); H.assertEqual(#f.db.ledger, 0)
end)

local function freshListings(f)
    f.db.listings, f.db.offers, f.db.approvals = {}, {}, {}
    local property = f.housing.state.get('home')
    property.state, property.listing = 'owned', nil
end

H.test('public sale requires an assigned agent recommendation and preserves quoted commission policy', function()
    local f = setup(); freshListings(f)
    H.assertEqual(f.housing.sales.createListing(5, 'home', { channel = 'public', price = 5000, biography = 'A home.' }, 1), false)
    assert(f.housing.sales.assignAgent(1, 'home', 'AGENT', 1))
    local ok, listing = f.housing.sales.createListing(5, 'home', { channel = 'public', price = 5000, biography = 'A home.' }, 2)
    assert(ok, listing)
    local offered, offer = f.housing.sales.submitOffer(2, listing.id, 4000); assert(offered, offer)
    H.assertEqual(f.housing.sales.decideOffer(1, offer.id, 'accept'), false)
    H.assertEqual(f.housing.sales.recommendOffer(2, offer.id, 'Good offer.'), false)
    assert(f.housing.sales.recommendOffer(5, offer.id, 'Good offer.'))
    assert(f.housing.sales.decideOffer(1, offer.id, 'accept'))
    f.env.Config.saleCommissions.public.society, f.env.Config.saleCommissions.public.agent = 0.7, 0.2
    assert(f.housing.sales.completeSale(2, offer.id))
    H.assertEqual(f.balances.BUYER, 6000); H.assertEqual(f.balances.realestate, 140)
    H.assertEqual(f.balances.AGENT, 100); H.assertEqual(f.balances.OWNER, 3760)
end)

H.test('off-market listing creates a named offer and excludes other buyers', function()
    local f = setup(); freshListings(f)
    assert(f.housing.sales.assignAgent(1, 'home', 'AGENT', 1))
    local ok, listing = f.housing.sales.createListing(5, 'home', { channel = 'off_market', buyer = 'BUYER', price = 5000, biography = 'Private viewing.' }, 2)
    assert(ok, listing)
    H.assertEqual(f.housing.sales.submitOffer(3, listing.id, 6000), false)
    local offer
    for _, row in pairs(f.db.offers) do if row.listing_id == listing.id then offer = row end end
    assert(offer)
    H.assertEqual(offer.buyer, 'BUYER'); H.assertEqual(offer.amount, 5000)
    assert(f.housing.sales.recommendOffer(5, offer.id, 'The named buyer is ready.'))
    assert(f.housing.sales.decideOffer(1, offer.id, 'accept'))
    assert(f.housing.sales.completeSale(2, offer.id))
    H.assertEqual(f.balances.SECOND, 10000); H.assertEqual(f.housing.state.get('home').owner, 'BUYER')
end)

H.test('owner private listing creates a direct sale without an agent recommendation', function()
    local f = setup(); freshListings(f)
    local ok, listing = f.housing.sales.createListing(1, 'home', { channel = 'private', buyer = 'BUYER', price = 5000, biography = 'Direct sale.' }, 1)
    assert(ok, listing)
    local offer
    for _, row in pairs(f.db.offers) do offer = row end
    assert(f.housing.sales.decideOffer(1, offer.id, 'accept'))
    assert(f.housing.sales.completeSale(2, offer.id))
    H.assertEqual(f.balances.OWNER, 5000); H.assertEqual(f.balances.AGENT, nil)
end)

H.test('an initial public listing lets its realtor review and approve incoming offers', function()
    local f = setup(); freshListings(f)
    local property = f.housing.state.get('home'); property.owner, property.state = nil, 'unowned'
    local ok, listing = f.housing.sales.createListing(5, 'home', { channel = 'public', price = 5000, biography = 'Initial sale.' }, 1)
    assert(ok, listing)
    local submitted, offer = f.housing.sales.submitOffer(2, listing.id, 5000); assert(submitted, offer)
    local view = f.housing.sales.view(5, 'home')
    H.assertEqual(#view.offers, 1); H.assertEqual(view.offers[1].id, offer.id)
    assert(f.housing.sales.recommendOffer(5, offer.id, 'Recommend sale.'))
    assert(f.housing.sales.decideOffer(5, offer.id, 'accept'))
    assert(f.housing.sales.completeSale(2, offer.id))
    H.assertEqual(f.housing.state.get('home').owner, 'BUYER')
end)

H.test('legacy listing edits invalidate the previous quote before republishing and preserve failure behavior', function()
    local f = setup()
    local callbacks = {}
    f.players[1].job = { name = 'realestate' }
    f.env.QB.callback = { register = function(name, fn) callbacks[name] = fn end }
    f.env.CreateThread, f.env.RegisterNetEvent = function() end, function() end
    setmetatable(f.env.exports, { __call = function() end })
    f.housing.admin, f.housing.doors = {}, {}
    assert(loadfile('server/ownership.lua', 't', f.env))()
    assert(loadfile('server/properties.lua', 't', f.env))()
    assert(loadfile('server/main.lua', 't', f.env))()
    local saved, err = callbacks['qbhousing:saveProperty'](1, { id = 'home', propertyType = 'house',
        interior = { type = 'mlo', entrance = { x = 2, y = 2, z = 0 } }, listing = { price = 6000 } })
    assert(saved, err)
    H.assertEqual(saved.listing.price, 6000)
    H.assertEqual(f.db.listings.listing.status, 'cancelled')
    H.assertEqual(f.db.offers.offer.status, 'cancelled')
    H.assertEqual(f.housing.sales.completeSale(2, 'offer'), false)
    H.assertEqual(f.balances.BUYER, 10000)
    H.assertEqual(f.db.listings[saved.listing.id].price, 6000)
    f.failSQL = true
    local failed = callbacks['qbhousing:saveProperty'](1, { id = 'home', listing = { price = 7000 } })
    H.assertEqual(failed, nil)
    H.assertEqual(f.housing.state.get('home').listing.price, 6000)
end)

H.report('housing sales and transaction recovery')
