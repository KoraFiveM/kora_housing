#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Runs actual housing services against host/SQL transport fixtures.
"${LUA:-lua}" tests/purchase.lua "${1:-server/main.lua}"
"${LUA:-lua}" tests/shell_exit.lua "${2:-client/main.lua}"
"${LUA:-lua}" tests/phase1.lua
"${LUA:-lua}" tests/storage.lua
"${LUA:-lua}" tests/doors.lua
"${LUA:-lua}" tests/app.lua

"${LUA:-lua}" tests/leases.lua
"${LUA:-lua}" tests/world.lua
"${LUA:-lua}" tests/scene.lua
"${LUA:-lua}" tests/admin.lua
"${LUA:-lua}" tests/contracts.lua
"${LUA:-lua}" tests/reconciliation.lua
