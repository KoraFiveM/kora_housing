Housing.gameplay = {}
local Gameplay = Housing.gameplay
local snapshot = {}
local activePlacement
local lifecycle = 0

local function field(id, label, kind, default, settings)
    local value = { id = id, label = label, type = kind, default = default }
    for key, item in pairs(settings or {}) do value[key] = item end
    return value
end
local function number(id, label, default, zero) return field(id, label, 'number', default, { required = true, min = zero and 0 or 1, max = 1000000000, wholeNumber = true }) end
local function citizen(id, label) return field(id or 'citizenid', label or 'Citizen ID', 'text', nil, { required = true, maxLength = 50 }) end
local function vector(id, label, default, required) return field(id, label, 'vector', default, { dimensions = 3, required = required ~= false }) end
local function money(value) return ('$%.0f'):format(tonumber(value) or 0) end
local function time(value) return tonumber(value) and os.date('%Y-%m-%d %H:%M', tonumber(value)) or tostring(value or '—') end
local function request(name, ...)
    local ok, result = QB.callback.trigger('qbhousing:' .. name, ...)
    if ok ~= true then return nil, result or 'Housing is unavailable.' end
    return result
end
local function capturePlacement(model, options)
    local ok, result = pcall(QB.placement.start, model, options)
    if not ok then return nil, tostring(result) end
    return result
end
local function result(ok, err)
    return { refresh = ok ~= nil, notice = { tone = ok ~= nil and 'success' or 'destructive', message = ok ~= nil and 'Saved.' or err or 'The operation failed.' } }
end
local function find(rows, id)
    for _, row in ipairs(rows or {}) do if tostring(row.id) == tostring(id) then return row end end
end
local function owners(view)
    return view.relationship == 'primary_owner' or view.relationship == 'coowner'
end
local function form(id, fields, action, label)
    return { type = 'form', id = id, fields = fields, action = { id = action, label = label } }
end
local function empty(title) return { type = 'empty', title = title } end
local function list(id, title, items)
    return #items > 0 and { type = 'list', id = id, title = title, items = items, searchable = true, pageSize = 10 } or empty('No ' .. title:lower())
