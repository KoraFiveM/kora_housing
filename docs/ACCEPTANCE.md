# Implementation and acceptance record

Recorded 15 October 2026. The complete local implementation is present. Results below distinguish executable service/SQL tests from live FiveM acceptance. No live rendering, production deployment or commercial-readiness claim follows from fixture tests.

## Executed housing checks

Run `bash tests/run.sh` inside kora_housing. The runner exercises actual housing source and actual kora_lib AppShell validation; framework natives, transport and most database/payment responses use controlled fixtures.

| Suite | Executed result | Coverage |
| --- | --- | --- |
| purchase.lua | 14 cases passed | Competing buyers while settlement yields; duplicates; exact co-owner approvals/rejection/staleness; insufficient funds; SQL/export failure; immutable pending journal after restart; lost commit response; balanced rollback; all three listing channels and initial agent sale; captured commission; legacy quote edits cancel prior approvals before republishing. |
| phase1.lua | 37 cases passed | Typed creator, stable identity, legacy preservation/backups, parent units and concurrent authoring, ownership and individually revoked grants, unavailable storage and failed persistence. |
| storage.lua | 8 cases passed | Live stash policy, emptiness barrier, purchase retry/capacity, full inventory and metadata failure, callback-only recovery rebind, former-owner garage scope, shared archived-owner entitlements and first successful claim. |
| doors.lua | 6 cases passed | Canonical mapping, owner/admin/revision/proximity gates, foreign/cross-property rejection, failed save, explicit unlink, required protection after uncertain commit. |
| leases.lua | 49 assertions passed | Anchored unique periods, gross initial rent/deposit, actual paid/missed behavior, captured threshold, empty-service no timer, end deadline, transient backoff, protected repeated eviction using the actual World service, guest grant retention, disputes/zero awards/refunds and original owner payees. |
| world.lua | 55 checks passed | Invalid/overlapping physical spaces, transform/model/count/revision/source-token validation, SQL failure, same-ID furniture recovery, camera grants/revocation/expiry/session limits/tenancy changes, persisted alarm cooldown, ownership transfer/archival, unknown-result revocation quarantine and targeted refresh. |
| app.lua | 62 checks passed | Actual shared AppShell validator/routes with populated listing/offer/approval, lease/payment/deduction, storage, furniture, cameras, alarm, inbox/recovery/admin data; stale/dirty drafts; optional land garage fields; server-backed action arguments. |
| scene.lua | 16 checks passed | Shared geometry/entities, observer loading without teleport, async cancellation, shell-to-MLO cleanup, camera controls/freeze/exit, unload/provider-stop fallback and editor error recovery. |
| shell_exit.lua | 102 checks passed | Existing shell exit, legacy entry compatibility, cleanup and revocation lifecycle. |
| admin.lua | 5 cases passed | Reviewed source/revision-bound confirmation, active lease/deposit/payment/child/preflight blocks, retained ownership/history, recovery before completion, staged retry and failed-save behavior. |
| reconciliation.lua | 19 assertions passed | Actual State, permissions, lease and world services: uncertain revocation denies immediately; joined worker settlement; coherent relationship reload; terminal lease/deposit/camera refresh; door/storage refresh before reopening; failure and newer-ambiguity guards. |
| contracts.lua | 65 client call sites checked | Manifest modules load; every literal client callback/event has a handler; compatibility routes and exports remain registered; requests deny before readiness. |

Counts mix named test cases and assertions and must not be added into a single invented acceptance count.

Run `python3 tests/migrations.py` for the separate hermetic database check. Executed against a disposable, socket-only MariaDB 10.11.14 instance, with no production connection or credentials. Passed: repeated application of all four housing migrations, preserved legacy source/checksum backup, real generated registry and sale statements, balanced ledger, collating-ID collision, explicit denial, foreign keys/rollback, and unique active listing, accepted offer, pending financial operation, lease, rent period and storage tier constraints.

## Executed dependency checks

