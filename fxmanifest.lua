fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qbhousing'
author 'qbcore2'
description 'Server-authoritative QBCore housing and real-estate listings'
version '1.0.0'

dependency 'qblib'
dependency 'qbsql'
dependency 'qbcore'
dependency 'qbinterior'
dependency 'qbtarget'
dependency 'qbbanking'
dependency 'qbinventory'
dependency 'qbgarages'
dependency 'qbdoorlock'
dependency 'qbdispatch'

shared_scripts {
    '@qblib/init.lua',
    '@qbsql/init.lua',
    '@qbcore/init.lua',
    'config.lua',
    'shared/schema.lua',
    'shared/permissions.lua',
}

server_scripts {
    'server/state.lua',
    'server/permissions.lua',
    'server/ownership.lua',
    'server/properties.lua',
    'server/domain.lua',
    'server/transactions.lua',
    'server/sales.lua',
    'server/leases.lua',
    'server/world.lua',
    'server/storage.lua',
    'server/doors.lua',
    'server/admin.lua',
    'server/main.lua',
}

client_scripts {
    'client/world.lua',
    'client/gameplay.lua',
    'client/app.lua',
    'client/main.lua',
}

files { 'sql/*.sql', 'locales/*.lua' }
