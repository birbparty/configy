import std/[unittest, os, strutils]
import configy

const TestApp = "testapp"
const TestDep = "teststore"

proc cleanTestDir() =
  try: removeDir(configDir(TestApp, TestDep))
  except: discard

suite "JSON round-trip":
  setup:
    discard ensureConfigDir(TestApp, TestDep)
  teardown:
    cleanTestDir()

  test "raw JSON write and read":
    let data = %*{"key": "value", "num": 42}
    writeConfigJson(TestApp, TestDep, "raw.json", data)
    let r = readConfigJson(TestApp, TestDep, "raw.json")
    check r.isSome
    check r.get["key"].getStr == "value"
    check r.get["num"].getInt == 42

  test "compressed JSON write and read":
    let data = %*{"hello": "world"}
    writeConfigJson(TestApp, TestDep, "compressed.json", data, compress = true)
    let r = readConfigJson(TestApp, TestDep, "compressed.json")
    check r.isSome
    check r.get["hello"].getStr == "world"

  test "pretty JSON write and read":
    let data = %*{"pretty": true}
    writeConfigJson(TestApp, TestDep, "pretty.json", data, pretty = true)
    let r = readConfigJson(TestApp, TestDep, "pretty.json")
    check r.isSome
    check r.get["pretty"].getBool == true

  test "missing file returns none":
    let r = readConfigJson(TestApp, TestDep, "nonexistent.json")
    check r.isNone

suite "Binary round-trip":
  setup:
    discard ensureConfigDir(TestApp, TestDep)
  teardown:
    cleanTestDir()

  test "raw bytes write and read":
    let data = "hello binary world"
    writeConfigBytes(TestApp, TestDep, "raw.bin", data)
    let r = readConfigBytes(TestApp, TestDep, "raw.bin")
    check r.isSome
    check r.get == data

  test "compressed bytes write and read":
    let data = "compress this data " & strutils.repeat("x", 100)
    writeConfigBytes(TestApp, TestDep, "compressed.bin", data, compress = true)
    let r = readConfigBytes(TestApp, TestDep, "compressed.bin")
    check r.isSome
    check r.get == data

  test "Snappy round-trip correctness on tiny input":
    let data = "x"
    writeConfigBytes(TestApp, TestDep, "tiny.bin", data, compress = true)
    let r = readConfigBytes(TestApp, TestDep, "tiny.bin")
    check r.isSome
    check r.get == data

  test "missing binary file returns none":
    let r = readConfigBytes(TestApp, TestDep, "nonexistent.bin")
    check r.isNone

  test "empty data raises ConfigParseError":
    expect ConfigParseError:
      writeConfigBytes(TestApp, TestDep, "empty.bin", "")

suite "Typed generic round-trip":
  type
    Settings = object
      volume: float
      fullscreen: bool

  setup:
    discard ensureConfigDir(TestApp, TestDep)
  teardown:
    cleanTestDir()

  test "writeConfig and readConfig round-trip":
    let s = Settings(volume: 0.8, fullscreen: true)
    writeConfig(TestApp, TestDep, "settings.json", s)
    let r = readConfig[Settings](TestApp, TestDep, "settings.json")
    check r.isSome
    check r.get.volume == 0.8
    check r.get.fullscreen == true

  test "compressed generic round-trip":
    let s = Settings(volume: 0.5, fullscreen: false)
    writeConfig(TestApp, TestDep, "settings_c.json", s, compress = true)
    let r = readConfig[Settings](TestApp, TestDep, "settings_c.json")
    check r.isSome
    check r.get.volume == 0.5

  test "missing file returns none":
    let r = readConfig[Settings](TestApp, TestDep, "missing_settings.json")
    check r.isNone

  test "type conversion failure raises ConfigParseError":
    writeConfigJson(TestApp, TestDep, "bad_type.json", %*42)
    expect ConfigParseError:
      discard readConfig[Settings](TestApp, TestDep, "bad_type.json")

suite "Error cases":
  setup:
    discard ensureConfigDir(TestApp, TestDep)
  teardown:
    cleanTestDir()

  test "0-byte file raises ConfigParseError":
    let path = configFile(TestApp, TestDep, "zero.bin")
    writeFile(path, "")
    expect ConfigParseError:
      discard readConfigBytes(TestApp, TestDep, "zero.bin")

  test "1-byte raw file (magic only) raises ConfigParseError":
    let path = configFile(TestApp, TestDep, "magic_only.bin")
    writeFile(path, "\x00")
    expect ConfigParseError:
      discard readConfigBytes(TestApp, TestDep, "magic_only.bin")

  test "1-byte Snappy file (magic only) raises ConfigParseError":
    let path = configFile(TestApp, TestDep, "snappy_only.bin")
    writeFile(path, "\x01")
    expect ConfigParseError:
      discard readConfigBytes(TestApp, TestDep, "snappy_only.bin")

  test "unknown magic byte raises ConfigParseError":
    let path = configFile(TestApp, TestDep, "bad_magic.bin")
    writeFile(path, "\xFF" & "some data")
    expect ConfigParseError:
      discard readConfigBytes(TestApp, TestDep, "bad_magic.bin")

  test "corrupt Snappy payload raises ConfigParseError":
    let path = configFile(TestApp, TestDep, "corrupt_snappy.bin")
    writeFile(path, "\x01" & "not valid snappy data at all !@#$")
    expect ConfigParseError:
      discard readConfigBytes(TestApp, TestDep, "corrupt_snappy.bin")

  test "cross-format: bytes file read as JSON raises ConfigParseError":
    writeConfigBytes(TestApp, TestDep, "bytes_as_json.bin", "hello binary")
    expect ConfigParseError:
      discard readConfigJson(TestApp, TestDep, "bytes_as_json.bin")

suite "File management":
  setup:
    discard ensureConfigDir(TestApp, TestDep)
  teardown:
    cleanTestDir()

  test "configFileExists returns false for missing file":
    check not configFileExists(TestApp, TestDep, "doesnotexist.json")

  test "configFileExists returns true after write":
    writeConfigJson(TestApp, TestDep, "exists.json", %*{"x": 1})
    check configFileExists(TestApp, TestDep, "exists.json")

  test "deleteConfig returns false for missing file":
    check not deleteConfig(TestApp, TestDep, "nothere.json")

  test "deleteConfig removes existing file and returns true":
    writeConfigJson(TestApp, TestDep, "to_delete.json", %*{"y": 2})
    check configFileExists(TestApp, TestDep, "to_delete.json")
    check deleteConfig(TestApp, TestDep, "to_delete.json")
    check not configFileExists(TestApp, TestDep, "to_delete.json")
