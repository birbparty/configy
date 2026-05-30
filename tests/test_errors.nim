import std/[unittest, os]
import configy

suite "ConfigError hierarchy":
  test "all subtypes are catchable as ConfigError":
    proc raiseConfigPathError() = raise newException(ConfigPathError, "test")
    proc raiseConfigIOError() = raise newException(ConfigIOError, "test")
    proc raiseConfigParseError() = raise newException(ConfigParseError, "test")
    proc raiseConfigUnsupportedError() = raise newException(ConfigUnsupportedError, "test")

    var caught = false
    try: raiseConfigPathError()
    except ConfigError: caught = true
    check caught

    caught = false
    try: raiseConfigIOError()
    except ConfigError: caught = true
    check caught

    caught = false
    try: raiseConfigParseError()
    except ConfigError: caught = true
    check caught

    caught = false
    try: raiseConfigUnsupportedError()
    except ConfigError: caught = true
    check caught

  test "ConfigPathError is raised for bad component":
    expect ConfigPathError: validateComponent("")
    expect ConfigPathError: validateComponent("/")
    expect ConfigPathError: validateComponent("..")

  test "ConfigParseError on 0-byte file":
    discard ensureConfigDir("testapp", "testerr")
    let path = configFile("testapp", "testerr", "zero.bin")
    writeFile(path, "")
    defer:
      discard tryRemoveFile(path)
      try: removeDir(configDir("testapp", "testerr"))
      except: discard
    expect ConfigParseError:
      discard readConfigBytes("testapp", "testerr", "zero.bin")

  test "ConfigUnsupportedError on read-only target":
    # This test executes only on 3DS/PSP/WASM (configyFsWritable=false).
    # On desktop/Windows/Vita it skips — verified by code inspection that
    # writeConfigJson raises ConfigUnsupportedError when not isWritable().
    when not configyFsWritable:
      expect ConfigUnsupportedError:
        writeConfigJson("x", "y", "f.json", %*{"a": 1})
    else:
      skip()
