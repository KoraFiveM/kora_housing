Housing = Housing or {}
Housing.app = {}

local APP_ID = 'qbhousing:real-estate'
local snapshot, selected, catalog = {}, nil, {}
local drafts = {}
local nextDraft = 0
local session = 0
local refreshing, refreshPending = false, false
local buildNavigation

local function text(key) return QB.lang('app.' .. key) end
local function money(value) return ('$%.0f'):format(tonumber(value) or 0) end
local function notice(message, tone) return { notice = { message = message, tone = tone or 'success' } } end
local function failure(message) return notice(message or text('unavailable'), 'destructive') end

local function request(name, ...)
    local ok, result = QB.callback.trigger('qbhousing:' .. name, ...)
    if ok ~= true then return nil, result or text('unavailable') end
    return result
end

local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function sortedOptions(values)
    local options = {}
    for id, value in pairs(values or {}) do
        options[#options + 1] = { value = id, label = type(value) == 'table' and value.label or tostring(value) }
    end
    table.sort(options, function(a, b) return a.label < b.label end)
    return options
end

local function formValues(property)
    local interior, garage = property.interior or {}, property.garage or {}
    return {
        id = property.id, label = property.label or property.id,
        propertyType = Config.propertyTypes[property.propertyType] and property.propertyType or nil,
        parentId = property.parentId, unitLabel = property.unitLabel,
        interiorType = interior.type or (property.propertyType == 'house' and 'shell' or 'none'), shellName = interior.name,
        entrance = copy(interior.entrance), exit = copy(interior.exit),
        garageEnabled = property.garage ~= nil, garageCoords = copy(garage.coords),
        garageSpawn = copy(garage.spawn), garageSlots = garage.slots or Config.defaultGarageSlots,
        price = property.listing and property.listing.price,
    }
end

local function draftFor(property)
    local key = property and property.id or 'new'
    if not drafts[key] then
        nextDraft = nextDraft + 1
        drafts[key] = { values = formValues(property or { propertyType = 'house' }), exterior = copy(property and property.exterior), revision = property and property.revision, serial = nextDraft }
    end
    return drafts[key]
end

local function field(id, label, kind, default, options)
    if kind == 'number' and (type(default) ~= 'number' or default ~= default) then default = nil end
    if kind == 'vector' and default ~= nil then
        local vector = {}
        for _, axis in ipairs({ 'x', 'y', 'z', 'w' }) do
            local value = type(default) == 'table' and default[axis] or nil
            if axis == 'w' and value == nil then value = 0 end
            if type(value) ~= 'number' or value ~= value then vector = nil; break end
            vector[axis] = value
        end
        default = vector
    end
    local result = { id = id, label = text(label), type = kind, default = default }
    for key, value in pairs(options or {}) do result[key] = value end
    return result
end

local function configurationFields(property)
    local values = draftFor(property).values
    local fields = {}
    if not property then fields[#fields + 1] = field('id', 'property_id', 'text', values.id, { required = true, maxLength = 64 }) end
    fields[#fields + 1] = field('label', 'label', 'text', values.label, { required = true, maxLength = 100 })
    fields[#fields + 1] = field('propertyType', 'property_type', 'select', values.propertyType, { required = true, options = sortedOptions(snapshot.types) })
    fields[#fields + 1] = field('parentId', 'parent_id', 'text', values.parentId, { maxLength = 64 })
    fields[#fields + 1] = field('unitLabel', 'unit_label', 'text', values.unitLabel, { maxLength = 50 })
    fields[#fields + 1] = field('price', 'reference_price', 'number', values.price, { min = 1, wholeNumber = true, description = text('price_help') })
    if values.propertyType ~= 'land' then

    local interiorOptions = { { value = 'shell', label = text('shell') }, { value = 'mlo', label = text('mlo') } }
    local typeSettings = (snapshot.types or {})[values.propertyType]
    if not typeSettings or typeSettings.interior ~= 'required' then table.insert(interiorOptions, 1, { value = 'none', label = text('no_interior') }) end
    fields[#fields + 1] = field('interiorType', 'interior_type', 'select', values.interiorType, { required = true, options = interiorOptions })
    if values.interiorType == 'shell' then
        fields[#fields + 1] = field('shellName', 'shell', 'select', values.shellName, { required = true, options = sortedOptions(snapshot.shells) })
    end
    if values.interiorType ~= 'none' then
        fields[#fields + 1] = field('entrance', 'entrance', 'vector', values.entrance, { required = true, dimensions = 4 })
        if values.interiorType == 'mlo' then
            fields[#fields + 1] = field('exit', 'exit', 'vector', values.exit, { dimensions = 4 })
        end
    end
    end
    fields[#fields + 1] = field('garageEnabled', 'configure_garage', 'checkbox', values.garageEnabled)
    if values.garageEnabled then
        fields[#fields + 1] = field('garageCoords', 'garage_coords', 'vector', values.garageCoords, { required = true, dimensions = 4 })
        fields[#fields + 1] = field('garageSpawn', 'garage_spawn', 'vector', values.garageSpawn, { required = true, dimensions = 4 })
        fields[#fields + 1] = field('garageSlots', 'garage_slots', 'number', values.garageSlots, { required = true, min = 1, max = Config.maxGarageSlots, wholeNumber = true })
    end
    return fields
end

local function configurationPayload(property, values)
    local payload = {
        id = property and property.id or values.id, label = values.label, propertyType = values.propertyType,
        parentId = values.parentId ~= '' and values.parentId or nil,
        unitLabel = values.unitLabel ~= '' and values.unitLabel or nil,
        exterior = copy(draftFor(property).exterior),
    }
    if values.price then payload.listing = { price = values.price } end
    if values.propertyType ~= 'land' and values.interiorType == 'shell' then
        local shell = (snapshot.shells or {})[values.shellName]
        payload.interior = { type = 'shell', name = values.shellName, entrance = values.entrance, exit = shell and copy(shell.exit), model = shell and shell.model }
    elseif values.propertyType ~= 'land' and values.interiorType == 'mlo' then
        payload.interior = { type = 'mlo', entrance = values.entrance, exit = type(values.exit) == 'table' and values.exit or nil }
    end
    if values.garageEnabled then
        payload.garage = { coords = values.garageCoords, spawn = values.garageSpawn, slots = values.garageSlots }
    end
    return payload
end

local function configurationContent(property)
    local draft = draftFor(property)
    local pointCount = draft.exterior and #(draft.exterior.polyzone or {}) or 0
    local actions = {
        { id = 'configuration:boundary', label = text('place_boundary'), icon = 'MapPinned', closeBeforeAction = true },
        { id = 'configuration:clear-boundary', label = text('clear_boundary'), icon = 'Eraser', disabled = pointCount == 0 },
    }
    if property then actions[#actions + 1] = { id = 'configuration:reload', label = text('reload'), icon = 'RefreshCw', confirm = text('reload_confirm') } end
    return {
        title = property and text('configuration') or text('new_property'),
        description = text('configuration_help'),
        actions = actions,
        blocks = {
            { type = 'details', items = { { label = text('boundary_points'), value = pointCount } } },
            { type = 'form', id = 'configuration:' .. draft.serial, fields = configurationFields(property),
                action = { id = property and 'property:save' or 'property:create', label = text('save') }, submitLabel = text('save') },
        },
    }
end

local function actionOptions()
    local actions = {}
    for id, action in pairs(snapshot.actions or {}) do
        if action.grantable then actions[id] = action end
    end
    return sortedOptions(actions)
end

local function accessContent(view)
    local property, allowed = view.property, view.allowed or {}
    local owners = { { citizenid = property.owner or text('unowned'), role = text('primary_owner') } }
    for citizenid in pairs(property.coowners or {}) do owners[#owners + 1] = { citizenid = citizenid, role = text('coowner') } end
    local grants = {}
    for citizenid, actions in pairs(property.permissionGrants or {}) do
        for action, enabled in pairs(actions) do
            grants[#grants + 1] = {
                id = citizenid .. ':' .. action, label = citizenid,
                description = ((snapshot.actions or {})[action] or {}).label or action,
                badge = enabled and text('allow') or text('deny'), tone = enabled and 'success' or 'destructive',
                data = { citizenid = citizenid, action = action },
                actions = allowed['permissions.manage'] and { { id = 'permission:remove', label = text('remove_grant'), confirm = text('remove_grant_confirm') } } or nil,
            }
        end
    end
    table.sort(grants, function(a, b) return a.id < b.id end)
    local blocks = { { type = 'table', columns = { { key = 'citizenid', label = text('citizen_id') }, { key = 'role', label = text('relationship') } }, rows = owners } }
    if allowed['coowners.manage'] then
        local options = {}
        for citizenid in pairs(property.coowners or {}) do options[#options + 1] = { value = citizenid, label = citizenid } end
        table.sort(options, function(a, b) return a.value < b.value end)
        blocks[#blocks + 1] = { type = 'form', id = 'add-coowner:' .. property.id, fields = { field('citizenid', 'citizen_id', 'text', nil, { required = true, maxLength = 50 }) }, action = { id = 'coowner:add', label = text('add_coowner') } }
        if #options > 0 then
            blocks[#blocks + 1] = { type = 'actions', actions = { { id = 'coowner:remove', label = text('remove_coowner'), confirm = text('remove_coowner_confirm'), fields = {
                field('citizenid', 'citizen_id', 'select', nil, { required = true, options = options }),
            } } } }
        end
    end
    if allowed['permissions.manage'] then
        blocks[#blocks + 1] = { type = 'form', id = 'grant:' .. property.id, fields = {
            field('citizenid', 'citizen_id', 'text', nil, { required = true, maxLength = 50 }),
            field('action', 'action', 'select', nil, { required = true, options = actionOptions(), searchable = true }),
            field('decision', 'decision', 'select', 'allow', { required = true, options = {
                { value = 'allow', label = text('allow') }, { value = 'deny', label = text('deny') }, { value = 'remove', label = text('remove_grant') },
            } }),
        }, action = { id = 'permission:set', label = text('save_access') } }
    end
    blocks[#blocks + 1] = #grants > 0 and { type = 'list', id = 'grants', title = text('individual_grants'), items = grants, searchable = true, pageSize = 10 }
        or { type = 'empty', title = text('no_grants') }
    local effective = {}
    for action, enabled in pairs(allowed) do effective[#effective + 1] = { action = ((snapshot.actions or {})[action] or {}).label or action, permission = enabled and text('allow') or text('deny') } end
    table.sort(effective, function(a, b) return a.action < b.action end)
    blocks[#blocks + 1] = { type = 'table', title = text('your_permissions'), columns = { { key = 'action', label = text('action') }, { key = 'permission', label = text('decision') } }, rows = effective, searchable = true, pageSize = 10 }
    return { title = text('people_access'), description = text('access_help'), blocks = blocks }
end

buildNavigation = function()
    local gameplayViews = Housing.gameplay and Housing.gameplay.navigation(snapshot) or {}
    local properties = {}
    for _, property in ipairs(snapshot.properties or {}) do
        properties[#properties + 1] = { id = property.id, label = property.label or property.id, description = property.propertyType,
            badge = property.state, action = 'property:open' }
    end
    local listings = {}
    for _, property in ipairs(catalog) do
        listings[#listings + 1] = { id = property.listing.id, label = property.label or property.id, description = property.listing.biography or property.propertyType,
            metadata = { { label = text('price'), value = money(property.listing and property.listing.price) } },
            actions = { { id = 'market:inspect', label = 'Inspect property', icon = 'Search' }, { id = 'sales:submit', label = text('request_purchase'), fields = { field('amount', 'price', 'number', property.listing.price, { required = true, min = 1, max = 1000000000, wholeNumber = true }) } } } }
    end
    local navigation = {
        { id = 'properties', label = text('my_properties'), icon = 'House', content = { title = text('my_properties'), actions = { { id = 'refresh', label = text('refresh'), icon = 'RefreshCw' } }, blocks = {
            #properties > 0 and { type = 'list', id = 'properties', items = properties, searchable = true, pageSize = 12 }
                or { type = 'empty', title = text('no_properties') },
        } } },
        { id = 'market', label = text('marketplace'), icon = 'Store', content = { title = text('marketplace'), blocks = {
            #listings > 0 and { type = 'list', id = 'market', items = listings, searchable = true, pageSize = 12 }
                or { type = 'empty', title = text('no_listings') },
        } } },
    }
    for _, view in ipairs(gameplayViews) do navigation[#navigation + 1] = view end
    if snapshot.admin or snapshot.realtor then navigation[#navigation + 1] = { id = 'new', label = text('new_property'), icon = 'Plus', content = configurationContent() } end
    if selected then
        local property = selected.property
        local tabs = {
            { id = 'overview', label = text('overview'), content = { title = property.label or property.id, blocks = {
                { type = 'details', items = {
                    { label = text('property_id'), value = property.id }, { label = text('property_type'), value = ((snapshot.types or {})[property.propertyType] or {}).label or property.propertyType },
                    { label = text('state'), value = property.state }, { label = text('relationship'), value = selected.relationship or text('guest') },
                    { label = text('primary_owner'), value = property.owner or text('unowned') }, { label = text('revision'), value = property.revision or 0 },
                } },
            } } },
            { id = 'access', label = text('people_access'), content = accessContent(selected) },
        }
        if selected.allowed and selected.allowed['property.edit'] then tabs[#tabs + 1] = { id = 'configuration', label = text('configuration'), content = configurationContent(property) } end
        if Housing.gameplay then for _, tab in ipairs(Housing.gameplay.tabs(selected)) do tabs[#tabs + 1] = tab end end
        navigation[#navigation + 1] = { id = 'property', label = property.label or property.id, icon = 'Building2', tabs = tabs }
    end
    return navigation
end

local function refreshData()
    local started = session
    local data, err = request('creatorSnapshot')
    if not data then return nil, err end
    local listings = QB.callback.trigger('qbhousing:catalog')
    if session ~= started then return nil, text('unavailable') end
    snapshot = data
    catalog = type(listings) == 'table' and listings or {}
    return true
end

local function selectedResult(id, tab, message, resetDraft)
    local started = session
    local view, err = request('propertyView', id)
    if session ~= started then return {} end
    if not view then return failure(err) end
    selected = view
    if resetDraft then drafts[id] = nil end
    local ok, loadErr = refreshData()
    if not ok then return failure(loadErr) end
    return { update = { navigation = buildNavigation() }, navigate = { viewId = 'property', tabId = tab or 'overview' }, notice = message and { message = message, tone = 'success' } or nil }
end

local function captureBoundary(property)
    local draft = draftFor(property)
    local started = session
    CreateThread(function()
        local existing = draft.exterior and { points = draft.exterior.polyzone, minZ = draft.exterior.minZ, maxZ = draft.exterior.maxZ, thickness = draft.exterior.thickness } or nil
        local captured = QB.zones.startCreator('poly', existing)
        if session ~= started then return end
        if captured and captured.opts then
            local options = captured.opts
            -- The zone creator returns a thickness measured above its lowest point.
            local minZ = options.minZ
            if not minZ then
                minZ = math.huge
                for _, point in ipairs(options.points or {}) do minZ = math.min(minZ, point.z) end
            end
            draft.exterior = { polyzone = copy(options.points), minZ = minZ, maxZ = options.maxZ or minZ + options.thickness }
            draft.dirty = true
        end
        local ok, err = refreshData()
        if session ~= started then return end
        if not ok then return QB.notify.send({ title = text('title'), message = err, type = 'error' }) end
        local viewId, tabId = 'new', nil
        if property then
            selected = request('propertyView', property.id)
            if session ~= started then return end
            viewId, tabId = selected and 'property' or 'properties', selected and 'configuration' or nil
        elseif not snapshot.admin and not snapshot.realtor then
            viewId = 'properties'
        end
        QB.nui.updateApp(APP_ID, { navigation = buildNavigation() })
        QB.nui.openApp(APP_ID, { viewId = viewId, tabId = tabId })
    end)
end

local function onAction(action, context)
    local values = type(context.value) == 'table' and context.value or {}
    if action == 'refresh' then
        local ok, err = refreshData()
        if not ok then return failure(err) end
        if selected then return selectedResult(selected.property.id, context.tabId) end
        return { update = { navigation = buildNavigation() } }
    end
    if action == 'market:inspect' then
        for _, item in ipairs(catalog) do if item.listing.id == context.itemId then return selectedResult(item.id) end end
        return failure(text('unavailable'))
    end
    if action == 'property:open' then return selectedResult(context.itemId) end
    if action == 'configuration:reload' and selected then return selectedResult(selected.property.id, 'configuration', nil, true) end
    if action == 'market:offer' then
        local ok, err = QB.callback.trigger('qbhousing:offer', context.itemId, snapshot.citizenid)
        return ok and notice(text('offer_sent')) or failure(err)
    end
    if Housing.gameplay then
        local response = Housing.gameplay.action(action, context, selected)
        if response then
            if not response.refresh then return response end
            if selected then return selectedResult(selected.property.id, context.tabId, response.notice and response.notice.message) end
            local loaded, loadErr = refreshData()
            if not loaded then return failure(loadErr) end
            return { update = { navigation = buildNavigation() }, notice = response.notice }
        end
    end
    if action == 'configuration:boundary' then
        local property
        if context.viewId == 'property' then property = selected and selected.property end
        captureBoundary(property)
        return
    end
    if action == 'configuration:clear-boundary' then
        local property
        if context.viewId == 'property' then property = selected and selected.property end
        local draft = draftFor(property)
        draft.exterior, draft.dirty = nil, true
        return { update = { navigation = buildNavigation() } }
    end
    if action == 'property:create' then
        local property, err = request('createProperty', configurationPayload(nil, values))
        if not property then return failure(err) end
        drafts.new = nil
        return selectedResult(property.id, 'configuration', text('property_created'), true)
    end
    local property = selected and selected.property
    if not property then return failure(text('select_property')) end
    if action == 'property:save' then
        local saved, err = request('editProperty', property.id, configurationPayload(property, values), draftFor(property).revision)
        if not saved then return failure(err) end
        return selectedResult(property.id, 'configuration', text('property_saved'), true)
    end
    if action == 'coowner:add' or action == 'coowner:remove' then
        local saved, err = request('coowners', property.id, action == 'coowner:add' and 'add' or 'remove', values.citizenid, property.revision)
        if not saved then return failure(err) end
        return selectedResult(property.id, 'access', text('access_saved'))
    end
    if action == 'permission:set' or action == 'permission:remove' then
        local enabled
        if action == 'permission:set' and values.decision ~= 'remove' then enabled = values.decision == 'allow' end
        local saved, err = request('setPermission', property.id, values.citizenid, values.action, enabled, property.revision)
        if not saved then return failure(err) end
        return selectedResult(property.id, 'access', text('access_saved'))
    end
    return failure(text('unavailable'))
end

function Housing.app.open(viewId)
    session = session + 1
    local started = session
    CreateThread(function()
        local ok, err = refreshData()
        if session ~= started then return end
        if not ok then return QB.notify.send({ title = text('title'), message = err, type = 'error' }) end
        selected, drafts = nil, {}
        QB.nui.registerApp({
            id = APP_ID, title = text('title'), icon = 'House', width = 1180, height = 780,
            defaultView = 'properties', navigation = buildNavigation(), onAction = onAction,
            onChange = function(action, context)
                if action ~= 'property:create' and action ~= 'property:save' then return end
                local property = action == 'property:save' and selected and selected.property or nil
                local draft = draftFor(property)
                draft.values, draft.dirty = copy(context.value), true
                return { navigation = buildNavigation() }
            end,
        })
        QB.nui.openApp(APP_ID, { viewId = viewId or 'properties' })
    end)
end

function Housing.app.sync()
    if not QB.nui.isAppOpen(APP_ID) then return end
    refreshPending = true
    if refreshing then return end
    refreshing = true
    local started = session
    CreateThread(function()
        repeat
            refreshPending = false
            local id = selected and selected.property.id
            local ok, err = refreshData()
            if session ~= started or not QB.nui.isAppOpen(APP_ID) then break end
            if not ok then
                QB.nui.closeApp(APP_ID)
                QB.notify.send({ title = text('title'), message = err, type = 'error' })
                break
            end
            if id and selected and selected.property.id == id then
                local view = request('propertyView', id)
                if session ~= started then break end
                if view then
                    selected = view
                    local draft = drafts[id]
                    -- A retained draft keeps its original revision so a background
                    -- update cannot make stale configuration overwrite newer work.
                    if draft and not draft.dirty then drafts[id] = nil end
                else
                    selected = nil
                end
            end
            QB.nui.updateApp(APP_ID, { navigation = buildNavigation() })
        until not refreshPending
        refreshing = false
    end)
end

function Housing.app.close()
    session = session + 1
    refreshPending = false
    selected, snapshot, catalog, drafts = nil, {}, {}, {}
    QB.nui.closeApp(APP_ID)
end

function Housing.app.refreshProperty(id, tab)
    local response = selectedResult(id, tab)
    if response.update then QB.nui.updateApp(APP_ID, response.update) end
    if response.navigate then QB.nui.openApp(APP_ID, response.navigate) end
    if response.notice then QB.notify.send({ title = text('title'), message = response.notice.message, type = response.notice.tone == 'destructive' and 'error' or 'success' }) end
end