end
local function actions(options, action, label, fields, confirm, close)
    options[#options + 1] = { id = action, label = label, fields = fields, confirm = confirm, closeBeforeAction = close }
end

local function offerItem(offer, propertyView)
    local buttons, cid = {}, snapshot.citizenid
    local market = propertyView and (propertyView.sales or propertyView.market) or {}
    local listing = find(market.listings, offer.listing_id)
    local isOwner = propertyView and owners(propertyView)
    local agent = offer.agent or listing and listing.agent
    if offer.status == 'submitted' then
        if agent == cid then actions(buttons, 'sales:recommend', 'Agent recommendation', { field('recommendation', 'Recommendation to the owners', 'textarea', offer.recommendation, { required = true, maxLength = 2000 }) }) end
        if isOwner or propertyView and not propertyView.property.owner and agent == cid then
            actions(buttons, 'sales:accept', 'Accept offer', nil, 'Accept these sale terms and record your approval?')
            actions(buttons, 'sales:reject', 'Reject offer', nil, 'Reject this offer?')
        end
    elseif offer.status == 'accepted' then
        if isOwner then
            actions(buttons, 'sales:approve', 'Approve sale', nil, 'Approve this exact buyer, price and payout? Every owner must approve.')
            actions(buttons, 'sales:reject', 'Reject sale', nil, 'Reject this sale and invalidate its approvals?')
        end
        if offer.buyer == cid then actions(buttons, 'sales:complete', 'Pay and complete purchase', nil, 'Pay ' .. money(offer.amount) .. ' from your bank and complete this property purchase?') end
    end
    if not propertyView then actions(buttons, 'inbox:offer', 'View property and sale terms', nil, nil, true) end
    local approvals = {}
    for _, approval in ipairs(offer.approvals or {}) do
        local current = not propertyView or tonumber(approval.ownership_revision) == tonumber(propertyView.property.ownershipRevision)
        approvals[#approvals + 1] = approval.citizenid .. ': ' .. (not current and 'Outdated' or tonumber(approval.approved) == 1 and 'Approved' or 'Rejected')
    end
    return { id = tostring(offer.id), label = money(offer.amount), badge = offer.status,
        description = offer.settlementSummary or offer.recommendation or offer.property_id or 'Property offer',
        metadata = { { label = 'Buyer', value = offer.buyer }, { label = 'Agent recommendation', value = offer.recommendation or 'Pending' },
            { label = 'Owner approvals', value = #approvals > 0 and table.concat(approvals, ' · ') or 'Pending' } }, actions = buttons }
end

local function salesTab(view)
    local property, market = view.property, view.sales or view.market or {}
    local blocks, options, listingItems, offerItems, history = {}, {}, {}, {}, {}
    if owners(view) then blocks[#blocks + 1] = form('agent:' .. property.id, { citizen() }, 'sales:agent', 'Authorize listing agent') end
    if (view.allowed or {})['sales.manage'] then
        if owners(view) then options[#options + 1] = { value = 'private', label = 'Direct private sale' } end
        if snapshot.realtor then options[#options + 1] = { value = 'public', label = 'Public agent listing' }; options[#options + 1] = { value = 'off_market', label = 'Agent off-market sale' } end
        if #options > 0 then blocks[#blocks + 1] = form('listing:' .. property.id, {
            field('channel', 'Sale channel', 'select', options[1].value, { required = true, options = options }), number('price', 'Asking price', property.listing and property.listing.price),
            field('biography', 'Property biography', 'textarea', nil, { required = true, maxLength = 4000 }),
            field('buyer', 'Buyer citizen ID (private and off-market sales)', 'text', nil, { maxLength = 50 }),
        }, 'sales:create', 'Create listing') end
    end
    for _, listing in ipairs(market.listings or {}) do
        local buttons = {}
        if listing.status == 'active' and (owners(view) or listing.agent == snapshot.citizenid) then actions(buttons, 'sales:cancel', 'Cancel listing', nil, 'Cancel this listing and its unfinished offers?') end
        if listing.status == 'active' and not owners(view) and (not listing.buyer or listing.buyer == snapshot.citizenid) then actions(buttons, 'sales:submit', 'Submit offer', { number('amount', 'Your offer', listing.price) }) end
        listingItems[#listingItems + 1] = { id = tostring(listing.id), label = money(listing.price), description = listing.biography, badge = listing.status, metadata = { { label = 'Channel', value = listing.channel } }, actions = buttons }
    end
    for _, offer in ipairs(market.offers or {}) do
        offerItems[#offerItems + 1] = offerItem(offer, view)
        for _, row in ipairs(offer.history or {}) do history[#history + 1] = { offer = tostring(offer.id), actor = row.actor, action = row.action, note = row.note or '', time = time(row.created_at) } end
    end
    blocks[#blocks + 1] = list('listings', 'Listings', listingItems)
    blocks[#blocks + 1] = list('offers', 'Offers and approvals', offerItems)
    blocks[#blocks + 1] = { type = 'table', title = 'Offer decision history', columns = { { key = 'offer', label = 'Offer' }, { key = 'actor', label = 'Character' },
        { key = 'action', label = 'Decision' }, { key = 'note', label = 'Note' }, { key = 'time', label = 'Time' } }, rows = history, searchable = true, pageSize = 10 }
    return { id = 'sales', label = 'Sales', content = { title = 'Property sales', description = 'All owners approve the same terms. Payment and ownership complete together after those approvals.', blocks = blocks } }
end

local function leaseItem(lease, propertyView)
    local buttons = {}
    if lease.status == 'proposed' then
        if lease.tenant == snapshot.citizenid then actions(buttons, 'lease:accept', 'Accept and pay first rent', nil, 'Pay the first rent of ' .. money(lease.rent) .. ' plus deposit of ' .. money(lease.deposit) .. ' and accept this rolling ' .. lease.interval_name .. ' lease?') end
        actions(buttons, 'lease:end', 'Cancel proposal', nil, 'Cancel this unaccepted lease proposal?')
    elseif lease.status == 'active' or lease.status == 'ending' then actions(buttons, 'lease:end', 'Request end of lease', nil, 'Request termination at the end of the current paid period?') end
    if not propertyView then actions(buttons, 'inbox:lease', 'View property and agreement', nil, nil, true) end
    local permissions = {}
    for action, allowed in pairs(type(lease.permissions) == 'table' and lease.permissions or {}) do
        if allowed then permissions[#permissions + 1] = (snapshot.actions[action] or {}).label or action end
    end
    table.sort(permissions)
    local held = lease.status == 'proposed' and lease.deposit or lease.deposit_remaining or lease.deposit
    return { id = tostring(lease.id), label = money(lease.rent) .. ' / ' .. lease.interval_name, badge = lease.status,
        description = lease.property_id .. ' · Rolling lease; termination takes effect after the paid period. Deposit review lasts ' .. tostring(Config.depositReviewSeconds / 3600) .. ' hours after the lease ends; disputed amounts remain held.',
        metadata = { { label = 'Tenant', value = lease.tenant }, { label = 'Paid through', value = time(lease.paid_through) }, { label = 'Next rent', value = time(lease.next_due) },
            { label = lease.status == 'proposed' and 'Deposit due on acceptance' or 'Deposit held', value = money(held) }, { label = 'Tenant permissions', value = #permissions > 0 and table.concat(permissions, ', ') or 'None' } }, actions = buttons }
end

local function rentalTab(view)
    local property, leases = view.property, view.lease or {}
    local blocks, history, deductions = {}, {}, {}
    if (view.allowed or {})['lease.manage'] and owners(view) and not leases.active then
        local options, defaults = {}, {}
        for action, definition in pairs(snapshot.actions or {}) do
            if definition.grantable and action ~= 'camera.view' and action ~= 'camera.manage' then options[#options + 1] = { value = action, label = definition.label } end
        end
        table.sort(options, function(a, b) return a.label < b.label end)
        for action, enabled in pairs(Config.tenantPermissions) do if enabled then defaults[#defaults + 1] = action end end
        blocks[#blocks + 1] = form('lease:' .. property.id, { citizen('tenant', 'Tenant citizen ID'),
            field('interval', 'Billing interval', 'select', 'weekly', { required = true, options = { { value = 'daily', label = 'Daily' }, { value = 'weekly', label = 'Weekly' } } }),
            number('rent', 'Rent per period'), number('deposit', 'Refundable deposit', 0, true),
            field('permissions', 'Tenant permissions', 'multiselect', defaults, { options = options, searchable = true }),
        }, 'lease:propose', 'Propose lease')
    end
    for _, lease in ipairs(leases.history or {}) do history[#history + 1] = leaseItem(lease, view) end
    if leases.active and leases.active.tenant == snapshot.citizenid then
        local permitted = {}
        for _, action in ipairs({ 'entry', 'stash.open', 'furniture.place', 'furniture.move', 'furniture.remove', 'garage.list', 'garage.store', 'garage.retrieve' }) do
            permitted[#permitted + 1] = { value = action, label = (snapshot.actions[action] or {}).label or action }
        end
        blocks[#blocks + 1] = form('lease-access:' .. property.id, { citizen(), field('action', 'Physical action', 'select', 'entry', { options = permitted, required = true }),
            field('decision', 'Permission', 'select', 'allow', { required = true, options = { { value = 'allow', label = 'Allow' }, { value = 'deny', label = 'Deny' }, { value = 'remove', label = 'Remove individual override' } } }),
        }, 'lease:access', 'Update occupancy access')
    end
    local leaseOptions = {}
    for _, lease in ipairs(leases.history or {}) do if (tonumber(lease.deposit_remaining) or 0) > 0 then leaseOptions[#leaseOptions + 1] = { value = tostring(lease.id), label = lease.tenant .. ' · ' .. lease.status } end end
    if owners(view) and #leaseOptions > 0 then blocks[#blocks + 1] = form('deduction:' .. property.id, {
        field('leaseId', 'Lease', 'select', nil, { required = true, options = leaseOptions }), field('category', 'Deduction category', 'select', 'damage', { required = true, options = { { value = 'damage', label = 'Documented damage' }, { value = 'unpaid_rent', label = 'Unpaid rent' } } }),
        number('amount', 'Proposed amount'), field('note', 'Evidence and explanation', 'textarea', nil, { required = true, maxLength = 2000 }),
    }, 'lease:deduct', 'Propose deposit deduction') end
    for _, deduction in ipairs(leases.deductions or {}) do
        local buttons, lease = {}, find(leases.history, deduction.lease_id)
        if deduction.status == 'proposed' and lease and lease.tenant == snapshot.citizenid then
            actions(buttons, 'lease:deduction-accept', 'Accept deduction', nil, 'Accept this deposit deduction?')
            actions(buttons, 'lease:deduction-dispute', 'Dispute deduction', nil, 'Dispute this amount and keep it protected pending resolution?')
        end
        if snapshot.admin and (deduction.status == 'proposed' or deduction.status == 'disputed') then actions(buttons, 'lease:deduction-resolve', 'Resolve deduction', { number('amount', 'Approved amount', deduction.amount, true), field('note', 'Resolution reason', 'textarea', nil, { required = true, maxLength = 2000 }) }) end
        deductions[#deductions + 1] = { id = tostring(deduction.id), label = money(deduction.amount) .. ' · ' .. deduction.category, description = deduction.note, badge = deduction.status, actions = buttons }
    end
    blocks[#blocks + 1] = list('leases', 'Lease history', history)
    blocks[#blocks + 1] = { type = 'table', title = 'Rent periods', columns = { { key = 'period_start', label = 'Period start' }, { key = 'amount', label = 'Rent' }, { key = 'status', label = 'Status' } }, rows = leases.payments or {}, searchable = true, pageSize = 10 }
    blocks[#blocks + 1] = list('deductions', 'Deposit deductions', deductions)
    return { id = 'rental', label = 'Rental', content = { title = 'Lease and payments', description = 'First rent is due on acceptance. Deposits are held separately; disputes remain protected. Times shown use your local clock.', blocks = blocks } }
end

local function storageTab(view)
    local storage, property, buttons, blocks = view.storage or {}, view.property, {}, {}
    local allowed = view.allowed or {}
    if allowed['stash.open'] then actions(buttons, 'storage:open', 'Open property storage', nil, nil, true) end
    if allowed['garage.list'] and property.garage then actions(buttons, 'storage:garage', 'Open garage', nil, nil, true) end
    local tier = type(storage.tier) == 'number' and storage.tier or 1
    local current, nextTier = Config.storageTiers[tier], Config.storageTiers[tier + 1]
    if current then blocks[#blocks + 1] = { type = 'details', items = { { label = 'Storage tier', value = current.label }, { label = 'Slots', value = current.slots }, { label = 'Maximum weight', value = current.maxWeight } } } end
    if nextTier and allowed['storage.upgrade'] then actions(buttons, 'storage:upgrade', 'Upgrade to ' .. nextTier.label .. ' · ' .. money(nextTier.price), nil, 'This upgrade stays with the property after sale or tenancy. No automatic refund is available. Pay ' .. money(nextTier.price) .. '?') end
    if allowed['property.edit'] then blocks[#blocks + 1] = form('stash:' .. property.id, { vector('coords', 'Storage fixture position', storage.coords) }, 'storage:configure', 'Save storage fixture') end
    blocks[#blocks + 1] = { type = 'actions', actions = buttons }
    return { id = 'storage', label = 'Storage & garage', content = { title = 'Property storage and vehicles', blocks = blocks } }
end

local function worldTab(view)
    local property, world, allowed = view.property, view.world or {}, view.allowed or {}
    local blocks, furniture, cameras, controls = {}, {}, {}, {}
    if allowed['property.edit'] then
        local fields = {}
        if property.interior and property.interior.type == 'shell' then fields[1] = vector('origin', 'Shared shell origin', world.space and world.space.origin) end
        actions(controls, 'world:space', 'Configure physical space', fields, nil, true)
        local doorIds = {}
        for _, door in pairs(property.doorlocks or {}) do doorIds[#doorIds + 1] = tostring(type(door) == 'table' and door.id or door) end
        blocks[#blocks + 1] = form('doors:' .. property.id, { field('doorIds', 'Existing door IDs, separated by commas', 'text', table.concat(doorIds, ', ')) }, 'world:doors', 'Save protected door links')
    end
    if world.space then
        if allowed['furniture.place'] then
            local models = {}
            for name, definition in pairs(world.models or Config.furnitureModels) do models[#models + 1] = { value = name, label = definition.label } end
            actions(controls, 'world:furniture-place', 'Place furniture', { field('model', 'Furniture', 'select', nil, { required = true, options = models, searchable = true }) }, nil, true)
        end
        for _, item in ipairs(world.furniture or {}) do
            local options = {}
            if allowed['furniture.move'] then actions(options, 'world:furniture-move', 'Move', nil, nil, true) end
            if allowed['furniture.remove'] then actions(options, 'world:furniture-remove', 'Remove', nil, 'Remove this furniture placement?') end
            furniture[#furniture + 1] = { id = item.id, label = (Config.furnitureModels[item.model] or {}).label or item.model, description = item.ownerCid, actions = options }
        end
        if allowed['camera.manage'] then
            actions(controls, 'world:camera-new', 'Place security camera', { field('label', 'Camera name', 'text', nil, { required = true, maxLength = 80 }),
                number('fov', 'Field of view (20–100)', 60), vector('console', 'Physical security console position') }, nil, true)
        end
        for _, camera in ipairs(world.cameras or {}) do
            local options = {}
            if allowed['camera.view'] then actions(options, 'world:camera-view', 'View from console', nil, nil, true) end
            if allowed['camera.manage'] then
                actions(options, 'world:camera-edit', 'Edit camera', { field('label', 'Camera name', 'text', camera.label, { required = true, maxLength = 80 }), number('fov', 'Field of view (20–100)', camera.fov), vector('console', 'Physical security console position', camera.console) }, nil, true)
                actions(options, 'world:camera-remove', 'Remove camera', nil, 'Remove this security camera?')
            end
            cameras[#cameras + 1] = { id = camera.id, label = camera.label, description = ('Field of view: %s°'):format(camera.fov), actions = options }
        end
    end
    blocks[#blocks + 1] = { type = 'actions', actions = controls }
    blocks[#blocks + 1] = list('furniture', 'Furniture', furniture)
    blocks[#blocks + 1] = list('cameras', 'Security cameras', cameras)
    if allowed['camera.manage'] and owners(view) then
        blocks[#blocks + 1] = form('camera-grant:' .. property.id, { citizen() }, 'world:camera-grant', ('Authorize viewing for %s hours'):format(Config.cameraGrantSeconds / 3600))
        local grants = {}
        for _, grant in ipairs(world.grants or {}) do grants[#grants + 1] = { id = grant.citizenid, label = grant.citizenid, description = 'Expires ' .. time(grant.expiresAt), actions = { { id = 'world:camera-revoke', label = 'Revoke', confirm = 'Revoke this authorization and close active views?' } } } end
        blocks[#blocks + 1] = list('camera-grants', 'Camera viewing grants', grants)
    end
    local alarm = world.alarm or { armed = false, revision = 0, doorUnlock = true, panic = true, cooldown = Config.alarmCooldown }
    if allowed['alarm.arm'] then blocks[#blocks + 1] = { type = 'actions', title = 'Alarm', actions = {
        { id = 'world:alarm-toggle', label = alarm.armed and 'Disarm alarm' or 'Arm alarm', state = alarm.armed },
        { id = 'world:panic', label = 'Send panic alarm', confirm = 'Send a property panic alarm to the police?' },
    } } end
    if allowed['alarm.configure'] then blocks[#blocks + 1] = form('alarm:' .. property.id, {
        field('doorUnlock', 'Alarm on unauthorized mapped-door unlock', 'checkbox', alarm.doorUnlock), field('panic', 'Enable panic alarm', 'checkbox', alarm.panic), number('cooldown', 'Alert cooldown (seconds)', alarm.cooldown),
    }, 'world:alarm-configure', 'Save alarm settings') end
    return { id = 'world', label = 'Furniture & security', content = { title = 'Shared physical space', description = 'Furniture belongs to this physical space and is visible to everyone nearby. Camera viewing requires the nearby physical console and a valid authorization.', blocks = blocks } }
end

function Gameplay.tabs(view)
    return { salesTab(view), rentalTab(view), storageTab(view), worldTab(view) }
end

function Gameplay.navigation(data)
    snapshot = data or {}
    local inbox, offers, leases, recovery = snapshot.inbox or {}, {}, {}, {}
    for _, offer in ipairs(inbox.offers or {}) do offers[#offers + 1] = offerItem(offer) end
    for _, lease in ipairs(inbox.leases or {}) do leases[#leases + 1] = leaseItem(lease) end
    local targetOptions = {}
    for _, property in ipairs(snapshot.properties or {}) do targetOptions[#targetOptions + 1] = { value = property.id, label = property.label or property.id } end
    for _, item in ipairs(inbox.recoveries or {}) do
        local buttons = {}
        if item.kind == 'garage' then actions(buttons, 'recovery:garage', 'Retrieve owned vehicles', nil, nil, true)
        elseif item.kind == 'furniture' or item.model then actions(buttons, 'recovery:furniture', 'Place recovered furniture', { field('propertyId', 'Destination property', 'select', nil, { required = true, options = targetOptions }) }, nil, true)
        else actions(buttons, 'recovery:claim', 'Collect recovered items', nil, nil, true) end
        recovery[#recovery + 1] = { id = tostring(item.id), label = item.label or item.model or 'Protected belongings', description = item.property_id or item.propertyId, actions = buttons }
    end
    local views = {
        { id = 'inbox', label = 'Offers & agreements', icon = 'Inbox', content = { title = 'Your offers and leases', blocks = { list('inbox-offers', 'Offers', offers), list('inbox-leases', 'Leases', leases),
            { type = 'table', title = 'Transaction status', columns = { { key = 'kind', label = 'Operation' }, { key = 'status', label = 'Status' }, { key = 'property_id', label = 'Property' } }, rows = inbox.transactions or {}, searchable = true, pageSize = 10 },
        } } },
        { id = 'recovery', label = 'Recovery', icon = 'PackageOpen', content = { title = 'Protected belongings', description = 'Belongings remain protected until claimed. Shared owner storage is collected by the first original owner who claims it. Vehicle ownership remains with its existing owner.', blocks = { list('recovery', 'Recovery entitlements', recovery) } } },
    }
    if snapshot.admin then views[#views + 1] = { id = 'administration', label = 'Administration', icon = 'Shield', content = { title = 'Housing administration', blocks = {
        form('admin-audit', { field('propertyId', 'Property ID', 'text', nil, { required = true, maxLength = 64 }) }, 'admin:audit', 'View audit history'),
        form('admin-archive', { field('propertyId', 'Property ID', 'text', nil, { required = true, maxLength = 64 }) }, 'admin:archive', 'Review archival'),
    } } } end
    return views
end

local function reopen(id, tab) Housing.app.refreshProperty(id, tab) end
local function worldFlow(view, action, values, itemId)
    local property, world = view.property, view.world or {}
    local started = lifecycle
    CreateThread(function()
        local ok, err
        if action == 'world:space' then
            local captured = QB.zones.startCreator('poly', world.space and world.space.bounds)
            if captured and captured.opts then
                local options, minZ = captured.opts, math.huge
                for _, point in ipairs(captured.opts.points) do minZ = math.min(minZ, point.z) end
                ok, err = request('configureSpace', property.id, { origin = values.origin, bounds = { points = options.points, minZ = options.minZ or minZ, maxZ = options.maxZ or minZ + options.thickness } }, world.space and world.space.revision or 0)
            end
        elseif action == 'world:furniture-place' or action == 'world:furniture-move' then
            local existing = find(world.furniture, itemId)
            local session; session, err = request('beginPlacement', property.id, existing and existing.model or values.model, existing and existing.id)
            if session then
                if lifecycle ~= started then return end
                activePlacement = { token = session.token, propertyId = property.id }
                local placement, placementErr = capturePlacement(session.model, { coords = session.transform.coords, rotation = session.transform.rotation, bounds = session.bounds, numericInput = true, raycast = existing == nil, copy = false })
                err = placementErr or err
                activePlacement = nil
                if lifecycle ~= started then return end
                if placement then ok, err = request('savePlacement', property.id, session.token, placement, session.revision) end
            end
        elseif action == 'world:camera-new' or action == 'world:camera-edit' then
            local existing = find(world.cameras, itemId)
            activePlacement = { propertyId = property.id }
            local placement, placementErr = capturePlacement(Config.cameraModel, { coords = existing and existing.coords, rotation = existing and existing.rotation, bounds = world.space.bounds, numericInput = true, raycast = existing == nil, copy = false })
            activePlacement, err = nil, placementErr
            if lifecycle ~= started then return end
            if placement then
                values.id, values.coords, values.rotation, values.heading = existing and existing.id, placement.coords, placement.rotation, placement.heading
                ok, err = request('saveCamera', property.id, values, existing and existing.revision)
            end
        elseif action == 'world:camera-view' then
            local camera; camera, err = request('openCamera', property.id, itemId)
            if camera then Housing.scene.viewCamera(camera); return end
        end
        if lifecycle ~= started then return end
        if err then QB.notify.send({ title = 'Housing', message = err, type = 'error' }) end
        reopen(property.id, 'world')
    end)
end

RegisterNetEvent('qbhousing:client:placementClosed', function(token, propertyId, reason)
    if not activePlacement or activePlacement.token ~= token or activePlacement.propertyId ~= propertyId then return end
    QB.placement.cancel()
    if reason then QB.notify.send({ title = 'Housing', message = reason, type = 'error' }) end
end)

local function clearPlacement()
    lifecycle = lifecycle + 1
    if activePlacement then pcall(QB.placement.cancel); activePlacement = nil end
end
AddEventHandler('QBCore:Client:OnPlayerUnload', clearPlacement)
AddEventHandler('onClientResourceStop', function(resource) if resource == GetCurrentResourceName() then clearPlacement() end end)

function Gameplay.action(action, context, view)
    local values = type(context.value) == 'table' and context.value or {}
    local id, itemId = view and view.property.id, context.itemId
    if action == 'inbox:offer' or action == 'inbox:lease' then
        local row = find((snapshot.inbox or {})[action == 'inbox:offer' and 'offers' or 'leases'], itemId)
        if not row then return result(nil, 'This agreement changed. Refresh the inbox.') end
        Housing.app.refreshProperty(row.property_id, action == 'inbox:offer' and 'sales' or 'rental')
        return {}
    end
    if action == 'sales:submit' then return result(request('submitOffer', itemId, values.amount)) end
    if action == 'sales:agent' then return result(request('assignAgent', id, values.citizenid, view.property.revision)) end
    if action == 'sales:create' then return result(request('createListing', id, values, view.property.revision)) end
    if action == 'sales:cancel' then return result(request('cancelListing', itemId)) end
    if action == 'sales:recommend' then return result(request('recommendOffer', itemId, values.recommendation)) end
    if action == 'sales:accept' or action == 'sales:reject' then return result(request('decideOffer', itemId, action == 'sales:accept' and 'accept' or 'reject')) end
    if action == 'sales:approve' then return result(request('approveSale', itemId, true)) end
    if action == 'sales:complete' then return result(request('completeSale', itemId)) end
    if action == 'lease:propose' then
        local permissions = {}
        for actionId in pairs(Config.tenantPermissions) do permissions[actionId] = false end
        for _, actionId in ipairs(values.permissions or {}) do permissions[actionId] = true end
        values.permissions = permissions
        return result(request('proposeLease', id, values, view.property.revision))
    end
    if action == 'lease:accept' then return result(request('acceptLease', itemId)) end
    if action == 'lease:end' then return result(request('requestLeaseEnd', itemId)) end
    if action == 'lease:access' then
        local allowed
        if values.decision ~= 'remove' then allowed = values.decision == 'allow' end
        return result(request('leaseAccess', view.lease.active.id, values.citizenid, values.action, allowed))
    end
    if action == 'lease:deduct' then return result(request('proposeDeduction', values.leaseId, { category = values.category, amount = values.amount, note = values.note })) end
    if action == 'lease:deduction-accept' or action == 'lease:deduction-dispute' then return result(request('decideDeduction', itemId, action == 'lease:deduction-accept' and 'accept' or 'dispute')) end
    if action == 'lease:deduction-resolve' then return result(request('resolveDeduction', itemId, values.amount, values.note)) end
    if action == 'storage:open' then return result(request('openStash', id)) end
    if action == 'storage:configure' then return result(request('configureStash', id, { coords = values.coords }, view.property.revision)) end
    if action == 'storage:upgrade' then return result(request('purchaseStorage', id)) end
    if action == 'storage:garage' then
        local grant, err = request('openGarage', id)
        if grant then exports.qbgarages:openGarage(grant.garageId or grant.id); return {} end
        return result(nil, err)
    end
    if action == 'recovery:claim' then return result(request('claimRecovery', itemId)) end
    if action == 'recovery:garage' then
        local entitlement = find((snapshot.inbox or {}).recoveries, itemId)
        local grant, err = request('openGarage', entitlement.property_id)
        if grant then exports.qbgarages:openGarage(grant.garageId or grant.id); return {} end
        return result(nil, err)
    end
    if action == 'recovery:furniture' then
        local entitlement = find((snapshot.inbox or {}).recoveries, itemId)
        local started = lifecycle
        CreateThread(function()
            local world, err = request('worldSnapshot', values.propertyId)
            if lifecycle ~= started then return end
            if not world or not world.space then QB.notify.send({ title = 'Housing', message = err or 'Configure the destination physical space first.', type = 'error' }); return end
            local coords = GetEntityCoords(PlayerPedId())
            activePlacement = { propertyId = values.propertyId }
            local placement, placementErr = capturePlacement(entitlement.model, { coords = { x = coords.x, y = coords.y, z = coords.z }, bounds = world.space.bounds, numericInput = true, raycast = true, copy = false })
            activePlacement = nil
            if lifecycle ~= started then return end
            if placementErr then QB.notify.send({ title = 'Housing', message = placementErr, type = 'error' }) end
            if placement then
                local saved; saved, err = request('claimFurniture', entitlement.id, values.propertyId, placement)
                if not saved then QB.notify.send({ title = 'Housing', message = err, type = 'error' }) end
            end
            reopen(values.propertyId, 'world')
        end)
        return {}
    end
    if action:match('^world:') and view then
        if action == 'world:space' or action == 'world:furniture-place' or action == 'world:furniture-move' or action == 'world:camera-new' or action == 'world:camera-edit' or action == 'world:camera-view' then worldFlow(view, action, values, itemId); return {} end
        local world = view.world or {}
        if action == 'world:doors' then
            local doorIds = {}
            for value in tostring(values.doorIds or ''):gmatch('[^,%s]+') do
                local doorId = tonumber(value)
                if not doorId or doorId < 1 or doorId % 1 ~= 0 then return result(nil, 'Use whole door IDs separated by commas.') end
                doorIds[#doorIds + 1] = doorId
            end
            return result(request('configureDoors', id, doorIds, view.property.revision))
        end
        if action == 'world:furniture-remove' then local item = find(world.furniture, itemId); return result(request('removeFurniture', id, itemId, item.revision)) end
        if action == 'world:camera-remove' then local camera = find(world.cameras, itemId); return result(request('removeCamera', id, itemId, camera.revision)) end
        if action == 'world:camera-grant' then return result(request('grantCamera', id, values.citizenid)) end
        if action == 'world:camera-revoke' then return result(request('revokeCamera', id, itemId)) end
        if action == 'world:alarm-toggle' then return result(request('setAlarm', id, not world.alarm.armed, world.alarm.revision)) end
        if action == 'world:alarm-configure' then return result(request('configureAlarm', id, values, world.alarm.revision)) end
        if action == 'world:panic' then return result(request('panic', id)) end
    end
    if action == 'admin:audit' then
        local rows, err = request('auditView', values.propertyId)
        if not rows then return result(nil, err) end
        local lines = {}
        for _, row in ipairs(rows) do lines[#lines + 1] = time(row.created_at) .. ' · ' .. tostring(row.action) .. ' · ' .. tostring(row.actor or 'System') .. ' · ' .. tostring(row.outcome) end
        QB.nui.openAlert({ title = 'Property audit · ' .. values.propertyId, message = #lines > 0 and table.concat(lines, '\n') or 'No audit events.', size = 'xl' })
        return {}
    end
    if action == 'admin:archive' then
        local preview, err = request('archivePreflight', values.propertyId)
        if not preview then return result(nil, err) end
        local confirmed = QB.nui.openAlert({ title = 'Archive property', message = (preview.summary or preview.detail or '') .. '\n\nArchive ' .. values.propertyId .. '? Ownership, history and protected belongings are retained. New listing and occupancy stop.', destructive = true })
        if not confirmed or not confirmed.confirmed then return {} end
        return result(request('archiveProperty', values.propertyId, preview.token))
    end
end
