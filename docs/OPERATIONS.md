# Installation and operations

## Install the coordinated resources

This implementation changes qbhousing and the installed qbcore, qbsql, qbbanking, qbinventory, qbgarages, qbdoorlock, qbinterior, qblib and qbdispatch. Keep these changes together. Existing public dependency interfaces remain available; housing uses the additive authoritative interfaces documented in the integration matrix.

1. Back up the database and the current versions of all changed resources. Use a maintenance window for the coordinated update.
2. Keep the framework's existing dependency startup order. qblib/qbsql/qbcore, inventory, target, banking, doors, garages, interior and dispatch must start before qbhousing; qbbanking also retains its existing qbtheme dependency. Optional qbphone only supplies mail notices.
3. Install the rebuilt qbsql bundle included in the working tree. Its build command is `npm run build` in qbsql when changing the driver source.
4. Let the existing resource migration runners apply their additive migrations. Do not import SQL manually as well. New files include core `010_player_column_operations.sql`, banking `001_durable_operations.sql`, inventory `002_recovery_operations.sql`, garages `001_property_garages.sql`, and housing `002_registry_access.sql`, `003_economy.sql`, `004_world.sql`. Existing migration files are unchanged.
5. Confirm the configured real-estate society account exists. The deposit escrow account is created on the first deposit-bearing acceptance. `qbbanking.Config.transactionCallers.qbhousing` and `qbdispatch.Config.trustedCallers.qbhousing` are enabled in this change.
6. Start housing and check startup diagnostics. Invalid legacy identity, missing owners, invalid parent relationships or corrupt world records stop activation. Initial inventory/door readiness is retried; mapped integrations fail closed until their owning policy is rebound.
7. Perform the live acceptance in ACCEPTANCE.md with test characters before opening the system to players.

Local implementation and repository publication do not apply production database migrations, restart resources or deploy the server.

## Author a property

Open `/realestate` as an authorized real-estate agent or administrator, select New property, and give it a stable ID and type. Houses, apartments and mansions require an interior; land requires exterior bounds and has no interior. Commercial properties, hotels, motels and buildings can use the appropriate interior or exterior space. A unit references a building/hotel/motel parent; each separately rented unit has its own property identity.

Configure entrances, MLO exits, optional garage coordinates/spawn/capacity and exterior bounds using the shared fields and polygon creator. On the property's furniture/security tab, configure the physical space. Shells require an explicit world origin and bounds containing the shell exit. Author distinct non-overlapping spaces for separate private layouts; all occupants and nearby viewers of one space see the same furniture. Land can have storage, garages, furniture and security within its authored bounds.

Use storage configuration for the stash fixture and door configuration to link existing qbdoorlock IDs. Housing never deletes the referenced doors. Door creation remains in qbdoorlock's existing authoring tools. Furniture uses the shared placement editor, free camera, rotation, surface raycast and numeric adjustments. Confirming persists the transform; cancellation, revocation, unload and stop remove previews.

A new property is an unowned draft. An agent publishes its initial listing, reviews the buyer's offer and approves it. A buyer completes payment only after the required approval. For an owned property, owners assign the selling agent; direct private sales need no agent. Every owner must approve the exact accepted offer and current ownership revision.

## Configured policy defaults

These choices follow the user's delegation to select defaults and revisit them later. All amounts are whole currency units.

| Setting | Default and behavior |
| --- | --- |
| Ownership | Unlimited. Co-owners have equal rights except primary-only membership changes. No automatic buyout when a co-owner leaves or is removed. |
| Sales | Public and agent off-market: 3.5% society + 2.5% agent. Direct private: zero commission. Floor commission legs; split net equally, with remainder to primary owner. Unowned net goes to society. |
| Immutable terms | A listing captures commission policy/version. Leases capture rent, schedule, missed-payment threshold, review period and original owner payees. Changes to config affect new agreements. Rent proceeds follow current owners; approved deposit deductions follow the captured original payees. |
| Rent | First payment on acceptance; subsequent periods anchored at activation, every 86400 or 604800 seconds. A paid period resets consecutive misses; 3 daily or 2 weekly confirmed insufficient balances evict. An outage stays pending. |
| Ending a lease | Either party requests end at the paid period boundary. No early-exit fee or automatic prorated refund. |
| Deposits | Optional amount, zero by default. Held in the named escrow account. After termination, a configurable 48-hour review permits itemized damage/unpaid-rent proposals. Tenant acceptance or reasoned administrator resolution authorizes a deduction. Undisputed remainder is refunded after review; proposed/disputed amounts remain held until decided. |
| Tenant access | Entry, own lease stash, garage and own furniture by default. Owner/co-owner physical access is suspended during tenancy until the tenant allows it. Financial/title controls remain. Sharing guests requires the lease's access-sharing permission. |
| Recovery | Indefinite retention, no automatic deletion. Stash identity is retained; furniture recovery reuses the original placement entitlement. Claims require inventory capacity and confirmed durable delivery. Archived shared owner storage is shared retrieval: the first successful authorized original-owner claim collects it. |
| Vehicles | Vehicle title stays with the vehicle owner. Former tenants and sellers retain retrieval of their own vehicles through recovery; they cannot store new vehicles using that entitlement. |
| Storage | 50 slots/100000 weight initially; 75/150000 for $10000; 100/200000 for $25000 additional. Sequential upgrades stay with the property and have no automatic refund. |
| Furniture | Allowlisted models, 100 placements per property type by default. Non-lease fixtures stay with a sold property. Tenant placements recover on termination. |
| Cameras | Physical native camera console within 100 metres of the feed, one client feed, at most four simultaneous viewers, five-minute sessions. Named viewer grants expire within 24 hours; only an owner/co-owner can issue or revoke them. Police have no job-only bypass. |
| Alarms | Disarmed initially; configurable unauthorized mapped-door unlock and authorized panic triggers; 60-second persisted cooldown. Existing validated lockpicking remains configurable through `allowDoorLockpick`. |
| Removal | Administrator-reviewed archival. Block leases, unresolved deposits, pending payments and active child units. Retain ownership/history and protected recovery; disable ordinary occupancy and new sales. No permanent deletion action. |

