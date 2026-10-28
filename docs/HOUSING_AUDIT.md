# QB Housing repository audit

Status: historical baseline audit on 15 October 2026, before Phase 1 changes. Some findings below are now addressed; see [final implementation and acceptance](ACCEPTANCE.md) for the current implementation. Source references describe baseline housing commit 6c03195 and the dependency working trees recorded below. No feature code, schema, configuration, or running resource was changed during the audit itself.

The existing resource is a useful compatibility baseline, but it does not yet implement the requested housing ecosystem. Safe financial settlement, inventory recovery, property garage authorization, and shared interior rendering require work in verified integration boundaries before they can meet the acceptance criteria. AppShell already supplies the required UI foundation.

Read the [integration matrix](/root/qblib-test-server/resources/[test]/kora_housing/docs/INTEGRATION_MATRIX.md) for actual dependency contracts and the [implementation proposal](/root/qblib-test-server/resources/[test]/kora_housing/docs/IMPLEMENTATION_PLAN.md) for the design and approval decisions.

## Existing resource and behavior

The complete resource source consists of:

```text
kora_housing/
  fxmanifest.lua
  config.lua
  README.md
  shared/schema.lua
  server/state.lua
  server/main.lua
  client/main.lua
  sql/001_housing.sql
  tests/run.sh
  tests/purchase.lua
  tests/shell_exit.lua
  test/                         empty directory
```

There is no housing frontend to replace. The client uses kora_lib menus and dialogs, with an existing declarative AppShell realtor dashboard. The server loads properties through kora_sql migrations, keeps a registry, rate limits callbacks, and serializes writes to each property within the running process.

Preserve these useful behaviors and interfaces:

- Stable string property IDs; the supplied shell catalog and relative exit offsets; shell cleanup on resource stop.
- `/realestate` and `/home`, including their configurable command names.
- Existing property JSON, owner values, key holders, furniture, stashes, clothing, doors, garages, and any unknown fields that existing consumers may retain.
- Real estate job and society account configuration; existing limits and configuration keys.
- `GetProperty` snapshots and the existing `HasAccess` entry/key interpretation.
- Purchase validation, the per-property write guard, and the regression coverage around failed persistence and duplicate confirmation.

The current creator supports shell or MLO configuration, not the requested gameplay property types. It requires a garage for every property and lists new properties immediately. Shell prices are constrained to 75–125% of catalog base prices. MLO prices need only be positive. These are existing observable rules, not approved new rules for commercial properties, land, or units. Any replacement must explicitly resolve their applicability.

Furniture, stashes, clothing, and door fields can be persisted, but there is no complete furniture placement/rendering, stash opening, or door registration workflow. The homeowner garage action calls an unverified export and normally reports that its garage is not linked. Co-ownership, custom action permissions, leases, deposits, recovery, storage purchases, camera viewing, alarms, and audit history are absent.

## Current contract inventory

All callback names below have the `qbhousing:` prefix. Registered callbacks return their handler values through the cross-resource kora_lib wrapper. Existing failures are generally `nil, message`; do not change those results to `false` as a style cleanup.

| Callback | Arguments after server source | Existing result and behavior |
| --- | --- | --- |
| `hydrate` | None | `{properties, realtor, citizenid, ready}`; full registry snapshot |
| `saveProperty` | Property table | Saved property or `nil, error`; realtor required, owner retained when editing |
| `catalog` | None | Array of listed property records |
| `realtorDashboard` | None | `{forSale, sold, averagePrice, soldCount}` or `nil, error` |
| `removeProperty` | Property ID | `true` or `nil, error`; currently realtor-only and rejects owned records |
| `offer` | Property ID, optional buyer citizen ID | `true` or `nil, error`; replaces one pending confirmation at asking price |
| `confirmPurchase` | Property ID | Saved property or `nil, error` |
| `keys` | Property ID, `give` or `remove`, target citizen ID | Key map or `nil, error`; primary owner only |
| `update` | Property ID, field, array | Saved property or `nil, error`; supports furniture, stashes, clothing |

Source: [server/main.lua](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua).

