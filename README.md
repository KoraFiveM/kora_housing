# kora_housing

Housing for kora_core and kora_lib: a type-aware in-game creator, unlimited ownership and co-ownership, public/private/off-market sales, rolling rentals, protected recovery, inventory upgrades, shared physical interiors, garages, furniture, security cameras, alarms and administrative archival.

Everything uses the existing AppShell and installed framework resources. There is no separate frontend, replacement inventory or property routing bucket. Financial settlement uses confirmed banking operations with a persistent journal and ledger; title and all payment legs commit together.

`/realestate` opens the market. `/home` opens your accessible properties, offers, agreements and recovery. Realtors and administrators can create properties. Owners manage access, agents, sales and tenancy. Administration includes audit history and a reviewed archival confirmation.

Install the coordinated dependency changes with housing; updating housing alone is insufficient. See [installation, configuration and recovery](docs/OPERATIONS.md) and [executed checks and remaining live acceptance](docs/ACCEPTANCE.md).

- [Implemented integration contracts](docs/INTEGRATION_MATRIX.md)
- [Architecture and selected gameplay policies](docs/IMPLEMENTATION_PLAN.md)
- [Original repository audit](docs/HOUSING_AUDIT.md)
- [Historical Phase 1 delivery](docs/PHASE1.md)

The local implementation and automated checks cover the full scope. FiveM multiplayer rendering, optional shell assets, actual dispatch delivery and camera performance still require the live acceptance described in the runbook before production release.

The server `qb-houses:hasKey(identifier, citizenid, house)` export reads native property IDs and the same entry permissions used by housing, including revocations and active leases. Owner lookups validate the character license. The stock importer and exact SQL read bridge project native ownership and supported fixtures; see [stock migration and remaining mapping boundaries](docs/LEGACY_SQL.md). Unchanged stock housing must not run beside this provider.
