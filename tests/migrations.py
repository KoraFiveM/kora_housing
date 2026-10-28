#!/usr/bin/env python3
"""Exercise housing migrations in a disposable, socket-only MariaDB instance."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time


def main():
    required = ("mariadb-install-db", "mariadbd", "mysql", "lua")
    for command in required:
        if not shutil.which(command):
            raise SystemExit(f"Missing {command}; this optional test requires local MariaDB binaries.")
    migrations = Path(__file__).resolve().parents[1] / "sql"
    with tempfile.TemporaryDirectory(prefix="qbhousing-migration-") as directory:
        root = Path(directory)
        subprocess.run([
            "mariadb-install-db", "--no-defaults", f"--datadir={root}",
            "--auth-root-authentication-method=normal", "--skip-test-db",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        options = [
            "mariadbd", "--no-defaults", f"--datadir={root}",
            f"--socket={root / 'mysql.sock'}", f"--pid-file={root / 'mysql.pid'}",
            f"--log-error={root / 'server.log'}", "--skip-networking",
        ]
        if os.geteuid() == 0:
            options.append("--user=root")
        server = subprocess.Popen(options, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        arguments = [
            "mysql", "--no-defaults", f"--socket={root / 'mysql.sock'}", "-uroot",
            "--batch", "--skip-column-names",
        ]

        def query(statement, succeeds=True):
            result = subprocess.run(arguments, input=statement, text=True, capture_output=True)
            assert (result.returncode == 0) == succeeds, result.stderr or statement
            return result.stdout.strip()

        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if server.poll() is not None:
                    raise RuntimeError((root / "server.log").read_text())
                result = subprocess.run(arguments, input="SELECT 1;", text=True, capture_output=True)
                if result.returncode == 0:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError("Disposable MariaDB did not become ready.")
            version = query("SELECT VERSION();")
            query("CREATE DATABASE housing_test CHARACTER SET utf8mb4;")
            arguments.append("housing_test")
            query((migrations / "001_housing.sql").read_text())
            legacy = json.dumps({
                "id": "legacy_home", "owner": "OWNER", "keys": {"KEYHOLDER": True},
                "unknownConsumerField": {"preserve": True}, "interior": {"type": "mlo"},
            })
            literal = "'" + legacy.replace("\\", "\\\\").replace("'", "''") + "'"
            query("INSERT INTO qbhousing_properties(id,owner,definition) VALUES ('legacy_home','OWNER'," + literal + ");")
            fingerprint = "SELECT SHA2(CONCAT(id,COALESCE(owner,''),definition),256) FROM qbhousing_properties;"
            before = query(fingerprint)
            migration = (migrations / "002_registry_access.sql").read_text()
            query(migration)
            query(migration)
            for filename in ("003_economy.sql", "004_world.sql", "005_stock_import.sql"):
                query((migrations / filename).read_text())
                query((migrations / filename).read_text())
            assert query(fingerprint) == before, "Migration changed legacy source data."
            assert query("SELECT property_type,revision,ownership_revision FROM qbhousing_properties;") == "legacy\t0\t0"
            state = (migrations.parent / "server" / "state.lua").read_text()
            backup = re.search(r"local backedUp, backupErr = QB\.sql\.execute\(\[\[(.*?)\]\]\)", state, re.S)
            assert backup, "Cannot find the actual startup backup query."
            query(backup.group(1))
            query(backup.group(1))
            assert query("SELECT definition_sha256=SHA2(definition,256) FROM qbhousing_legacy_backup WHERE property_id='legacy_home';") == "1"

            capture = subprocess.run(["lua", "-"], cwd=migrations.parent, text=True, capture_output=True, check=True, input="""
                function AddEventHandler() end
                local tools = dofile('../kora_core/test/mocks.lua')
                json = { encode = tools.stableEncode, decode = tools.simpleDecode }
                QB = { sql = { NULL = '\\0qbsql:null\\0' } }
                QB.sql.transactionChecked = function(statements) print(json.encode(statements)); return {success=true} end
                dofile('config.lua'); dofile('shared/schema.lua'); dofile('server/state.lua')
                assert(Housing.state.persist({ id='generated', owner='OWNER', propertyType='land',
                    coowners={COOWNER=true}, permissionGrants={KEYHOLDER={entry=false}}, keys={} },
                    { actor='OWNER', action='test.persist', target='COOWNER' }))
            """)
            statements = json.loads(capture.stdout)

            def literal(value):
                if value == "\0qbsql:null\0":
                    return "NULL"
                if isinstance(value, (int, float)):
                    return str(value)
                return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"

            def prepared_transaction(rows):
                transaction = ["START TRANSACTION;"]
                for statement in rows:
                    transaction.append("PREPARE housing_statement FROM " + literal(statement["query"]) + ";")
                    names = []
                    for index, value in enumerate(statement["values"]):
                        name = "@housing_param_" + str(index)
                        transaction.append("SET " + name + "=" + literal(value) + ";")
                        names.append(name)
                    transaction.append("EXECUTE housing_statement USING " + ",".join(names) + ";")
                    transaction.append("DEALLOCATE PREPARE housing_statement;")
                transaction.append("COMMIT;")
                return "\n".join(transaction)

            stock_capture = subprocess.run(["lua", "-"], cwd=migrations.parent, text=True, capture_output=True, check=True, input="""
                local f = dofile('tests/stock_fixture.lua')()
                assert(f.housing.legacy.importStock())
                print(f.json.encode(f.writes[1]))
            """)
            # The plain-Lua fixture quotes NUL/newlines using Lua escapes.
            stock_statements = json.loads(stock_capture.stdout.replace("\\\n", "\\n").replace("\\0", "\\u0000"))
            query(prepared_transaction(stock_statements))
            assert query("SELECT owner,property_type,revision FROM qbhousing_properties WHERE id='old_home';") == "OWNER\tlegacy\t1"
            assert query("SELECT allowed FROM qbhousing_permissions WHERE property_id='old_home' AND citizenid='KEY' AND action='entry';") == "1"
            assert query("SELECT source_sha256=SHA2(source_data,256) FROM qbhousing_stock_import WHERE property_id='old_home';") == "1"
            stock_backup = json.loads(bytes.fromhex(query("SELECT HEX(source_data) FROM qbhousing_stock_import WHERE property_id='old_home';")).decode())
            assert stock_backup["player_houses"]["decorations"] == '[{"object":"custom_model"}]'
            # Native edits win: replay cannot overwrite either ownership or revocation.
            query("UPDATE qbhousing_properties SET owner='NEW' WHERE id='old_home'; UPDATE qbhousing_permissions SET allowed=0 WHERE property_id='old_home' AND citizenid='KEY';")
            query(prepared_transaction(stock_statements), succeeds=False)
            assert query("SELECT owner FROM qbhousing_properties WHERE id='old_home';") == "NEW"
            assert query("SELECT allowed FROM qbhousing_permissions WHERE property_id='old_home' AND citizenid='KEY' AND action='entry';") == "0"
            assert query("SELECT COUNT(*) FROM qbhousing_stock_import WHERE property_id='old_home';") == "1"

            fixture_capture = subprocess.run(["lua", "-"], cwd=migrations.parent, text=True, capture_output=True, check=True, input="""
                local f = dofile('tests/stock_fixture.lua')()
                f.locations[1].name='fixture_home';f.owners[1].house='fixture_home'
                f.owners[1].decorations='[{"hashname":"prop_chair_01a","x":2,"y":3,"z":-26,"rotx":10,"roty":20,"rotz":30}]'
                f.owners[1].outfit='{"x":3,"y":4,"z":-25}'
                f.owners[1].logout='{"x":5,"y":6,"z":-25}'
                assert(f.housing.legacy.importStock());print(f.json.encode(f.writes[1]))
            """)
            fixture_statements = json.loads(fixture_capture.stdout.replace("\\\n", "\\n").replace("\\0", "\\u0000"))
            query(prepared_transaction(fixture_statements))
            assert query("SELECT id,property_id,status FROM qbhousing_stashes WHERE id='fixture_home';") == "fixture_home\tfixture_home\tactive"
            assert query("SELECT JSON_VALUE(definition,'$.legacy.stash.capacity.maxWeight'),JSON_VALUE(definition,'$.clothing[0].coords.z'),JSON_VALUE(definition,'$.logout.z') FROM qbhousing_properties WHERE id='fixture_home';") == "1000000\t-25\t-25"
            assert query("SELECT owner_cid,JSON_VALUE(definition,'$.coords.z'),JSON_VALUE(definition,'$.rotation.roll') FROM qbhousing_furniture WHERE id='stock:fixture_home:1';") == "OWNER\t-26\t20"
            query(prepared_transaction(fixture_statements), succeeds=False)
            assert query("SELECT COUNT(*) FROM qbhousing_furniture WHERE property_id='fixture_home';") == "1"

            upgrade_capture = subprocess.run(["lua", "-"], cwd=migrations.parent, text=True, capture_output=True, check=True, input="""
                local f = dofile('tests/stock_fixture.lua')()
                f.locations[1].name='upgrade_home';f.owners[1].house='upgrade_home'
                f.owners[1].decorations='[{"hashname":"prop_chair_01a","x":2,"y":3,"z":-26,"rotx":10,"roty":20,"rotz":30}]'
                f.owners[1].outfit='{"x":3,"y":4,"z":-25}';f.owners[1].logout='{"x":5,"y":6,"z":-25}'
                local convert=f.housing.legacy.prepareFixtures
                f.housing.legacy.prepareFixtures=function(property) return property,{} end
                assert(f.housing.legacy.importStock());assert(f.load())
                f.housing.state.get('upgrade_home').permissionGrants.KEY.entry=false
                f.housing.legacy.prepareFixtures=convert
                assert(f.housing.legacy.upgradeFixtures())
                print(f.json.encode({f.writes[1],f.writes[2]}))
            """)
            initial, upgrade = json.loads(upgrade_capture.stdout.replace("\\\n", "\\n").replace("\\0", "\\u0000"))
            query(prepared_transaction(initial))
            query("UPDATE qbhousing_permissions SET allowed=0 WHERE property_id='upgrade_home' AND citizenid='KEY' AND action='entry';")
            assert query("SELECT COUNT(*) FROM qbhousing_stashes WHERE property_id='upgrade_home';") == "0"
            stash_insert = next(row for row in upgrade if 'INSERT INTO `qbhousing_stashes`' in row['query'])
            query(prepared_transaction([*upgrade, stash_insert]), succeeds=False)
            assert query("SELECT revision FROM qbhousing_properties WHERE id='upgrade_home';") == "1"
            assert query("SELECT COUNT(*) FROM qbhousing_stashes WHERE property_id='upgrade_home';") == "0"
            assert query("SELECT COUNT(*) FROM qbhousing_furniture WHERE property_id='upgrade_home';") == "0"
            query(prepared_transaction(upgrade))
            assert query("SELECT revision,JSON_VALUE(definition,'$.logout.z') FROM qbhousing_properties WHERE id='upgrade_home';") == "2\t-25"
            assert query("SELECT allowed FROM qbhousing_permissions WHERE property_id='upgrade_home' AND citizenid='KEY' AND action='entry';") == "0"
            assert query("SELECT COUNT(*) FROM qbhousing_stashes WHERE id='upgrade_home';") == "1"
            assert query("SELECT COUNT(*) FROM qbhousing_furniture WHERE property_id='upgrade_home';") == "1"

            query(prepared_transaction(statements))
            assert query("SELECT owner,revision,ownership_revision FROM qbhousing_properties WHERE id='generated';") == "OWNER\t1\t1"
            assert query("SELECT allowed FROM qbhousing_permissions WHERE property_id='generated' AND citizenid='KEYHOLDER';") == "0"
            assert query("SELECT COUNT(*) FROM qbhousing_audit WHERE property_id='generated';") == "1"
            statements[0]["values"][0], statements[0]["values"][1] = "GENERATED", "OUTSIDER"
            query(prepared_transaction(statements), succeeds=False)
            assert query("SELECT owner FROM qbhousing_properties WHERE id='generated';") == "OWNER", "A collating ID must not overwrite another property."
            query("""
                INSERT INTO qbhousing_properties(id,owner,definition) VALUES ('building','OWNER','{}'),('unit','OWNER','{}');
                INSERT INTO qbhousing_units(property_id,parent_id,unit_label) VALUES ('unit','building','1');
                INSERT INTO qbhousing_coowners(property_id,citizenid) VALUES ('legacy_home','COOWNER');
                INSERT INTO qbhousing_permissions(property_id,citizenid,action,allowed) VALUES ('legacy_home','KEYHOLDER','entry',0);
            """)
            assert query("SELECT allowed FROM qbhousing_permissions WHERE property_id='legacy_home' AND citizenid='KEYHOLDER';") == "0"
            for statement in (
                "INSERT INTO qbhousing_coowners(property_id,citizenid) VALUES ('legacy_home','COOWNER');",
                "INSERT INTO qbhousing_permissions(property_id,citizenid,action,allowed) VALUES ('legacy_home','KEYHOLDER','entry',1);",
                "INSERT INTO qbhousing_units(property_id,parent_id) VALUES ('legacy_home','missing');",
                "INSERT INTO qbhousing_coowners(property_id,citizenid) VALUES ('missing','COOWNER');",
                "DELETE FROM qbhousing_properties WHERE id='building';",
            ):
                query(statement, succeeds=False)
            query("""
                START TRANSACTION;
                UPDATE qbhousing_properties SET owner='CHANGED' WHERE id='legacy_home';
                INSERT INTO qbhousing_coowners(property_id,citizenid) VALUES ('legacy_home','COOWNER');
                COMMIT;
            """, succeeds=False)
            assert query("SELECT owner FROM qbhousing_properties WHERE id='legacy_home';") == "OWNER"
            # Use the actual sale service's emitted statements against real tables.
            sale_capture = subprocess.run(["lua", "-"], cwd=migrations.parent, text=True, capture_output=True, check=True, input="""
                local f = dofile('tests/domain_fixture.lua')()
                assert(f.housing.sales.completeSale(2, 'offer'))
                local call = f.bankCalls[1]
                print(f.json.encode({ key = call.key, request = call.request, row = f.db.transactions[call.key] }))
            """)
            sale = json.loads(sale_capture.stdout)
            query("""
                INSERT INTO qbhousing_properties(id,owner,definition,property_type,revision,ownership_revision)
                  VALUES ('home','OWNER','{"id":"home","owner":"OWNER"}','land',1,1);
                INSERT INTO qbhousing_listings(id,property_id,channel,seller,biography,price,status,ownership_revision,created_at)
                  VALUES ('listing','home','private','OWNER','Home',5000,'active',1,100);
                INSERT INTO qbhousing_offers(id,listing_id,buyer,amount,status,created_at)
                  VALUES ('offer','listing','BUYER',5000,'accepted',100),('other','listing','SECOND',5000,'submitted',100);
            """)
            for invalid in (
                "INSERT INTO qbhousing_listings(id,property_id,channel,biography,price,status,ownership_revision,created_at) VALUES ('duplicate','home','public','Duplicate',1,'active',1,100);",
                "UPDATE qbhousing_offers SET status='accepted' WHERE id='other';",
            ):
                query(invalid, succeeds=False)
            journal = sale["row"]
            query("INSERT INTO qbhousing_transactions(id,property_id,kind,actor,status,request,result,created_at,updated_at) VALUES (" + ",".join(literal(v) for v in (
                sale["key"], "home", "sale", "BUYER", "pending", journal["request"], journal["result"], 100, 100,
            )) + ");")
            query("INSERT INTO qbhousing_transactions(id,property_id,kind,status,request,result,created_at,updated_at) VALUES ('duplicate-op','home','sale','pending','{}','{}',100,100);", succeeds=False)
            query(prepared_transaction(sale["request"]["statements"]))
            assert query("SELECT owner,revision,ownership_revision FROM qbhousing_properties WHERE id='home';") == "BUYER\t2\t2"
            assert query("SELECT status FROM qbhousing_offers WHERE id='offer';") == "completed"
            assert query("SELECT status FROM qbhousing_offers WHERE id='other';") == "superseded"
            assert query("SELECT SUM(amount),COUNT(*) FROM qbhousing_ledger WHERE operation_id=" + literal(sale["key"]) + ";") == "0\t2"
            assert query("SELECT status FROM qbhousing_transactions WHERE id=" + literal(sale["key"]) + ";") == "completed"
            query("""
                INSERT INTO qbhousing_leases(id,property_id,tenant,landlord,interval_name,rent,permissions,status,ownership_revision,created_at)
                  VALUES ('lease','home','TENANT','BUYER','daily',100,'{}','active',2,100);
            """)
            query("INSERT INTO qbhousing_leases(id,property_id,tenant,landlord,interval_name,rent,permissions,status,ownership_revision,created_at) VALUES ('lease-duplicate','home','OTHER','BUYER','weekly',100,'{}','proposed',2,100);", succeeds=False)
            query("INSERT INTO qbhousing_rent_periods(lease_id,period_start,period_end,amount,status,operation_id) VALUES ('lease',100,86500,100,'paid','period-1');")
            query("INSERT INTO qbhousing_rent_periods(lease_id,period_start,period_end,amount,status,operation_id) VALUES ('lease',100,86500,100,'paid','period-duplicate');", succeeds=False)
            query("INSERT INTO qbhousing_storage_purchases(property_id,tier,operation_id,buyer) VALUES ('home',2,'storage-1','BUYER');")
            query("INSERT INTO qbhousing_storage_purchases(property_id,tier,operation_id,buyer) VALUES ('home',2,'storage-duplicate','BUYER');", succeeds=False)
            print(f"Housing migrations: PASS ({version}); repeat application, legacy backup/checksum, actual stock ownership/key/backup and populated fixture import/upgrade with replay and rollback protection, actual registry/sale SQL, balanced ledger, collating ID rejection, unique active listings/accepted offers/leases/pending operations/rent periods/storage tiers, foreign keys and rollback.")
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    main()