Old `sellerCommission` and `societyCommission` keys remain for compatibility. The new sale engine uses `saleCommissions`; it does not silently treat the old 2%/3% values as the newly selected 2.5%/3.5% policy.

## Compatibility and recovery

Existing property IDs, owner fields, boolean keys and unknown JSON fields remain intact. Migration backs up original definitions with SHA-256 before importing entry grants. Legacy records remain classed `legacy` until reviewed in the creator. Existing valid public listings are imported; incomplete direct listings are retained as historical `legacy` rows until republished with a buyer. Imported pending offers require a new recommendation/owner decision; they never become automatic checkout authorization. Old fixture JSON is retained; use the new physical-space editor for normalized rendered placements.

The original callback names and exports remain registered. Legacy listing edits cancel approvals for the previous quote before republishing a public listing. A direct listing draft requires a named buyer in the new sales screen. Legacy `offer` now submits an offer for the acting buyer, and `confirmPurchase` only completes an accepted offer after all approvals through the shared settlement engine. A legacy caller cannot select and charge another character. Legacy `removeProperty` remains administrator-only and invokes the same archival safeguards; the AppShell workflow adds a visible preflight and confirmation. Public synchronization hides pending buyers and private/off-market quote details; authorized parties receive their own sales view, and trusted server GetProperty retains the full record. These are deliberate security/workflow corrections to the old direct-money path.

`GetProperty(id)` returns a detached server record. `HasAccess(source,id)` and `HasPermission(source,id,action)` use current server authorization. Mapped stashes, doors and garages require the live housing policy; a stopped resource never grants fallback public access.

Financial operations have immutable IDs and stored requests. A timeout or unknown banking result leaves the property locked for automatic receipt lookup/retry. Restarting housing resumes pending journals without creating a second debit. Never manually delete a pending journal, receipt, ledger, inventory recovery receipt or core column lock to force a retry. Restore the failed dependency/database, inspect the recorded operation and let the owning service reconcile it. Shared core locks prevent queued whole-column money/inventory saves or hot-restart workers from restoring stale balances/items.

Archival records `archiving` before protecting belongings and ends at `archived`. A failure in inventory/world recovery keeps normal access denied and retries the same records. No item copy is made. Recovery with insufficient carrying capacity is retryable. If item delivery committed but housing metadata failed, the inventory receipt prevents a second delivery.

An ambiguous nonfinancial write quarantines its property while the old SQL worker settles and authoritative registry/lease/world data reload. Reconciliation retries only known uncertain properties. Review diagnostics for corrupted records that need repair rather than bypassing the quarantine.

Rollback means restoring the coordinated database/resource backup during maintenance, before new live transactions. Do not run destructive down migrations after sales, leases or claims have occurred. Keep the new financial/recovery tables for reconciliation and audit even if disabling housing; restoring only old property JSON cannot reverse money or item delivery safely.

## Rendering limits

Native camera view is local rendering in an already nearby physical scene, not an arbitrary-distance video stream. Configured viewer limits are admission limits, not benchmark results. Shared MLOs/shells have shared collisions and scenery. Housing does not offer visually private layouts at identical coordinates. Entry checks enforce housing teleports, doors and protected actions; they cannot make an open MLO physically inaccessible to a modified client. Server-authorized money, inventory, vehicles and management actions remain independently checked.

Optional shell models listed in the catalog may require their existing asset packs. Confirm each chosen model in FiveM. Test exterior recovery/garage positions and concave land stash positions before enabling a lease.
