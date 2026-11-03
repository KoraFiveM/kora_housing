local NULL = Kora.sql.NULL

local function str(name, length, null)
    if null then return { name = name, type = ('varchar(%d)'):format(length), null = true, default = NULL } end
    return { name = name, type = ('varchar(%d)'):format(length) }
end
local function big(name, unsigned, null, default)
    if null then return { name = name, type = 'bigint', unsigned = unsigned, null = true, default = NULL } end
    return { name = name, type = 'bigint', unsigned = unsigned, default = default }
end
local function int(name, default, null)
    if null then return { name = name, type = 'int', unsigned = true, null = true, default = NULL } end
    return { name = name, type = 'int', unsigned = true, default = default }
end
local function text(name, kind, null)
    if null then return { name = name, type = kind, null = true, default = NULL } end
    return { name = name, type = kind }
end
local function flag(name) return { name = name, type = 'tinyint(1)' } end
local function fk(name, column, table_name, ref)
    return { name = name, columns = { column }, ref_table = table_name, ref_columns = { ref or 'id' } }
end
local function activeColumn(_, expr)
    return { name = 'active_property', type = 'varchar(64)', generated = { expr = expr } }
end

QBHousingSchema = {
    {
        name = 'qbhousing_properties',
        columns = {
            str('id', 64), str('owner', 50, true), text('definition', 'longtext'),
            { name = 'updated_at', type = 'timestamp', default = { raw = 'CURRENT_TIMESTAMP' }, on_update = 'CURRENT_TIMESTAMP' },
            { name = 'property_type', type = 'varchar(24)', default = 'legacy' },
            int('revision', 0), int('ownership_revision', 0),
        },
        primary = { 'id' },
        indexes = { { name = 'idx_qbhousing_owner', columns = { 'owner' } } },
    },
    {
        name = 'qbhousing_legacy_backup',
        columns = {
            str('property_id', 64), str('owner', 50, true), text('definition', 'longtext'),
            { name = 'definition_sha256', type = 'char(64)' },
            { name = 'captured_at', type = 'timestamp', default = { raw = 'CURRENT_TIMESTAMP' } },
        },
        primary = { 'property_id' },
    },
    {
        name = 'qbhousing_coowners',
        columns = { str('property_id', 64), str('citizenid', 50) },
        primary = { 'property_id', 'citizenid' },
        indexes = { { name = 'idx_qbhousing_coowner', columns = { 'citizenid' } } },
        foreign = { fk('fk_qbhousing_coowners_property', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_permissions',
        columns = { str('property_id', 64), str('citizenid', 50), str('action', 48), flag('allowed') },
        primary = { 'property_id', 'citizenid', 'action' },
        indexes = { { name = 'idx_qbhousing_permission_subject', columns = { 'citizenid' } } },
        foreign = { fk('fk_qbhousing_permissions_property', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_units',
        columns = { str('property_id', 64), str('parent_id', 64), str('unit_label', 50, true) },
        primary = { 'property_id' },
        indexes = { { name = 'idx_qbhousing_unit_parent', columns = { 'parent_id' } } },
        foreign = {
            fk('fk_qbhousing_unit_property', 'property_id', 'qbhousing_properties'),
            fk('fk_qbhousing_unit_parent', 'parent_id', 'qbhousing_properties'),
        },
    },
    {
        name = 'qbhousing_audit',
        columns = {
            { name = 'id', type = 'bigint', unsigned = true, auto_increment = true },
            str('property_id', 64), str('actor', 50, true), str('action', 48), str('target', 50, true),
            str('outcome', 16), text('context', 'longtext'),
            { name = 'created_at', type = 'timestamp', default = { raw = 'CURRENT_TIMESTAMP' } },
        },
        primary = { 'id' },
        indexes = { { name = 'idx_qbhousing_audit_property', columns = { 'property_id', 'created_at' } } },
    },
    {
        name = 'qbhousing_agents',
        columns = { str('property_id', 64), str('citizenid', 50) },
        primary = { 'property_id', 'citizenid' },
        foreign = { fk('qbhousing_agents_ibfk_1', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_listings',
        columns = {
            str('id', 64), str('property_id', 64), str('channel', 16), str('seller', 50, true),
            str('agent', 50, true), str('buyer', 50, true), text('biography', 'text'), big('price', true),
            text('commission_policy', 'longtext', true), int('policy_version', 1), str('status', 16),
            int('ownership_revision'), big('created_at'),
            activeColumn('property_id', "CASE WHEN `status`='active' THEN `property_id` ELSE NULL END"),
        },
        primary = { 'id' },
        indexes = {
            { name = 'uq_housing_active_listing', columns = { 'active_property' }, unique = true },
            { name = 'idx_housing_listing_property', columns = { 'property_id', 'created_at' } },
        },
        foreign = { fk('qbhousing_listings_ibfk_1', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_offers',
        columns = {
            str('id', 64), str('listing_id', 64), str('buyer', 50), big('amount', true), str('status', 16),
            text('recommendation', 'text', true), big('created_at'),
            { name = 'accepted_listing', type = 'varchar(64)', generated = { expr = "CASE WHEN `status`='accepted' THEN `listing_id` ELSE NULL END" } },
        },
        primary = { 'id' },
        indexes = {
            { name = 'uq_housing_accepted_offer', columns = { 'accepted_listing' }, unique = true },
            { name = 'idx_housing_offer_buyer', columns = { 'buyer', 'status' } },
            { name = 'listing_id', columns = { 'listing_id' } },
        },
        foreign = { fk('qbhousing_offers_ibfk_1', 'listing_id', 'qbhousing_listings') },
    },
    {
        name = 'qbhousing_sale_approvals',
        columns = { str('offer_id', 64), str('citizenid', 50), int('ownership_revision'), flag('approved') },
        primary = { 'offer_id', 'citizenid' },
        foreign = { fk('qbhousing_sale_approvals_ibfk_1', 'offer_id', 'qbhousing_offers') },
    },
    {
        name = 'qbhousing_offer_history',
        columns = {
            { name = 'id', type = 'bigint', unsigned = true, auto_increment = true },
            str('offer_id', 64), str('actor', 50), str('action', 32), text('note', 'text', true), big('created_at'),
        },
        primary = { 'id' },
        indexes = { { name = 'offer_id', columns = { 'offer_id', 'created_at' } } },
        foreign = { fk('qbhousing_offer_history_ibfk_1', 'offer_id', 'qbhousing_offers') },
    },
    {
        name = 'qbhousing_transactions',
        columns = {
            str('id', 100), str('property_id', 64), str('kind', 24), str('actor', 50, true), str('status', 16),
            text('request', 'longtext'), text('result', 'longtext'), str('error', 256, true),
            big('created_at'), big('updated_at'),
            activeColumn('property_id', "CASE WHEN `status`='pending' THEN `property_id` ELSE NULL END"),
        },
        primary = { 'id' },
        indexes = {
            { name = 'uq_housing_pending_transaction', columns = { 'active_property' }, unique = true },
            { name = 'status', columns = { 'status', 'updated_at' } },
        },
    },
    {
        name = 'qbhousing_ledger',
        columns = { str('operation_id', 100), int('leg'), str('citizenid', 50, true), str('account', 50, true), big('amount'), str('kind', 16) },
        primary = { 'operation_id', 'leg' },
        foreign = { fk('qbhousing_ledger_ibfk_1', 'operation_id', 'qbhousing_transactions') },
    },
    {
        name = 'qbhousing_leases',
        columns = {
            str('id', 64), str('property_id', 64), str('tenant', 50), str('landlord', 50), str('interval_name', 8),
            big('rent', true), big('deposit', true, false, 0), big('deposit_remaining', true, false, 0),
            text('permissions', 'longtext'), str('status', 16), int('revision', 1),
            int('deposit_review_seconds', 172800), int('ownership_revision'), text('owner_payees', 'longtext', true),
            int('missed_limit', nil, true), int('policy_version', 1), big('deposit_release_at', false, true),
            big('next_due', false, true), big('paid_through', false, true), int('missed', 0),
            big('end_at', false, true), big('created_at'),
            activeColumn('property_id', "CASE WHEN `status` IN ('proposed','active','evicting','ending') THEN `property_id` ELSE NULL END"),
        },
        primary = { 'id' },
        indexes = {
            { name = 'uq_housing_active_lease', columns = { 'active_property' }, unique = true },
            { name = 'tenant', columns = { 'tenant', 'status' } },
            { name = 'status', columns = { 'status', 'next_due' } },
            { name = 'property_id', columns = { 'property_id' } },
        },
        foreign = { fk('qbhousing_leases_ibfk_1', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_rent_periods',
        columns = { str('lease_id', 64), big('period_start'), big('period_end'), big('amount', true), str('status', 16), str('operation_id', 100) },
        primary = { 'lease_id', 'period_start' },
        indexes = { { name = 'operation_id', columns = { 'operation_id' }, unique = true } },
        foreign = { fk('qbhousing_rent_periods_ibfk_1', 'lease_id', 'qbhousing_leases') },
    },
    {
        name = 'qbhousing_deposit_deductions',
        columns = {
            str('id', 64), str('lease_id', 64), str('category', 16), big('amount', true), big('approved_amount', true, true),
            text('note', 'text'), text('decision_note', 'text', true), str('status', 16), str('actor', 50), big('created_at'),
        },
        primary = { 'id' },
        indexes = { { name = 'lease_id', columns = { 'lease_id', 'status' } } },
        foreign = { fk('qbhousing_deposit_deductions_ibfk_1', 'lease_id', 'qbhousing_leases') },
    },
    {
        name = 'qbhousing_lease_access',
        columns = { str('lease_id', 64), str('citizenid', 50), str('action', 48), flag('allowed') },
        primary = { 'lease_id', 'citizenid', 'action' },
        foreign = { fk('qbhousing_lease_access_ibfk_1', 'lease_id', 'qbhousing_leases') },
    },
    {
        name = 'qbhousing_stashes',
        columns = { str('id', 100), str('property_id', 64), str('lease_id', 64, true), str('tenant', 50, true), str('status', 16), text('coords', 'longtext') },
        primary = { 'id' },
        indexes = {
            { name = 'property_id', columns = { 'property_id', 'status' } },
            { name = 'tenant', columns = { 'tenant', 'status' } },
        },
    },
    {
        name = 'qbhousing_storage_purchases',
        columns = { str('property_id', 64), int('tier'), str('operation_id', 100), str('buyer', 50) },
        primary = { 'property_id', 'tier' },
        indexes = { { name = 'operation_id', columns = { 'operation_id' }, unique = true } },
    },
    {
        name = 'qbhousing_evictions',
        columns = { str('lease_id', 64), str('reason', 32), str('status', 16), big('created_at') },
        primary = { 'lease_id' },
        foreign = { fk('qbhousing_evictions_ibfk_1', 'lease_id', 'qbhousing_leases') },
    },
    {
        name = 'qbhousing_recovery',
        columns = {
            str('id', 100), str('property_id', 64), str('lease_id', 64, true), str('citizenid', 50),
            str('kind', 16), str('reference', 100), str('status', 16), big('created_at'),
        },
        primary = { 'id' },
        indexes = {
            { name = 'kind', columns = { 'kind', 'reference', 'citizenid' }, unique = true },
            { name = 'citizenid', columns = { 'citizenid', 'status' } },
        },
    },
    {
        name = 'qbhousing_garages',
        columns = { str('property_id', 64), str('garage_key', 50) },
        primary = { 'property_id' },
        indexes = { { name = 'garage_key', columns = { 'garage_key' }, unique = true } },
        foreign = { fk('qbhousing_garages_ibfk_1', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_garage_recovery',
        columns = { str('property_id', 64), str('citizenid', 50) },
        primary = { 'property_id', 'citizenid' },
        foreign = { fk('qbhousing_garage_recovery_ibfk_1', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_spaces',
        columns = { str('property_id', 64), text('definition', 'longtext'), int('revision') },
        primary = { 'property_id' },
        foreign = { fk('fk_qbhousing_space_property', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_furniture',
        columns = {
            str('id', 64), str('property_id', 64), str('owner_cid', 50), str('lease_id', 64, true),
            str('status', 16), text('definition', 'longtext'), int('revision'),
        },
        primary = { 'id' },
        indexes = {
            { name = 'idx_qbhousing_furniture_property', columns = { 'property_id', 'status' } },
            { name = 'idx_qbhousing_furniture_recovery', columns = { 'owner_cid', 'status' } },
        },
        foreign = { fk('fk_qbhousing_furniture_property', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_cameras',
        columns = { str('id', 64), str('property_id', 64), text('definition', 'longtext'), int('revision') },
        primary = { 'id' },
        indexes = { { name = 'idx_qbhousing_camera_property', columns = { 'property_id' } } },
        foreign = { fk('fk_qbhousing_camera_property', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_camera_grants',
        columns = { str('property_id', 64), str('citizenid', 50), big('expires_at', true) },
        primary = { 'property_id', 'citizenid' },
        foreign = { fk('fk_qbhousing_camera_grant_property', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_alarms',
        columns = { str('property_id', 64), text('definition', 'longtext'), int('revision') },
        primary = { 'property_id' },
        foreign = { fk('fk_qbhousing_alarm_property', 'property_id', 'qbhousing_properties') },
    },
    {
        name = 'qbhousing_stock_import',
        columns = {
            str('property_id', 64), text('source_data', 'longtext'), { name = 'source_sha256', type = 'char(64)' },
            { name = 'imported_at', type = 'timestamp', default = { raw = 'CURRENT_TIMESTAMP' } },
        },
        primary = { 'property_id' },
    },
}
