{.used.}

## Tests for tiered storage via ATTACH DATABASE functionality

import
  std/[os, options, strutils],
  testutils/unittests,
  ../../eth/db/[kvstore, kvstore_sqlite3]

procSuite "SqStoreRef Tiered Storage":
  let testDir = getTempDir() / "nim_eth_tiered_test"

  setup:
    # Clean up any previous test artifacts
    removeDir(testDir)
    createDir(testDir)

  teardown:
    removeDir(testDir)

  test "Backward compatibility - no schema uses main database":
    let db = SqStoreRef.init(testDir, "main", inMemory = false)[]
    defer: db.close()

    # Open kvstore without schema (original behavior)
    let kv = db.openKvStore("test_table").expect("open kvstore")
    defer: kv[].close()

    # Basic operations should work
    check kv.put([byte 1, 2, 3], [byte 4, 5, 6]).isOk

    var retrieved: seq[byte]
    check kv.get([byte 1, 2, 3], proc(data: openArray[byte]) =
      retrieved = @data
    ).expect("get") == true

    check retrieved == @[byte 4, 5, 6]

  test "Attach database and create kvstore":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    # Attach a secondary database
    let coldPath = testDir / "cold" / "cold.sqlite3"
    let attached = db.attachDatabase(coldPath, "cold")
    check attached.isOk
    check attached.get().schema == "cold"
    check attached.get().path == coldPath

    # Verify cold directory was created
    check dirExists(testDir / "cold")

    # Create kvstore in attached database
    let coldKv = db.openKvStore("cold_data", schema = "cold")
    check coldKv.isOk
    defer: coldKv.get()[].close()

    # Write and read data
    check coldKv.get().put([byte 10, 20], [byte 30, 40]).isOk

    var retrieved: seq[byte]
    check coldKv.get().get([byte 10, 20], proc(data: openArray[byte]) =
      retrieved = @data
    ).expect("get") == true

    check retrieved == @[byte 30, 40]

  test "Quote database paths and identifiers":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    let attached = db.attachDatabase(
      testDir / "cold tier's.sqlite3", "123")
    check attached.isOk

    let kv = db.openKvStore("select\"archive", schema = "123")
      .expect("quoted kvstore")
    defer: kv[].close()

    check kv.put([byte 1], [byte 2]).isOk
    var value: seq[byte]
    check kv.get([byte 1], proc(data: openArray[byte]) =
      value = @data
    ).expect("get")
    check value == @[byte 2]

    let keywordSchema = db.attachDatabase(
      testDir / "keyword.sqlite3", "select")
    check keywordSchema.isOk
    let keywordKv = db.openKvStore("group", schema = "select")
      .expect("keyword kvstore")
    defer: keywordKv[].close()
    check keywordKv.put([byte 3], [byte 4]).isOk

  test "Read-only attachment rejects writes":
    let archivePath = testDir / "archive.sqlite3"

    block:
      let db = SqStoreRef.init(testDir, "writer")[]
      defer: db.close()
      discard db.attachDatabase(archivePath, "archive").expect("attach")
      let kv = db.openKvStore("data", schema = "archive").expect("kvstore")
      defer: kv[].close()
      check kv.put([byte 1], [byte 2]).isOk

    block:
      let db = SqStoreRef.init(testDir, "reader")[]
      defer: db.close()
      let attached = db.attachDatabase(
        archivePath, "archive", readOnly = true).expect("read-only attach")
      check attached.readOnly

      let kv = db.openKvStore("data", schema = "archive")
        .expect("read-only kvstore")
      defer: kv[].close()

      var value: seq[byte]
      check kv.get([byte 1], proc(data: openArray[byte]) =
        value = @data
      ).expect("get")
      check value == @[byte 2]
      check kv.put([byte 2], [byte 3]).isErr
      check db.exec("DELETE FROM \"archive\".\"data\";").isErr

  test "Read-only attachment does not create missing directories":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    let missingDir = testDir / "missing"
    check db.attachDatabase(
      missingDir / "archive.sqlite3", "archive", readOnly = true).isErr
    check not dirExists(missingDir)

  test "Multiple attached databases (tiered storage)":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    # Attach hot (SSD) and cold (HDD) databases
    let hotAttached = db.attachDatabase(testDir / "hot.sqlite3", "hot")
    let coldAttached = db.attachDatabase(testDir / "cold.sqlite3", "cold")

    check hotAttached.isOk
    check coldAttached.isOk

    # Create stores in each tier
    let mainKv = db.openKvStore("metadata").expect("main kv")
    let hotKv = db.openKvStore("recent_blocks", schema = "hot").expect("hot kv")
    let coldKv = db.openKvStore("old_blocks", schema = "cold").expect("cold kv")

    defer:
      mainKv[].close()
      hotKv[].close()
      coldKv[].close()

    # Write to each tier
    check mainKv.put([byte 0], [byte 0, 0]).isOk
    check hotKv.put([byte 1], [byte 1, 1]).isOk
    check coldKv.put([byte 2], [byte 2, 2]).isOk

    # Verify data is in correct stores
    var val: seq[byte]

    check mainKv.get([byte 0], proc(d: openArray[byte]) = val = @d).get() == true
    check val == @[byte 0, 0]

    check hotKv.get([byte 1], proc(d: openArray[byte]) = val = @d).get() == true
    check val == @[byte 1, 1]

    check coldKv.get([byte 2], proc(d: openArray[byte]) = val = @d).get() == true
    check val == @[byte 2, 2]

    # Verify data is NOT in wrong stores
    check mainKv.get([byte 1], proc(d: openArray[byte]) = discard).get() == false
    check hotKv.get([byte 2], proc(d: openArray[byte]) = discard).get() == false
    check coldKv.get([byte 0], proc(d: openArray[byte]) = discard).get() == false

  test "Get attached databases list":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    check db.getAttachedDatabases().len == 0

    discard db.attachDatabase(testDir / "db1.sqlite3", "tier1")
    discard db.attachDatabase(testDir / "db2.sqlite3", "tier2")

    let attached = db.getAttachedDatabases()
    check attached.len == 2

    var schemas: seq[string]
    for a in attached:
      schemas.add(a.schema)

    check "tier1" in schemas
    check "tier2" in schemas

  test "Detach database":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    # Note: "temp" is a reserved schema name in SQLite (used for temporary tables)
    let attachResult = db.attachDatabase(testDir / "archive.sqlite3", "archive")
    check attachResult.isOk
    check db.getAttachedDatabases().len == 1

    # Create and use a kvstore
    let kv = db.openKvStore("data", schema = "archive").expect("kv")
    check kv.put([byte 1], [byte 2]).isOk
    kv[].close()

    # Detach
    check db.detachDatabase("archive").isOk
    check db.getAttachedDatabases().len == 0

    # Cannot open kvstore in detached database
    let kv2 = db.openKvStore("data", schema = "archive")
    check kv2.isErr

  test "Error: attach same schema twice":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    let first = db.attachDatabase(testDir / "db1.sqlite3", "myschema")
    check first.isOk

    let second = db.attachDatabase(testDir / "db2.sqlite3", "myschema")
    check second.isErr
    check "already attached" in second.error

  test "Error: invalid schema name":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    # Schema with spaces
    check db.attachDatabase(testDir / "db.sqlite3", "my schema").isErr

    # Schema with special characters
    check db.attachDatabase(testDir / "db.sqlite3", "my-schema").isErr
    check db.attachDatabase(testDir / "db.sqlite3", "my.schema").isErr

    # Empty schema
    check db.attachDatabase(testDir / "db.sqlite3", "").isErr

    # Reserved names are case-insensitive
    check db.attachDatabase(testDir / "main.sqlite3", "MAIN").isErr
    check db.attachDatabase(testDir / "temp.sqlite3", "Temp").isErr

    # Valid schemas
    check db.attachDatabase(testDir / "db1.sqlite3", "valid_schema").isOk
    check db.attachDatabase(testDir / "db2.sqlite3", "ValidSchema123").isOk

  test "Error: open kvstore with non-existent schema":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    let kv = db.openKvStore("data", schema = "nonexistent")
    check kv.isErr
    check "not attached" in kv.error

  test "Checkpoint specific database":
    let db = SqStoreRef.init(testDir, "main", manualCheckpoint = true)[]
    defer: db.close()

    discard db.attachDatabase(testDir / "cold.sqlite3", "cold")

    let mainKv = db.openKvStore("data").expect("main kv")
    let coldKv = db.openKvStore("cold_data", schema = "cold").expect("cold kv")
    defer:
      mainKv[].close()
      coldKv[].close()

    # Write some data
    for i in 0'u8..<100'u8:
      check mainKv.put([byte i], [byte i, byte i]).isOk
      check coldKv.put([byte i], [byte i, byte i, byte i]).isOk

    # Checkpoint main database
    db.checkpointDatabase("", SqStoreCheckpointKind.passive)

    # Checkpoint cold database
    db.checkpointDatabase("cold", SqStoreCheckpointKind.passive)

  test "Data persists after close and reopen":
    block:
      let db = SqStoreRef.init(testDir, "main")[]
      discard db.attachDatabase(testDir / "cold.sqlite3", "cold")

      let mainKv = db.openKvStore("metadata").expect("main")
      let coldKv = db.openKvStore("archive", schema = "cold").expect("cold")

      check mainKv.put([byte 1, 2, 3], [byte 10, 20, 30]).isOk
      check coldKv.put([byte 4, 5, 6], [byte 40, 50, 60]).isOk

      mainKv[].close()
      coldKv[].close()
      db.close()

    # Reopen and verify
    block:
      let db = SqStoreRef.init(testDir, "main")[]
      defer: db.close()

      # Reattach cold database
      discard db.attachDatabase(testDir / "cold.sqlite3", "cold")

      let mainKv = db.openKvStore("metadata").expect("main")
      let coldKv = db.openKvStore("archive", schema = "cold").expect("cold")
      defer:
        mainKv[].close()
        coldKv[].close()

      var val: seq[byte]

      check mainKv.get([byte 1, 2, 3], proc(d: openArray[byte]) = val = @d).get() == true
      check val == @[byte 10, 20, 30]

      check coldKv.get([byte 4, 5, 6], proc(d: openArray[byte]) = val = @d).get() == true
      check val == @[byte 40, 50, 60]

  test "Multiple tables in same attached database":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    discard db.attachDatabase(testDir / "cold.sqlite3", "cold")

    # Create multiple tables in the cold database
    let blocks = db.openKvStore("blocks", schema = "cold").expect("blocks")
    let states = db.openKvStore("states", schema = "cold").expect("states")
    let blobs = db.openKvStore("blobs", schema = "cold").expect("blobs")

    defer:
      blocks[].close()
      states[].close()
      blobs[].close()

    # Each table is independent
    check blocks.put([byte 1], [byte 1]).isOk
    check states.put([byte 1], [byte 2]).isOk
    check blobs.put([byte 1], [byte 3]).isOk

    var val: seq[byte]
    check blocks.get([byte 1], proc(d: openArray[byte]) = val = @d).get() == true
    check val == @[byte 1]

    check states.get([byte 1], proc(d: openArray[byte]) = val = @d).get() == true
    check val == @[byte 2]

    check blobs.get([byte 1], proc(d: openArray[byte]) = val = @d).get() == true
    check val == @[byte 3]

  test "Contains operation works with schema":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    discard db.attachDatabase(testDir / "cold.sqlite3", "cold")

    let kv = db.openKvStore("data", schema = "cold").expect("kv")
    defer: kv[].close()

    check kv.put([byte 1, 2, 3], [byte 0]).isOk

    check kv.contains([byte 1, 2, 3]).get() == true
    check kv.contains([byte 4, 5, 6]).get() == false

  test "Delete operation works with schema":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    discard db.attachDatabase(testDir / "cold.sqlite3", "cold")

    let kv = db.openKvStore("data", schema = "cold").expect("kv")
    defer: kv[].close()

    check kv.put([byte 1], [byte 10]).isOk
    check kv.put([byte 2], [byte 20]).isOk

    check kv.contains([byte 1]).get() == true
    check kv.del([byte 1]).get() == true
    check kv.contains([byte 1]).get() == false
    check kv.contains([byte 2]).get() == true

  test "Clear operation works with schema":
    let db = SqStoreRef.init(testDir, "main")[]
    defer: db.close()

    discard db.attachDatabase(testDir / "cold.sqlite3", "cold")

    let kv = db.openKvStore("data", schema = "cold").expect("kv")
    defer: kv[].close()

    check kv.put([byte 1], [byte 10]).isOk
    check kv.put([byte 2], [byte 20]).isOk
    check kv.put([byte 3], [byte 30]).isOk

    check kv.clear().get() == true

    check kv.contains([byte 1]).get() == false
    check kv.contains([byte 2]).get() == false
    check kv.contains([byte 3]).get() == false
