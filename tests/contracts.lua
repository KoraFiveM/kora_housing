-- Load every manifest server module and verify all client requests have handlers.
local m = dofile('../qbcore/test/mocks.lua')
json = { encode = m.stableEncode, decode = m.simpleDecode }
local callbacks, events, provided, threads = {}, {}, {}, {}
function GetCurrentResourceName() return 'qbhousing' end
function CreateThread(fn) threads[#threads + 1] = fn end
function AddEventHandler() end
function RegisterNetEvent(name, fn) assert(not events[name], 'Repeated event ' .. name); events[name] = fn end
function TriggerClientEvent() end
function SetTimeout() end
exports = setmetatable({}, { __call = function(_, name, fn) provided[name] = fn end })
QB = { callback = { register = function(name, fn, options)
    assert(not callbacks[name], 'Repeated callback ' .. name)
    assert(options.rateLimit.max and options.rateLimit.window, 'Callback needs rate limit')
    callbacks[name] = fn
end }, sql = {}, timers = {} }
QB.compat = dofile('../qblib/compat/provider.lua')()
dofile('config.lua'); dofile('shared/schema.lua'); dofile('shared/permissions.lua')
local function read(path) local f = assert(io.open(path)); local s = f:read('*a'); f:close(); return s end
local manifest = read('fxmanifest.lua')
for file in manifest:match('server_scripts%s*{(.-)}'):gmatch("'([^']+)'") do dofile(file) end
local checked = 0
for file in manifest:match('client_scripts%s*{(.-)}'):gmatch("'([^']+)'") do
    local source = read(file)
    for name in source:gmatch("request%('([^']+)'") do
        assert(callbacks['qbhousing:' .. name], file .. ' calls unregistered ' .. name); checked = checked + 1
    end
    for name in source:gmatch("QB.callback.trigger%('([^']+)'") do
        assert(name == 'qbhousing:' or callbacks[name], file .. ' calls unregistered ' .. name); checked = checked + 1
    end
    for name in source:gmatch("TriggerServerEvent%('([^']+)'") do
        assert(events[name], file .. ' emits unregistered ' .. name); checked = checked + 1
    end
end
for _, name in ipairs({ 'GetProperty', 'HasAccess', 'HasPermission' }) do assert(provided[name], 'Missing export ' .. name) end
for _, name in ipairs({ 'hydrate', 'saveProperty', 'catalog', 'realtorDashboard', 'removeProperty', 'offer', 'confirmPurchase', 'keys', 'update' }) do
    assert(callbacks['qbhousing:' .. name], 'Missing compatibility callback ' .. name)
end
-- Registered routes must deny before startup, including failed database/provider load.
local value, err = callbacks['qbhousing:completeSale'](1, 'forged')
assert(value == nil and type(err) == 'string', 'Callbacks must fail closed while not ready')
assert(#threads == 1, 'Exactly one bootstrap worker')
print(('housing contracts: %d client request sites, all callbacks/events/exports registered; readiness denied'):format(checked))
