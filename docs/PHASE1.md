# QB Housing Phase 1 delivery

Phase 1 implements the property registry, co-ownership and shared action permissions, with AppShell creation, populated editing and access management. The user approved this phase on 15 October 2026. Changes are local; no existing server database was migrated and no resource was deployed or restarted.

## Delivered behavior

- Stable existing property IDs and primary ownership remain in qbhousing_properties. Co-owners, individual allowed/denied actions, unit relationships and audit records have separate tables.
- Primary owners alone add/remove co-owners. Co-owners share configuration and permission-management rights. Character lookup, identity, authority and exact property revision are checked on the server; no ownership limit is imposed.
- Existing keys remain entry-only access. Explicit denial overrides legacy keys immediately. Removing an entry grant also removes its legacy key. Current owners receive their rights through ownership rather than editable key grants.
- The shared permission service rejects unknown actions and untrusted property snapshots. A named camera grant is required for an administrator who is not an owner; no police job bypass is introduced.
- The creator supports houses, apartments, mansions, commercial properties, hotels, motels, buildings and land. Land uses exterior bounds without requiring an interior or garage. Shell models/exits derive from server configuration. MLO bounds, entrance vectors, optional garage vectors and slot counts are validated.
- Parent-unit changes require authority over affected buildings, reject invalid parent types/cycles and serialize against archival. Changing a building with units into a noncontainer is rejected through both creator APIs.
- Configuration editing preserves stored extension data and existing ownership, keys and relationships. Client-supplied ownership, grants and state cannot overwrite authoritative values. New drafts do not automatically become public listings.
- A property write commits its definition, relationships and audit together before changing live state or broadcasting. Failed writes leave live data and revision unchanged. Duplicate IDs rejected by SQL collation cannot overwrite an existing owner.
- AppShell refreshes revoked access while preserving an unsaved configuration draft and its original revision. An explicit reload discards the stale draft. Registered zones, UI state and owned shell handles are cleaned on unload/stop.

Permission flags for later stash/garage/furniture/security modules are persistent configuration, not a claim that those integrations already enforce them. No later-phase action screens are presented as complete features.

## Compatibility and explicit security corrections

Legacy callback names and argument/result shapes remain available. GetProperty remains a detached server snapshot; HasAccess returns a single boolean for current entry authorization. HasPermission(source,propertyId,action) is additive and returns boolean plus an optional denial reason.

Required security/workflow corrections are intentional: only admins can use legacy removal, which archives an unowned property and preserves its records; owned removal remains rejected. Primary/co-owner relationships and new permission maps are excluded from legacy public broadcasts/catalog/dashboard/entry payloads. Authorized owners/admins inspect them through private views. Existing public fields, including legacy keys, remain compatible.

Legacy key mutation now verifies the target character and uses the shared service. Bulk furniture/stash/clothing updates require property-management authority; a placement-only grant cannot replace another owner's whole furniture array. Configuration or membership changes invalidate outstanding legacy purchase confirmations. Co-owned checkout is refused until unanimous sale approvals exist. Legacy checkout still uses its original commission configuration and best-effort financial handling; selected future channel policies are not activated prematurely.

## Installation and data migration

1. Back up the existing database and resource checkout. Keep the existing kora_lib, kora_sql, kora_core, kora_interior, kora_target and kora_banking startup dependencies. No new framework dependency is introduced.
2. Review Config.propertyTypes and coordinateLimit. Existing command names, commission values, shell catalog and limits remain configured as before. Entrances/vertices outside coordinateLimit are rejected by new edits; adjust it deliberately for custom maps.
3. Install all manifest-listed files together. Startup applies untouched migration 001 and additive migration 002 through kora_sql. This was tested on MariaDB 10.11.14; other database versions require their own migration check.
4. Startup captures original row JSON/owner plus its SHA-256 in qbhousing_legacy_backup, imports legacy entry keys without overriding an existing denial, then loads authoritative relational relationships.
5. Invalid JSON, conflicting IDs/owners, malformed nested structures, unknown property types, orphan primary/co-owners, invalid unit parents or cycles stop activation with a diagnostic. Repair against the preserved original data and retry; no invalid property is silently skipped. Existing unclassified records use type legacy and report a classification message. An authorized creator edit assigns their gameplay type without guessing from the shell.
6. Open /realestate as the configured realestate job or an administrator to create/configure drafts. Owners/co-owners use /home to edit their properties and action grants. Existing owned properties retain title; the Phase 1 creator does not include a new title-transfer operation.

No down migration is provided. Before any new writes, rollback means restoring the pre-update database and resource together. After new writes, use forward repair and reconcile history; restoring an old money snapshot can corrupt financial state. DDL may commit implicitly. Do not remove relationship/audit tables as a shortcut to rolling back.

## New callback contracts

New callbacks have prefix qbhousing: and return true,result or false,reason. Source identity comes from the callback framework, never from a client field. Mutations are rate limited to five per ten seconds per callback.

| Callback | Arguments after server source | Result |
| --- | --- | --- |
| creatorSnapshot | None | Authorized properties array, types, shells, action labels/grantability and actor flags |
| propertyView | Property ID | Private property projection, relationship and allowed action map |
| createProperty | Configuration payload | Saved unowned draft |
| editProperty | Property ID, configuration payload, expected revision | Saved configuration |
| coowners | Property ID, add/remove, target citizen ID, expected revision | Saved property |
| setPermission | Property ID, target citizen ID, action, boolean or nil, expected revision | Saved property; nil removes grant |
| permissions | Property ID | Detached owner/co-owner/key/grant management snapshot |

Configuration fields are id, label, propertyType, parentId, unitLabel, interior, exterior, garage and optional listing.price. Optional configuration fields omitted in a new edit are cleared; unrelated stored fields remain. Coordinate vectors use numeric x/y/z and optional w. Bounds use exterior.polyzone points and finite minZ/maxZ. Shell interior requires type/name/entrance and derives model/exit. Server treats these as configuration only, not title, grants, billing or financial approval.

## Verification and remaining acceptance

Run the default isolated checks with bash tests/run.sh. They load actual housing services and kora_lib/core/qbsql code while controlling the FiveM host and transport boundaries. The optional python3 tests/migrations.py starts a separate socket-only MariaDB datadir, exercises real migration/persistence SQL, and removes that instance afterward; it does not use the installed server database or credentials.

Final executed results:

| Check | Result |
| --- | --- |
| Existing purchase regressions | 19 tests passed |
| Phase 1 domain and persistence checks | 36 tests passed |
| Existing shell exit checks | 99 checks passed |
| AppShell and client lifecycle checks | 49 checks passed |
| Isolated MariaDB 10.11.14 migration and persistence SQL | Passed |
| All housing Lua syntax, whitespace and local documentation links | Passed |

Coverage includes stale revisions, forged ownership/grants, role separation, failed writes, per-property concurrency, parent races, restart restoration, denied legacy keys, migration conflicts, AppShell draft behavior and lifecycle cleanup. Database checks cover migration replay, unchanged legacy definitions, checksum backup, foreign keys, uniqueness, transaction rollback and case-colliding IDs.

Live FiveM/browser acceptance has not been executed. In particular, actual in-game form rendering, model assets, multiplayer movement and resource-stop behavior remain release checks. kora_interior's existing createShell performs its own teleport while loading; the client cleans late returned objects, but geometry-only creation and complete movement cancellation require the planned Phase 4 provider extension. Durable money settlement, rent, recovery transfers, shared furniture, garage/door policies and cameras remain later phases.
