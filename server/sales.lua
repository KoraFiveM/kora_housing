Housing.sales = {}
local S, D, State, P = Housing.sales, Housing.domain, Housing.state, Housing.permissions

local function getListing(id)
    return QB.sql.single('SELECT * FROM `qbhousing_listings` WHERE `id`=?', { id })
end

local function getOffer(id)
    local offer, err = QB.sql.single('SELECT * FROM `qbhousing_offers` WHERE `id`=?', { id })
    if not offer then return nil, err or 'Offer was not found.' end
    local listing, listingErr = getListing(offer.listing_id)
    if not listing then return nil, listingErr or 'Listing was not found.' end
    return offer, listing
end

local function seller(src, property, listing)
    local cid = P.citizenId(src)
    return D.owner(property, cid) or not property.owner and listing.agent == cid and P.isRealtor(src)
end

local function available(property)
    if not property or (property.state == 'archived' or property.state == 'archiving') then return false, 'Property is unavailable.' end
    local blocked, err = QB.sql.scalar('SELECT COUNT(*) FROM `qbhousing_leases` WHERE `property_id`=? AND (`status` IN (?,?,?,?) OR `deposit_remaining`>0)', { property.id, 'proposed', 'active', 'ending', 'evicting' })
    if blocked == nil or tonumber(blocked) > 0 then return false, err or 'Resolve existing leases and deposits before listing this property.' end
    return true
end

function S.assignAgent(src, id, target, revision)
    return D.lock(id, function()
        local property = State.get(id)
        if not D.owner(property, P.citizenId(src)) or property.state == 'archived' or property.state == 'archiving' or property.revision ~= revision then return false, 'Refresh the property and verify ownership.' end
        local exists, err = D.character(target)
        if not exists then return false, err end
        local changed = Housing.copy(property)
        local saved, saveErr = State.persist(changed, { actor = P.citizenId(src), action = 'sales.assignAgent', target = target }, {
            { query = 'INSERT IGNORE INTO `qbhousing_agents` (`property_id`,`citizenid`) VALUES (?,?)', values = { id, target } },
        })
        if not saved then return false, saveErr end
        D.agents[id] = D.agents[id] or {}; D.agents[id][target] = true
        return true, saved
    end)
end

