return function()
    local tools = dofile('../qbcore/test/mocks.lua')
    local json = { encode = tools.stableEncode, decode = tools.simpleDecode }
    local function copy(v) return json.decode(json.encode(v)) end
    local f = { present = true, rows = {}, markers = {}, grants = {}, writes = {}, stashes = {}, furniture = {},
        locations = { { id = 12, name = 'old_home', label = 'Old Home', owned = 1,
            price = 200000, tier = 1, coords = '{"enter":{"x":1,"y":2,"z":3}}', garage = '{}' } },
        owners = { { id = 7, house = 'old_home', citizenid = 'OWNER', identifier = 'license:owner',
            keyholders = '["OWNER","KEY"]', decorations = '[{"object":"custom_model"}]', stash = '{"x":4,"y":5,"z":6}' } },
        characters = { OWNER = { citizenid = 'OWNER', license = 'license:owner' } } }
    local env = {}; for k,v in pairs(_G) do env[k]=v end
    env.Housing, env.Config, env.json = nil, nil, json
    env.AddEventHandler, env.print = function() end, function() end
    env.QB = { sql = { NULL = '\0qbsql:null\0', awaitCheckedOperations = function() return {} end } }
    local sql = env.QB.sql
    local function values(map) local out = {}; for _,v in pairs(map) do out[#out+1]=copy(v) end; return out end
    function sql.query(query, params)
        if f.readFailure then return nil, 'read failure' end
        if query:find('INFORMATION_SCHEMA',1,true) then return f.present and { {name='houselocations'}, {name='player_houses'} } or {} end
        if query:find('FROM `qbhousing_stock_import`',1,true) then return values(f.markers) end
        if query:find('FROM `qbhousing_properties`',1,true) then return values(f.rows) end
        if query:find('FROM `houselocations`',1,true) then return copy(f.locations) end
        if query:find('FROM `player_houses`',1,true) then return copy(f.owners) end
        if query:find('FROM `qbhousing_stashes`',1,true) then local out={};for _,row in pairs(f.stashes) do if not params or row.property_id==params[1] then out[#out+1]=copy(row) end end;return out end
        if query:find('FROM `qbhousing_furniture`',1,true) then local out={};for _,row in pairs(f.furniture) do if not params or row.property_id==params[1] then out[#out+1]=copy(row) end end;return out end
        if query:find('FROM `qbhousing_permissions`',1,true) then return values(f.grants) end
        if query:find('FROM `players`',1,true) then return values(f.characters) end
        return {}
    end
    function sql.single(_,params) return copy(f.characters[params[1]]) end
    function sql.execute() return {affectedRows=1} end
    local function apply(statements)
        for _, s in ipairs(statements) do
            local p=s.values
            if s.query:find('INSERT INTO `qbhousing_properties`',1,true) then
                f.rows[p[1]]={id=p[1],owner=p[2]~=sql.NULL and p[2] or nil,definition=p[3],property_type=p[4],revision=p[5],ownership_revision=p[6]}
            elseif s.query:find('UPDATE `qbhousing_properties`',1,true) then
                f.rows[p[6]]={id=p[6],owner=p[1]~=sql.NULL and p[1] or nil,definition=p[2],property_type=p[3],revision=p[4],ownership_revision=p[5]}
            elseif s.query:find('INSERT INTO `qbhousing_stashes`',1,true) then
                f.stashes[p[1]]={id=p[1],property_id=p[2],status=p[3],coords=p[4]}
            elseif s.query:find('INSERT INTO `qbhousing_furniture`',1,true) then
                f.furniture[p[1]]={id=p[1],property_id=p[2],owner_cid=p[3],status=p[4],definition=p[5],revision=p[6]}
            elseif s.query:find('INTO `qbhousing_permissions`',1,true) then
                local key=p[1]..':'..p[2]..':'..p[3]
                if not f.grants[key] then f.grants[key]={property_id=p[1],citizenid=p[2],action=p[3],allowed=p[4] or 1} end
            elseif s.query:find('INSERT INTO `qbhousing_stock_import`',1,true) then
                f.markers[p[1]]={property_id=p[1],source_data=p[2]}
            end
        end
    end
    function sql.transactionChecked(statements)
        f.writes[#f.writes+1]=copy(statements)
        if f.failWrite then return {success=false,code='unavailable',message='write failure'} end
        apply(statements)
        if f.unknownCommit then f.unknownCommit=nil; return {success=false,code='indeterminate',message='unknown commit'} end
        return {success=true}
    end
    function sql.transaction(statements) apply(statements); return true end
    env.exports={qbcore={getPlayerByCitizenId=function(_,cid) return f.characters[cid] end,getOfflinePlayerData=function(_,cid) return f.characters[cid] end}}
    for _,path in ipairs({'config.lua','shared/schema.lua','shared/permissions.lua','server/state.lua','server/legacy.lua','server/legacy_fixtures.lua','server/permissions.lua'}) do
        assert(loadfile(path,'t',env))()
    end
    f.housing,f.json,f.env=env.Housing,json,env
    function f.load() local ok,err=f.housing.state.load(); f.housing.state.ready=ok; return ok,err end
    return f
end
