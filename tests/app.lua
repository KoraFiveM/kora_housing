-- Exercise housing definitions through kora_lib's real AppShell validator and routes.
package.path = '../kora_lib/test/?.lua;' .. package.path
local mocks = require('mocks')
mocks.install()
dofile('../kora_lib/config.lua')
dofile('../kora_lib/build/initiate.lua')
dofile('../kora_lib/local/resources/client.lua')
dofile('../kora_lib/modules/util/shared.lua')

local callbacks, messages = {}, {}
function RegisterNUICallback(name, callback) callbacks[name] = callback end
function SendNUIMessage(message) messages[#messages + 1] = message end
function SetNuiFocus() end
function SetNuiFocusKeepInput() end
function IsNuiFocusKeepingInput() return false end
QBTheme = { apply = function() end }
dofile('../kora_lib/modules/nui/client.lua')
dofile('config.lua')

local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local locale = dofile('locales/en.lua')
QB.lang = function(key) return (assert(locale.app[key:match('^app%.(.+)$')], key)) end
QB.notify = { send = function(payload) error(payload.message) end }
local property = {
    id = 'existing', label = 'Existing home', propertyType = 'house', owner = 'owner', revision = 4,
    state = 'owned', coowners = { coowner = true }, permissionGrants = { visitor = { entry = false } },
    interior = { type = 'shell', name = 'CreateApartmentShell', entrance = { x = 10, y = 20, z = 30 }, exit = Config.shells.CreateApartmentShell.exit },
    listing = { price = 125000 },
}
dofile('shared/schema.lua')
dofile('shared/permissions.lua')
Housing.copy = copy
local actorAdmin = true
QB.permissions = { hasPermission = function() return actorAdmin end }
exports = { kora_core = { getPlayer = function() return { citizenid = 'owner', job = { name = 'unemployed' } } end } }
Housing.state = { ready = true, properties = { existing = property }, get = function(id) return Housing.state.properties[id] end }
dofile('server/permissions.lua')
dofile('server/properties.lua')
local calls, rejectEdit, grantValue = {}, false, true
QB.callback = { trigger = function(name, ...)
    local args = table.pack(...)
    calls[name] = args
    if name == 'qbhousing:creatorSnapshot' then
        return Housing.properties.snapshot(1)
    elseif name == 'qbhousing:catalog' then return {}
    elseif name == 'qbhousing:propertyView' then return Housing.properties.view(1, args[1])
    elseif name == 'qbhousing:createProperty' then
        property = copy(args[1]); property.revision, property.state, property.coowners, property.permissionGrants = 0, 'unowned', {}, {}
        Housing.state.properties[property.id] = property
        return true, copy(property)
    elseif name == 'qbhousing:editProperty' then
        if rejectEdit then return false, 'Property changed. Refresh before saving.' end
        property.label, property.revision = args[2].label, property.revision + 1
        return true, copy(property)
    elseif name == 'qbhousing:recommendOffer' then return true, true
    elseif name == 'qbhousing:configureAlarm' then return true, true
    elseif name == 'qbhousing:coowners' then return true, copy(property)
    elseif name == 'qbhousing:setPermission' then grantValue = args[4]; return true, copy(property)
    end
    error('Unexpected callback: ' .. name)
end }
QB.zones = { startCreator = function(kind)
    check(kind == 'poly', 'capture a polygon with the shared creator')
    return { type = 'poly', opts = { points = { { x = 1, y = 1, z = 5 }, { x = 8, y = 1, z = 7 }, { x = 1, y = 8, z = 6 } }, thickness = 4 } }
end }
dofile('client/gameplay.lua')
dofile('client/app.lua')

local function lastMessage(action)
    for index = #messages, 1, -1 do if messages[index].action == action then return messages[index] end end
end
local function route(channel, action, context)
    local opened = assert(lastMessage('openApp')).data
    local result
    callbacks[channel]({ appId = 'qbhousing:real-estate', token = opened.token, actionId = action,
        viewId = context.viewId or 'property', tabId = context.tabId, itemId = context.itemId, value = context.value }, function(value) result = value end)
    check(result and result.ok == true, result and result.error or 'AppShell route did not respond')
    return result.result or {}
end
local function act(action, context) return route('kora_lib:app:action', action, context or {}) end
local function change(action, context) return route('kora_lib:app:change', action, context) end
local function form(app, viewId, tabId)
    for _, view in ipairs(app.navigation) do
        if view.id == viewId then
            local content = view.content
            for _, tab in ipairs(view.tabs or {}) do if tab.id == tabId then content = tab.content end end
            for _, block in ipairs(content.blocks) do if block.type == 'form' then return block end end
        end
    end
end
local function getField(block, id)
    for _, field in ipairs(block.fields) do if field.id == id then return field end end
end

Housing.app.open('properties')
check(lastMessage('openApp').data.payload.app.id == 'qbhousing:real-estate', 'retain the established app id')
local result = act('property:open', { itemId = 'existing' })
local editor = assert(form(result.app, 'property', 'configuration'))
check(getField(editor, 'label').default == 'Existing home', 'edit loads the existing label')
check(getField(editor, 'price').default == 125000, 'edit loads the existing price')
check(getField(editor, 'entrance').default.w == 0, 'legacy coordinates without heading are valid shared vector defaults')
check(not getField(editor, 'id'), 'stable id is not an editable field')

result = change('property:save', { value = { label = 'Draft', propertyType = 'house', interiorType = 'shell', price = '', entrance = { x = '', y = 2, z = 3, w = 0 } } })
check(result.app ~= nil, 'incomplete numeric and vector drafts do not invalidate AppShell updates')
rejectEdit = true
result = act('property:save', { value = { label = 'Changed home', propertyType = 'house', interiorType = 'shell', shellName = 'CreateApartmentShell', entrance = { x = 10, y = 20, z = 30, w = 0 }, price = 125000 } })
check(result.notice.tone == 'destructive', 'stale save failure stays visible')
check(calls['qbhousing:editProperty'][3] == 4 and property.label == 'Existing home', 'save includes expected revision and rejected edit changes no local saved data')
rejectEdit = false

act('permission:set', { value = { citizenid = 'visitor', action = 'entry', decision = 'deny' } })
check(grantValue == false, 'explicit deny remains false across the callback')
act('permission:set', { value = { citizenid = 'visitor', action = 'entry', decision = 'allow' } })
check(grantValue == true, 'allow remains true across the callback')
act('permission:remove', { value = { citizenid = 'visitor', action = 'entry' } })
check(grantValue == nil and calls['qbhousing:setPermission'][5] == 4, 'grant removal sends nil and retains the revision after it')
act('coowner:remove', { value = { citizenid = 'coowner' } })
check(calls['qbhousing:coowners'][2] == 'remove' and calls['qbhousing:coowners'][4] == 4, 'co-owner removal uses the revision-bound contract')

property.revision = 5
local draftId = editor.id
Housing.app.sync()
editor = assert(form(lastMessage('updateApp').data.app, 'property', 'configuration'))
check(getField(editor, 'label').default == 'Draft', 'server sync preserves an unsaved configuration draft')
check(editor.id == draftId, 'background refresh retains the browser form draft identity')
act('property:save', { value = { label = 'Draft', propertyType = 'house', interiorType = 'shell', shellName = 'CreateApartmentShell', entrance = { x = 10, y = 20, z = 30, w = 0 } } })
check(calls['qbhousing:editProperty'][3] == 4, 'background updates cannot silently advance a dirty draft revision')
act('configuration:reload')
result = act('property:open', { itemId = 'existing' })
editor = assert(form(result.app, 'property', 'configuration'))
check(getField(editor, 'label').default == property.label, 'confirmed reload discards the draft for the saved configuration')
check(editor.id ~= draftId, 'confirmed reload replaces the browser draft identity')

local richLease = { id = 'agreement', property_id = 'existing', tenant = 'owner', rent = 1500, deposit = 3000, deposit_remaining = 2500,
    interval_name = 'weekly', status = 'active', paid_through = 1700000000, next_due = 1700000000, permissions = { entry = true, ['stash.open'] = true } }
local richSales = { agents = { { citizenid = 'agent' } }, listings = { { id = 'listing', agent = 'owner', property_id = 'existing', channel = 'public', price = 150000, biography = 'A populated listing.', status = 'active' } },
    offers = { { id = 'offer', listing_id = 'listing', property_id = 'existing', buyer = 'buyer', agent = 'owner', amount = 145000, status = 'submitted', recommendation = 'Recommend acceptance',
        approvals = { { citizenid = 'owner', approved = 1, ownership_revision = 1 } }, settlementSummary = '$145000 total with recorded payouts.' } } }
Housing.sales = { view = function() return copy(richSales) end, summary = function() return 'Durable sale payout terms.' end }
Housing.leases = { active = function() return copy(richLease) end, permission = function() return nil end, view = function() return { active = copy(richLease), history = { copy(richLease) },
    payments = { { id = 'period', period_start = 1700000000, amount = 1500, status = 'paid' } },
    deductions = { { id = 'deduction', lease_id = 'agreement', amount = 500, category = 'damage', note = 'Repair evidence', status = 'disputed' } } } end }
Housing.storage = { view = function() return { tier = 1, coords = { x = 1, y = 2, z = 3 } } end,
    recoveryList = function() return true, { { id = 'garage:existing', property_id = 'existing', kind = 'garage', label = 'Protected vehicles' },
        { id = 'chair-recovery', propertyId = 'existing', kind = 'furniture', model = 'prop_chair_01a' }, { id = 'stash-recovery', kind = 'inventory', label = 'Protected items' } } end }
Housing.world = { ready = true, snapshot = function() return true, { space = { revision = 2, origin = { x = 1, y = 2, z = 3 } },
    furniture = { { id = 'chair', model = 'prop_chair_01a', ownerCid = 'owner', revision = 1 } },
    cameras = { { id = 'camera', label = 'Front room', fov = 60, console = { x = 1, y = 2, z = 3 }, revision = 1 } },
    grants = { { citizenid = 'guest', expiresAt = 1700000000 } }, alarm = { armed = true, revision = 2, doorUnlock = true, panic = true, cooldown = 60 } } end }
QB.sql = { query = function(sql) return sql:find('qbhousing_offers') and copy(richSales.offers) or { copy(richLease) } end }
Housing.app.open('properties')
result = act('property:open', { itemId = 'existing' })
check(form(result.app, 'property', 'rental') ~= nil and form(result.app, 'property', 'world') ~= nil, 'populated rental and security definitions pass the real AppShell validator')
result = act('sales:recommend', { tabId = 'sales', itemId = 'offer', value = { recommendation = 'Reviewed the offer.' } })
check(calls['qbhousing:recommendOffer'][1] == 'offer' and result.notice.tone == 'success', 'actual sales payload uses the property view sales field and durable offer id')
result = act('world:alarm-configure', { tabId = 'world', value = { doorUnlock = true, panic = false, cooldown = 90 } })
check(calls['qbhousing:configureAlarm'][3] == 2, 'security actions include their independent persistent revision')
Housing.sales, Housing.leases, Housing.storage, Housing.world = nil, nil, nil, nil

actorAdmin, property.owner, property.coowners = false, 'another-owner', {}
property.permissionGrants.owner = { entry = true }
property.revision = property.revision + 1
Housing.app.sync()
local refreshed = lastMessage('updateApp').data.app
local propertyView
for _, view in ipairs(refreshed.navigation) do if view.id == 'property' then propertyView = view end end
local hasConfiguration = false
for _, tab in ipairs(propertyView and propertyView.tabs or {}) do if tab.id == 'configuration' then hasConfiguration = true end end
check(propertyView and not hasConfiguration, 'revoked management removes the configuration tab immediately')
local access = propertyView.tabs[2].content
local managedForms = 0
for _, block in ipairs(access.blocks) do if block.type == 'form' then managedForms = managedForms + 1 end end
check(managedForms == 0, 'revoked access management leaves no mutation forms')
property.permissionGrants.owner.entry = false
Housing.app.sync()
refreshed = lastMessage('updateApp').data.app
local hasProperty = false
for _, view in ipairs(refreshed.navigation) do if view.id == 'property' then hasProperty = true end end
check(not hasProperty, 'revoked property access removes its selected view')
actorAdmin, property.owner = true, 'owner'
Housing.app.open('properties')

result = change('property:create', { viewId = 'new', value = { id = 'land', label = 'Land', propertyType = 'land' } })
editor = assert(form(result.app, 'new'))
check(not getField(editor, 'interiorType') and getField(editor, 'garageEnabled'), 'land form omits interior and supports an optional physical garage')
check(getField(editor, 'garageEnabled').default ~= true and not getField(editor, 'garageCoords'), 'new land starts with no garage or inherited fixture coordinates')
act('configuration:boundary', { viewId = 'new' })
local opened = lastMessage('openApp').data.payload
check(opened.viewId == 'new', 'world capture returns to new property even when another property was selected')
act('property:create', { viewId = 'new', value = { id = 'land', label = 'Land', propertyType = 'land', interiorType = 'shell', garageEnabled = true,
    garageCoords = { x = 2, y = 2, z = 6, w = 0 }, garageSpawn = { x = 3, y = 3, z = 6, w = 0 }, garageSlots = 2 } })
local payload = calls['qbhousing:createProperty'][1]
check(payload.interior == nil and payload.garage.slots == 2 and payload.owner == nil, 'land payload supports a garage without an interior or ownership assignment')
check(payload.exterior.minZ == 5 and payload.exterior.maxZ == 9, 'boundary height matches kora_lib lowest-point plus thickness semantics')
check(payload.id == 'land' and payload.label == 'Land', 'new draft retains typed fields across world capture')

local imported = copy(Housing.state.properties.existing)
imported.id, imported.propertyType, imported.garage = 'imported', 'legacy', nil
Housing.state.properties.imported = imported
Housing.app.open('properties')
result = act('property:open', { itemId = 'imported' })
editor = assert(form(result.app, 'property', 'configuration'))
check(getField(editor, 'propertyType').default == nil and getField(editor, 'propertyType').required, 'an imported legacy property opens with an empty required type selection')
check(getField(editor, 'interiorType').default == 'shell' and getField(editor, 'entrance').default.x == imported.interior.entrance.x, 'legacy classification retains existing interior settings')
check(not Housing.validateProperty(copy(imported)), 'an imported property requires a supported classification before strict saving')
local classified = copy(imported)
classified.propertyType = 'house'
check(Housing.validateProperty(classified), 'explicit classification validates the existing legacy interior without inventing title or fixtures')
editor = assert(form(result.app, 'new'))
check(getField(editor, 'garageEnabled').default == false and not getField(editor, 'garageCoords'), 'a fresh creator does not inherit the previous land garage')

local events, zones, commands = {}, {}, {}
local syncs, closes = 0, 0
local environment = {}
for key, value in pairs(_G) do environment[key] = value end
environment.QB = { interact = {
    addBoxZone = function(id) zones[id] = true; return {} end,
    removeZone = function(id) zones[id] = nil end,
} }
environment.Housing = { app = {
    sync = function() syncs = syncs + 1 end,
    close = function() closes = closes + 1 end,
    open = function(viewId) commands.opened = viewId end,
} }
environment.RegisterNetEvent = function(name, handler) events[name] = handler end
environment.AddEventHandler = environment.RegisterNetEvent
environment.RegisterCommand = function(name, handler) commands[name] = handler end
environment.CreateThread = function() end
environment.GetCurrentResourceName = function() return 'kora_housing' end
environment.vector3 = function(x, y, z) return { x = x, y = y, z = z } end
assert(loadfile('client/main.lua', 't', environment))()
local function worldProperty(id, state)
    return { id = id, state = state or 'owned', interior = { entrance = { x = 1, y = 2, z = 3 } } }
end
events['qbhousing:client:synced']({ first = worldProperty('first') })
check(zones['qbhousing:first'] and syncs == 1, 'a server sync registers its fixture and refreshes the open application')
events['qbhousing:client:synced']({ second = worldProperty('second') })
check(not zones['qbhousing:first'] and zones['qbhousing:second'], 'replacement sync removes deleted property fixtures')
events['qbhousing:client:synced']({ second = worldProperty('second', 'archived') })
check(not next(zones), 'archival removes the physical interaction')
events['qbhousing:client:synced']({ first = worldProperty('first') })
events['onClientResourceStop']('another-resource')
check(zones['qbhousing:first'], 'an unrelated resource stopping does not remove housing fixtures')
events['onClientResourceStop']('kora_housing')
check(not next(zones) and closes == 1, 'resource stop clears housing fixtures and closes its app')
events['qbhousing:client:synced']({ first = worldProperty('first') })
events['QBCore:Client:OnPlayerUnload']()
check(not next(zones) and closes == 2, 'character unload clears fixtures and private application state')
commands[Config.command]()
check(commands.opened == 'market', 'retain the market command entry')
commands[Config.homeCommand]()
check(commands.opened == 'properties', 'retain the homeowner command entry')

local removed, teleported, failed = 0, 0, 0
environment.PlayerPedId = function() return 41 end
environment.DoesEntityExist = function(object) return object == 91 end
environment.DeleteEntity = function() removed = removed + 1 end
environment.SetEntityCoords = function() teleported = teleported + 1 end
environment.QB.notify = { send = function() failed = failed + 1 end }
environment.exports = { kora_interior = { createGeometry = function()
    events['QBCore:Client:OnPlayerUnload']()
    return { { 91 }, {} }
end } }
local shellProperty = worldProperty('shell')
shellProperty.interior.exit, shellProperty.interior.model = { x = 0, y = 0, z = 0 }, 'shell_v16low'
events['qbhousing:client:enterShell'](shellProperty)
check(removed == 1 and teleported == 0, 'a shell finishing after character unload is deleted without teleporting')
environment.exports.kora_interior.createGeometry = function() return nil end
events['qbhousing:client:enterShell'](shellProperty)
check(failed == 1 and teleported == 0, 'an unavailable interior provider reports failure without teleporting')

print(('qbhousing AppShell: %d checks passed'):format(checks))
