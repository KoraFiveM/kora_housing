fx_version 'cerulean'
game 'gta5'
provide 'qb-houses'
lua54 'yes'

name 'kora_housing'
-- Keep the legacy resource name resolvable for exports['qbhousing'] callers.
provide 'qbhousing'
author 'qbcore2'
description 'Server-authoritative QBCore housing and real-estate listings'
version '1.0.0'

dependency 'kora_lib'
dependency 'kora_sql'
dependency 'kora_core'
dependency 'kora_interior'
dependency 'kora_target'
dependency 'kora_banking'
dependency 'kora_inventory'
dependency 'kora_garages'
dependency 'kora_doorlock'
dependency 'kora_dispatch'

shared_scripts {
    '@kora_lib/init.lua',
    '@kora_sql/init.lua',
    '@kora_core/init.lua',
    'config.lua',
    'shared/schema.lua',
    'shared/permissions.lua',
}

server_scripts {
    'server/state.lua',
    'server/legacy.lua',
    'server/permissions.lua',
    'server/compat.lua',
    'server/compat_sql.lua',
    'server/ownership.lua',
    'server/properties.lua',
    'server/domain.lua',
    'server/transactions.lua',
    'server/sales.lua',
    'server/leases.lua',
    'server/world.lua',
    'server/storage.lua',
    'server/legacy_fixtures.lua',
    'server/doors.lua',
    'server/admin.lua',
    'server/main.lua',
}

client_scripts {
    'client/fixtures.lua',
    'client/world.lua',
    'client/gameplay.lua',
    'client/app.lua',
    'client/main.lua',
}

files { 'sql/*.sql', 'locales/*.lua' }