| Interface | Contract |
| --- | --- |
| Server event `qbhousing:server:enter` | Property ID; checks owner/key and proximity before issuing shell entry |
| Client event `qbhousing:client:synced` | Property registry snapshot |
| Client event `qbhousing:client:purchaseOffer` | Property record; opens buyer confirmation |
| Client event `qbhousing:client:enterShell` | Property record; creates local shell and teleports |
| Server export `GetProperty(id)` | JSON copy of record; missing record follows existing copy behavior |
| Server export `HasAccess(source, id)` | Boolean owner/key entry access |
| AppShell ID | `qbhousing:real-estate` |
| Commands | `Config.command`, `Config.homeCommand`; defaults `realestate`, `home` |
| Framework hook | `QBCore:Client:OnPlayerLoaded` hydrates housing |

No external kora_housing callers were found in the searched active resource Lua/SQL/docs. External consumers must still be assumed. `kora_garages` separately reads legacy `houselocations`; kora_core's legacy spawn bridge mentions `player_houses`. Neither is a migration source for kora_housing without an explicit importer and verified mapping.

## Material gaps and conflicts

| Priority | Finding and effect | Evidence |
| --- | --- | --- |
| Critical | Buyer debit precedes property persistence; refund, society credit, and seller credit are separate and unchecked for durable completion. A crash or export failure can leave money and ownership inconsistent. The in-memory write guard cannot recover a restart. | [Purchase](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua) |
| High | There is no durable financial receipt/idempotency contract in the current banking exports. A housing journal alone cannot determine whether a payment happened immediately before a crash. | Integration matrix banking and SQL rows |
| High | Removal currently permits realtors, contradicting the requested admin-only removal. It deletes an unowned record without an audit or dependent-data policy. The original brief did not choose archival versus deletion; the proposal selects admin-only archival under the user's delegated discretion. | [Removal](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua) |
| High | `keys`, `update`, and `offer` mutate live registry tables before the database confirms the write. Failed persistence can therefore leave changed live state. Payload arrays have only length checks, not model, transform, item, zone, or nested-schema validation. | [Offer](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua), [keys and updates](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua) |
| High | Full property definitions, owners, and key maps are sent to all clients. Future leases, camera grants, and financial records must use authorized views rather than extending that snapshot with sensitive data. Existing snapshot consumers require a deliberate compatibility transition. | [Broadcast](/root/qblib-test-server/resources/[test]/kora_housing/server/state.lua), [hydrate](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua) |
| High | The generic garage implementation does not enforce housing permissions or property capacity; the housing `openGarage` export call has no matching implementation. Inventory access must survive restored stashes, housing restarts, and revocation during open sessions. | Integration matrix garages and inventory rows |
| High | Shells are spawned locally per entering player at the entrance origin. There is no shared physical-space registry or occupant lifecycle. Property-specific visuals cannot be privately separated at identical world coordinates in one shared environment. | [Shell entry](/root/qblib-test-server/resources/[test]/kora_housing/client/main.lua), integration matrix interiors row |
| Medium | Current commission config is 2% `sellerCommission` plus 3% society. The 2% is deducted but never paid to an agent. This conflicts with the proposed 2.5% agent plus 3.5% society policy. | [Config](/root/qblib-test-server/resources/[test]/kora_housing/config.lua), [payouts](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua) |
| Medium | Current offers cannot carry a negotiated amount, agent recommendation, seller decision, multiple offers, or co-owner approvals. A single pending object is overwritten and is not an offer history. Saving an owned property sets it to `owned`, so the normal creator does not produce a resale listing. | [Save](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua), [offer](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua) |
| Medium | The edit action calls `createProperty(property)`, but that function accepts no argument and starts the creation flow again. MLO entry uses the shell event, whose server handler rejects MLOs; no doorlock integration completes that path. | [Creator](/root/qblib-test-server/resources/[test]/kora_housing/client/main.lua), [dashboard actions](/root/qblib-test-server/resources/[test]/kora_housing/client/main.lua) |
| Medium | The real-estate command calls the server-only getPlayer export on the client. Native client core exposes getPlayerData instead, so job-based dashboard routing can fail before opening the UI. | [Housing command](/root/qblib-test-server/resources/[test]/kora_housing/client/main.lua), [native client API](/root/qblib-test-server/resources/[test]/kora_core/modules/player/client.lua:8) |
| Medium | Entry proximity assumes valid numeric coordinates. The shared normalizer validates very little beyond ID, interior type, arrays, and garage slots. Malformed stored/client configuration can cause runtime errors. | [Normalizer](/root/qblib-test-server/resources/[test]/kora_housing/shared/schema.lua), [proximity](/root/qblib-test-server/resources/[test]/kora_housing/server/main.lua) |
| Medium | Zone rebuild removes IDs from the newly assigned snapshot rather than tracking previously registered IDs, so a removed property can leave a stale interaction until lifecycle cleanup. The exit thread polls every frame while inside. | [Zones](/root/qblib-test-server/resources/[test]/kora_housing/client/main.lua), [sync](/root/qblib-test-server/resources/[test]/kora_housing/client/main.lua), [exit thread](/root/qblib-test-server/resources/[test]/kora_housing/client/main.lua) |