- qbcore: full `test/run.sh` passed, including column fencing, ordinary/queued save interleaving, offline writers, login and persistent coordinator restart cases.
- qbinventory: full 45 smoke scripts passed, including 2681 reported assertions; focused housing recovery/policy suite includes 209. Ordinary stash/provider and existing inventory contracts also ran.
- qbsql: Lua bridge smoke tests and 77 JavaScript tests passed; checked transaction rollback/expected-row and prior-worker joining cases ran. Driver bundle rebuilt.
- qbbanking: existing client/contracts/server regressions and durable finance suite passed. Commit/rollback, gross funds, escrow, changed-request refusal, lost response and restart receipt/publication behavior are covered.
- qbgarages: property integration 8 cases and legacy-housing compatibility passed. qbdoorlock: 7 policy cases passed, preserving ordinary hook semantics.
- qbinterior: geometry creation/cleanup 7 checks passed. qblib: placement 21 cases passed, including numeric/bounded/raycast placement and owner-scoped cancellation. AppShell is exercised by the composed housing app tests.

The finance implementation was also exercised with its actual SQL against a separate disposable MariaDB during development: balanced settlement, stale domain-row rollback, insufficient balance, durable receipt uniqueness, unchanged-row behavior and persisted core fencing. The repeatable housing database runner covers the domain side without requiring a configured live DSN.

## Final change map

| Files/resource | Result |
| --- | --- |
| shared/schema.lua, shared/permissions.lua, config.lua, locales/en.lua | Type-aware property/fixture settings, named action permissions, explicit configurable gameplay defaults. |
| server/state.lua, properties.lua, ownership.lua, permissions.lua, domain.lua | Registry, creator, primary/co-owner relationships, authoritative access, checked revision writes and quarantined ambiguous results. |
| server/sales.lua, transactions.lua, leases.lua | Relational listings/offers/approvals/history, one durable financial path, individual rent periods, escrow/deposit decisions and deadline-driven termination. |
| server/storage.lua, doors.lua | Verified inventory/garage/door adapters, policy rebinding, empty-stash sale barrier, durable recovery and preserved vehicle title. |
| server/world.lua | Shared spaces, bounded furniture placements/recovery, camera/grant/session lifecycle, configured alarm/dispatch. |
| server/admin.lua, main.lua, fxmanifest.lua | Audited staged archival, full callback inventory and compatibility adapters, migrations and dependency readiness. |
| client/app.lua, gameplay.lua, world.lua, main.lua | Existing AppShell screens, shared world editors, native local camera view, coherent scene/occupant lifecycle. |
| sql/002–004 and tests/* | Additive relational records, backup/identity preservation, service failure tests and real database constraints. |
| Coordinated dependency changes | Durable core/banking/SQL and inventory boundaries, opt-in garage/door policies, geometry-only shells, shared placement extensions, dispatch allowlist. |

Important actions and financial outcomes have persistent journals, ledgers, histories or audit rows. Requests are never authorized by a visible button. No placeholder callback, separate UI project, replacement inventory or housing bucket was introduced.

## Live acceptance still required

Execute on a staging FiveM server with the coordinated resources and actual assets:

1. Create shell, MLO, land and parent/unit examples. Enter with two characters and a nearby observer; confirm shared transforms/collisions, no observer teleport, clean exits and distinct non-overlapping layouts.
2. Complete all three sale channels with owner, co-owner, agent and two buyers. Confirm actual online/offline bank statements, society/agent payouts and vehicle retrieval after title transfer. Restart the owning resources at the documented pending points and verify receipts and login recover.
3. Exercise daily and weekly schedules with controlled staging times, insufficient funds, paid reset, termination, deposit agreement/dispute/admin resolution and both successful/full-inventory recovery. Confirm owner physical access returns only after recovery is protected.
4. Try unauthorized and revoked entry, door, stash, garage, furniture and camera requests. Check a provider stop/restart while sessions/editors are active. Confirm no preview, entity, camera, freeze, HUD/control or NUI-focus leak.
5. Confirm camera-present notices and actual occupant rendering. Run one, two and four viewers within the admitted 100-metre scene; measure performance and verify expiry/revocation/switch/exit behavior. No arbitrary-distance feed is promised.
6. Trigger each enabled alarm with on-duty police and confirm actual dispatch delivery/cooldown across restart. Confirm optional phone failure leaves recovery usable.
7. Archive occupied-history examples after resolving current leases/deposits. Confirm reviewed administrative authorization, original-owner recovery, former vehicle ownership/retrieval and preserved audit/history. Verify external doors are retained.

These live checks were not executed in this environment. Deployment should follow their results, not an assumption that simulated natives prove multiplayer rendering or asset availability.