function S.createListing(src, id, payload, revision)
    return D.lock(id, function()
        local property, cid = State.get(id), P.citizenId(src)
        local ok, err = available(property)
        if not ok then return false, err end
        if property.revision ~= revision or type(payload) ~= 'table' then return false, 'Refresh the property before creating a listing.' end
        local channel = payload.channel
        local policy = Config.saleCommissions[channel]
        if not policy or not Housing.finite(policy.society) or not Housing.finite(policy.agent) or policy.society < 0 or policy.agent < 0 or policy.society + policy.agent > 1 or not D.amount(payload.price) then return false, 'Choose a valid sale channel and whole asking price.' end
        if type(payload.biography) ~= 'string' or #payload.biography < 1 or #payload.biography > 4000 then return false, 'Provide a property biography of at most 4000 characters.' end
        if channel == 'private' then
            if not D.owner(property, cid) then return false, 'Only an owner can arrange a private sale.' end
        elseif not P.isRealtor(src) or property.owner and not D.owner(property, cid) and not D.agent(id, cid) then
            return false, 'An owner must authorize the listing agent.'
        end
        if channel ~= 'public' then
            local exists, targetErr = D.character(payload.buyer)
            if not exists then return false, targetErr end
            if D.owner(property, payload.buyer) then return false, 'An existing owner cannot buy this property.' end
        end
        local listingId = D.id()
        if not listingId then return false, 'Listing storage is unavailable.' end
        local listing = { id = listingId, property_id = id, channel = channel, seller = property.owner,
            agent = channel ~= 'private' and cid or nil, buyer = channel ~= 'public' and payload.buyer or nil,
            biography = payload.biography, price = payload.price, commission_policy = Housing.copy(policy), policy_version = Config.salePolicyVersion, status = 'active', ownership_revision = property.ownershipRevision, created_at = os.time() }
        local writes = {
            { query = [[INSERT INTO `qbhousing_listings` (`id`,`property_id`,`channel`,`seller`,`agent`,`buyer`,`biography`,`price`,`status`,`ownership_revision`,`created_at`,`commission_policy`,`policy_version`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)]],
                values = { listing.id, id, channel, listing.seller or QB.sql.NULL, listing.agent or QB.sql.NULL, listing.buyer or QB.sql.NULL, listing.biography, listing.price, 'active', listing.ownership_revision, listing.created_at, json.encode(policy), Config.salePolicyVersion } },
        }
        if listing.buyer then
            local offerId = D.id()
            if not offerId then return false, 'Offer storage is unavailable.' end
            writes[#writes + 1] = { query = 'INSERT INTO `qbhousing_offers` (`id`,`listing_id`,`buyer`,`amount`,`status`,`created_at`) VALUES (?,?,?,?,?,?)', values = { offerId, listingId, listing.buyer, listing.price, 'submitted', os.time() } }
        end
        local changed = Housing.copy(property)
        changed.state, changed.pending = 'listed', nil
        changed.listing = { id = listingId, type = channel == 'public' and 'open_market' or 'direct', price = payload.price, realtor = listing.agent, biography = payload.biography }
        local saved, saveErr = State.persist(changed, { actor = cid, action = 'listing.create' }, writes)
        if not saved then return false, saveErr or 'This property already has an active listing.' end
        return true, listing
    end)
end

function S.submitOffer(src, listingId, amount)
    local listing = getListing(listingId)
    if not listing then return false, 'Listing was not found.' end
    return D.lock(listing.property_id, function()
        local cid, property = P.citizenId(src), State.get(listing.property_id)
        local current = getListing(listingId)
        if not current or current.status ~= 'active' or not available(property) then return false, 'This listing is unavailable.' end
        if not cid or D.owner(property, cid) or current.buyer and current.buyer ~= cid then return false, 'You cannot offer on this listing.' end
        if not D.amount(amount) then return false, 'Offer a positive whole amount.' end
        local id = D.id()
        if not id then return false, 'Offer storage is unavailable.' end
        local ok, err = D.sql({
            { query = 'INSERT INTO `qbhousing_offers` (`id`,`listing_id`,`buyer`,`amount`,`status`,`created_at`) VALUES (?,?,?,?,?,?)', values = { id, listingId, cid, amount, 'submitted', os.time() } },
            { query = 'INSERT INTO `qbhousing_offer_history` (`offer_id`,`actor`,`action`,`created_at`) VALUES (?,?,?,?)', values = { id, cid, 'submitted', os.time() } },
        })
        return ok, ok and { id = id, amount = amount, status = 'submitted' } or err
    end)
end

function S.recommendOffer(src, offerId, note)
    local offer, listing = getOffer(offerId)
    if not offer then return false, listing end
    return D.lock(listing.property_id, function()
        offer, listing = getOffer(offerId)
        if not offer or listing.status ~= 'active' or listing.agent ~= P.citizenId(src) or not P.isRealtor(src) then return false, 'Only the assigned agent can recommend this offer.' end
        if offer.status ~= 'submitted' or type(note) ~= 'string' or #note < 1 or #note > 2000 then return false, 'Provide a recommendation for a submitted offer.' end
        local ok, err = D.sql({
            { query = 'UPDATE `qbhousing_offers` SET `recommendation`=? WHERE `id`=? AND `status`=?', values = { note, offerId, 'submitted' } },
            { query = 'INSERT INTO `qbhousing_offer_history` (`offer_id`,`actor`,`action`,`note`,`created_at`) VALUES (?,?,?,?,?)', values = { offerId, P.citizenId(src), 'recommended', note, os.time() } },
        })
        return ok, ok and true or err
    end)
end

function S.decideOffer(src, offerId, decision)
    local offer, listing = getOffer(offerId)
    if not offer then return false, listing end
    return D.lock(listing.property_id, function()
        local property, cid = State.get(listing.property_id), P.citizenId(src)
        offer, listing = getOffer(offerId)
        if not offer or listing.status ~= 'active' or not seller(src, property, listing) then return false, 'Only the seller can decide this offer.' end
        if listing.ownership_revision ~= property.ownershipRevision then return false, 'Ownership changed; publish a new listing.' end
        if offer.status ~= 'submitted' and offer.status ~= 'accepted' then return false, 'This offer has already been decided.' end
        if decision ~= 'accept' and decision ~= 'reject' then return false, 'Choose accept or reject.' end
        if decision == 'accept' and listing.agent and (not offer.recommendation or offer.recommendation == '') then return false, 'The agent must first provide a recommendation.' end
        local ok, err = D.sql({
            { query = 'UPDATE `qbhousing_offers` SET `status`=? WHERE `id`=?', values = { decision == 'accept' and 'accepted' or 'rejected', offerId } },
            { query = 'INSERT INTO `qbhousing_sale_approvals` (`offer_id`,`citizenid`,`ownership_revision`,`approved`) VALUES (?,?,?,?) ON DUPLICATE KEY UPDATE `ownership_revision`=VALUES(`ownership_revision`),`approved`=VALUES(`approved`)', values = { offerId, cid, property.ownershipRevision, decision == 'accept' and 1 or 0 } },
            { query = 'INSERT INTO `qbhousing_offer_history` (`offer_id`,`actor`,`action`,`created_at`) VALUES (?,?,?,?)', values = { offerId, cid, decision, os.time() } },
        })
        return ok, ok and true or err
    end)
end

function S.approveSale(src, offerId, approved)
    if type(approved) ~= 'boolean' then return false, 'Approval must be accepted or rejected.' end
    return S.decideOffer(src, offerId, approved and 'accept' or 'reject')
end

function S.completeSale(src, offerId)
    local offer, listing = getOffer(offerId)
    if not offer then return false, listing end
    local cid = P.citizenId(src)
    if offer.buyer ~= cid then return false, 'Only the selected buyer can complete this sale.' end
    if offer.status == 'completed' then return true, State.publicProperty(State.get(listing.property_id)) end
    return D.lock(listing.property_id, function()
        offer, listing = getOffer(offerId)
        local property = State.get(listing.property_id)
        if not offer or offer.status ~= 'accepted' or listing.status ~= 'active' or not available(property) then return false, 'The sale is not ready.' end
        if D.owner(property, cid) or property.ownershipRevision ~= listing.ownership_revision then return false, 'Ownership changed; this approval is stale.' end
        local approvals, err = QB.sql.query('SELECT * FROM `qbhousing_sale_approvals` WHERE `offer_id`=?', { offerId })
        if not approvals then return false, err end
        local approved = {}
        for _, row in ipairs(approvals) do if tonumber(row.approved) == 1 and row.ownership_revision == property.ownershipRevision then approved[row.citizenid] = true end end
        for _, owner in ipairs(D.owners(property)) do if not approved[owner] then return false, 'Every owner must approve the exact sale.' end end
        if not property.owner and not approved[listing.agent] then return false, 'The listing agent must approve the initial sale.' end
        local frozen, freezeErr = Housing.storage.freezeForSale(property.id)
        if not frozen then return false, freezeErr end
        local policy = type(listing.commission_policy) == 'string' and json.decode(listing.commission_policy) or listing.commission_policy or Config.saleCommissions[listing.channel]
        if not policy or not Housing.finite(policy.society) or not Housing.finite(policy.agent) or policy.society < 0 or policy.agent < 0 or policy.society + policy.agent > 1 then Housing.storage.unfreeze(property.id); return false, 'Sale commission settings are invalid.' end
        local society, agent = math.floor(offer.amount * policy.society), math.floor(offer.amount * policy.agent)
        local credits = D.split(property, offer.amount - society - agent)
        if society > 0 then credits[#credits + 1] = { account = Config.societyAccount, amount = society } end
        if agent > 0 then credits[#credits + 1] = { citizenid = listing.agent, amount = agent } end
        local changed = Housing.copy(property)
        changed.owner, changed.coowners, changed.keys, changed.permissionGrants = cid, {}, {}, {}
        changed.state, changed.pending, changed.soldAt, changed.soldPrice = 'owned', nil, os.time(), offer.amount
        local writes = {
            { query = 'UPDATE `qbhousing_offers` SET `status`=? WHERE `id`=? AND `status`=?', values = { 'completed', offerId, 'accepted' }, expectedRows = 1 },
            { query = 'UPDATE `qbhousing_offers` SET `status`=? WHERE `listing_id`=? AND `id`<>? AND `status` IN (?,?)', values = { 'superseded', listing.id, offerId, 'submitted', 'accepted' } },
            { query = 'UPDATE `qbhousing_listings` SET `status`=? WHERE `id`=? AND `status`=?', values = { 'completed', listing.id, 'active' }, expectedRows = 1 },
            { query = 'DELETE FROM `qbhousing_agents` WHERE `property_id`=?', values = { property.id } },
        }
        for _, owner in ipairs(D.owners(property)) do writes[#writes + 1] = { query = 'INSERT IGNORE INTO `qbhousing_garage_recovery` (`property_id`,`citizenid`) VALUES (?,?)', values = { property.id, owner } } end
        if Housing.world.ownershipStatements then for _, statement in ipairs(Housing.world.ownershipStatements(property.id, cid)) do writes[#writes + 1] = statement end end
        writes[#writes + 1] = { query = 'INSERT INTO `qbhousing_offer_history` (`offer_id`,`actor`,`action`,`created_at`) VALUES (?,?,?,?)', values = { offerId, cid, 'completed', os.time() } }
        local key, keyErr = Housing.transactions.nextKey('sale:' .. offerId)
        if not key then Housing.storage.unfreeze(property.id); return false, keyErr end
        local ok, result, code = Housing.transactions.run(key, 'sale', cid, changed, { { citizenid = cid, amount = offer.amount } }, credits, writes)
        if ok then D.agents[property.id] = nil end
        if code ~= 'pending' then Housing.storage.unfreeze(property.id) end
        return ok, ok and State.publicProperty(State.get(property.id)) or result
    end)
end

function S.cancelListing(src, id)
    local listing = getListing(id)
    if not listing then return false, 'Listing was not found.' end
    return D.lock(listing.property_id, function()
        listing = getListing(id)
        if not listing or listing.status ~= 'active' then return false, 'This listing is no longer active.' end
        local property = State.get(listing.property_id)
        if not seller(src, property, listing) and listing.agent ~= P.citizenId(src) then return false, 'You cannot cancel this listing.' end
        local changed = Housing.copy(property)
        changed.state, changed.pending = property.owner and 'owned' or 'unowned', nil
        local saved, err = State.persist(changed, { actor = P.citizenId(src), action = 'listing.cancel' }, {
            { query = 'UPDATE `qbhousing_listings` SET `status`=? WHERE `id`=?', values = { 'cancelled', id } },
            { query = 'UPDATE `qbhousing_offers` SET `status`=? WHERE `listing_id`=? AND `status` IN (?,?)', values = { 'cancelled', id, 'submitted', 'accepted' } },
        })
        return saved ~= nil, saved or err
    end)
end

function S.catalog()
    local rows, err = QB.sql.query('SELECT * FROM `qbhousing_listings` WHERE `status`=? AND `channel`=? ORDER BY `created_at` DESC LIMIT 200', { 'active', 'public' })
    if not rows then return nil, err end
    local result = {}
    for _, listing in ipairs(rows) do
        local property = State.get(listing.property_id)
        if property and property.state ~= 'archived' then
            local copy = State.publicProperty(property)
            copy.listing = { id = listing.id, price = listing.price, biography = listing.biography, realtor = listing.agent, type = 'open_market' }
            result[#result + 1] = copy
        end
    end
    return result
end

function S.view(src, id)
    local cid, property = P.citizenId(src), State.get(id)
    local management = D.owner(property, cid) or P.isAdmin(src) or P.isRealtor(src) and (not property.owner or D.agent(id, cid))
    local listings = QB.sql.query('SELECT * FROM `qbhousing_listings` WHERE `property_id`=? ORDER BY `created_at` DESC LIMIT 100', { id }) or {}
    local result = { agents = management and Housing.copy(D.agents[id] or {}) or {}, listings = {}, offers = {} }
    for _, listing in ipairs(listings) do
        if management or listing.channel == 'public' or listing.buyer == cid then
            result.listings[#result.listings + 1] = listing
            local query = 'SELECT * FROM `qbhousing_offers` WHERE `listing_id`=?'
            local params = { listing.id }
            if not management then query = query .. ' AND `buyer`=?'; params[#params + 1] = cid end
            local offers = QB.sql.query(query .. ' ORDER BY `created_at` DESC LIMIT 100', params) or {}
            for _, offer in ipairs(offers) do
                offer.approvals = QB.sql.query('SELECT `citizenid`,`approved`,`ownership_revision` FROM `qbhousing_sale_approvals` WHERE `offer_id`=?', { offer.id }) or {}
                offer.property_id, offer.agent, offer.channel = id, listing.agent, listing.channel
                offer.history = QB.sql.query('SELECT `actor`,`action`,`note`,`created_at` FROM `qbhousing_offer_history` WHERE `offer_id`=? ORDER BY `id`', { offer.id }) or {}
                offer.settlementSummary = S.summary(property, listing, offer.amount)
                result.offers[#result.offers + 1] = offer
            end
        end
    end
    return result
end

function S.summary(property, listing, amount)
    local policy = type(listing.commission_policy) == 'string' and json.decode(listing.commission_policy) or listing.commission_policy or Config.saleCommissions[listing.channel]
    if not policy then return 'Commission policy is unavailable.' end
    local society, agent = math.floor(amount * policy.society), math.floor(amount * policy.agent)
    local pieces = { ('$%d total · $%d society · $%d agent'):format(amount, society, agent) }
    for _, leg in ipairs(D.split(property, amount - society - agent)) do pieces[#pieces + 1] = ('$%d to %s'):format(leg.amount, leg.citizenid or leg.account) end
    return table.concat(pieces, ' · ')
end

function S.importLegacy()
    for id, property in pairs(State.properties) do
        if property.state == 'listed' and property.listing and D.amount(property.listing.price) then
            local existing, err = QB.sql.single('SELECT `id` FROM `qbhousing_listings` WHERE `property_id`=? LIMIT 1', { id })
            if err then return false, err end
            if not existing then
                local listingId = D.id()
                if not listingId then return false, 'Legacy listing import is unavailable.' end
                local direct = property.listing.type == 'direct'
                local buyer = direct and property.pending and property.pending.buyer
                local agent = property.listing.realtor
                local status = agent and (not direct or buyer) and 'active' or 'legacy'
                local writes = { { query = 'INSERT INTO `qbhousing_listings` (`id`,`property_id`,`channel`,`seller`,`agent`,`buyer`,`biography`,`price`,`status`,`ownership_revision`,`created_at`,`commission_policy`,`policy_version`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
                    values = { listingId, id, direct and 'off_market' or 'public', property.owner or QB.sql.NULL, agent or QB.sql.NULL, buyer or QB.sql.NULL, property.label, property.listing.price, status, property.ownershipRevision, os.time(), json.encode(Config.saleCommissions[direct and 'off_market' or 'public']), Config.salePolicyVersion } }, D.audit(id, nil, 'listing.import', { status = status }) }
                if agent and property.owner then writes[#writes + 1] = { query = 'INSERT IGNORE INTO `qbhousing_agents` (`property_id`,`citizenid`) VALUES (?,?)', values = { id, agent } } end
                if buyer and status == 'active' then
                    local offerId = D.id()
                    if not offerId then return false, 'Legacy offer import is unavailable.' end
                    writes[#writes + 1] = { query = 'INSERT INTO `qbhousing_offers` (`id`,`listing_id`,`buyer`,`amount`,`status`,`created_at`) VALUES (?,?,?,?,?,?)', values = { offerId, listingId, buyer, property.listing.price, 'submitted', os.time() } }
                end
                local ok, writeErr = D.sql(writes)
                if not ok then return false, writeErr end
            end
        end
    end
    return true
end
