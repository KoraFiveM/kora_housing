# Stock housing SQL compatibility

The selected native stack uses `kora_housing` as the owner of property data. The
original `houselocations` and `player_houses` tables are an import archive. They
are retained unchanged, together with the lossless `qbhousing_stock_import`
backup. Running stock `qb-houses` beside this provider is unsupported.

The reviewed source is `qbcore-fivem/qb-houses` at
`3f2478557f22e4f063c7f1cbe3a994993101c54f`. The same reads are consumed by pinned
`qb-spawn`, `qb-multicharacter`, and `qb-garages`.

## Live read bridge

`kora_sql` routes these exact ad-hoc reads to native housing:

- `SELECT * FROM houselocations`
- `SELECT * FROM houselocations WHERE name = ?`
- `SELECT owned FROM houselocations WHERE name = ?`
- `SELECT * FROM houselocations WHERE name LIKE ? ORDER BY LENGTH(name) desc, name DESC`
- `SELECT * FROM player_houses`
- `SELECT * FROM player_houses WHERE house = ?`
- `SELECT * FROM player_houses WHERE citizenid = ?`
- `SELECT * FROM player_houses WHERE identifier = ? AND citizenid = ?`

Whitespace, paired identifier backticks, and named binds accepted by kora_sql are
supported. The native export `readLegacyHousing(operation, args, callback)` is
restricted to the actual `kora_sql` caller. The callback receives `(rows, error)`.
The bridge feeds the ordinary query/single/scalar/prepare result adapters.
It waits for native readiness and reports failures; it never substitutes old
archive rows after a provider error or stop.

Only calls whose original resource is `kora_housing` bypass projection. This lets
its importer read the source before native state is ready, without recursion.
Other ad-hoc writes and unsupported reads referring to these tables fail
explicitly while native housing is selected. Transaction/batch SQL is not
rewritten by this adapter; consumers must use native housing operations rather
than direct stock writes. Stock tables must not be used as live authority.

Reads use current native owners, owner licenses, effective entry permissions,
listing/last-sale prices, entrance/garage coordinates, placed furniture, active
owner stash coordinates and the single native clothing fixture. Archived
properties disappear from live results. Reads hold the existing property write
gates while identity/stash SQL yields, so native sales, revocations and fixture
writes cannot produce a mixture of revisions. Reconciliation and pending
payment states fail explicitly. Original numeric row IDs are preserved for
imported records; native-only properties have no invented legacy numeric ID.

The `LIKE` form supports the ASCII case-insensitive wildcard subset. Other
collations, MLOs without a stock tier, multiple stashes/clothing fixtures, and a
native garage with separate interaction/spawn positions require a dedicated
mapping. They fail explicitly instead of returning a misleading stock shape.

## Shell placement and fixture migration

The importer preserves stock entrance coordinates (including `h` as native `w`)
and the single garage point; an all-zero garage is absent. The sixteen bundled
stock shell tiers map through `Config.legacyHousing.shellTiers`. Tier 11 uses the
actual `shell_garagem` archetype, and tier 16 uses `CreateFurniMotelStandard`.
The stock shell origin is the entrance minus `Config.legacyHousing.minZOffset`
(default 30). Imported fallback entry now uses that origin, the authored exit
and heading, and returns to the unchanged exterior. Older ownership-only
records can acquire the newly supported standard motel mapping at startup.

Imported shared scenes explicitly request the original `CreateObject` placement.
Ordinary native scenes keep `CreateObjectNoOffset`. Fallback entry uses geometry
without the provider's teleport and checks the character lifecycle before moving
the player; unload during model streaming releases the late shell. This avoids
teleporting a replacement character. No client supplies a new shell origin or
boundary to gain access.

Nonempty representable fixture records become real native records in the same
checked transaction as the new property and permanent import marker:

- Stash IDs stay equal to the original house name, preserving the authoritative
  kora_inventory contents without copying or replacing items. The pinned source
  config supplies tier 1 capacity only: 50 slots and 1,000,000 weight. Other
  tiers require their actual configured capacity in
  `Config.legacyHousing.stashTiers`; unknown capacity remains unmapped. Policy
  checks enforce current entry and storage rights and native lease/recovery
  rules. Purchased upgrades persist their real capacity with the property;
  an upgrade below imported capacity is refused before payment.
- Furniture retains its model, absolute coordinates and full rotation in
  `qbhousing_furniture`. Stock explicitly applied `SetEntityCoordsNoOffset`
  after object creation; the native object provider has matching placement.
  Shared scenes render those rows normally. Fallback shells render the same
  native rows with lifecycle cleanup. Custom model availability still depends
  on installed assets; streaming failure is reported rather than hidden.
- Outfit locations become a native clothing fixture. Its interaction invokes
  `qbclothing:OpenWardrobe` after server authorization; existing owned-outfit
  and clothing-session rules remain authoritative.
- Logout locations become a native logout fixture. The action rejects active
  character-selection cinematics and delegates to core's durable logout with
  the stored exterior position. A failed save leaves the character active and
  reports an error. Core's normal logged-in state change opens native character
  selection; the saved position does not strand the character under the map.

Each fixture action sends only a property ID and action name. The server checks
readiness, current permissions, property mutation/reconciliation gates, the
entered property bound to the same citizen ID, and proximity to the stored
fixture. Revoked entry stops use immediately. Existing ownership-only imports
upgrade through native revision-checked persistence without restoring sold,
archived, deleted or reclassified properties, revoked grants, or conflicting
native fixture rows. The source archive and checksum remain unchanged.
Malformed/sparse fixture records and native conflicts remain explicitly marked
in `legacy.unmappedFixtures`; full ownership-row projection refuses these gaps.
Mapped wardrobe/logout/stash/furniture fields project from current native data.

## Remaining physical boundary

Exact model-local bounds for every bundled shell are decoded and verified in
[qbinterior's asset report](../../kora_interior/docs/SHELL_GEOMETRY.md). These are not
verified stock world bounds: stock `CreateObject` placement differs from the
centered native, and the available metadata does not unambiguously establish
all resulting world Z limits. `legacy.needsWorldMapping` stays set. Configure
an accurate origin, polygon and height bounds with native `configureSpace`
before enabling unrestricted native furniture placement/security features.
The existing validation requires the origin and exit inside the boundary,
rejects overlaps and preserves existing fixture positions.

Unknown/optional paid shell tiers need their installed assets and an explicit
mapping; altered source offsets need their actual settings. Multiple native
stashes/clothing points, split garage points, and MLOs exceed the stock scalar
schema and require a deliberate mapping. Do not clear flags merely to suppress
an error. The stock data/client compatibility bridge is not a second housing
authority and does not enable unsupported raw stock mutations. Rendering,
collision, multiplayer transitions and interactive wardrobe/logout acceptance
remain untested without connected FiveM clients.

## Verification

From `resources/[test]/qbhousing`, run `bash tests/run.sh`. Focused suites are
`lua tests/stock_import.lua`, `lua tests/legacy_sql.lua`,
`lua tests/legacy_fixtures.lua`, `lua tests/fixtures_client.lua` and
`lua tests/shell_lifecycle.lua`. `python3 tests/migrations.py` runs real emitted
fresh-import and upgrade SQL against its own disposable socket-only MariaDB,
including complete rollback, replay protection and retained revocations.
From `resources/[test]/qbsql`, run `bash test/run.sh` and `npm run build`.
`node --test test/js/legacy-housing.test.js` covers exact routing, original
caller bypass, errors, stop behavior and protection from stale archive reads.
