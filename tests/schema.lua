local h = dofile('../kora_core/test/harness.lua')

Kora = { sql = { NULL = '__NULL__' } }
dofile('server/schema.lua')

h.test('schema declares every housing table parents-first with foreign keys resolving', function()
    h.assertEqual(#QBHousingSchema, 29)
    local seen = {}
    for _, spec in ipairs(QBHousingSchema) do
        for _, fk in ipairs(spec.foreign or {}) do
            h.assertTrue(seen[fk.ref_table], spec.name .. ' references ' .. fk.ref_table .. ' before it is declared')
        end
        seen[spec.name] = true
    end
    for _, name in ipairs({ 'qbhousing_properties', 'qbhousing_listings', 'qbhousing_leases', 'qbhousing_stock_import', 'qbhousing_alarms' }) do
        h.assertTrue(seen[name], name)
    end
end)

h.test('main.lua creates structure through the declarative schema, not sql files', function()
    local file = assert(io.open('server/main.lua')); local source = file:read('a'); file:close()
    h.assertTrue(source:find('Kora.sql.ensureTables(QBHousingSchema)', 1, true))
    h.assertEqual(source:find('migrateFiles', 1, true), nil)
end)

h.report('qbhousing schema')
