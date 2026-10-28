# QB Housing architecture and implementation proposal

Status: the user authorized completion after Phase 1. All implementation phases are now represented in the working tree; see [operations](OPERATIONS.md) and [executed acceptance](ACCEPTANCE.md) for final contracts, checks and live limitations. The phase table below preserves the approved architecture, not a list of still-missing features. The user delegated policy choices on 15 October 2026 with permission to revisit them.

Build incrementally inside kora_housing using procedural Lua, plain tables, kora_lib AppShell, kora_sql, and the installed integrations. Preserve stable property IDs and public contracts. Add only the missing authoritative integration capabilities identified in the [verified matrix](/root/qblib-test-server/resources/[test]/kora_housing/docs/INTEGRATION_MATRIX.md). No independent inventory, banking, frontend, CSS system, or routing buckets are proposed.

## Configurable gameplay defaults

Policy versions are recorded on financial operations and leases. Editing configuration applies to new agreements; it must not retroactively change an accepted sale, rent period, deposit, or recovery entitlement.

| Area | Selected default | Consequence and configurability |
| --- | --- | --- |
| Ownership | Unlimited primary properties; equal co-owner management rights except primary-only membership changes. All current owners approve a sale. | Ownership is independent of tenancy and access grants. A membership change invalidates pending sale approvals. |
| Commission | Public agent and agent-facilitated off-market sales: 3.5% society plus 2.5% recorded agent. Direct owner-to-buyer private sales: 0%. | One channel-specific policy table; existing commission config keys retained and explicitly migrated for the new workflow. Existing old values are reported before activation. No government share. |
| Rounding and proceeds | Whole currency units. Floor each commission leg. Divide remaining proceeds equally among current owners; any integer remainder goes to primary owner. | This is a payout rule, not persistent fractional title ownership. Show every leg before approval. Initial unowned-property sales route net proceeds to the configured real-estate society account, with the agent leg separate. |
| Co-owner departure | Primary owner manages membership. No automatic buyout, debt, inheritance, or transfer of a fractional interest. Voluntary departure is a request to the primary owner. | The removal confirmation explains that no buyout is paid, and membership changes are audited. Existing owners are warned that removal does not pay a share; a sale is the supported cash-settlement path. |
| Listings | Only authorized agents publish listings; owner authorization is required for owned properties. One active listing per property. | Biography, asking price, offers above/below ask, agent recommendation, seller decision, and each approval are persistent. Rejection or expiry does not erase history. |
| Sale conditions | Block sale while an active lease, eviction, another financial operation, or nonempty owner/shared stash affects the property. | No silent transfer of belongings, tenant contract or deposit. All sale channels use the same settlement service. Stash-empty checks must be protected against concurrent deposits through settlement. |
| Rent timing | First rent is charged on tenant acceptance. Schedule is anchored to lease activation, with unique 24-hour/7-day periods. Advance next_due after each confirmed paid or missed period; provider ambiguity stays pending. | UTC timestamps for persistence; UI displays local time. No calendar-midnight/DST surprise. Lease activation waits for confirmed first payment. |
| Lease duration and termination | Rolling daily/weekly lease. Either party may request end at the end of the current paid period. No automatic early-exit fee or prorated refund. | End requests are recorded and visible to both parties. Active lease terms cannot be silently edited. Administrative intervention requires a reason and audit. |
| Missed rent | Confirmed insufficient funds immediately misses that unique period. Evict after 3 consecutive daily or 2 consecutive weekly misses; a confirmed paid period resets the consecutive count. | Provider/DB outage remains pending and never counts as insufficient funds. Process due periods chronologically after restart; each period is charged at most once. |
| Deposits | Disabled by default; landlord may specify a deposit before lease acceptance. Hold funds in confirmed escrow. | Deductions are itemized unpaid rent or documented damage, requiring tenant agreement or audited admin resolution. After the configured 48-hour end-of-lease review, refund undisputed balance; proposed/disputed amounts stay in escrow. No automatic damage assessment. |
| Tenant permissions | Default entry, lease stash, garage and furniture placement/removal of tenant-owned placements. No sales, co-owner, camera-viewing, or access-sharing right. | Owner can set individual action grants before lease acceptance. Owner/co-owner physical entry, tenant stash, and furniture actions are suspended during tenancy unless explicitly authorized by tenant; title/financial management remains. Restore owner physical access after completed termination. |
| Keys and guests | New key grants authorize entry only; guests have no rights without an explicit grant. | Other actions are individually selectable. Preserve existing legacy boolean keys as entry-only grants. No key or guest becomes an owner or tenant. |
| Recovery | Indefinite protected retention by default; no automatic item destruction, sale, or expiry. | Existing tenant stash is retained under its lease identity and reclassified as recovery. Tenant-owned furniture is recovered as the original placement/model entitlement, not an invented inventory item. Subsequent tenancy gets a different stash. |
| Vehicles after eviction or sale | Vehicle title never transfers with housing. Former authorized users may retrieve their own vehicles through an exterior recovery action; they cannot store new ones. | Keep vehicle records and garage association until retrieval. No deletion, forced impound, or duplicate spawn. New owner capacity excludes vehicles in retrieval-only recovery. |
| Storage | Base 50 slots/100000 weight units, matching installed inventory defaults. Next tier 75/150000 for $10000; next tier 100/200000 for $25000 additional. | Prices/capacities are editable before activation. Upgrades belong to property, survive sale, and are sequential; no automatic refund or downgrade. Tenant purchases require storage-upgrade permission and an explicit no-refund acknowledgement. |
| Furniture | Default limit 100 per independently configurable property type, preserving existing maxFurniture baseline. Only configured object models; no peds or vehicles. | Object counts, bounds and ownership validated on server. Placed owner fixtures stay with property on sale; tenant placements go to tenant recovery at tenancy end. |
| Shared interiors | Distinct, non-overlapping physical origins for independently furnished shell properties in the same world. MLO units use distinct authored bounds. | Multiple users of one physical space see the same authoritative furniture set. Building common areas have their own space/property identity. Reject overlapping private layouts; no client-specific invisible collisions or buckets. |
| Cameras | Native scripted view from a physical security console in the same streamed property scene; camera must be within 100m of viewer. One active feed per client, initially maximum 4 viewers per property. | These are configurable admission limits, not measured performance claims. Distant online viewing is excluded until a successful scope prototype. Occupants receive camera-present notice. Placement grants do not confer viewing rights. |
| Police access | Explicit owner grant to a named character, default expiry 24 hours; no job-only bypass. | Revoke immediately closes active authorized sessions and blocks further opens/switches. Session expires within 5 minutes and requires fresh authorization. Ownership/lease changes invalidate sessions. |
| Alarms | Initially disarmed. Authorized user arms/disarms. Default trigger is a server-confirmed mapped door unlock by someone lacking property entry permission, plus an explicit authorized panic action. | No invented movement detector or trusted client breach report. 60-second persistent per-property dispatch cooldown. Dispatch title Property alarm, code HSG-ALARM, police recipients, configured priority/duration. Admin and scripted maintenance changes do not trigger unless explicitly configured. |
| Removal | Admin-only archival. Refuse archival during active leases, eviction, unresolved deposits, or financial operations. | Preserve ownership, audit, financial rows, items and vehicle title. Stop listings and new occupancy. Snapshot current owner/co-owner access to shared stashes as retrieval-only; do not infer item title or let later grants expose those contents. Garage becomes retrieval-only until emptied. Permanent deletion is not exposed. |