These findings are reported separately from implementation. Existing regression tests establish useful narrow guarantees; they do not establish production readiness.

## Database conventions and compatibility

The existing schema is `qbhousing_properties(id VARCHAR(64) PRIMARY KEY, owner VARCHAR(50) NULL, definition LONGTEXT, updated_at TIMESTAMP)` with an owner index, InnoDB, and utf8mb4. Nearly all relationships currently live in JSON within `definition`. There are no relational offer, ownership-history, lease, or payment tables.

kora_sql provides ordered, resource-scoped `QB.sql.migrateFiles` migrations and checksums through `qbsql_migrations`. Keep migration 1 byte-for-byte intact. Add numbered migrations and include them in the housing manifest. DDL recovery must account for implicit commits; do not promise that a failed multi-statement schema migration rolls back automatically. SQL transaction success also does not mean a conditional update affected a row.

New character references should match kora_core's `VARCHAR(50)`, not kora_banking's legacy `VARCHAR(11)`. Preserve raw legacy definitions during conversion. Invalid JSON, mismatched row/JSON IDs, orphan owners, unrecognized shell names, and unknown property types need an explicit migration report; do not silently discard or guess them. Existing `soldAt` and `soldPrice` are historical metadata, not evidence of a reconciled financial transaction.

## Dependency availability and working tree boundaries

All named dependency resources are present locally. The requested qb-inventory implementation is installed as `kora_inventory` and advertises the compatible resource identity. No ps_lib or additional framework is needed. Availability on disk does not verify runtime health, model asset delivery, OneSync behavior, or live database contents.

| Resource | HEAD at audit | Working tree at audit start |
| --- | --- | --- |
| kora_housing | `6c03195` | Clean |
| kora_core | `19a1096` | Existing permissions/txAdmin changes |
| kora_lib | `d8f9f00` | Existing callbacks/events/config/logging changes |
| kora_sql | `f0886ac` | Clean |
| kora_banking | `b886a66` | Clean |
| kora_inventory | `30ccd66` | Clean |
| kora_target | `903278c` | Clean |
| kora_doorlock | `f96e27f` | Clean |
| kora_garages | `f2185fe` | Existing server change and tests |
| kora_interior | `1dd1012` | Clean |
| kora_dispatch | `2dcd508` | Clean |
| kora_businesses | `e51e523` | Existing CCTV server/tests changes |
| kora_jobcreator | `24681f8` | Clean |
| kora_robberies | `0e73572` | Clean |

The audit reads the current working tree, including those existing changes, rather than assuming HEAD is the exact installed code. Those changes were left intact.

## Verification results

Executed isolated existing suites with controlled host/transport mocks:

| Suite | Result | Scope |
| --- | --- | --- |
| Housing purchase | 19 passed, 0 failed | Actual housing/core money/qbsql adapter with controlled SQL callbacks |
| Housing shell exit | 99 checks passed | Three configured shells; relative exit conversion, prompt and entity cleanup |
| kora_banking regressions | Passed | Client 36 assertions, contracts 4 assertions, server balance/history and organization bootstrap regressions |
| kora_sql transaction and migration tests | 19 passed | Node unit tests, no live database |
| kora_core money, persistence, native APIs, transaction | 30 passed | Existing mocked smoke suites |
| kora_lib NUI, placement, freecam, raycast, entities, stream, callback, locales, notify | 202 passed | Existing plain Lua mocked smoke suites |

No live SQL migration/import, crash recovery, multiplayer concurrency, financial reconciliation, inventory recovery, browser AppShell interaction, remote camera, shared furniture, or full acceptance run was performed. Features that do not exist cannot pass their acceptance tests. No live DB credentials were read, and no resource was restarted or deployed.