These defaults resolve the missing choices rather than treating checked checklist boxes as policy values. Configuration may change future rules; no destructive action or retroactive economic migration should be inferred from that configurability.

## Modules and dependency boundaries

Keep one function table per meaningful service; no classes, factories, generic repositories, or metatable architecture. Split a file only when it holds an independent responsibility. Network callbacks call services, services validate and persist, adapters call verified external APIs. Internal functions normally return `true,result` / `false,reason`; legacy callbacks retain their existing result shapes.

| Files to create or evolve | Responsibility |
| --- | --- |
| shared/schema.lua, shared/permissions.lua, config.lua, locales/en.lua | Type-aware validation, action names, public configuration and translations. Preserve unknown legacy JSON fields. |
| server/state.lua, server/properties.lua | Registry, typed property configuration, revisions, bounded snapshots, physical-space references, authorized creation/editing. Publish changes only after persistence succeeds. |
| server/ownership.lua, server/permissions.lua | Primary/co-owner relationships, membership changes, individual grants, active tenancy rules, authorization and revocation. |
| server/transactions.lua, server/adapters/banking.lua | Persistent operation identity, property locks, escrow/settlement receipts, ledger, restart reconciliation. One shared money path. |
| server/sales.lua | Public/private/off-market listing, offer, recommendation, approval and decision history; invokes shared transaction service. |
| server/leases.lua, server/recovery.lua | Lease acceptance, due periods, deposits, eviction, recovery entitlements and claim lifecycle. |
| server/storage.lua, server/adapters/inventory.lua | Property/lease stash identities, authoritative policy rebind, storage purchase and recovery operations. |
| server/interiors.lua, server/adapters/doors.lua | Shared physical-space/occupant state, entry/exit authorization, door mapping and integration lifecycle. |
| server/furniture.lua, server/security.lua, server/adapters/garages.lua | Validated placements, camera/alarms, and garage registrations/policies. Separate only as implementation grows. |
| server/admin.lua, server/audit.lua | Archive preflight/confirmation, migration diagnostics, authorized audit views, append-only administrative history. |
| server/main.lua | Bootstrap, readiness, callback registration and compatibility wrappers. Keep domain logic in the services above. |
| client/main.lua, client/app.lua, client/interiors.lua, client/furniture.lua, client/security.lua | Commands, AppShell definitions/actions, shared physical visuals, existing placement tool orchestration, local camera view and cleanup. |
| sql/002_*.sql onward, tests/* | Additive migrations, conversion fixtures and meaningful behavior/failure tests. |

Do not generate all these files as empty modules. Each phase ships complete behavior through persistence, server authorization, verified integration and AppShell, with its own tests.

## Property and relational model

Retain `qbhousing_properties.id VARCHAR(64)` as the external property identity. Retain `owner VARCHAR(50)` as the canonical primary owner, naturally permitting at most one primary owner. Add co-owner rows independently; do not invent an ownership percentage field. IDs never derive from owner, tenancy, listing, camera, or furniture state.

Add property type, status, revision and ownership revision. Store parent/unit and physical-space links in new housing relationship tables whose CREATE statements can establish foreign keys without unsupported ALTER constraints on the existing property table. Configuration JSON is suitable for entrances, bounds and flexible type settings. Relationship and monetary rows below must be queryable independently of that JSON. `definition` remains a compatibility representation written in the same transaction as authoritative changes.

| Proposed table group | Required relationships, constraints and indexes |
| --- | --- |
| qbhousing_properties, qbhousing_units, qbhousing_spaces and qbhousing_property_spaces | Existing property PK; new unit relationship has unique child property and parent FK, with unit label; indexed owner/type/status; revision for compare-and-set. New property-space link carries its FKs. Spaces store stable origin/bounds/interior configuration and one coherent rendering set. |
| qbhousing_coowners | Composite PK(property_id,citizenid), creator/timestamps; reject primary duplicated as co-owner inside locked membership transaction; index citizenid. |
| qbhousing_permissions | Property/character/action grant, grantor, expiry and revision; unique subject/action per property. Separate role/relationship from an allowed action. Tenant overrides reference lease. |
| qbhousing_listings, qbhousing_offers, qbhousing_sale_approvals | Property/seller/agent/channel/biography/price/status/revision; offer buyer/amount/status/recommendation; approvals unique(sale_id,citizenid) bound to price, membership and offer revisions. Enforce one active listing and sale through a locked property operation slot and tested uniqueness. |
| qbhousing_transactions, qbhousing_ledger | Unique resource-scoped operation key and immutable fingerprint, kind, property/lease/offer references, policy version, provider reservation/receipt and status; ledger has unique(operation_id,leg) and immutable amounts/accounts/outcomes. |
| qbhousing_leases, qbhousing_rent_periods | Property/tenant/terms, paid-through and next due; one active lease per unit; unique(lease_id,period_start), due index(status,due_at), payment operation reference and missed outcome. |
| qbhousing_deposits, qbhousing_deposit_deductions | Lease/escrow transaction, amount, itemized category/evidence/note, proposed/agreed/disputed/resolved status, approvers and refund operation. |
| qbhousing_stashes, qbhousing_storage_purchases | Property/optional lease, unique inventory reference, tier, lifecycle; unique operation and upgrade transition to block duplicate purchases. Capacities are trusted server configuration. |
| qbhousing_furniture | Property/space, stable placement ID, allowlisted model, full position/rotation, placer, owner/lease provenance, revision. No client-selected authoritative price or ownership. |
| qbhousing_cameras, qbhousing_camera_grants, qbhousing_alarms | Property/space, approved transform/FOV/console, named viewers/expiry, arming/configuration and persistent dispatch cooldown. Index camera/property and grant subject. |
| qbhousing_evictions, qbhousing_recovery, qbhousing_recovery_claims | Unique lease eviction, property/tenant, retained inventory or furniture entitlement, claim operation/receipt and status; unique entitlement claim prevents duplicated delivery. |
| qbhousing_audit | Actor character/resource, target, property/operation, action/outcome, timestamp and bounded context. Index property/time and operation; never log full player data, license identifiers, or secrets. |

All new character IDs match core VARCHAR(50). Housing-owned child FKs should reject accidental deletion. Keep history after character soft deletion; no cascade into financial history. Verify deployed types/collations and orphan rows before adding any FK to players. Use JSON/LONGTEXT only for flexible definitions or bounded metadata, not transactional relationships. Convert SQL IDs/dates to a documented string/UTC timestamp boundary rather than relying on JavaScript Date coercion.

## Migration and recovery plan

1. Back up housing, relevant banking/player money, inventory and vehicle data with a restore drill in a disposable database. Inventory/core own those tables; housing migrations do not rewrite them directly.
2. Keep migration 001 unchanged. Add retry-safe numbered schema migrations using the actual kora_sql runner. Define housing-child foreign keys in new CREATE TABLE statements, then convert rows into them after validation. The runner does not support adding foreign keys with ALTER; the proposed relationship tables avoid that requirement. Deployed legacy character FKs remain conditional on a separately reviewed compatible migration capability. Do not assume DDL rolls back.
3. Preserve each original housing row and raw JSON in a migration backup table with checksum. Report invalid JSON, row/definition ID mismatches, orphan characters, unknown type, invalid coordinates, and missing shells. Activation stops on unresolved conflicts rather than dropping data.
4. Preserve IDs, owner, legacy key map, all placements/stash references and unknown fields. Old shell/MLO data has no gameplay type: flag as legacy-unclassified for admin selection before enabling type-specific operations; do not infer apartment versus house from a model name.
5. Backfill explicit relationships idempotently. Do not turn an old pending purchase into an approved sale or an old soldPrice into a confirmed ledger entry. Preserve them as legacy history needing reconciliation.
6. Keep old JSON/API projections synchronized transactionally. Test legacy `nil/false` shapes and fixture snapshots. Existing limits and shell-price bounds remain explicit legacy compatibility settings; new type-aware creator can create land without forcing garage/interior fields.
7. Cut over after row counts, sums, references and effective permissions match a dry-run report. If deployment fails before new writes, restore backup and old resource. After new financial/gameplay writes, use forward repair and reconciliation; restoring old money snapshots would duplicate or erase transactions.

No down-migration or rollback SQL is supplied in this proposal because no new migration is being applied. Implementation must supply the restore/forward-repair runbook with the actual migration files.

## Shared permission service

Every protected server operation calls the same `can(source,propertyId,action,context)` service. Resolve source to character server-side, load authoritative relationship/status, check required proximity/space, then action permission. Unknown actions, missing dependencies, expired grants and missing required policy deny access. In-memory caches carry a permission revision and invalidate on membership, lease, grant, archival and integration restart.

Action groups include entry, furniture place/move/remove, stash open, storage upgrade, garage list/store/retrieve, camera view/manage, alarm arm/configure, access share, listing/offer/sale actions, lease management, property configuration and archive. Identity relationships never imply each other's rights.

Primary and co-owner share property management rights; only primary changes co-owner membership. All owners approve sale. Active lease rules protect tenant occupancy and lease belongings. Key holders have entry by default; guests need an explicit grant. Agents may act only on authorized listings/assignments; job does not grant tenant stash, camera or entry access. Admin operations use framework authorization, explicit reason where destructive, and audit. Police viewing requires named owner authorization even for admins acting as police.

External integrations must enforce the same permission at the actual action boundary: inventory each open/transfer, garages list/store/spawn, doorlock toggle, camera session open/switch, and furniture persistence. UI controls reflect allowed actions but never supply authority. Revocation closes affected sessions and prevents new operations without restart.

## Financial consistency strategy

The existing APIs cannot meet durable, exactly-once settlement. Add a narrowly scoped kora_banking reservation/receipt capability coordinated with kora_core's online/offline money and persistence. Proposed capabilities are reserve bank funds, get operation receipt, settle explicit credit legs, and release reservation. These are **not existing export names**.

Each provider operation stores its immutable argument fingerprint, resource/key, balance mutation and receipt in one checked database transaction. Same key/same request returns the recorded outcome; same key/different request fails. Confirmed insufficient funds, provider unavailable, rejected, and indeterminate are distinct outcomes. An ambiguous call result leads to receipt lookup using the same key, never a new debit key.

Core coordination must serialize ordinary money changes, queued saves of the entire money column, character login/logout and offline updates. Direct housing SQL against players.money is prohibited: a delayed core save could overwrite it. Preserve existing public money export contracts. Prove the new boundary with interleaved core writes before integrating housing sales.

For kora_sql, add a checked transaction primitive or validate a Lua bridge to its existing pinned JS transaction. Required behavior: inspect row counts and roll back before commit if funds/revision/claim preconditions change zero rows. Do not change existing transaction semantics for other callers.

Sale processing uses a small durable workflow:

1. Validate actor, seller/buyer identities, active property status, agent assignment, price, payout accounts, all ownership approvals and policy. Persist one property operation lock with the reviewed revisions and operation key.
2. Reserve the buyer's gross amount into bank-owned escrow. Require a confirmed durable receipt. Failure leaves ownership unchanged; insufficient funds is a final rejected operation, while ambiguity remains pending.
3. Revalidate property and approvals. Commit the ownership transition, cleared/rebased access, sale history and pending settlement record together through checked SQL. The property remains finalizing and cannot be resold or leased.
4. Settle escrow to the recorded owner/society/agent legs exactly once. Publish completed ownership and a success message only after the confirmed settlement and final housing commit. While finalizing, effective permissions must not expose a half-complete sale as completed.
5. Before the ownership transition, failed validation releases escrow idempotently. After transition, recovery finishes settlement using the stored fingerprint; no blind refund or ad hoc owner reversal. Indeterminate operations remain locked and visible to reconciliation administrators.

This is an idempotent escrow workflow across integrations, not a claim that independent exports share one ACID transaction. Its guarantee depends on the provider extension being implemented and tested. Persistent locks survive restart, and reconciliation runs at startup and on relevant provider recovery. Bounded timers handle pending work; no client polling or arbitrary timed lock expiration can authorize a second sale.

Rent, deposits, storage upgrades and refunds use that same service. Each rent period has a unique key; a repeated callback/restart obtains its existing outcome. Eviction starts once per lease after confirmed missed thresholds. Charge periods must never increment misses merely because SQL or banking is offline.

## Interiors and furniture

Separate a logical property from a physical space. A standalone shell receives a validated stable origin distinct from other independently furnished properties. A building has common-space identity plus explicit units; shared MLO space uses authored unit bounds. Land has exterior bounds and no mandatory interior, stash or garage. Hotel/motel buildings and units use the same parent/unit model; unit inventory/tenancy is not stored on the building parent.

The server authorizes entry and protected interactions and maintains occupants. Physical MLO walking cannot be made perfectly server-enforced by a menu callback; use configured physical doorlocks and server validation of valuable actions. No teleport event is treated as a security boundary against a modified client.

Reuse kora_interior geometry, kora_lib resource-owned local entities, kora_target fixtures and existing cleanup. First add a geometry-only creation option/export to kora_interior, preserving its current automatic teleport by default; background streaming through the current createShell would teleport nearby users or camera viewers. Entry then explicitly orchestrates the appropriate teleport. Locally spawned scenery must derive from the same server-approved space revision for every occupant; that is shared rendering, not private per-player instances. Stream only relevant spaces, reference count local geometry, and remove resource-owned entities when no longer relevant or on stop. Collision, occupants, furniture, camera-visible geometry and reconnect behavior need two-client acceptance before release.

Furniture placement requests a server session for an allowlisted model/property and current permission revision. Close AppShell through its world-editor action pattern. Use an additive kora_lib placement options argument for initial transform, bounds, numeric position/rotation, camera raycast movement and gameplay confirmation without copying a developer snippet. Preserve the existing start(model) tool.

Server confirmation checks session/actor/model, finite coordinates and rotation, bounds, count, placement revision and current authorization. The server cannot independently prove a client's raycast hit; enforce trusted bounds/model rules instead. Persist one placement before broadcasting its revision. On cancel/error/revocation/disconnect/stop, delete previews, release models/camera/controls/focus, and invalidate the session. Never use kora_lib for prop-to-bone attachment; any future attachment follows the numeric-bone project convention.

## Inventory and recovery

Use stable inventory references: owner fixture IDs remain property-based; tenant belongings use lease-based IDs. Owner/shared stash contents must be empty and locked against new deposits before sale settlement. During tenancy, those owner fixtures never become the tenant's inventory; lease stashes are separate. Inventory still owns all item contents and transfer logic. Housing owns access, tier and entitlement metadata.

Extend the existing inventory registration boundary to rebind housing's resource-owned access callback after either resource restarts. Persist accessRequired so an unavailable policy denies access. Inventory's current canAccess and transfer lock already support repeated checks. An openInventory hook alone is insufficient because its exceptions allow access and hooks disappear on housing stop.

Eviction freezes tenant property actions, records the unique eviction, marks lease stash/furniture as protected recovery, installs the recovery access boundary, and only then completes tenancy/access restoration. Do not copy items with a get/set pair or the unsafe internal rename path. New tenancy receives a different stash; owner never gains the evicted stash.

Item recovery claims require an inventory-owned durable operation with a stable claim key and receipt covering both source and destination. Current in-memory transfer plus periodic flush is insufficient to promise exactly-once delivery after crash. A retry must return the original receipt, not deliver again. Full destination inventory leaves the entitlement available. Furniture recovery instead atomically consumes its housing entitlement and inserts one validated placement at an authorized destination property; it does not invent a matching inventory item. Optional kora_phone mail notifies the tenant; the actual claim interface remains housing AppShell with the appropriate server-authorized operation.

## Garage and security integrations

Add property garage registration/policy support to kora_garages; keep its existing callbacks and public/job/gang garages. Apply housing permission to every list/store/spawn path. Reuse kora_core per-plate locking/conditional state handling through kora_garages. Validate submitted entity existence, plate, owner, distance, expected state and routing context before persistence or deletion. Persist garage_id and capacity only for opted-in property garages, preserving legacy public behavior.

The garage identifier column is 50 characters while property IDs are 64; use a mapped durable short garage key, not string concatenation that can truncate. Recovery vehicle access is entitlement to retrieve that player's own stored vehicle, not continuing property ownership or permission.

Door policy must be opt-in and authoritative for mapped housing doors. Existing grant-only hooks cannot veto. An absent housing policy must fail closed for those doors, while ordinary doors retain existing behavior. Track whether housing created a door or references another resource's door; property lifecycle must not delete external assets.

Camera sessions validate named grants and property state server-side, use bounded admission tokens and owner-managed revocation. A physical camera view is local rendering, not a remote streaming service. Profile 1, 2 and 4 viewers with actual occupants; do not claim the configured limit is tested capacity. Close sessions on revoke, expiry, property change, exit, disconnect and stop; restore camera, controls, streaming focus and NUI state.

Alarm triggers consume verified server door state/panic signals. A server door unlock event includes actor and used item but does not independently label burglary; consult housing entry permission rather than guessing from an item name. A persisted cooldown and event key prevent duplicate dispatch. Include only approved property location/label and alarm type in the dispatch payload, and add kora_housing to trusted callers.

## AppShell and proposed API inventory

Keep the current app ID as a compatibility entry and build one shared housing shell with Marketplace, My Properties, Offers, Leases and Payments, Recovery, and authorized Agent/Admin navigation. Property tabs cover overview, people/access, sales, tenancy, storage/garage, furniture, cameras/alarms and history. Use shared details/list/table/form/timeline/stats blocks and existing busy/error/confirmation behavior. No browser project or housing CSS is needed.

The creator uses property-type-aware shared forms. Standalone house/apartment/mansion/commercial/unit can choose shell or MLO; hotel/motel/building parents configure common spaces and units; land configures exterior bounds with optional supported fixtures. Never require an irrelevant shell, garage or stash. Property identity, price/listing, entrance/exit, bounds, door IDs, fixtures and type settings each receive server validation. Editing loads existing values and checks revision.

The callback names below are **proposed additions**, to be registered and tested in their owning phase. All receive framework-provided source; client payloads contain only allowed inputs and expected revisions. Reads return authorized projections; new mutations return `true,result` or `false,reason`. The established callbacks listed in the audit retain signatures/results through adapters, with explicitly required security/workflow corrections documented.

| Capability | Proposed kora_housing callback names | Required server gate |
| --- | --- | --- |
| Property and creator | propertyView, createProperty, editProperty, creatorSnapshot | Authorized view; create/edit authority, typed schema, expected revision |
| Ownership and grants | coowners, permissions, setPermission | Owner management; primary-only co-owner edits; valid target character |
| Sales | createListing, submitOffer, recommendOffer, decideOffer, approveSale, directSale, saleStatus | Agent assignment or owner authority; buyer identity; immutable reviewed terms; all owners |
| Leases | proposeLease, acceptLease, requestLeaseEnd, leasePayments, depositDecision | Parties, versioned terms, unique period and financial operation |
| Storage and recovery | openStash, purchaseStorage, recoveryList, claimRecovery | Current action permission/proximity; inventory-authorized durable operation |
| Furniture | beginPlacement, savePlacement, removePlacement | Session, model, bounds, count, permission and placement revision |
| Security | saveCamera, cameraGrant, openCamera, switchCamera, closeCamera, configureAlarm, armAlarm, panic | Explicit action grant; session identity/expiry; trusted server alarm context |
| Administration | auditView, archivePreflight, archiveProperty, reconcileOperation | Admin permission; revision-bound confirmation token; dependency preflight |

Garages continue to use kora_garages interfaces with the new server policy boundary. Door state continues through kora_doorlock. A proposed additive server HasPermission(source,propertyId,action) export exposes the same boolean authorization service; GetProperty and HasAccess retain their established contracts. No financial network event bypasses shared services. New outbound events carry only authorized property/space revisions, session invalidation and relevant notifications. Register and unregister every handler with dependency/resource lifecycle; document exact payloads when implemented rather than inventing current contracts.

## Dependency ordered delivery phases

| Phase | Concrete files and delivered behavior | Acceptance before proceeding |
| --- | --- | --- |
| 1 Registry and access | Evolve shared/schema.lua, server/state.lua/main.lua, config.lua, client/main.lua; add properties/ownership/permissions/audit, AppShell creator/people views and additive migration. Preserve legacy snapshots and API wrappers. | Migration dry-run keeps IDs/unknown data; invalid rows reported; unlimited ownership; no duplicate co-owner; primary-only membership; revoked grant immediately denies; real edit loads prior values; land does not require garage; no live-state mutation on SQL failure. |
| 2 Durable integration boundaries | Add tested banking/core reservation+receipt coordination, checked kora_sql transaction boundary, inventory access rebind/durable claim primitives, opt-in garage/door policy seams. Integration tests cover their real contracts. | Restart at every provider commit boundary; interleaved queued core saves cannot restore spent money; zero-row conditional failure rolls back; same key/same request returns same receipt, changed request rejects; stopped housing denies mapped stash/door/garage access. Existing dependency suites remain green. |
| 3 Complete sales | Add transactions/sales, relational listing/offer/approval/ledger migrations and AppShell market/private-sale/agent/history actions. | Two buyers cannot both acquire same property; duplicate submit/confirm cannot double debit; insufficient funds causes no transfer; export/SQL failure stays rejected or recoverable; all co-owners approve exact terms; price/membership changes invalidate approvals; all three channels settle identical underlying services and confirmed payout sums. |
| 4 Physical access and furniture | Add interiors/furniture, typed physical spaces, kora_interior geometry-only capability, verified kora_target/kora_doorlock/garage integration, additive placement options and shared editor UI. | Two occupants see same saved transform/collision; background shell loading never teleports nearby viewers; distinct properties do not overlap private layouts; valid model/bounds/count enforced server-side; invalid/revoked requests denied; preview/model/camera/zone cleanup on cancel/error/stop; unauthorized garage list/store/retrieve rejected; no duplicate vehicle spawn. |
| 5 Rentals storage and recovery | Add leases/recovery/storage, their normalized tables, due-work processing, deposit and inventory integration, AppShell agreement/payment/upgrade/recovery views and optional mail notice. | Unique period prevents double debit across restart; immediate insufficient-funds miss, correct 3/2 eviction threshold; repeated eviction does not repeat recovery; owner access restored only after protected recovery is installed; claim retries and inventory-full failures cannot duplicate/lose items; tier charged/applied once; disputed deposit stays accounted for. |
| 6 Cameras alarms and archival | Add security/admin workflows, camera/grant/alarm schema, dispatch trust config, AppShell security/audit/archive preflight. | Actual 1/2/4 viewer prototype within allowed scene; expiry/revoke closes feeds; unauthorized police denied; occupants informed; alarm cooldown persists after restart; forged client alarms denied; only admin may archive, with active lease/money/deposit blocks and all belongings/vehicles preserved. |
| 7 Release audit | Complete resource manifest, README/install/config/migration/reconciliation runbooks and end-to-end acceptance record. | Verify every callback/event registered and used; all protected actions share permission checks; migration compatibility; all money legs reconcile; restart/disconnect/provider outages exercised; no lifecycle leaks, placeholder UI or duplicate business logic; report every unexecuted live check. |

Phase 1 proceeds independently of later financial or rendering prototypes. A phase is complete only when its actual persistence, server and UI path works within the verified test environment. Live FiveM acceptance remains a separate release gate. Later phases do not bypass unresolved technical guarantees to appear complete.

## Release and installation requirements

Keep kora_lib, kora_sql, kora_core and the required integrations ahead of housing in resource startup order. Add inventory, doorlock, garages and dispatch manifest dependencies when their features become required; optional mail must degrade cleanly. Verify dependency readiness and rebind policies after either side restarts, using events rather than permanent health polling.

Installation documentation must name the tested server/database versions, migration backup/repair steps, explicit gameplay defaults and legacy config mapping, available shell asset packs, physical-space authoring, dispatch trust entry, storage units/prices, camera scope limits and administrative reconciliation procedure. Do not install or apply migrations from this proposal alone.

Local implementation is complete and its executed verification is recorded in ACCEPTANCE.md. Baseline and Phase 1 notes are historical. Live FiveM acceptance remains a production release gate and is not claimed by the automated checks.
